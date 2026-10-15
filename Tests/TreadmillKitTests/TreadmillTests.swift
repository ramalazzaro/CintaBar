import Foundation
import Testing

@testable import TreadmillKit

/// A link that records what the model asks of it and lets tests play the treadmill.
@MainActor
final class FakeLink: TreadmillLink {
    /// Reports `knownConnection` as soon as a handler is set, as a link is meant to.
    var eventHandler: (@MainActor (LinkEvent) -> Void)? {
        didSet { if let knownConnection, eventHandler != nil { emit(.connection(knownConnection)) } }
    }
    /// What the link already knows before anything listens; `nil` for a link with nothing to say yet.
    var knownConnection: Connection?
    var sent: [TreadmillCommand] = []
    var calls: [String] = []
    /// What the model asked to remember, handed back whenever the treadmill becomes ready.
    var remembersIgnoringPause = false

    func search() { calls.append("search") }
    func connect(to candidateID: UUID) { calls.append("connect") }
    func disconnect() { calls.append("disconnect") }
    func forget() { calls.append("forget") }
    func use(_ wireProtocol: WireProtocol) { calls.append("use \(wireProtocol.rawValue)") }
    func send(_ command: TreadmillCommand) { sent.append(command) }
    func remember(ignoresPause: Bool) { remembersIgnoringPause = ignoresPause }

    func emit(_ event: LinkEvent) { eventHandler?(event) }

    func becomeReady(speedRange: ClosedRange<Double> = 1...16) {
        emit(.ignoresPause(remembersIgnoringPause))
        emit(.connection(.ready(name: "FS-TEST")))
        emit(.speedRange(speedRange))
    }

    func run(at speed: Double, elapsed: Int = 1) {
        emit(.sample(Sample(belt: .running, speed: speed, incline: 0, elapsed: elapsed)))
    }
}

@MainActor
@Suite struct TreadmillTests {
    private let link = FakeLink()
    private let treadmill: Treadmill

    init() {
        treadmill = Treadmill(link: link)
    }

    @Test func aLinkReportsWhatItKnowsAsSoonAsTheModelListens() {
        let waiting = FakeLink()
        waiting.knownConnection = .unavailable(.permissionPending)
        #expect(Treadmill(link: waiting).connection == .unavailable(.permissionPending))

        let silent = FakeLink()
        #expect(Treadmill(link: silent).connection == .unavailable(.unknown))
    }

    @Test func commandsNeedAConnection() {
        treadmill.start()
        treadmill.setSpeed(3)
        treadmill.stop()
        #expect(link.sent.isEmpty)
    }

    @Test func speedChangesNeedAMovingBelt() {
        link.becomeReady()
        treadmill.setSpeed(3)
        #expect(link.sent.isEmpty)

        link.run(at: 1)
        treadmill.setSpeed(3)
        #expect(link.sent == [.target(speed: 3, incline: 0)])
    }

    @Test func speedIsClampedToWhatTheTreadmillSupports() {
        link.becomeReady(speedRange: 0.8...12)
        link.run(at: 1)
        treadmill.setSpeed(20)
        treadmill.setSpeed(0)
        #expect(link.sent == [.target(speed: 12, incline: 0), .target(speed: 0.8, incline: 0)])
    }

    @Test func startAtGoesToTheSpeedOnceTheBeltMoves() {
        link.becomeReady()
        treadmill.start(at: 4)
        #expect(link.sent == [.start])

        link.emit(.sample(Sample(belt: .countdown(3))))
        #expect(link.sent == [.start])

        link.run(at: 1)
        #expect(link.sent == [.start, .target(speed: 4, incline: 0)])
        #expect(treadmill.targetSpeed == 4)
    }

    @Test func stopForgetsThePendingStartSpeed() {
        link.becomeReady()
        treadmill.start(at: 4)
        treadmill.stop()
        link.run(at: 1)
        #expect(link.sent == [.start, .stop])
    }

    @Test func targetFollowsTheRequestUntilTheTreadmillGetsThere() {
        link.becomeReady()
        link.run(at: 1)
        treadmill.setSpeed(3)
        #expect(treadmill.targetSpeed == 3)

        link.run(at: 2)
        #expect(treadmill.targetSpeed == 3)

        link.run(at: 3)
        #expect(treadmill.targetSpeed == 3)

        // Changed from the console: the treadmill's own report wins again.
        link.run(at: 2.5)
        #expect(treadmill.targetSpeed == 2.5)
    }

    @Test func aRequestDoesNotOutliveTheRun() {
        link.becomeReady()
        link.emit(.inclineRange(0...10, step: 1))
        link.run(at: 3)
        treadmill.setSpeed(8)
        treadmill.setIncline(4)
        treadmill.stop()
        #expect(treadmill.targetSpeed == 3)
        #expect(treadmill.targetIncline == 0)

        // Nor one the treadmill ended by itself. Against a stale target, the next run's "slower"
        // would be a jump up to it.
        treadmill.setSpeed(8)
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        link.run(at: 1)
        #expect(treadmill.targetSpeed == 1)

        treadmill.setSpeed(8)
        treadmill.pause()
        #expect(treadmill.targetSpeed == 1)
    }

    @Test func samplesOnlyTouchWhatTheyMention() {
        link.becomeReady()
        link.run(at: 2, elapsed: 10)
        link.emit(.sample(Sample(elapsed: 11)))
        #expect(treadmill.belt == .running)
        #expect(treadmill.speed == 2)
        #expect(treadmill.session.elapsed == 11)

        link.emit(.sample(Sample(belt: .paused)))
        #expect(treadmill.belt == .paused)
        #expect(treadmill.session.elapsed == 11)
    }

    @Test func losingTheConnectionClearsEverything() {
        link.becomeReady(speedRange: 1...20)
        link.emit(.inclineRange(0...10, step: 1))
        link.run(at: 5, elapsed: 60)
        link.emit(.sample(Sample(calories: 7, steps: 130, heartRate: 92)))
        treadmill.setSpeed(6)

        link.emit(.connection(.searching))
        #expect(!treadmill.isReady)
        #expect(treadmill.belt == .idle)
        #expect(treadmill.speed == 0)
        #expect(treadmill.heartRate == nil)
        #expect(treadmill.session == Session())
        #expect(treadmill.speedRange == Treadmill.defaultSpeedRange)
        #expect(treadmill.inclineRange == 0...0)
        #expect(treadmill.targetSpeed == 0)
    }

    @Test func distanceIsIntegratedWhenTheTreadmillDoesNotReportIt() {
        link.becomeReady()
        for second in 1...60 {
            link.run(at: 6, elapsed: second)
        }
        #expect(abs(treadmill.session.distance - 0.1) < 1e-9)
    }

    @Test func caloriesAndStepsFollowTheTreadmillsTotals() {
        link.becomeReady()
        link.run(at: 5, elapsed: 60)
        #expect(treadmill.session.calories == 0)
        #expect(treadmill.session.steps == 0)

        link.emit(.sample(Sample(elapsed: 61, calories: 7, steps: 130)))
        #expect(treadmill.session.calories == 7)
        #expect(treadmill.session.steps == 130)

        // A treadmill may send a total apart from its clock, as the FT-200 does, and not in
        // every report.
        link.emit(.sample(Sample(steps: 132)))
        link.run(at: 5, elapsed: 62)
        #expect(treadmill.session.calories == 7)
        #expect(treadmill.session.steps == 132)
        #expect(treadmill.session.elapsed == 62)
    }

    @Test func aNewWorkoutStartsTheTotalsOver() {
        link.becomeReady()
        link.emit(.sample(Sample(belt: .running, speed: 5, elapsed: 600, calories: 40, steps: 900)))

        link.run(at: 1, elapsed: 1)
        #expect(treadmill.session.calories == 0)
        #expect(treadmill.session.steps == 0)

        // When the clock and the totals restart in the same report, the new totals are kept.
        link.emit(.sample(Sample(elapsed: 600, calories: 40, steps: 900)))
        link.emit(.sample(Sample(elapsed: 2, calories: 1, steps: 3)))
        #expect(treadmill.session.calories == 1)
        #expect(treadmill.session.steps == 3)
    }

    @Test func heartRateLastsAsLongAsTheReading() {
        link.becomeReady()
        #expect(treadmill.heartRate == nil)

        link.emit(.sample(Sample(heartRate: 92)))
        #expect(treadmill.heartRate == 92)

        // Not mentioning it leaves the last reading alone.
        link.run(at: 5)
        #expect(treadmill.heartRate == 92)

        // Zero means the treadmill has nothing to read, not a heart at rest.
        link.emit(.sample(Sample(heartRate: 0)))
        #expect(treadmill.heartRate == nil)
    }

    @Test func linkCallsPassThrough() {
        treadmill.search()
        treadmill.connect(to: Candidate(id: UUID(), name: "FS-TEST", isLikelyTreadmill: true))
        treadmill.use(.fitShow)
        treadmill.forget()
        treadmill.disconnect()
        #expect(link.calls == ["search", "connect", "use FitShow", "forget", "disconnect"])
    }
}
