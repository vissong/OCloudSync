import Foundation

public enum DateRepairPolicy {
  /// A duplicate found in the library is never owned by this importer.
  public static func owns(_ record: SyncRecord, photoID: String, hash: String?) -> Bool {
    guard let hash, !hash.isEmpty else { return false }
    return record.state == .imported && record.photoID == photoID && record.sha256 == hash
  }
  public static func same(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
    default: return false
    }
  }
  /// Preserve dates edited in Photos after a date was explicitly set by this app.
  public static func mayRepair(current: Date?, previousManaged: Date?) -> Bool {
    previousManaged == nil || same(current, previousManaged)
  }
}
