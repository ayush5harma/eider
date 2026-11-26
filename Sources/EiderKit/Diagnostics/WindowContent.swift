import ApplicationServices
import Foundation

/// What an app's windows show, read through the Accessibility API. Needs the
/// Accessibility permission for the process asking (for the CLI, the terminal
/// it runs in); without it the answer is nil and nothing is judged.
///
/// Why content and not a count of elements: a Catalyst window always has its
/// title bar (three buttons, a group, the title) and two nested groups for the
/// scene, so a small window with real content is about as many elements as an
/// empty one. Measured 2026-11-27 on macOS 27.3 with the e2e probe: empty,
/// window > group > group and nothing else (7 elements in all); with its one
/// text field, window > group > group > text field (8). Feather 2.9.0, with
/// content: headings and text under the same groups. So content is any element
/// inside the window's groups that is not itself a group. (System Events'
/// "entire contents of window 1" answered 0 for all three that day, so it is
/// no measure.)
enum WindowContent {
    /// Stop counting past this: only "none or some" matters.
    static let countLimit = 50
    /// A hung app must not hang the probe.
    private static let messagingTimeout: Float = 1

    /// Elements other than groups inside the groups of the app's windows, up
    /// to `limit`; nil without permission or with no window.
    static func contentElements(pid: Int32, limit: Int = countLimit) -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let windows = children(of: app, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return nil }
        var queue = windows.flatMap { children(of: $0, attribute: kAXChildrenAttribute) }.filter(isGroup)
        var count = 0
        while !queue.isEmpty, count < limit {
            let element = queue.removeFirst()
            for child in children(of: element, attribute: kAXChildrenAttribute) {
                if !isGroup(child) { count += 1 }
                queue.append(child)
            }
        }
        return count
    }

    private static func isGroup(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return false }
        return (value as? String) == kAXGroupRole
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
