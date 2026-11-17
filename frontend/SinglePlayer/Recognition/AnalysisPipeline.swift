import PencilKit

/// What a pipeline is showing. Every result carries the drawing revision it
/// was computed for.
enum AnalysisPhase<Value> {
    /// The recognizer is deselected.
    case off
    /// Paused while the other writing mode is active.
    case paused
    /// Nothing to analyze (for example an empty drawing).
    case idle
    /// Analysis of `revision` was requested; nothing is shown yet.
    case pending(revision: Int)
    case ready(revision: Int, value: Value)
    case failed(revision: Int, message: String)
}

extension AnalysisPhase: Equatable where Value: Equatable {}

struct AnalysisState<Value> {
    var phase: AnalysisPhase<Value> = .idle
    /// The revision being analyzed right now, if any.
    var runningRevision: Int?
    /// The newest revision waiting for the running job to finish, if any.
    var queuedRevision: Int?

    var value: Value? {
        if case let .ready(_, value) = phase { value } else { nil }
    }

    /// The revision of the shown result or failure.
    var shownRevision: Int? {
        switch phase {
        case let .ready(revision, _), let .failed(revision, _): revision
        default: nil
        }
    }

    var isUpdating: Bool { runningRevision != nil || queuedRevision != nil }
}

extension AnalysisState: Equatable where Value: Equatable {}

enum PipelinePolicy {
    /// Drawing-edit analysis: a new request never cancels the running job. At
    /// most one job runs; only the newest waiting request is kept and starts as
    /// soon as the running job finishes. Results publish monotonically and
    /// stay visible until a newer one or a barrier replaces them.
    case coalesceNewest
    /// Explicit requests (search): every request cancels older work and
    /// clears the shown result immediately.
    case latestWins
}

enum StopReason {
    case off, paused
}

/// The one place that decides whether a result may still be shown.
///
/// A job receives a `publish` function. Publishing succeeds only while the job
/// is newer than every barrier, and only if its revision is not older than the
/// revision already shown; it returns whether the value was shown. A job may
/// publish more than once for its revision (for example full text, then
/// per-stroke text).
@MainActor
final class AnalysisPipeline<Request, Value> {
    typealias Publish = @MainActor (Value) -> Bool
    typealias Job = @MainActor (_ request: Request, _ revision: Int, _ publish: @escaping Publish) async throws -> Void

    let policy: PipelinePolicy
    private let job: Job

    /// Called before `state` changes, so an owning ObservableObject can notify.
    var onWillChange: (() -> Void)?
    private(set) var state = AnalysisState<Value>() {
        willSet { onWillChange?() }
    }
    private(set) var isActive = true

    /// Bumped by every barrier. A job may publish only with the current value.
    private var generation = 0
    private var running: Task<Void, Never>?
    private var queued: (request: Request, revision: Int)?
    /// Every spawned task, including invalidated ones still finishing.
    private var outstanding: [UUID: Task<Void, Never>] = [:]

    init(policy: PipelinePolicy, job: @escaping Job) {
        self.policy = policy
        self.job = job
    }

    /// Requests analysis of `request` at `revision`, following the policy.
    /// Ignored while the pipeline is stopped.
    func submit(_ request: Request, revision: Int) {
        guard isActive else { return }
        switch policy {
        case .latestWins:
            invalidate()
            state = AnalysisState(phase: .pending(revision: revision))
        case .coalesceNewest:
            if state.shownRevision == nil { state.phase = .pending(revision: revision) }
        }
        queued = (request, revision)
        state.queuedRevision = revision
        startNextIfIdle()
    }

    /// Cancels running work, drops queued work, and resets the display to
    /// `phase` immediately. Nothing requested before a barrier can publish.
    /// A stopped pipeline keeps showing why it is stopped.
    func barrier(showing phase: AnalysisPhase<Value>) {
        invalidate()
        if isActive { state = AnalysisState(phase: phase) }
    }

    /// A barrier that also ignores submissions until `start()`.
    func stop(_ reason: StopReason) {
        invalidate()
        isActive = false
        state = AnalysisState(phase: reason == .off ? .off : .paused)
    }

    /// Accepts submissions again. The caller submits whatever is current.
    func start() {
        guard !isActive else { return }
        isActive = true
        state = AnalysisState(phase: .idle)
    }

    /// Waits until every job, including invalidated ones, has returned.
    func waitUntilSettled() async {
        while let task = outstanding.values.first { await task.value }
    }

    private func invalidate() {
        generation += 1
        running?.cancel()
        running = nil
        queued = nil
    }

    private func startNextIfIdle() {
        guard isActive, running == nil, let next = queued else { return }
        queued = nil
        state.runningRevision = next.revision
        state.queuedRevision = nil
        let token = generation
        let id = UUID()
        let task = Task {
            await self.run(next.request, revision: next.revision, token: token)
            self.outstanding[id] = nil
        }
        running = task
        outstanding[id] = task
    }

    private func run(_ request: Request, revision: Int, token: Int) async {
        let publish: Publish = { [weak self] value in
            self?.show(.ready(revision: revision, value: value), revision: revision, token: token) ?? false
        }
        do {
            try await job(request, revision, publish)
        } catch is CancellationError {
            // Only barriers cancel; the result is discarded below.
        } catch {
            show(.failed(revision: revision, message: error.localizedDescription), revision: revision, token: token)
        }
        guard token == generation else { return }
        running = nil
        state.runningRevision = nil
        startNextIfIdle()
    }

    @discardableResult
    private func show(_ phase: AnalysisPhase<Value>, revision: Int, token: Int) -> Bool {
        guard token == generation, isActive else { return false }
        if let shown = state.shownRevision, revision < shown { return false }
        state.phase = phase
        return true
    }
}

/// The drawing-edit pipelines (PencilKit and Vision), handled uniformly for
/// edits, barriers, and pausing.
@MainActor
protocol InkAnalysisPipeline: AnyObject {
    var isActive: Bool { get }
    func submit(_ request: PKDrawing, revision: Int)
    /// A barrier that shows `.idle`, for example when the drawing becomes empty.
    func resetToIdle()
    func stop(_ reason: StopReason)
    func start()
    func waitUntilSettled() async
}

extension AnalysisPipeline: InkAnalysisPipeline where Request == PKDrawing {
    func resetToIdle() { barrier(showing: .idle) }
}
