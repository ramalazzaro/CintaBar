import Foundation
import Testing

@testable import TreadmillKit

@Suite struct FTMSTests {
    @Test func targetsAreLittleEndianFixedPoint() {
        #expect([UInt8](FTMS.setSpeed(3.5)) == [0x02, 0x5E, 0x01])
        #expect([UInt8](FTMS.setIncline(1.5)) == [0x03, 0x0F, 0x00])
        #expect([UInt8](FTMS.setIncline(-0.5)) == [0x03, 0xFB, 0xFF])
    }

    @Test func treadmillDataWithSpeedOnly() {
        let parsed = FTMS.parseTreadmillData(Data([0x00, 0x00, 0x5E, 0x01]))
        #expect(parsed == FTMS.TreadmillData(speed: 3.5))
    }

    @Test func treadmillDataWithEnergyAndHeartRate() {
        // Flags: distance, incline, energy, heart rate and elapsed time.
        let notification: [UInt8] = [
            0x8C, 0x05,
            0x5E, 0x01,  // 3.50 km/h
            0xD2, 0x04, 0x00,  // 1234 m
            0x0F, 0x00, 0x00, 0x00,  // 1.5 %, ramp angle
            0x19, 0x00, 0x2C, 0x01, 0x05,  // 25 kcal, then per hour and per minute
            0x5A,  // 90 bpm
            0x58, 0x02,  // 600 s
        ]
        let parsed = FTMS.parseTreadmillData(Data(notification))
        #expect(
            parsed
                == FTMS.TreadmillData(
                    speed: 3.5, distance: 1.234, incline: 1.5, elapsed: 600, calories: 25, heartRate: 90))
    }

    @Test func treadmillDataSkipsFieldsItDoesNotUse() {
        // Flags: average speed, elevation gain, both paces, heart rate, metabolic equivalent and
        // elapsed time.
        let notification: [UInt8] = [
            0x72, 0x07,
            0x5E, 0x01,  // 3.50 km/h
            0x2C, 0x01,  // Average speed
            0x0A, 0x00, 0x00, 0x00,  // Elevation gain
            0x11, 0x14,  // Instantaneous and average pace
            0x5A,  // 90 bpm
            0x23,  // Metabolic equivalent
            0x58, 0x02,  // 600 s
        ]
        let parsed = FTMS.parseTreadmillData(Data(notification))
        #expect(parsed == FTMS.TreadmillData(speed: 3.5, elapsed: 600, heartRate: 90))
    }

    @Test func energyTheTreadmillDoesNotCountIsLeftOut() {
        // Flags: energy and heart rate. An energy of all ones means "not available".
        let notification: [UInt8] = [0x80, 0x01, 0x5E, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x5A]
        #expect(FTMS.parseTreadmillData(Data(notification)) == FTMS.TreadmillData(speed: 3.5, heartRate: 90))
    }

    @Test func treadmillDataWithoutSpeedWhenMoreDataIsSet() {
        // Bit 0 set means this notification carries no speed; here it only has the elapsed time.
        let parsed = FTMS.parseTreadmillData(Data([0x01, 0x04, 0x3C, 0x00]))
        #expect(parsed == FTMS.TreadmillData(elapsed: 60))
    }

    @Test func treadmillDataCapturedFromANogaFT200() {
        // Each second the FT-200 sends its telemetry followed by what's taken for a step count.
        // Seventeen seconds in it has counted no energy or steps yet, and it has no heart rate
        // to give.
        let telemetry: [UInt8] = [
            0x8C, 0x05, 0x64, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x11, 0x00,
        ]
        #expect(
            FTMS.parseTreadmillData(Data(telemetry))
                == FTMS.TreadmillData(
                    speed: 1.0, distance: 0.004, incline: 0, elapsed: 17, calories: 0, heartRate: 0))
        #expect(FTMS.parseTreadmillData(Data([0x01, 0x20, 0x00, 0x00, 0x00])) == FTMS.TreadmillData(steps: 0))
    }

    @Test func stepCountIsReadFromTheReservedFlagAsTwoBytes() {
        // An assumption, not the specification: no capture shows these bytes moving. The third
        // one is left out of the count either way.
        #expect(FTMS.parseTreadmillData(Data([0x01, 0x20, 0x10, 0x02, 0x00])) == FTMS.TreadmillData(steps: 528))
        #expect(FTMS.parseTreadmillData(Data([0x01, 0x20, 0x10, 0x02, 0x07])) == FTMS.TreadmillData(steps: 528))
    }

    @Test func stepCountComesAfterEverythingTheSpecificationDefines() {
        // Flags: no speed, elapsed time, remaining time, belt force with power output, and steps.
        let notification: [UInt8] = [
            0x01, 0x3C,
            0x58, 0x02,  // 600 s
            0x2C, 0x01,  // Remaining time
            0x05, 0x00, 0x64, 0x00,  // Force on the belt and power output
            0x10, 0x02, 0x00,  // 528 steps
        ]
        #expect(FTMS.parseTreadmillData(Data(notification)) == FTMS.TreadmillData(elapsed: 600, steps: 528))
    }

    @Test func truncatedTreadmillDataYieldsWhatIsThere() {
        #expect(FTMS.parseTreadmillData(Data([0x04])) == nil)
        #expect(FTMS.parseTreadmillData(Data([0x04, 0x00, 0x5E, 0x01, 0xD2])) == FTMS.TreadmillData(speed: 3.5))
    }

    @Test func supportedRanges() throws {
        let speed = try #require(FTMS.parseSpeedRange(Data([0x64, 0x00, 0xB0, 0x04, 0x0A, 0x00])))
        #expect(speed.range == 1.0...12.0)
        #expect(speed.step == 0.1)

        let incline = try #require(FTMS.parseInclineRange(Data([0xEC, 0xFF, 0x96, 0x00, 0x05, 0x00])))
        #expect(incline.range == -2.0...15.0)
        #expect(incline.step == 0.5)

        #expect(FTMS.parseSpeedRange(Data([0x64, 0x00])) == nil)
    }

    @Test func statusEvents() {
        #expect(FTMS.parseStatus(Data([0x02, 0x01])) == .stopped)
        #expect(FTMS.parseStatus(Data([0x02, 0x02])) == .paused)
        #expect(FTMS.parseStatus(Data([0x03])) == .safetyKey)
        #expect(FTMS.parseStatus(Data([0x04])) == .started)
        #expect(FTMS.parseStatus(Data([0x05, 0x5E, 0x01])) == nil)
    }

    @Test func startRejection() {
        #expect(FTMS.isStartRejection(Data([0x80, 0x07, 0x04])))
        #expect(!FTMS.isStartRejection(Data([0x80, 0x07, 0x01])))
        #expect(!FTMS.isStartRejection(Data([0x80, 0x02, 0x04])))
    }

    @Test func beltTrackerFollowsAWorkout() {
        var tracker = FTMS.BeltTracker()
        #expect(tracker.state == .idle)

        tracker.startRequested()
        tracker.record(speed: 0)
        #expect(tracker.state == .countdown(0))

        tracker.record(speed: 1.0)
        #expect(tracker.state == .running)

        // The pause event arrives while the belt is still slowing down.
        tracker.record(.paused)
        #expect(tracker.state == .running)
        tracker.record(speed: 0)
        #expect(tracker.state == .paused)

        // Resumed from the console, with no event.
        tracker.record(speed: 2.0)
        #expect(tracker.state == .running)

        tracker.record(.stopped)
        tracker.record(speed: 0)
        #expect(tracker.state == .idle)
    }

    @Test func beltTrackerGivesUpOnARefusedStart() {
        var tracker = FTMS.BeltTracker()
        tracker.record(.safetyKey)
        #expect(tracker.state == .safetyKey)

        tracker.startRequested()
        #expect(tracker.state == .countdown(0))
        tracker.startCancelled()
        #expect(tracker.state == .idle)
    }
}
