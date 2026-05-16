import AppKit
import ApplicationServices
import IOKit.hid

/// macOS privacy gates nvdr's keyboard hook behind two separate permissions:
///
/// - **Accessibility** — required to create a `CGEventTap`. Without it
///   `CGEvent.tapCreate` returns `nil`, so we can't see (or swallow) keys.
/// - **Input Monitoring** — required to open an `IOHIDManager`. Without it
///   the raw Caps Lock press/release stream is empty.
///
/// Both are granted in System Settings ▸ Privacy & Security and are tied to
/// the app's code signature, so they persist across launches once granted.
enum Permissions {
    // MARK: Accessibility (CGEventTap)

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Triggers the system "… would like to control this computer" prompt and
    /// drops an entry into the Accessibility list so the user can flip it on.
    static func requestAccessibility() {
        // The literal value of `kAXTrustedCheckOptionPrompt` — referenced
        // directly to avoid the non-concurrency-safe imported global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Input Monitoring (IOHIDManager)

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the Input Monitoring prompt. Returns `true` if already granted.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Deep links into System Settings

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
