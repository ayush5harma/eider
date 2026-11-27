import EiderCore
import Foundation

extension InstalledApp: InstalledRecord {}

/// The Mac library's update offer; the matching itself is `UpdateChecker` in EiderCore.
public typealias AvailableUpdate = UpdateOffer<InstalledApp>
