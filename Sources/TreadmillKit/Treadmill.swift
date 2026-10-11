import Foundation
import Observation

/// The treadmill as the user interface sees it: what it's doing, and the commands it takes.
///
/// It's protocol agnostic. A ``TreadmillLink`` does the talking and reports back with
/// ``LinkEvent``s.
@MainActor @Observable
public final class Treadmill {
    /// In effect until the treadmill reports what it supports. Deliberately low.
    public static let defaultSpeedRange = 1.0...6.0

    public private(set) var connection = Connection.unavailable(.unknown)
    /// Devices found by the current search.
    public private(set) var candidates: [Candidate] = []
    /// The protocols the connected treadmill offers.
    public private(set) var availableProtocols: [WireProtocol] = []
    public private(set) var activeProtocol: WireProtocol?
    /// The speeds the treadmill supports, in km/h.
    public private(set) var speedRange = Treadmill.defaultSpeedRange
    /// The inclines the treadmill supports; empty when the incline isn't motorized.
    public private(set) var inclineRange = 0.0...0.0
    public private(set) var inclineStep = 1.0

    public private(set) var belt = BeltState.idle
    /// Belt speed in km/h, as reported by the treadmill.
    public private(set) var speed = 0.0
    /// Incline as reported by the treadmill: a level for FitShow, percent for FTMS.
    public private(set) var incline = 0.0
    public private(set) var session = Session()

    public var isReady: Bool {
        if case .ready = connection { true } else { false }
    }

    public var isMoving: Bool { belt == .running || belt == .stopping }
    /// The speed asked for, until the treadmill reaches it; then the speed it reports.
    public var targetSpeed: Double { requestedSpeed?.value ?? speed }
    public var targetIncline: Double { requestedIncline?.value ?? incline }

    @ObservationIgnored private var requestedSpeed: Target?
    @ObservationIgnored private var requestedIncline: Target?
    @ObservationIgnored private var speedAfterStart: Target?
    private let link: any TreadmillLink

    /// A value asked for from the menu.
    ///
    /// It stands until the treadmill reaches it or it expires. After that the treadmill's own
    /// report wins, because the console and the remote can change the same value. The default
    /// allowance covers a belt ramping across its whole speed range.
    private struct Target {
        let value: Double
        private let deadline: ContinuousClock.Instant

        init(_ value: Double, validFor duration: Duration = .seconds(40)) {
            self.value = value
            deadline = .now + duration
        }

        var isExpired: Bool { .now > deadline }

        func isSettled(by reported: Double) -> Bool { abs(reported - value) < 0.05 || isExpired }
    }

    public init(link: any TreadmillLink) {
        self.link = link
        link.eventHandler = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Commands

    /// Starts the belt, or resumes it after a pause. The treadmill runs its own countdown first.
    ///
    /// - Parameter speed: The speed to go to once the belt is moving, in km/h. Pass `nil` to stay
    ///   at the speed the treadmill starts with.
    public func start(at speed: Double? = nil) {
        guard isReady else { return }
        speedAfterStart = speed.map { Target(clamp($0), validFor: .seconds(20)) }
        link.send(.start)
    }

    public func pause() {
        guard isReady else { return }
        link.send(.pause)
    }

    public func stop() {
        guard isReady else { return }
        speedAfterStart = nil
        link.send(.stop)
    }

    /// Sets the belt speed in km/h, clamped to what the treadmill supports.
    public func setSpeed(_ speed: Double) {
        guard isReady, belt == .running else { return }
        requestedSpeed = Target(clamp(speed))
        link.send(.target(speed: targetSpeed, incline: targetIncline))
    }

    public func setIncline(_ incline: Double) {
        guard isReady, belt == .running else { return }
        requestedIncline = Target(min(max(incline, inclineRange.lowerBound), inclineRange.upperBound))
        link.send(.target(speed: targetSpeed, incline: targetIncline))
    }

    public func use(_ wireProtocol: WireProtocol) { link.use(wireProtocol) }
    public func connect(to candidate: Candidate) { link.connect(to: candidate.id) }
    public func search() { link.search() }
    public func forget() { link.forget() }
    public func disconnect() { link.disconnect() }

    // MARK: - Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .connection(let connection):
            self.connection = connection
            if !isReady {
                requestedSpeed = nil
                requestedIncline = nil
                speedAfterStart = nil
                speedRange = Self.defaultSpeedRange
                inclineRange = 0...0
                inclineStep = 1
                record(Sample(belt: .idle, speed: 0, incline: 0))
                session = Session()
            }
        case .candidates(let candidates):
            self.candidates = candidates
        case .protocols(let available, let active):
            availableProtocols = available
            activeProtocol = active
        case .speedRange(let range):
            speedRange = range
        case .inclineRange(let range, let step):
            inclineRange = range
            inclineStep = step
        case .sample(let sample):
            record(sample)
        }
    }

    /// Stores what the treadmill reported, touching only what changed so observers aren't told
    /// about identical samples.
    private func record(_ sample: Sample) {
        let wasRunning = belt == .running
        if let belt = sample.belt, belt != self.belt { self.belt = belt }
        if let speed = sample.speed, speed != self.speed { self.speed = speed }
        if let incline = sample.incline, incline != self.incline { self.incline = incline }
        if let elapsed = sample.elapsed {
            var updated = session
            updated.record(elapsed: elapsed, speed: speed, distance: sample.distance)
            if updated != session { session = updated }
        }

        if requestedSpeed?.isSettled(by: speed) == true { requestedSpeed = nil }
        if requestedIncline?.isSettled(by: incline) == true { requestedIncline = nil }
        if belt == .running, !wasRunning, let pending = speedAfterStart {
            speedAfterStart = nil
            if !pending.isExpired { setSpeed(pending.value) }
        }
    }

    /// Rounds to a tenth, then clamps, so an odd range limit can't be overshot by the rounding.
    private func clamp(_ speed: Double) -> Double {
        min(max((speed * 10).rounded() / 10, speedRange.lowerBound), speedRange.upperBound)
    }
}
