import XCTest
@testable import Mio

final class CloudRetryTests: XCTestCase {
    func testFailuresBackOffAndSuccessfulManualRetryResetsTheSchedule() {
        let now=Date(timeIntervalSince1970:1000)
        var schedule=CloudRetrySchedule()
        XCTAssertTrue(schedule.allowsAttempt(at:now))
        schedule.record(success:false,at:now)
        XCTAssertFalse(schedule.allowsAttempt(at:now.addingTimeInterval(15)))
        XCTAssertTrue(schedule.allowsAttempt(at:now.addingTimeInterval(30)))
        for _ in 0..<12 { schedule.record(success:false,at:now) }
        XCTAssertEqual(schedule.nextAttempt,now.addingTimeInterval(300))
        schedule.record(success:true,at:now)
        XCTAssertTrue(schedule.allowsAttempt(at:now))
        schedule.record(success:false,at:now)
        XCTAssertEqual(schedule.nextAttempt,now.addingTimeInterval(30))
        schedule.reset();XCTAssertTrue(schedule.allowsAttempt(at:now))
    }
}
