import CoreFoundation
import Foundation

/// A property-list value that is Sendable, so certificate details (such as a
/// profile's entitlements) can cross actors as plain values.
public enum PlistValue: Sendable, Hashable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// Converts what PropertyListSerialization returns; nil for anything else.
    init?(propertyList value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // NSNumber bridges both <true/> and <integer>; only the CFBoolean
            // singleton is a real boolean.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            self = .array(array.compactMap(PlistValue.init(propertyList:)))
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.compactMapValues(PlistValue.init(propertyList:)))
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
