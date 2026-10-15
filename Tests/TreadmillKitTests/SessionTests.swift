import Testing

@testable import TreadmillKit

@Suite struct SessionTests {
    @Test func distanceIsIntegratedFromSpeed() {
        var session = Session()
        for second in 1...600 {
            session.record(elapsed: second, speed: 6)
        }
        #expect(session.elapsed == 600)
        #expect(abs(session.distance - 1.0) < 1e-9)
    }

    @Test func repeatedSamplesWithinASecondAddNothing() {
        var session = Session()
        session.record(elapsed: 1, speed: 6)
        let distance = session.distance
        session.record(elapsed: 1, speed: 6)
        #expect(session.distance == distance)
    }

    @Test func reportedDistanceWins() {
        var session = Session()
        session.record(elapsed: 1, speed: 6, distance: 0.25)
        #expect(session.distance == 0.25)
    }

    @Test func joiningMidWorkoutDoesNotInventDistance() {
        var session = Session()
        session.record(elapsed: 900, speed: 6)
        #expect(session.elapsed == 900)
        #expect(session.distance == 0)
    }

    @Test func caloriesAndStepsAreTheTreadmillsOwnTotals() {
        var session = Session()
        session.record(elapsed: 60, speed: 6)
        #expect(session.calories == 0)
        #expect(session.steps == 0)

        session.record(calories: 7.5, steps: 130)
        session.record(elapsed: 61, speed: 6)
        #expect(session.calories == 7.5)
        #expect(session.steps == 130)

        // Whichever one a report leaves out keeps its last value.
        session.record(calories: nil, steps: 132)
        session.record(calories: 7.6, steps: nil)
        #expect(session.calories == 7.6)
        #expect(session.steps == 132)
    }

    @Test func aClockThatGoesBackStartsANewWorkout() {
        var session = Session()
        for second in 1...60 {
            session.record(elapsed: second, speed: 6)
        }
        session.record(calories: 7.5, steps: 130)
        session.record(elapsed: 0, speed: 0)
        #expect(session == Session())
    }

    // MARK: - Held for a pause

    /// Ten minutes in, held for a pause.
    private func heldSession() -> Session {
        var session = Session()
        session.record(elapsed: 600, speed: 6, distance: 1)
        session.record(calories: 50, steps: 1200)
        session.isHeld = true
        return session
    }

    @Test func nothingCountsWhileHeld() {
        var session = heldSession()
        // A clock that keeps going, then counts that start over, which would be a new workout.
        session.record(elapsed: 605, speed: 0, distance: 1.01)
        session.record(calories: 51, steps: 1210)
        session.record(elapsed: 0, speed: 0, distance: 0)
        session.record(calories: 0, steps: 0)
        #expect(session.elapsed == 600)
        #expect(abs(session.distance - 1) < 1e-9)
        #expect(session.calories == 50)
        #expect(session.steps == 1200)
    }

    @Test func countsStartedOverWhileHeldCarryOn() {
        var session = heldSession()
        session.record(elapsed: 0, speed: 0, distance: 0)
        session.record(calories: 0, steps: 0)
        session.isHeld = false

        session.record(elapsed: 1, speed: 3, distance: 0.001)
        session.record(calories: 0.1, steps: 2)
        session.record(elapsed: 2, speed: 3, distance: 0.002)
        #expect(session.elapsed == 601)
        #expect(abs(session.distance - 1.001) < 1e-9)
        #expect(session.calories == 50.0)
        #expect(session.steps == 1200)
    }

    @Test func countsStartedOverAsTheBeltStartsAgainCarryOnToo() {
        var session = heldSession()
        session.isHeld = false

        // Each count picks up in a report of its own, and none of those first reports counts.
        session.record(elapsed: 2, speed: 3, distance: 0.002)
        session.record(calories: nil, steps: 3)
        session.record(calories: 0.2, steps: nil)
        #expect(session.elapsed == 600)
        #expect(abs(session.distance - 1.0) < 1e-9)
        #expect(session.calories == 50.0)
        #expect(session.steps == 1200)
    }

    @Test func anIntegratedDistanceCarriesOnToo() {
        var session = Session()
        for second in 1...60 {
            session.record(elapsed: second, speed: 6)
        }
        session.isHeld = true
        session.record(elapsed: 0, speed: 0)
        session.isHeld = false
        for second in 1...60 {
            session.record(elapsed: second, speed: 6)
        }
        #expect(session.elapsed == 119)
        #expect(abs(session.distance - (0.1 + 59.0 * 6 / 3600)) < 1e-9)
    }

    @Test func onlyTheFirstReportAfterAHoldMayStartOver() {
        var session = heldSession()
        session.isHeld = false
        // The first report after a hold is where the count picks up, not progress.
        session.record(elapsed: 601, speed: 6)
        #expect(session.elapsed == 600)

        // Outside a pause, a clock that goes back is a new workout again.
        session.record(elapsed: 0, speed: 0)
        #expect(session == Session())
    }

    @Test func aTreadmillThatPausesItsOwnCountsCarriesOnOnceToo() {
        // What the Noga FT-200 does: at the stop command it freezes its clock and distance, reports
        // zero for both while the belt is stopped, and picks them up where they were once the belt
        // runs again.
        var session = Session()
        for second in 1...226 {
            session.record(elapsed: second, speed: 6, distance: Double(second) / 600)
        }
        session.isHeld = true
        session.record(elapsed: 0, speed: 0, distance: 0)
        session.record(elapsed: 0, speed: 0, distance: 0)
        #expect(session.elapsed == 226)
        #expect(abs(session.distance - 226.0 / 600) < 1e-9)

        session.isHeld = false
        session.record(elapsed: 226, speed: 1, distance: 226.0 / 600)
        #expect(session.elapsed == 226)
        #expect(abs(session.distance - 226.0 / 600) < 1e-9)
        session.record(elapsed: 227, speed: 1, distance: 227.0 / 600)
        #expect(session.elapsed == 227)
        #expect(abs(session.distance - 227.0 / 600) < 1e-9)
    }
}
