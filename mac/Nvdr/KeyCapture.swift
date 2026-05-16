// `@preconcurrency`: CGEvent isn't `Sendable`, but the event-tap callback is
// invoked synchronously on the main run loop, so handing the event to a
// `MainActor` closure never actually crosses a thread boundary.
@preconcurrency import CoreGraphics
import Foundation
import IOKit.hid
import Observation

/// System-wide low-level keyboard hook.
///
/// Two cooperating mechanisms, both deliberately lower-level than anything
/// SwiftUI or AppKit exposes:
///
/// 1. A **`CGEventTap`** at `.cghidEventTap` sees every keyDown / keyUp /
///    flagsChanged before any application *or* the system (so ⌘Q, ⌘Tab,
///    ⌘Space are ours to forward, not the local Mac's). With `.defaultTap`
///    we can also *swallow* events — while forwarding is on, keystrokes go
///    only to the remote NVDA and never act on this Mac.
///
/// 2. An **`IOHIDManager`** reads Caps Lock straight off the HID layer. The
///    normal event API only reports Caps Lock as a *toggle* (one event per
///    press, no release) — that is the "press it twice" bug from the iOS
///    build. The HID report gives a clean down(1) / up(0) per physical
///    press, so Caps Lock works as a real held NVDA modifier.
///
/// The reference Windows add-on (`addon/globalPlugins/nvdrBridge`) toggles
/// forwarding with NVDA+F11; we reproduce that as **Caps Lock + F11** (or
/// Ctrl+Option+F11 when the NVDA modifier is set to VO keys), recognised
/// from anywhere regardless of which app is focused.
///
/// Callbacks are scheduled on the main run loop, so the C trampolines below
/// can hop straight onto the main actor with `assumeIsolated`.
@MainActor
@Observable
final class KeyCapture {
    enum State: Equatable {
        case stopped
        case needsAccessibility
        case needsInputMonitoring
        case running
    }

    private(set) var state: State = .stopped

    private let bridge: BridgeClient
    private let settings: AppSettings

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var hidManager: IOHIDManager?

    /// Physical Caps Lock state, from the HID hook (not the toggle LED).
    @ObservationIgnored private var capsHeld = false
    /// True once we've forwarded a Caps Lock *down* — guards the matching up
    /// so a Caps Lock press that merely armed `capslock+F11` is never sent.
    @ObservationIgnored private var capsForwarded = false
    /// Physical down-state of the non-Caps modifiers. `flagsChanged` only
    /// reports a transition, not a direction, so we recover it by toggling.
    @ObservationIgnored private var downModifiers: Set<CGKeyCode> = []

    init(bridge: BridgeClient, settings: AppSettings) {
        self.bridge = bridge
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Install both hooks. If a permission is missing, sets `state` to the
    /// matching `.needs…` case and fires the system prompt instead.
    func start() {
        stop()

        guard Permissions.hasAccessibility else {
            state = .needsAccessibility
            Permissions.requestAccessibility()
            return
        }
        guard Permissions.hasInputMonitoring else {
            state = .needsInputMonitoring
            Permissions.requestInputMonitoring()
            return
        }
        guard installEventTap() else {
            // Accessibility flipped on but the tap still failed — usually a
            // just-granted permission that needs another beat.
            state = .needsAccessibility
            return
        }
        installHIDManager()
        state = .running
    }

    /// Re-run `start()` — used by the permissions banner's "Recheck" button
    /// after the user grants access in System Settings.
    func recheck() { start() }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil

        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(
                hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil

        capsHeld = false
        capsForwarded = false
        downModifiers.removeAll()
        if state == .running { state = .stopped }
    }

    // MARK: Forwarding toggle

    /// Flip forwarding on/off. Called by `capslock+F11`, the menu command,
    /// and the on-screen toggle. Clears modifier bookkeeping so a chord held
    /// across the toggle can't strand a key on the remote.
    func toggleForwarding() {
        bridge.forwardingEnabled.toggle()
        downModifiers.removeAll()
        capsForwarded = false
    }

    // MARK: Install helpers

    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyCaptureEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func installHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match physical keyboards…
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        // …and, within them, only the Caps Lock element.
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager, keyCaptureHIDValueCallback, Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    // MARK: Event handling (called from the C trampolines, on the main actor)

    /// Returns the event to let it through, or `nil` to swallow it.
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or interrupted — re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // capslock+F11 (NVDA+F11) toggles forwarding from anywhere. Swallow
        // every F11 transition while the NVDA modifier is held so it neither
        // triggers Mission Control nor leaks to the remote.
        if keyCode == MacKeyCode.f11, nvdaModifierHeld(event) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat {
                toggleForwarding()
            }
            return nil
        }

        switch type {
        case .keyDown, .keyUp:
            guard bridge.forwardingEnabled else { return Unmanaged.passUnretained(event) }
            if let vk = MacKeyVK.vk(
                forKeyCode: keyCode,
                leftOptionMapping: settings.leftOptionMapping,
                rightOptionMapping: settings.rightOptionMapping,
                commandMapping: settings.commandMapping
            ) {
                bridge.sendKey(vk: vk, pressed: type == .keyDown)
            }
            // Swallow everything while forwarding — even unmapped keys — so
            // the local Mac never reacts to a keystroke meant for the slave.
            return nil

        case .flagsChanged:
            return handleFlagsChanged(keyCode: keyCode, event: event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Caps Lock comes through the HID hook with a real direction. Here we
        // only suppress the synthetic toggle so it can't flip local Caps
        // state while forwarding.
        if keyCode == MacKeyCode.capsLock {
            return bridge.forwardingEnabled ? nil : Unmanaged.passUnretained(event)
        }

        let pressed: Bool
        if downModifiers.contains(keyCode) {
            downModifiers.remove(keyCode)
            pressed = false
        } else {
            downModifiers.insert(keyCode)
            pressed = true
        }

        guard bridge.forwardingEnabled else { return Unmanaged.passUnretained(event) }
        if let vk = MacKeyVK.vk(
            forKeyCode: keyCode,
            leftOptionMapping: settings.leftOptionMapping,
            rightOptionMapping: settings.rightOptionMapping,
            commandMapping: settings.commandMapping
        ) {
            bridge.sendKey(vk: vk, pressed: pressed)
        }
        return nil
    }

    /// Raw Caps Lock press/release straight from the HID report.
    func handleCapsLock(pressed: Bool) {
        capsHeld = pressed
        if pressed {
            if bridge.forwardingEnabled {
                bridge.sendKey(vk: VK.capital, pressed: true)
                capsForwarded = true
            }
        } else {
            if capsForwarded, bridge.forwardingEnabled {
                bridge.sendKey(vk: VK.capital, pressed: false)
            }
            capsForwarded = false
        }
    }

    /// Is the configured NVDA modifier physically held right now? Caps Lock
    /// comes from the HID hook; VO keys (Ctrl+Option) from the live flags.
    private func nvdaModifierHeld(_ event: CGEvent) -> Bool {
        switch settings.nvdaModifier {
        case .capsLock:
            return capsHeld
        case .voKeys:
            return event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate)
        }
    }
}

// MARK: - C callback trampolines

/// `CGEventTapCallBack`. Runs on the main run loop, so we can assume the main
/// actor and call straight into `KeyCapture`.
private func keyCaptureEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        capture.handleEvent(type: type, event: event)
    }
}

/// `IOHIDValueCallback` for the matched Caps Lock element.
private func keyCaptureHIDValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let capture = Unmanaged<KeyCapture>.fromOpaque(context).takeUnretainedValue()
    let pressed = IOHIDValueGetIntegerValue(value) != 0
    MainActor.assumeIsolated {
        capture.handleCapsLock(pressed: pressed)
    }
}
