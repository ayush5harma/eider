import ApplicationServices
import Foundation

/// How much an app's windows hold, read through the Accessibility API: the
/// same count as System Events' "entire contents of window 1", which is how
/// YouTube's empty window was measured (8 elements empty, 79 with content).
/// Needs the Accessibility permission for the process asking (for the CLI, the
/// terminal it runs in); without it the answer is nil and nothing is judged.
enum WindowContent {
    /// Stop counting past this: only "a handful or more" matters.
    static let countLimit = 200
    /// A hung app must not hang the probe.
    private static let messagingTimeout: Float = 1

    /// Accessibility elements inside the app's windows (the windows themselves
    /// not counted), up to `limit`; nil without permission or with no window.
    static func elementCount(pid: Int32, limit: Int = countLimit) -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let windows = children(of: app, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return nil }
        var queue = windows.flatMap { children(of: $0, attribute: kAXChildrenAttribute) }
        var count = 0
        while !queue.isEmpty, count < limit {
            let element = queue.removeFirst()
            count += 1
            queue += children(of: element, attribute: kAXChildrenAttribute)
        }
        return count
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
