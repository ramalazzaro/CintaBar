import Foundation
import Testing

@testable import TreadmillKit

@Suite struct FitShowTests {
    @Test func commandsAreFramedWithAnXorChecksum() {
        #expect([UInt8](FitShow.queryStatus) == [0x02, 0x51, 0x51, 0x03])
        #expect([UInt8](FitShow.querySpeedRange) == [0x02, 0x50, 0x02, 0x52, 0x03])
        #expect([UInt8](FitShow.stop) == [0x02, 0x53, 0x03, 0x50, 0x03])
        #expect([UInt8](FitShow.pause) == [0x02, 0x53, 0x06, 0x55, 0x03])
        #expect([UInt8](FitShow.start) == [0x02, 0x53, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x52, 0x03])
    }

    @Test func targetEncodesSpeedInTenthsAndSignedIncline() {
        #expect([UInt8](FitShow.target(speed: 3.5, incline: 0)) == [0x02, 0x53, 0x02, 35, 0, 0x72, 0x03])
        #expect(FitShow.payload(of: FitShow.target(speed: 12.34, incline: -2)) == [0x53, 0x02, 123, 0xFE])
        #expect(FitShow.payload(of: FitShow.target(speed: 99, incline: 0)) == [0x53, 0x02, 255, 0])
    }

    @Test func clockIsSentAsYearSince2000ThenMonthDayAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 30, second: 5))
        )
        #expect(
            FitShow.payload(of: FitShow.syncClock(to: date, calendar: calendar)) == [0x50, 0x00, 26, 10, 11, 9, 30, 5])
    }

    @Test func corruptFramesAreRejected() {
        #expect(FitShow.parse(Data([0x02, 0x51, 0x03, 0x00, 0x03])) == nil)  // Wrong checksum.
        #expect(FitShow.parse(Data([0x51, 0x03, 0x52, 0x03])) == nil)  // No start marker.
        #expect(FitShow.parse(Data([0x02, 0x51, 0x03, 0x52])) == nil)  // No end marker.
        #expect(FitShow.parse(Data()) == nil)
    }

    @Test func runningStatusCarriesTelemetry() {
        // 3.5 km/h, incline 2, 300 s, a distance that isn't used, 2.5 kcal, 528 steps and 90 bpm.
        let frame = FitShow.frame([0x51, 3, 35, 2, 0x2C, 0x01, 0xF4, 0x01, 0x19, 0x00, 0x10, 0x02, 90])
        #expect(
            FitShow.parse(frame)
                == .status(
                    belt: .running, speed: 3.5, incline: 2, elapsed: 300, calories: 2.5, steps: 528, heartRate: 90))
    }

    @Test func totalsAndHeartRateNeedAFullFrame() {
        // One byte short of a full frame, so the totals in it aren't taken either.
        let short = FitShow.frame([0x51, 3, 35, 2, 0x2C, 0x01, 0xF4, 0x01, 0x19, 0x00, 0x10, 0x02])
        #expect(FitShow.parse(short) == .status(belt: .running, speed: 3.5, incline: 2, elapsed: 300))

        // Nothing counted yet and no hand on the sensors, with a byte of unknown meaning at the end.
        let untouched = FitShow.frame([0x51, 3, 10, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x55])
        #expect(
            FitShow.parse(untouched)
                == .status(belt: .running, speed: 1.0, incline: 0, elapsed: 1, calories: 0, steps: 0, heartRate: 0))
    }

    @Test(arguments: [
        (code: UInt8(0), belt: BeltState.idle),
        (code: 2, belt: .countdown(3)),
        (code: 5, belt: .fault(3)),
        (code: 6, belt: .safetyKey),
        (code: 7, belt: .calibrating),
        (code: 99, belt: .idle),
    ])
    func statusWithoutTelemetry(code: UInt8, belt: BeltState) {
        #expect(
            FitShow.parse(FitShow.frame([0x51, code, 3])) == .status(belt: belt, speed: 0, incline: 0, elapsed: nil))
    }

    @Test func pausedAndStoppingKeepTheirTelemetry() {
        #expect(
            FitShow.parse(FitShow.frame([0x51, 10, 0, 0, 60, 0]))
                == .status(belt: .paused, speed: 0, incline: 0, elapsed: 60)
        )
        #expect(
            FitShow.parse(FitShow.frame([0x51, 4, 12, 0xFF, 0, 1]))
                == .status(belt: .stopping, speed: 1.2, incline: -1, elapsed: 256)
        )
    }

    @Test func speedRangeIsMaximumThenMinimumInTenths() {
        #expect(FitShow.parse(FitShow.frame([0x50, 0x02, 100, 10, 0])) == .speedRange(1.0...10.0))
        #expect(FitShow.parse(FitShow.frame([0x50, 0x02, 10, 100])) == nil)
        #expect(FitShow.parse(FitShow.frame([0x50, 0x02, 100, 0])) == nil)
    }

    @Test func inclineRangeFallsBackToNoneWhenUnsupported() {
        #expect(FitShow.parse(FitShow.frame([0x50, 0x03, 15, 0, 0x02])) == .inclineRange(0...15))
        #expect(FitShow.parse(FitShow.frame([0x50, 0x03])) == .inclineRange(0...0))
    }
}
