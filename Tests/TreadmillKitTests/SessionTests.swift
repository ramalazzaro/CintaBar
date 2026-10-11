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

    @Test func aClockThatGoesBackStartsANewWorkout() {
        var session = Session()
        for second in 1...60 {
            session.record(elapsed: second, speed: 6)
        }
        session.record(elapsed: 0, speed: 0)
        #expect(session == Session())
    }
}
