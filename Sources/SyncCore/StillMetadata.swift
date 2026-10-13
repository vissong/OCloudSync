import Foundation
import CoreFoundation

public enum StillMetadata {
  public static func validateGPS(_ original: [String: Any]?, _ converted: [String: Any]?) throws {
    guard let original else { return }
    guard let converted else { throw SyncFailure("Location metadata was lost") }
    // ImageIO can round camera EXIF rational coordinates when encoding HEIC.
    // Bound that numerical change to 2e-6 degrees (under 0.23 m per axis), not
    // a relative tolerance that grows with longitude. Other fields stay exact.
    // Its previously unsupported positioning-method tag may still be omitted.
    for (key, value) in original where key != "ProcessingMethod" {
      guard let result = converted[key] else {
        throw SyncFailure("Location metadata was lost: \(key)")
      }
      if key == "Latitude" || key == "Longitude" {
        let maximum = key == "Latitude" ? 90.0 : 180.0
        guard let before = coordinate(value, maximum: maximum),
          let after = coordinate(result, maximum: maximum), abs(before - after) <= 0.000002
        else { throw SyncFailure("Location metadata changed: \(key)") }
      } else if !NSDictionary(dictionary: [key: value]).isEqual(to: [key: result]) {
        throw SyncFailure("Location metadata changed: \(key)")
      }
    }
  }

  private static func coordinate(_ value: Any, maximum: Double) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let degrees = number.doubleValue
    return degrees.isFinite && degrees >= 0 && degrees <= maximum ? degrees : nil
  }
}
