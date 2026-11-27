import Foundation

/// The Mac window's sidebar. Kept in EiderKit: the iOS app has tabs of its own.
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case library, updates, browse, activity, sources
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
