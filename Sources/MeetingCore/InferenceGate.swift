import Foundation

/// An actor alone is reentrant across await. This permit serializes native inference jobs.
public actor InferenceGate {
  public enum Priority: Int, Sendable { case background, live }
  private struct Waiter {
    let id: UUID
    let priority: Priority
    let continuation: CheckedContinuation<Void, Error>
  }
  private var held = false
  private var waiters: [Waiter] = []
  public init() {}
  public func acquire(priority: Priority) async throws {
    try Task.checkCancellation()
    if !held {
      held = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
    // The caller owns the permit now, even if cancellation raced with release().
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }
  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
  public func release() {
    if let index = waiters.firstIndex(where: { $0.priority == .live }) ?? waiters.indices.first {
      waiters.remove(at: index).continuation.resume()
    } else {
      held = false
    }
  }
}
