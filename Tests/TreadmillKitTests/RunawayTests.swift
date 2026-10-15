import Testing

@testable import TreadmillKit

/// A scheduler whose clock only moves when a test says so.
@MainActor
final class FakeTimers {
    private var pending: [(id: Int, due: Duration, action: @MainActor () -> Void)] = []
    private var now = Duration.zero
    private var lastID = 0

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        lastID += 1
        let id = lastID
        pending.append((id, now + delay, action))
        return { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    /// Lets time pass, running whatever falls due on the way, in order.
    func advance(by duration: Duration) {
        let end = now + duration
        while let next = pending.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            pending.removeAll { $0.id == next.id }
            now = next.due
            next.action()
        }
        now = end
    }
}

@MainActor
@Suite struct RunawayTests {
    private let link = FakeLink()
    private let timers = FakeTimers()
    private let treadmill: Treadmill

    /// What the link has been sent once 3.5 km/h is asked for, when nothing else is.
    private let request = TreadmillCommand.target(speed: 3.5, incline: 0)
    private var stops: Int { link.sent.count { $0 == .stop } }

    init() {
        treadmill = Treadmill(link: link, scheduler: timers.schedule)
        link.becomeReady()
    }

    /// Asks for 3.5 km/h at 3, and has the belt take off instead.
    private func runAway() {
        link.run(at: 3)
        treadmill.setSpeed(3.5)
        link.run(at: 5)
    }

    // MARK: - Detection

    @Test func aBeltThatShootsPastWhatWasAskedIsARunaway() {
        link.run(at: 3)
        treadmill.setSpeed(3.5)
        link.run(at: 3.5 + RunawayGuard.margin)
        #expect(treadmill.runaway == nil)

        link.run(at: 4.6)
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: RunawayGuard.countdown))
    }

    @Test func aBeltThatSpeedsUpWhenAskedToSlowDownIsARunaway() {
        link.run(at: 5)
        treadmill.setSpeed(4.5)
        link.run(at: 5.5)
        link.run(at: 6)
        #expect(treadmill.runaway == nil)

        link.run(at: 6.1)
        #expect(treadmill.runaway == .warning(requested: 4.5, secondsUntilStop: 5))
    }

    @Test func aBeltSlowingDownIsHeldToHowFarItGot() {
        link.run(at: 10)
        treadmill.setSpeed(4)
        link.run(at: 8)
        link.run(at: 7)
        link.run(at: 7.9)
        #expect(treadmill.runaway == nil)

        // Still under the 10 it started from, but it was at 7 and should be heading for 4.
        link.run(at: 8.1)
        #expect(treadmill.runaway == .warning(requested: 4, secondsUntilStop: 5))
    }

    @Test func rampingToTheSpeedAskedForIsNot() {
        link.run(at: 3)
        treadmill.setSpeed(8)
        for speed in stride(from: 3.5, through: 8, by: 0.5) {
            link.run(at: speed)
        }
        // An overshoot, and a press of the console's own button.
        link.run(at: 8.4)
        link.run(at: 8.5)
        treadmill.setSpeed(4)
        for speed in stride(from: 8, through: 4, by: -0.5) {
            link.run(at: speed)
        }
        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == nil)
        #expect(link.sent == [.target(speed: 8, incline: 0), .target(speed: 4, incline: 0)])
    }

    @Test func theConsoleCanDoAsItLikes() {
        // Nothing was asked for from the app.
        link.run(at: 3)
        link.run(at: 12)
        #expect(treadmill.runaway == nil)

        // Something was, but the belt got there a while ago.
        treadmill.setSpeed(4)
        link.run(at: 4)
        timers.advance(by: RunawayGuard.grace)
        link.run(at: 12)
        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == nil)
        #expect(stops == 0)
    }

    @Test func passingThroughTheSpeedAskedForDoesNotDisarmIt() {
        link.run(at: 3)
        treadmill.setSpeed(3.5)
        // On its way to the maximum the belt reports exactly what was asked for, which ends the
        // request: the target follows the reports again.
        link.run(at: 3.5)
        link.run(at: 4)
        #expect(treadmill.targetSpeed == 4)
        #expect(treadmill.runaway == nil)

        timers.advance(by: RunawayGuard.grace - .seconds(1))
        link.run(at: 4.6)
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: 5))
    }

    @Test func aWarningOutlastsTheGracePeriod() {
        link.run(at: 3)
        treadmill.setSpeed(3.5)
        link.run(at: 3.5)
        timers.advance(by: RunawayGuard.grace - .seconds(2))
        link.run(at: 5)
        // The grace period would have ended here, with three seconds still on the warning.
        timers.advance(by: .seconds(5))
        #expect(treadmill.runaway == .stopped(requested: 3.5))
        #expect(link.sent == [request, .stop])
    }

    @Test func aStartSpeedIsWatched() {
        treadmill.start(at: 4)
        link.run(at: 1)
        link.run(at: 5.1)
        #expect(treadmill.runaway == .warning(requested: 4, secondsUntilStop: 5))
    }

    @Test func anInclineChangeIsWatchedForTheSpeedItRepeats() {
        link.emit(.inclineRange(0...10, step: 1))
        link.run(at: 3)
        treadmill.setIncline(2)
        link.run(at: 4.1)
        #expect(treadmill.runaway == .warning(requested: 3, secondsUntilStop: 5))
    }

    @Test func itWorksInMilesToo() {
        treadmill.treadmillsSpeakingMiles = ["FS-TEST"]
        link.run(at: 2)
        // 2.5 mph, a shade over 4 km/h. A full km/h more is 3.13 mph.
        treadmill.setSpeed(4)
        link.run(at: 3.1)
        #expect(treadmill.runaway == nil)

        link.run(at: 3.2)
        #expect(treadmill.runaway == .warning(requested: 2.5 * Treadmill.kilometersPerMile, secondsUntilStop: 5))
    }

    // MARK: - The warning

    @Test func nobodyAnsweringStopsTheBeltOnce() {
        runAway()
        for seconds in stride(from: 5, through: 1, by: -1) {
            #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: seconds))
            #expect(link.sent == [request])
            // Telemetry goes on meanwhile, and doesn't start the count over.
            link.run(at: 5.5)
            timers.advance(by: .seconds(1))
        }
        #expect(treadmill.runaway == .stopped(requested: 3.5))
        #expect(link.sent == [request, .stop])

        // Not again, whatever the belt does next.
        link.run(at: 16)
        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == .stopped(requested: 3.5))
        #expect(link.sent == [request, .stop])

        treadmill.acknowledgeRunaway()
        #expect(treadmill.runaway == nil)
    }

    @Test func stoppingAnswersIt() {
        runAway()
        timers.advance(by: .seconds(4))
        treadmill.stop()
        #expect(treadmill.runaway == nil)
        #expect(link.sent == [request, .stop])

        timers.advance(by: .seconds(60))
        #expect(link.sent == [request, .stop])
    }

    @Test func keepingGoingSilencesItUntilTheNextRequest() {
        runAway()
        treadmill.acknowledgeRunaway()
        #expect(treadmill.runaway == nil)

        link.run(at: 12)
        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == nil)
        #expect(link.sent == [request])

        treadmill.setSpeed(6)
        link.run(at: 13.1)
        #expect(treadmill.runaway == .warning(requested: 6, secondsUntilStop: 5))
    }

    @Test func aNewRequestStartsOver() {
        runAway()
        timers.advance(by: .seconds(4))
        // Whoever asks for another speed is at the controls. The belt is judged against that.
        treadmill.setSpeed(3)
        #expect(treadmill.runaway == nil)
        timers.advance(by: .seconds(60))
        #expect(stops == 0)

        link.run(at: 6.1)
        #expect(treadmill.runaway == .warning(requested: 3, secondsUntilStop: 5))
    }

    @Test func pausingAnswersItToo() {
        runAway()
        treadmill.pause()
        #expect(treadmill.runaway == nil)
        timers.advance(by: .seconds(60))
        #expect(link.sent == [request, .pause])
    }

    // MARK: - Calling it off

    @Test func aSpeedBackInBoundsCallsItOff() {
        runAway()
        timers.advance(by: .seconds(4))
        link.run(at: 4.4)
        #expect(treadmill.runaway == nil)
        timers.advance(by: .seconds(5))
        #expect(link.sent == [request])

        // It's still being watched, and a second warning gets its full five seconds.
        link.run(at: 5)
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: 5))
        timers.advance(by: .seconds(4))
        #expect(link.sent == [request])
        timers.advance(by: .seconds(1))
        #expect(link.sent == [request, .stop])
    }

    @Test(arguments: [BeltState.idle, .paused, .stopping, .safetyKey])
    func aBeltThatIsNoLongerRunningCallsItOff(resting: BeltState) {
        runAway()
        timers.advance(by: .seconds(4))
        link.emit(.sample(Sample(belt: resting, speed: 0)))
        #expect(treadmill.runaway == nil)

        timers.advance(by: .seconds(60))
        #expect(link.sent == [request])
    }

    @Test func aLostLinkCallsItOffAndSaysSo() {
        runAway()
        timers.advance(by: .seconds(4))
        link.emit(.connection(.waiting(name: "FS-TEST")))
        #expect(treadmill.runaway == .unreachable)

        timers.advance(by: .seconds(60))
        #expect(link.sent == [request])

        // Nor is anything sent when the link comes back.
        link.becomeReady()
        link.run(at: 16)
        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == .unreachable)
        #expect(link.sent == [request])

        treadmill.acknowledgeRunaway()
        #expect(treadmill.runaway == nil)
    }

    // MARK: - The option

    @Test func theAutomaticStopCanBeTurnedOff() {
        treadmill.stopsRunawayBelt = false
        runAway()
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: nil))

        timers.advance(by: .seconds(60))
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: nil))
        #expect(link.sent == [request])

        treadmill.stop()
        #expect(link.sent == [request, .stop])
    }

    @Test func turningItOffCallsOffTheCountdown() {
        runAway()
        timers.advance(by: .seconds(4))
        treadmill.stopsRunawayBelt = false
        #expect(treadmill.runaway == .warning(requested: 3.5, secondsUntilStop: nil))

        timers.advance(by: .seconds(60))
        #expect(link.sent == [request])
    }
}
