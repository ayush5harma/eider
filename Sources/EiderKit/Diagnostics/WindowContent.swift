import ApplicationServices
import Foundation

/// What an app's windows show, read through the Accessibility API. Needs the
/// Accessibility permission for the process asking (for the CLI, the terminal
/// it runs in); without it the answer is nil and nothing is judged.
///
/// Why content and not a count of elements: a Catalyst window always has its
/// title bar (three buttons, one holding a group, and the title) and two
/// nested groups for the scene, so a small window with real content is about
/// as many elements as an empty one. Measured 2026-11-27 on macOS 27.3 with
/// the e2e probe: empty, window > group > group and the title bar (7 elements
/// in all); with its one text field, 8. So content is any element below the
/// window that is neither a group nor part of the title bar (the window's own
/// buttons and title text). An alert sheet or a toolbar is content: in the
/// same day's sweep StikDebug 3.2.2 and SideStore 0.7.0 each showed an alert
/// sheet over a scene group that was empty while the alert was up.
/// (System Events' "entire contents of window 1" answered 0 for every
/// Catalyst window that day, so it is no measure.)
enum WindowContent {
    /// Stop counting past this: only "none or some" matters.
    static let countLimit = 50
    /// A hung app must not hang the probe.
    private static let messagingTimeout: Float = 1
    /// The window's own title bar, at the top level of every Catalyst window.
    private static let titleBarRoles: Set<String> = [kAXButtonRole, kAXStaticTextRole]

    /// Elements below the app's windows that are neither groups nor the title
    /// bar, up to `limit`; nil without permission or with no window.
    static func contentElements(pid: Int32, limit: Int = countLimit) -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let windows = children(of: app, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return nil }
        var queue = windows.flatMap { children(of: $0, attribute: kAXChildrenAttribute) }
            .filter { !titleBarRoles.contains(role(of: $0)) }
        var count = 0
        while !queue.isEmpty, count < limit {
            let element = queue.removeFirst()
            if role(of: element) != kAXGroupRole { count += 1 }
            queue += children(of: element, attribute: kAXChildrenAttribute)
        }
        return count
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
