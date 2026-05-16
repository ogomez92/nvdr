import SwiftUI
import UIKit

/// Hosts a `UIView` that becomes first responder so attached Bluetooth
/// keyboard events flow through `pressesBegan`/`pressesEnded`. UIKit is the
/// only path that exposes raw HID press events; SwiftUI's keyboard shortcuts
/// abstract too aggressively (no key-up, no individual modifiers).
///
/// Mirrors the Python add-on's `_hook_keyDown` / `_hook_keyUp` in
/// `addon/globalPlugins/nvdrBridge/__init__.py`: each press becomes one
/// `key vk pressed=1` IPC line; each release becomes `key vk pressed=0`.
struct KeyboardCapture: UIViewRepresentable {
    let bridge: BridgeClient
    let settings: AppSettings

    func makeUIView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.bridge = bridge
        v.settings = settings
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        Task { @MainActor in _ = v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.bridge = bridge
        view.settings = settings
    }
}

/// First-responder UIView that observes Bluetooth keyboard events and
/// forwards them to the bridge.
final class CaptureView: UIView {
    var bridge: BridgeClient?
    var settings: AppSettings?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Task { @MainActor in _ = self.becomeFirstResponder() }
        }
    }

    /// Make sure the system doesn't pre-empt our keys with default behaviors
    /// (e.g. Cmd+Tab analogues, focus changes). With this true, every key
    /// reaches `pressesBegan` first.
    @objc func _wantsPriorityOverSystemBehaviorWhenKeyboardEvent() -> Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: false) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled press is functionally a release as far as the slave is
        // concerned — emit the up so we don't strand a modifier.
        _ = forward(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }

    /// Returns true if at least one press in the set was claimed (forwarded).
    /// When forwarding is off we always return false so the system can route
    /// the event normally (e.g. keep-alive scrolling, tab focus).
    @discardableResult
    private func forward(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        guard let bridge, bridge.forwardingEnabled else { return false }
        let optionMap = settings?.optionMapping ?? .alt
        let commandMap = settings?.commandMapping ?? .alt
        var claimed = false
        for press in presses {
            guard let key = press.key else { continue }
            guard let vk = HIDToVK.vk(for: key, optionMapping: optionMap, commandMapping: commandMap) else { continue }
            bridge.sendKey(vk: vk, pressed: pressed)
            claimed = true
        }
        return claimed
    }

    /// UIKit also offers `keyCommands` for Cmd-prefixed shortcuts. We don't
    /// need that path because `pressesBegan` already gives us every key, but
    /// returning an empty array prevents the system from synthesizing
    /// menu-bar style shortcuts behind our back.
    override var keyCommands: [UIKeyCommand]? { [] }
}
