import Testing

@testable import TreadmillKit

/// Treadmills that acknowledge a pause and keep the belt running, as the Noga FT-200 does over
/// FTMS, and the pause that stands in for it by stopping the belt.
@MainActor
@Suite struct PauseTests {
    private let link = FakeLink()
    private let timers = FakeTimers()
    private let treadmill: Treadmill

    init() {
        treadmill = Treadmill(link: link, scheduler: timers.schedule)
    }

    /// Connects to a treadmill with a motorized incline.
    private func connect() {
        link.becomeReady()
        link.emit(.inclineRange(0...10, step: 1))
    }

    /// Has the belt carry on at `speed` as if it hadn't been told to pause, reporting every second
    /// until the check runs out.
    private func keepGoing(at speed: Double, from elapsed: Int) {
        for second in 1...4 {
            link.run(at: speed, elapsed: elapsed + second)
            timers.advance(by: .seconds(1))
        }
    }

    // MARK: - Finding out

    @Test func aPauseTheBeltIgnoresIsNoticed() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        #expect(link.sent == [.pause])

        // The FT-200 says it paused, and carries on as before.
        for second in 61...63 {
            link.run(at: 4, elapsed: second)
            timers.advance(by: .seconds(1))
        }
        // Pressing again meanwhile adds nothing.
        treadmill.pause()
        #expect(link.sent == [.pause])
        #expect(!treadmill.ignoresPause)

        link.run(at: 4, elapsed: 64)
        timers.advance(by: .seconds(1))
        #expect(treadmill.ignoresPause)
        #expect(link.remembersIgnoringPause)
        // So the first press still stops the belt, a few seconds late.
        #expect(link.sent == [.pause, .stop])
    }

    @Test func aBeltThatSlowsDownHonorsIt() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        // As FTMS has it: running until the belt stands still.
        link.run(at: 3.2, elapsed: 61)
        link.run(at: 1.5, elapsed: 62)
        link.emit(.sample(Sample(belt: .paused, speed: 0)))
        timers.advance(by: .seconds(60))
        #expect(link.sent == [.pause])
        #expect(!treadmill.ignoresPause)
        #expect(!link.remembersIgnoringPause)
        #expect(treadmill.belt == .paused)

        // The treadmill resumes at its own speed, as it always did.
        treadmill.start()
        link.run(at: 4, elapsed: 63)
        #expect(link.sent == [.pause, .start])
    }

    @Test(arguments: [BeltState.paused, .stopping])
    func aBeltThatSaysItIsPausingHonorsIt(state: BeltState) {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        // FitShow may say so before the belt has slowed down at all.
        link.emit(.sample(Sample(belt: state, speed: 4, elapsed: 61)))
        timers.advance(by: .seconds(60))
        #expect(link.sent == [.pause])
        #expect(!treadmill.ignoresPause)
    }

    @Test func aTreadmillThatGoesQuietProvesNothing() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        timers.advance(by: .seconds(60))
        #expect(link.sent == [.pause])
        #expect(!treadmill.ignoresPause)
    }

    @Test func stoppingCallsOffTheCheck() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        link.run(at: 4, elapsed: 61)
        treadmill.stop()
        keepGoing(at: 4, from: 61)
        #expect(link.sent == [.pause, .stop])
        #expect(!treadmill.ignoresPause)
    }

    @Test func askingForASpeedCallsOffThePause() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        treadmill.setSpeed(5)
        keepGoing(at: 5, from: 60)
        #expect(link.sent == [.pause, .target(speed: 5, incline: 0)])
        #expect(!treadmill.ignoresPause)
    }

    // MARK: - Remembering

    @Test func whatIsLearnedIsRememberedForTheTreadmill() {
        connect()
        link.run(at: 4, elapsed: 60)
        treadmill.pause()
        keepGoing(at: 4, from: 60)
        #expect(link.remembersIgnoringPause)

        // Another treadmill might not.
        link.emit(.connection(.waiting(name: "FS-TEST")))
        #expect(!treadmill.ignoresPause)
        // This one comes back.
        connect()
        #expect(treadmill.ignoresPause)

        // And after a relaunch, the first pause stops the belt straight away.
        let relaunched = Treadmill(link: link, scheduler: timers.schedule)
        connect()
        #expect(relaunched.ignoresPause)
        link.run(at: 4, elapsed: 1)
        relaunched.pause()
        #expect(link.sent == [.pause, .stop, .stop])
    }

    // MARK: - Pausing by stopping

    @Test func aTreadmillKnownToIgnoreItIsStoppedStraightAway() {
        link.remembersIgnoringPause = true
        connect()
        #expect(treadmill.ignoresPause)
        link.run(at: 5, elapsed: 300)
        treadmill.pause()
        #expect(link.sent == [.stop])

        // FTMS reports a belt that's slowing down as running. Nothing more is asked of it.
        link.run(at: 2.5, elapsed: 301)
        #expect(treadmill.belt == .running)
        treadmill.setSpeed(6)
        treadmill.setIncline(2)
        treadmill.pause()
        #expect(link.sent == [.stop])

        // Then as idle, once it stands still.
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        #expect(treadmill.belt == .paused)
        #expect(!treadmill.isMoving)
        timers.advance(by: .seconds(60))
        #expect(link.sent == [.stop])
    }

    @Test func resumingGoesBackToTheSpeedAndIncline() {
        link.remembersIgnoringPause = true
        connect()
        link.emit(.sample(Sample(belt: .running, speed: 5, incline: 3, elapsed: 300)))
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0, incline: 3)))

        treadmill.start()
        #expect(link.sent == [.stop, .start])
        link.emit(.sample(Sample(belt: .countdown(3))))
        #expect(treadmill.belt == .countdown(3))

        // The FT-200 starts at its slowest, and the belt only goes back once it's moving.
        link.emit(.sample(Sample(belt: .running, speed: 1, incline: 0, elapsed: 1)))
        #expect(treadmill.belt == .running)
        #expect(link.sent == [.stop, .start, .target(speed: 5, incline: 3)])
        #expect(treadmill.targetSpeed == 5)
        #expect(treadmill.targetIncline == 3)
    }

    @Test func itResumesAtWhatWasAskedFor() {
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 5, elapsed: 300)
        // Paused before the belt got there.
        treadmill.setSpeed(5.5)
        treadmill.setIncline(2)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        treadmill.start()
        link.run(at: 1, elapsed: 1)
        #expect(link.sent.last == .target(speed: 5.5, incline: 2))
    }

    @Test func aSpeedLimitSetWhilePausedHoldsTheResumeToIt() {
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 8, elapsed: 300)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        treadmill.speedLimit = 6
        treadmill.start()
        link.run(at: 1, elapsed: 1)
        #expect(link.sent == [.stop, .start, .target(speed: 6, incline: 0)])
    }

    @Test func itResumesInMilesToo() {
        treadmill.treadmillsSpeakingMiles = ["FS-TEST"]
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 3, elapsed: 300)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        treadmill.start()
        link.run(at: 0.6, elapsed: 1)
        #expect(link.sent == [.stop, .start, .target(speed: 3, incline: 0)])
    }

    @Test func aResumeTheTreadmillRefusesLeavesItPaused() {
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 5, elapsed: 300)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        treadmill.start()
        // What the FTMS link reports when the start is refused.
        link.emit(.sample(Sample(belt: .countdown(0))))
        link.emit(.sample(Sample(belt: .idle)))
        #expect(treadmill.belt == .paused)

        treadmill.start()
        link.run(at: 1, elapsed: 1)
        #expect(link.sent == [.stop, .start, .start, .target(speed: 5, incline: 0)])
    }

    @Test func stoppingWhilePausedEndsTheWorkout() {
        link.remembersIgnoringPause = true
        connect()
        link.emit(.sample(Sample(belt: .running, speed: 5, elapsed: 300, distance: 0.4)))
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0, elapsed: 0, distance: 0)))
        treadmill.stop()
        #expect(link.sent == [.stop, .stop])
        #expect(treadmill.belt == .idle)
        #expect(treadmill.session == Session())

        // What comes next is a new workout, at the treadmill's own speed.
        treadmill.start()
        link.run(at: 1, elapsed: 1)
        #expect(link.sent == [.stop, .stop, .start])
        #expect(treadmill.session.elapsed == 1)
    }

    @Test func theConsoleCanResumeItButNotTheSpeed() {
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 5, elapsed: 300)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0, elapsed: 0)))

        // Started from the console, which is no request to go back to 5 km/h.
        link.emit(.sample(Sample(belt: .countdown(3))))
        link.run(at: 1, elapsed: 1)
        #expect(treadmill.belt == .running)
        #expect(link.sent == [.stop])
        // The first report after the pause is where the clock picks up, not progress.
        #expect(treadmill.session.elapsed == 300)
    }

    @Test func losingTheConnectionEndsThePause() {
        link.remembersIgnoringPause = true
        connect()
        link.run(at: 5, elapsed: 300)
        treadmill.pause()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))

        link.emit(.connection(.waiting(name: "FS-TEST")))
        #expect(treadmill.belt == .idle)
        #expect(!treadmill.ignoresPause)

        connect()
        link.emit(.sample(Sample(belt: .idle, speed: 0)))
        #expect(treadmill.belt == .idle)
        treadmill.start()
        link.run(at: 1, elapsed: 1)
        #expect(link.sent == [.stop, .start])
    }

    // MARK: - The workout

    @Test func theWorkoutCarriesOnThroughThePause() {
        link.remembersIgnoringPause = true
        connect()
        link.emit(.sample(Sample(belt: .running, speed: 6, elapsed: 600, distance: 1, calories: 50, steps: 1200)))
        treadmill.pause()

        // A treadmill that starts its counts over as the belt stops, the steps in a report of their own.
        link.emit(.sample(Sample(steps: 0)))
        link.emit(.sample(Sample(belt: .running, speed: 2, elapsed: 601, distance: 1.001, calories: 50)))
        link.emit(.sample(Sample(belt: .idle, speed: 0, elapsed: 0, distance: 0, calories: 0)))
        #expect(treadmill.belt == .paused)
        #expect(treadmill.session.elapsed == 600)
        #expect(abs(treadmill.session.distance - 1) < 1e-9)
        #expect(treadmill.session.calories == 50)
        #expect(treadmill.session.steps == 1200)

        // Nor does the clock run while the belt is paused, whatever the treadmill's does.
        for second in 1...30 {
            link.emit(.sample(Sample(belt: .idle, speed: 0, elapsed: second)))
            timers.advance(by: .seconds(1))
        }
        #expect(treadmill.session.elapsed == 600)

        treadmill.start()
        link.emit(.sample(Sample(belt: .countdown(3))))
        link.emit(.sample(Sample(belt: .running, speed: 1, elapsed: 1, distance: 0.001, calories: 0)))
        link.emit(.sample(Sample(steps: 2)))
        link.emit(.sample(Sample(belt: .running, speed: 3, elapsed: 2, distance: 0.002, calories: 1)))
        #expect(treadmill.session.elapsed == 601)
        #expect(abs(treadmill.session.distance - 1.001) < 1e-9)
        #expect(treadmill.session.calories == 51)
        #expect(treadmill.session.steps == 1200)
    }

    @Test func aTreadmillThatPausesItsOwnCountsDoesNotCountThemTwice() {
        // What the Noga FT-200 does over FTMS: at the stop command it freezes its clock and distance,
        // reports zero for both while the belt is stopped, and picks them up where they were once
        // the belt runs again.
        link.remembersIgnoringPause = true
        connect()
        link.emit(.sample(Sample(belt: .running, speed: 6, elapsed: 226, distance: 0.377)))
        treadmill.pause()
        link.emit(.sample(Sample(belt: .running, speed: 3, elapsed: 0, distance: 0)))
        link.emit(.sample(Sample(belt: .idle, speed: 0, elapsed: 0, distance: 0)))
        #expect(treadmill.session.elapsed == 226)

        treadmill.start()
        link.emit(.sample(Sample(belt: .countdown(3))))
        link.emit(.sample(Sample(belt: .running, speed: 1, elapsed: 226, distance: 0.377)))
        #expect(treadmill.session.elapsed == 226)
        #expect(abs(treadmill.session.distance - 0.377) < 1e-9)
        link.emit(.sample(Sample(belt: .running, speed: 1.5, elapsed: 227, distance: 0.3774)))
        #expect(treadmill.session.elapsed == 227)
        #expect(abs(treadmill.session.distance - 0.3774) < 1e-9)
    }
}
