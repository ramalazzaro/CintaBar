import Foundation
import Testing

@testable import TreadmillKit

/// A link that records what the model asks of it and lets tests play the treadmill.
@MainActor
private final class FakeLink: TreadmillLink {
    var eventHandler: (@MainActor (LinkEvent) -> Void)?
    var sent: [TreadmillCommand] = []
    var calls: [String] = []

    func search() { calls.append("search") }
    func connect(to candidateID: UUID) { calls.append("connect") }
    func disconnect() { calls.append("disconnect") }
    func forget() { calls.append("forget") }
    func use(_ wireProtocol: WireProtocol) { calls.append("use \(wireProtocol.rawValue)") }
    func send(_ command: TreadmillCommand) { sent.append(command) }

    func emit(_ event: LinkEvent) { eventHandler?(event) }

    func becomeReady(speedRange: ClosedRange<Double> = 1...16) {
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
        treadmill.setSpeed(6)

        link.emit(.connection(.searching))
        #expect(!treadmill.isReady)
        #expect(treadmill.belt == .idle)
        #expect(treadmill.speed == 0)
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

    @Test func linkCallsPassThrough() {
        treadmill.search()
        treadmill.connect(to: Candidate(id: UUID(), name: "FS-TEST", isLikelyTreadmill: true))
        treadmill.use(.fitShow)
        treadmill.forget()
        treadmill.disconnect()
        #expect(link.calls == ["search", "connect", "use FitShow", "forget", "disconnect"])
    }
}
