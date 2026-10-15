import Testing

@testable import TreadmillKit

/// A treadmill that takes and reports mph, behind the switch that says so.
@MainActor
@Suite struct MilesTests {
    private let link = FakeLink()
    private let treadmill: Treadmill
    private let mile = Treadmill.kilometersPerMile

    init() {
        treadmill = Treadmill(link: link)
        treadmill.treadmillsSpeakingMiles = ["FS-TEST"]
    }

    @Test func itIsOffUntilTheUserSaysSo() {
        treadmill.treadmillsSpeakingMiles = []
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 2.5)
        #expect(!treadmill.speaksMiles)
        #expect(treadmill.speedRange == 0.5...10)
        #expect(treadmill.speed == 2.5)
    }

    @Test func reportsAreConvertedOnTheWayIn() {
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 2.5)
        #expect(treadmill.speaksMiles)
        #expect(treadmill.speedRange == 0.5 * mile...10 * mile)
        #expect(treadmill.speed == 2.5 * mile)
    }

    @Test func commandsAreConvertedOnTheWayOut() {
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 1)
        // 4 km/h is 2.49 mph. The treadmill gets the nearest speed its console could show.
        treadmill.setSpeed(4)
        #expect(link.sent == [.target(speed: 2.5, incline: 0)])
        #expect(treadmill.targetSpeed == 2.5 * mile)
    }

    @Test func aRoundTripSettles() {
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 1)
        // 3.3 km/h is 2.05 mph, sent as 2.1: that's 0.08 km/h off, more than a request held in
        // km/h would take for an answer.
        treadmill.setSpeed(3.3)
        #expect(link.sent == [.target(speed: 2.1, incline: 0)])

        link.run(at: 2.1)
        #expect(treadmill.targetSpeed == treadmill.speed)

        // The request is over, so a change made from the console shows.
        link.run(at: 2)
        #expect(treadmill.targetSpeed == 2 * mile)
    }

    @Test func everyRequestIsACleanSpeedThatSettles() {
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 0.5)
        for tenths in 5...170 {
            treadmill.setSpeed(Double(tenths) / 10)
            guard case .target(let sent, _) = link.sent.last else {
                Issue.record("No speed was sent for \(tenths) tenths")
                continue
            }
            #expect(sent == (sent * 10).rounded() / 10)
            #expect((0.5...10).contains(sent))

            link.run(at: sent)
            link.run(at: 0.5)
            #expect(treadmill.targetSpeed == 0.5 * mile)
        }
    }

    @Test func theRangeIsKeptInTheTreadmillsUnit() {
        link.becomeReady(speedRange: 0.55...7.46)
        link.run(at: 1)
        treadmill.setSpeed(40)
        treadmill.setSpeed(0)
        #expect(link.sent == [.target(speed: 7.46, incline: 0), .target(speed: 0.55, incline: 0)])
    }

    @Test func anInclineChangeRepeatsTheSpeedAsReported() {
        link.becomeReady(speedRange: 0.5...10)
        link.emit(.inclineRange(0...10, step: 1))
        link.run(at: 2.13)
        treadmill.setIncline(3)
        #expect(link.sent == [.target(speed: 2.13, incline: 3)])
    }

    @Test func distanceIsWorkedOutFromTheConvertedSpeed() {
        link.becomeReady()
        // A minute at 3 mph. What it reports as kilometers are most likely miles.
        for second in 1...60 {
            let reported = Double(second) * 3 / 3600
            link.emit(.sample(Sample(belt: .running, speed: 3, elapsed: second, distance: reported)))
        }
        #expect(abs(treadmill.session.distance - 3 * mile / 60) < 1e-9)
    }

    @Test func theSwitchFollowsTheTreadmill() {
        link.becomeReady()
        #expect(treadmill.speaksMiles)

        link.emit(.connection(.ready(name: "FS-OTHER")))
        #expect(!treadmill.speaksMiles)

        // Forgetting a treadmill and choosing it again finds the switch as it was.
        link.emit(.connection(.searching))
        #expect(!treadmill.speaksMiles)
        link.becomeReady()
        #expect(treadmill.speaksMiles)
    }

    @Test func flippingTheSwitchReinterpretsWhatWasReported() {
        treadmill.treadmillsSpeakingMiles = []
        link.becomeReady(speedRange: 0.5...10)
        link.run(at: 2)
        treadmill.setSpeed(3)

        treadmill.speaksMiles = true
        #expect(treadmill.treadmillsSpeakingMiles == ["FS-TEST"])
        #expect(treadmill.speedRange == 0.5 * mile...10 * mile)
        #expect(treadmill.speed == 2 * mile)
        // What was asked for meant something else in the other unit.
        #expect(treadmill.targetSpeed == 2 * mile)

        treadmill.speaksMiles = false
        #expect(treadmill.treadmillsSpeakingMiles.isEmpty)
        #expect(treadmill.speedRange == 0.5...10)
        #expect(abs(treadmill.speed - 2) < 1e-9)
        // Flipping it is a setting, not a command.
        #expect(link.sent == [.target(speed: 3, incline: 0)])
    }

    @Test func theSwitchNeedsATreadmill() {
        treadmill.treadmillsSpeakingMiles = []
        treadmill.speaksMiles = true
        #expect(treadmill.treadmillsSpeakingMiles.isEmpty)
        #expect(!treadmill.speaksMiles)
    }
}
