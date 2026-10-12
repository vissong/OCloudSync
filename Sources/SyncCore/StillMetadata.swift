import Foundation

public enum StillMetadata {
  public static func validateGPS(_ original: [String: Any]?, _ converted: [String: Any]?) throws {
    guard let original else { return }
    guard let converted else { throw SyncFailure("Location metadata was lost") }
    // ImageIO's HEIC encoder omits the EXIF GPS positioning-method tag. Keep all
    // other source GPS fields exact, including coordinates, references and dates.
    for (key, value) in original where key != "ProcessingMethod" {
      guard let result = converted[key],
        NSDictionary(dictionary: [key: value]).isEqual(to: [key: result])
      else {
        throw SyncFailure("Location metadata changed")
      }
    }
  }
}
