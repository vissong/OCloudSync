import XCTest
@testable import SyncCore

final class StillMetadataTests: XCTestCase {
  let source: [String: Any] = [
    "Latitude": 1.234567, "LatitudeRef": "N", "Longitude": 2.345678,
    "LongitudeRef": "E", "Altitude": 12.5, "AltitudeRef": 0,
    "DateStamp": "2030:01:02", "TimeStamp": "03:04:05", "ProcessingMethod": "CELLID",
  ]

  func testCoordinateReencodingRoundingWithinTwoMillionthsOfADegree() throws {
    for delta in [-0.00000166666667, 0.00000166666667] {
      var converted = source
      converted["Latitude"] = 1.234567 + delta
      converted["Longitude"] = 2.345678 - delta
      converted.removeValue(forKey: "ProcessingMethod")
      XCTAssertNoThrow(try StillMetadata.validateGPS(source, converted))
    }
  }

  func testActualCoordinateChangesAreRejected() {
    for field in ["Latitude", "Longitude"] {
      for delta in [-0.00000201, 0.00000201, 0.01] {
        var converted = source
        converted[field] = (source[field] as! Double) + delta
        XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
      }
    }
  }

  func testCoordinateLossReferencesAndOtherGPSFieldsStayStrict() {
    for field in source.keys where field != "ProcessingMethod" {
      var converted = source
      converted.removeValue(forKey: field)
      XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
    }
    for (field, value) in ["LatitudeRef": "S", "LongitudeRef": "W", "DateStamp": "2030:01:03", "TimeStamp": "03:04:06"] {
      var converted = source; converted[field] = value
      XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
    }
    var converted = source; converted["Altitude"] = 12.500001
    XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
    XCTAssertThrowsError(try StillMetadata.validateGPS(source, nil))
  }

  func testInvalidCoordinateNumbersCannotPassEvenIfEqual() {
    for field in ["Latitude", "Longitude"] {
      for value: Any in [Double.nan, Double.infinity, -Double.infinity, 181.0, -1.0, true, "1.234567"] {
        var original = source; original[field] = value
        XCTAssertThrowsError(try StillMetadata.validateGPS(original, original))
        XCTAssertThrowsError(try StillMetadata.validateGPS(source, original))
      }
    }
    var invalidLatitude = source; invalidLatitude["Latitude"] = 91.0
    XCTAssertThrowsError(try StillMetadata.validateGPS(invalidLatitude, invalidLatitude))
  }
}
