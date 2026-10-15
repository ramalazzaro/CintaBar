import Foundation
import TreadmillKit

/// A pretend treadmill, for working on the app without hardware. Launch with `--simulate` to use it.
///
/// It behaves roughly like a Noga FT-200: a three-second countdown, a belt that starts at 1 km/h
/// and ramps half a km/h per second toward the target, and a report every second. Unlike the
/// FT-200 it has a motorized incline, reads a heart rate and offers both protocols, so every menu
/// item can be tried.
///
/// Three more launch arguments make it misbehave, to try what guards against that. With `--miles`
/// it takes and reports mph, as some firmware does. With `--runaway` it heads for its top speed
/// whatever speed it's asked for. With `--ignores-pause` it takes a pause and keeps going, clock
/// and all, as the FT-200 does over FTMS. A stop still stops it, and starts its clock over as ever.
final class SimulatedLink: TreadmillLink {
    var eventHandler: (@MainActor (LinkEvent) -> Void)? {
        didSet { if eventHandler != nil { emit(.connection(connection)) } }
    }

    private static let treadmill = Candidate(id: UUID(), name: "FS-SIMULATED", isLikelyTreadmill: true)
    private static let speaker = Candidate(id: UUID(), name: "Kitchen Speaker", isLikelyTreadmill: false)
    private static let inclineRange = 0.0...12.0

    private let speaksMiles = CommandLine.arguments.contains("--miles")
    private let runsAway = CommandLine.arguments.contains("--runaway")
    private let ignoresPause = CommandLine.arguments.contains("--ignores-pause")
    /// The protocols the app was told ignore a pause. Unlike the real link's, this is forgotten
    /// at quit, so that every launch can try finding it out again.
    private var protocolsIgnoringPause: Set<WireProtocol> = []
    /// In its own unit, like every speed here.
    private var speedRange: ClosedRange<Double> { speaksMiles ? 0.6...10.0 : 1.0...16.0 }
    private var connection = Connection.unavailable(.unknown) {
        didSet { emit(.connection(connection)) }
    }
    private var isConnected = false
    private var wireProtocol = WireProtocol.ftms
    private var belt = BeltState.idle
    private var speed = 0.0
    private var incline = 0.0
    private var targetSpeed = 1.0
    private var targetIncline = 0.0
    private var elapsed = 0
    /// In its own unit too, though it's reported as kilometers.
    private var distance = 0.0
    private var ticker: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var searchTimer: Task<Void, Never>?

    init() {
        // Like Bluetooth powering on a moment after launch.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            search()
        }
    }

    // MARK: - TreadmillLink

    func search() {
        guard !isConnected else { return }
        connection = .searching
        searchTimer?.cancel()
        searchTimer = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                emit(.candidates([Self.treadmill, Self.speaker]))
                try await Task.sleep(for: .seconds(15))
                connection = .searchEnded
            } catch {}
        }
    }

    func connect(to candidateID: UUID) {
        searchTimer?.cancel()
        emit(.candidates([]))
        let chosen = candidateID == Self.treadmill.id ? Self.treadmill : Self.speaker
        connection = .waiting(name: chosen.name)
        transition?.cancel()
        transition = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard chosen == Self.treadmill else {
                // Not a treadmill after all; the real link gives up on it and searches again.
                search()
                return
            }
            isConnected = true
            emit(.protocols(available: WireProtocol.allCases, active: wireProtocol))
            emit(.speedRange(speedRange))
            emit(.inclineRange(Self.inclineRange, step: 1))
            emit(.ignoresPause(protocolsIgnoringPause.contains(wireProtocol)))
            connection = .ready(name: chosen.name)
            runTicker()
        }
    }

    func disconnect() {
        ticker?.cancel()
        transition?.cancel()
        isConnected = false
        belt = .idle
        speed = 0
        elapsed = 0
        distance = 0
        emit(.protocols(available: [], active: nil))
    }

    func forget() {
        disconnect()
        search()
    }

    func use(_ wireProtocol: WireProtocol) {
        guard wireProtocol != self.wireProtocol else { return }
        self.wireProtocol = wireProtocol
        guard isConnected else { return }
        disconnect()
        connect(to: Self.treadmill.id)
    }

    func send(_ command: TreadmillCommand) {
        guard isConnected else { return }
        switch command {
        case .start:
            guard [.idle, .paused, .safetyKey].contains(belt) else { return }
            if belt == .idle {
                targetSpeed = speedRange.lowerBound
                targetIncline = 0
                elapsed = 0
                distance = 0
            }
            countDown()
        case .pause:
            // The FT-200 answers that it paused, and carries on as before.
            guard belt == .running, !ignoresPause else { return }
            slowDown(to: .paused)
        case .stop:
            guard belt != .idle else { return }
            slowDown(to: .idle)
        case .target(let speed, let incline):
            guard belt == .running else { return }
            targetSpeed =
                runsAway ? speedRange.upperBound : min(max(speed, speedRange.lowerBound), speedRange.upperBound)
            targetIncline = min(max(incline, Self.inclineRange.lowerBound), Self.inclineRange.upperBound)
        }
    }

    func remember(ignoresPause: Bool) {
        if ignoresPause {
            protocolsIgnoringPause.insert(wireProtocol)
        } else {
            protocolsIgnoringPause.remove(wireProtocol)
        }
    }

    // MARK: - Behavior

    private func emit(_ event: LinkEvent) {
        eventHandler?(event)
    }

    private func countDown() {
        transition?.cancel()
        transition = Task {
            do {
                for remaining in stride(from: 3, through: 1, by: -1) {
                    belt = .countdown(remaining)
                    emit(.sample(Sample(belt: belt)))
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                return
            }
            belt = .running
            speed = max(speed, speedRange.lowerBound)
            report()
        }
    }

    private func slowDown(to resting: BeltState) {
        transition?.cancel()
        transition = Task {
            belt = .stopping
            report()
            do {
                while speed > 0 {
                    try await Task.sleep(for: .milliseconds(700))
                    speed = max(0, speed - 1.5)
                    report()
                }
            } catch {
                return
            }
            belt = resting
            if resting == .idle {
                elapsed = 0
                distance = 0
            }
            report()
        }
    }

    private func runTicker() {
        ticker?.cancel()
        ticker = Task {
            while true {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                switch belt {
                case .running:
                    elapsed += 1
                    speed = approach(speed, targetSpeed, by: 0.5)
                    incline = approach(incline, targetIncline, by: 1)
                    distance += speed / 3600
                    report()
                case .paused:
                    report()
                default:
                    break
                }
            }
        }
    }

    private func report() {
        let sample = Sample(
            belt: belt, speed: speed, incline: incline, elapsed: elapsed, distance: distance,
            calories: calories, steps: steps, heartRate: heartRate)
        emit(.sample(sample))
    }

    /// About what a kilometer costs a walker of average weight, and how many steps it takes.
    private var calories: Double { distance * 60 }
    private var steps: Int { Int(distance * 1300) }

    /// A pulse that follows the pace during a workout, and no reading once it's over.
    private var heartRate: Int { belt == .idle ? 0 : Int(65 + 6 * speed) }

    private func approach(_ value: Double, _ target: Double, by step: Double) -> Double {
        abs(target - value) <= step ? target : value + (target > value ? step : -step)
    }
}
