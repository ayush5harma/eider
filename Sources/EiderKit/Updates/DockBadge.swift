import Foundation

/// The number on the Dock tile and the Updates sidebar item, as the App Store
/// shows it: the count of available updates, and no badge at all at zero.
public enum DockBadge {
    public static func label(forUpdateCount count: Int) -> String? {
        count > 0 ? String(count) : nil
    }
}
