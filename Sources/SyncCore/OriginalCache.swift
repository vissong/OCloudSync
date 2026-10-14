import Foundation

public struct CacheStatistics: Sendable, Equatable {
  public var fileCount = 0
  public var entryCount = 0
  public var logicalBytes: Int64 = 0
  public var allocatedBytes: Int64 = 0
}
public struct CacheClearResult: Sendable {
  public let failedEntries: Int
  public let remaining: CacheStatistics
}

/// Only the caller's originals directory is handled. Symbolic links are never traversed.
public enum OriginalCache {
  private static func checkRoot(_ directory: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw SyncFailure("缓存目录不是普通文件夹，已停止清理")
    }
  }
  public static func measure(_ directory: URL) throws -> CacheStatistics {
    try checkRoot(directory)
    let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,
      .totalFileAllocatedSizeKey,.fileAllocatedSizeKey]
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: keys,options: [],errorHandler: { _, error in
        enumerationError = error; return false
      }) else { throw SyncFailure("无法读取原文件缓存目录") }
    var result = CacheStatistics()
    for case let file as URL in enumerator {
      try Task.checkCancellation()
      let values = try file.resourceValues(forKeys: Set(keys))
      result.entryCount += 1
      // Foundation does not descend into symlinks; skipDescendants here can skip the next directory.
      if values.isSymbolicLink == true { continue }
      guard values.isRegularFile == true else { continue }
      result.fileCount += 1
      result.logicalBytes += Int64(values.fileSize ?? 0)
      result.allocatedBytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
    if let enumerationError { throw enumerationError }
    return result
  }
  /// Run while the import pipeline is idle. Failure is reported, never converted to an empty count.
  public static func clear(_ directory: URL) throws -> CacheClearResult {
    try clear(directory, remove: { try FileManager.default.removeItem(at: $0) })
  }
  static func clear(_ directory: URL, remove: (URL) throws -> Void) throws -> CacheClearResult {
    try checkRoot(directory)
    let children = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil)
    var failed = 0
    for child in children {
      // removeItem removes a symlink itself, including links inside a directory, not its target.
      do { try remove(child) } catch { failed += 1 }
    }
    return CacheClearResult(failedEntries: failed,remaining: try measure(directory))
  }
}
