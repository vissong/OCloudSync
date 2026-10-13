import Foundation

/// One producer and one consumer, with at most one prepared item waiting ahead.
/// Throwing/cancellation joins both stages before returning to ledger recovery.
@MainActor public enum ImportPipeline {
  private enum Event<Output: Sendable>: Sendable {
    case prepared(Output)
    case consumed
  }

  public static func run<Input: Sendable, Output: Sendable>(
    items: [Input], canPrepare: @escaping @MainActor () -> Bool = { true },
    prepare: @escaping @MainActor (Input) async throws -> Output,
    consume: @escaping @MainActor (Output) async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    try await withThrowingTaskGroup(of: Event<Output>.self) { group in
      var next = 0, preparing = false, consuming = false
      var buffered: Output?
      do {
        if !items.isEmpty, canPrepare() {
          let first = items[0]
          group.addTask { .prepared(try await prepare(first)) }
          next = 1; preparing = true
        }
        while let event = try await group.next() {
          try Task.checkCancellation()
          switch event {
          case .prepared(let output): preparing = false; buffered = output
          case .consumed: consuming = false
          }
          if !consuming, let output = buffered {
            buffered = nil; consuming = true
            group.addTask {
              try Task.checkCancellation()
              try await consume(output)
              return .consumed
            }
          }
          if !preparing, buffered == nil, next < items.count, canPrepare() {
            let input = items[next]
            next += 1; preparing = true
            group.addTask {
              try Task.checkCancellation()
              return .prepared(try await prepare(input))
            }
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }
}

/// This round's outcomes, not an iCloud upload count or a durable historical batch.
public struct ImportProgress: Sendable {
  public let total: Int
  public private(set) var imported = 0, duplicates = 0, failed = 0, deferred = 0
  private var finished = Set<String>()
  public init(total: Int) { self.total = total }
  public var processed: Int { finished.count }
  public var successful: Int { imported + duplicates }
  public var remaining: Int { max(0, total - processed) }
  public mutating func finish(key: String, state: RecordState) {
    guard finished.insert(key).inserted else { return }
    switch state {
    case .imported: imported += 1
    case .duplicate: duplicates += 1
    case .failed, .importing: failed += 1
    default: deferred += 1
    }
  }
}
