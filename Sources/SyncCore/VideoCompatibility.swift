import AVFoundation
import CryptoKit
import Foundation

public struct VideoCompatibilityInfo: Codable, Equatable, Sendable {
  public let sourceHash: String
  public let importHash: String
  public init(sourceHash: String, importHash: String) {
    self.sourceHash = sourceHash; self.importHash = importHash
  }
}
public struct PreparedCompatibleVideo: Sendable {
  public let file: URL
  public let hash: String
  public let info: VideoCompatibilityInfo?
}

public enum VideoCompatibility {
  public static func prepare(_ file: URL, asset: RemoteAsset, sourceHash: String? = nil) async throws -> PreparedCompatibleVideo {
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      guard asset.isVideo else { throw SyncFailure("仅视频可做封装兼容处理") }
      do {
        let hash = try await MediaFileValidator.validate(file, asset: asset)
        guard sourceHash == nil || sourceHash == hash else { throw SyncFailure("视频原文件在兼容处理前发生变化") }
        return PreparedCompatibleVideo(file: file, hash: hash, info: nil)
      } catch is VideoPlaybackUnsupported {
        let hash = try RemoteAsset.hashFile(file)
        guard sourceHash == nil || sourceHash == hash else { throw SyncFailure("视频原文件在兼容处理前发生变化") }
        let plan = try HEVCCompatibility.plan(file)
        try await HEVCCompatibility.checkSamples(file, lengthBytes: plan.lengthBytes, parameterSets: plan.parameterSets)
        let result = try HEVCCompatibility.copy(file, sourceHash: hash, patches: plan.patches)
        let outputHash = try await MediaFileValidator.validate(result.file, asset: asset)
        guard outputHash == result.hash else { throw SyncFailure("兼容副本在校验期间发生变化") }
        return PreparedCompatibleVideo(file: result.file, hash: outputHash,
          info: VideoCompatibilityInfo(sourceHash: hash, importHash: outputHash))
      }
    }
    return try await withTaskCancellationHandler(operation: {
      let result = try await worker.value
      try Task.checkCancellation()
      return result
    }, onCancel: { worker.cancel() })
  }
}

/// Narrow, lossless normalization. No media payload, track, timing or metadata box is rewritten.
enum HEVCCompatibility {
  struct Patch { let offset: Int; let bytes: Data }
  struct Plan { let patches: [Patch]; let lengthBytes: Int; let parameterSets: Set<Data> }
  struct Box { let start: Int; let payload: Int; let end: Int; let type: String }
  static func failure() -> SyncFailure {
    SyncFailure("此 HEVC 视频无法安全无损兼容，保留原文件；未转码或导入")
  }
  static func plan(_ file: URL, entryType: String = "hev1") throws -> Plan {
    let reader = try FileHandle(forReadingFrom: file)
    defer { try? reader.close() }
    let size = try reader.seekToEnd()
    guard size <= UInt64(Int.max) else { throw failure() }
    var boxCount = 0
    func read(_ start: Int, _ count: Int) throws -> Data {
      try Task.checkCancellation()
      guard start >= 0, count >= 0, start <= Int(size), count <= Int(size) - start else { throw failure() }
      try reader.seek(toOffset: UInt64(start))
      guard let data = try reader.read(upToCount: count), data.count == count else { throw failure() }
      return data
    }
    func boxes(_ start: Int, _ end: Int) throws -> [Box] {
      var result = [Box](), cursor = start
      while cursor < end {
        boxCount += 1
        guard boxCount <= 100_000, end - cursor >= 8 else { throw failure() }
        let header = try read(cursor, 8)
        var length = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var headerSize = 8
        if length == 1 {
          guard end - cursor >= 16 else { throw failure() }
          length = try read(cursor + 8, 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
          headerSize = 16
        } else if length == 0 { length = UInt64(end - cursor) }
        guard length >= headerSize, length <= UInt64(end - cursor) else { throw failure() }
        result.append(Box(start: cursor, payload: cursor + headerSize, end: cursor + Int(length),
          type: String(decoding: header.suffix(4), as: UTF8.self)))
        cursor += Int(length)
      }
      return result
    }
    let roots = try boxes(0, Int(size))
    guard roots.filter({ $0.type == "moov" }).count == 1 else { throw failure() }
    var level = roots.filter { $0.type == "moov" }
    for type in ["trak", "mdia", "minf", "stbl", "stsd"] {
      level = try level.flatMap { try boxes($0.payload, $0.end).filter { $0.type == type } }
    }
    var plans = [Plan]()
    for table in level {
      guard table.end - table.payload >= 8 else { throw failure() }
      let header = try read(table.payload, 8)
      guard header.prefix(4).allSatisfy({ $0 == 0 }) else { throw failure() }
      let count = header.suffix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      let entries = try boxes(table.payload + 8, table.end)
      guard entries.count == count else { throw failure() }
      for entry in entries where entry.type == entryType {
        guard entries.count == 1, entry.end - entry.payload >= 78 else { throw failure() }
        let configs = try boxes(entry.payload + 78, entry.end).filter { $0.type == "hvcC" }
        guard configs.count == 1, let config = configs.first, config.end - config.payload <= 1_048_576 else { throw failure() }
        let data = try read(config.payload, config.end - config.payload)
        guard data.count >= 23, data[0] == 1 else { throw failure() }
        let lengthBytes = Int(data[21] & 3) + 1
        guard [1,2,4].contains(lengthBytes) else { throw failure() }
        var patches = [Patch(offset: entry.start + 4, bytes: Data("hvc1".utf8))]
        var cursor = 23, parameterTypes = Set<UInt8>(), parameterSets = Set<Data>()
        for _ in 0..<Int(data[22]) {
          guard data.count - cursor >= 3 else { throw failure() }
          let type = data[cursor] & 0x3f
          let count = Int(data[cursor + 1]) * 256 + Int(data[cursor + 2])
          if [32,33,34].contains(type) {
            guard count > 0 else { throw failure() }
            parameterTypes.insert(type)
            if data[cursor] & 0x80 == 0 {
              patches.append(Patch(offset: config.payload + cursor, bytes: Data([data[cursor] | 0x80])))
            }
          }
          cursor += 3
          for _ in 0..<count {
            guard data.count - cursor >= 2 else { throw failure() }
            let size = Int(data[cursor]) * 256 + Int(data[cursor + 1]); cursor += 2
            guard size >= 2, size <= data.count - cursor, (data[cursor] >> 1) & 0x3f == type else { throw failure() }
            if [32,33,34].contains(type) { parameterSets.insert(data.subdata(in: cursor..<(cursor + size))) }
            cursor += size
          }
        }
        guard cursor == data.count, parameterTypes == [32,33,34] else { throw failure() }
        plans.append(Plan(patches: patches, lengthBytes: lengthBytes, parameterSets: parameterSets))
      }
    }
    guard plans.count == 1, let plan = plans.first else { throw failure() }
    return plan
  }

  static func checkSample(_ data: Data, lengthBytes: Int, parameterSets: Set<Data> = []) throws {
    guard [1,2,4].contains(lengthBytes), !data.isEmpty else { throw failure() }
    var cursor = 0
    while cursor < data.count {
      try Task.checkCancellation()
      guard data.count - cursor >= lengthBytes else { throw failure() }
      let length = data[cursor..<(cursor + lengthBytes)].reduce(0) { ($0 << 8) | Int($1) }
      cursor += lengthBytes
      guard length >= 2, length <= data.count - cursor, data[cursor] & 0x80 == 0,
        data[cursor + 1] & 7 != 0 else { throw failure() }
      let type = (data[cursor] >> 1) & 0x3f
      // Recorders repeat configuration at fragment boundaries. Allow byte-identical copies only;
      // changing in-band parameter sets need a real remux and must never be blindly relabeled.
      if [32,33,34].contains(type) {
        guard parameterSets.contains(data.subdata(in: cursor..<(cursor + length))) else { throw failure() }
      }
      cursor += length
    }
  }
  static func checkSamples(_ file: URL, lengthBytes: Int, parameterSets: Set<Data>) async throws {
    let asset = AVURLAsset(url: file)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else { throw failure() }
    let reader = try AVAssetReader(asset: asset)
    defer { reader.cancelReading() }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw failure() }
    reader.add(output)
    guard reader.startReading() else { throw failure() }
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      if CMSampleBufferGetNumSamples(sample) == 0 { continue }
      guard let block = CMSampleBufferGetDataBuffer(sample) else { throw failure() }
      let size = CMBlockBufferGetDataLength(block)
      guard size > 0, size <= 64 * 1024 * 1024 else { throw failure() }
      var data = Data(count: size)
      let status = data.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw failure() }
      try checkSample(data, lengthBytes: lengthBytes, parameterSets: parameterSets)
      count += 1
    }
    try Task.checkCancellation()
    guard reader.status == .completed, count > 0 else { throw failure() }
  }

  static func copy(_ file: URL, sourceHash: String, patches: [Patch]) throws -> (file: URL, hash: String) {
    let directory = file.deletingLastPathComponent().appendingPathComponent("compatiblevideos").appendingPathComponent(sourceHash)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temp = directory.appendingPathComponent(UUID().uuidString + ".mp4")
    guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure() }
    defer { try? FileManager.default.removeItem(at: temp) }
    let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: temp)
    defer { try? input.close(); try? output.close() }
    var originalHash = SHA256(), modifiedHash = SHA256(), offset = 0
    while var data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      originalHash.update(data: data)
      for patch in patches {
        let lower = max(offset, patch.offset), upper = min(offset + data.count, patch.offset + patch.bytes.count)
        if lower < upper {
          data.replaceSubrange((lower - offset)..<(upper - offset), with: patch.bytes[(lower - patch.offset)..<(upper - patch.offset)])
        }
      }
      modifiedHash.update(data: data)
      try output.write(contentsOf: data); offset += data.count
    }
    guard originalHash.finalize().map({ String(format: "%02x", $0) }).joined() == sourceHash else { throw failure() }
    let hash = modifiedHash.finalize().map { String(format: "%02x", $0) }.joined()
    try output.synchronize(); try output.close()
    try Task.checkCancellation()
    let destination = directory.appendingPathComponent("compatible.mp4")
    if FileManager.default.fileExists(atPath: destination.path) {
      if try RemoteAsset.hashFile(destination) == hash { return (destination, hash) }
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temp, to: destination)
    return (destination, hash)
  }
}
