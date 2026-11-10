import Foundation
import Observation

/// One row of the Activity list.
public struct ActivityItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case succeeded
        /// An update was asked for and nothing newer exists.
        case upToDate
        case cancelled
        case failed(code: String, message: String)
    }

    public let id = UUID()
    public let request: InstallRequest
    public let options: InstallOptions
    public var state = State.running
    public var fraction = 0.0
    public var phase: OperationEvent.Phase?
    public var message = "Starting"
    public var bytesReceived: Int64?
    public var bytesTotal: Int64?

    public var title: String { request.title }
    public var isRunning: Bool { state == .running }
    public var isFailed: Bool { if case .failed = state { return true } else { return false } }
    public var canRetry: Bool { isFailed || state == .cancelled }

    init(request: InstallRequest, options: InstallOptions) {
        self.request = request
        self.options = options
    }
}

/// Runs operations and keeps the list the Activity section draws. Events arrive
/// through an `AsyncStream` rather than one `Task` per event, because separate
/// tasks hopping to the main actor are not guaranteed to run in order and a
/// progress bar that moves backwards is a visible bug.
@MainActor @Observable
public final class ActivityModel {
    public private(set) var items: [ActivityItem] = []
    public var hasRunning: Bool { items.contains(where: \.isRunning) }

    @ObservationIgnored private let backend: AppBackend
    @ObservationIgnored private let onFinished: @MainActor (ActivityItem) -> Void
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(backend: AppBackend, onFinished: @escaping @MainActor (ActivityItem) -> Void = { _ in }) {
        self.backend = backend
        self.onFinished = onFinished
    }

    @discardableResult
    public func start(_ request: InstallRequest, options: InstallOptions = InstallOptions()) -> UUID {
        let item = ActivityItem(request: request, options: options)
        items.insert(item, at: 0)
        run(item.id)
        return item.id
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    public func retry(_ id: UUID) {
        guard let item = item(id), item.canRetry else { return }
        update(id) { $0.state = .running; $0.fraction = 0; $0.phase = nil; $0.message = "Starting"; $0.bytesReceived = nil; $0.bytesTotal = nil }
        run(id)
    }

    public func clearFinished() {
        items.removeAll { !$0.isRunning }
    }

    /// Resolves once the operation has finished; the tests wait on this.
    public func waitUntilFinished(_ id: UUID) async {
        await tasks[id]?.value
    }

    // MARK: Running

    private func run(_ id: UUID) {
        guard let item = item(id) else { return }
        let backend = self.backend
        let (stream, continuation) = AsyncStream.makeStream(of: OperationEvent.self)
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.apply(event, to: id) }
        }
        tasks[id] = Task { @MainActor [weak self] in
            var outcome = ActivityItem.State.succeeded
            do {
                if try await backend.perform(item.request, options: item.options, onEvent: { continuation.yield($0) }) == nil {
                    outcome = .upToDate
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                let failure = OperationFailure.wrap(error)
                outcome = .failed(code: failure.code, message: failure.message)
            }
            continuation.finish()
            await consumer.value
            self?.finish(id, outcome)
        }
    }

    private func apply(_ event: OperationEvent, to id: UUID) {
        update(id) {
            $0.fraction = event.fraction
            $0.phase = event.phase
            $0.message = event.message
            $0.bytesReceived = event.bytesReceived
            $0.bytesTotal = event.bytesTotal
        }
    }

    private func finish(_ id: UUID, _ state: ActivityItem.State) {
        tasks[id] = nil
        update(id) {
            $0.state = state
            if state == .succeeded { $0.fraction = 1; $0.message = "Installed" }
            if state == .upToDate { $0.fraction = 1; $0.message = "Already up to date" }
            if state == .cancelled { $0.message = "Cancelled" }
            if case .failed(_, let message) = state { $0.message = message }
        }
        if let finished = item(id) { onFinished(finished) }
    }

    private func item(_ id: UUID) -> ActivityItem? { items.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout ActivityItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
