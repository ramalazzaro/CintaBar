import Testing

@testable import TreadmillKit

@MainActor
@Suite struct SpeedLimitTests {
    private let link = FakeLink()
    private let treadmill: Treadmill

    init() {
        treadmill = Treadmill(link: link)
        link.becomeReady()
    }

    @Test func thereIsNoneByDefault() {
        link.run(at: 5)
        treadmill.setSpeed(16)
        #expect(treadmill.speedLimit == nil)
        #expect(link.sent == [.target(speed: 16, incline: 0)])
    }

    @Test func noRequestGoesPastIt() {
        treadmill.speedLimit = 6
        link.run(at: 5.8)
        // What "Faster" and a preset do.
        treadmill.setSpeed(treadmill.targetSpeed + 0.5)
        treadmill.setSpeed(12)
        #expect(link.sent == [.target(speed: 6, incline: 0), .target(speed: 6, incline: 0)])
        #expect(treadmill.targetSpeed == 6)
    }

    @Test func startAtIsHeldToIt() {
        treadmill.speedLimit = 3
        treadmill.start(at: 8)
        link.run(at: 1)
        #expect(link.sent == [.start, .target(speed: 3, incline: 0)])
    }

    @Test func aLimitSetDuringTheCountdownStillCounts() {
        treadmill.start(at: 8)
        treadmill.speedLimit = 3
        link.run(at: 1)
        #expect(link.sent == [.start, .target(speed: 3, incline: 0)])
    }

    @Test func settingItSendsNothing() {
        link.run(at: 9)
        treadmill.speedLimit = 4
        #expect(link.sent.isEmpty)
        #expect(treadmill.speed == 9)
    }

    @Test func theConsoleIsNotBoundByItButTheAppStillIs() {
        treadmill.speedLimit = 6
        link.run(at: 9)
        #expect(treadmill.speed == 9)
        // "Slower" from a speed the console set.
        treadmill.setSpeed(treadmill.targetSpeed - 0.5)
        #expect(link.sent == [.target(speed: 6, incline: 0)])
    }

    @Test func anInclineChangeDoesNotRepeatASpeedPastIt() {
        treadmill.speedLimit = 6
        link.emit(.inclineRange(0...10, step: 1))
        link.run(at: 9)
        // The speed sent along is the one reported, unless the console took it past the limit.
        treadmill.setIncline(2)
        #expect(link.sent == [.target(speed: 6, incline: 2)])
    }

    @Test func itIsRoundedDownInTheTreadmillsUnit() {
        treadmill.treadmillsSpeakingMiles = ["FS-TEST"]
        link.emit(.speedRange(0.5...10))
        treadmill.speedLimit = 4
        link.run(at: 1)
        // 4 km/h is 2.49 mph. The nearest tenth is 2.5, which is over the limit.
        treadmill.setSpeed(4)
        treadmill.setSpeed(12)
        #expect(link.sent == [.target(speed: 2.4, incline: 0), .target(speed: 2.4, incline: 0)])
        #expect(treadmill.targetSpeed <= 4)
    }

    @Test func aLimitThatIsATenthIsNotRoundedAway() {
        link.run(at: 1)
        for tenths in 10...160 {
            let limit = Double(tenths) / 10
            treadmill.speedLimit = limit
            treadmill.setSpeed(16)
            #expect(link.sent.last == .target(speed: limit, incline: 0))
        }
    }

    @Test func aLimitUnderTheSlowestSpeedAsksForTheSlowest() {
        treadmill.speedLimit = 0.5
        link.run(at: 3)
        treadmill.setSpeed(5)
        #expect(link.sent == [.target(speed: 1, incline: 0)])
    }
}
