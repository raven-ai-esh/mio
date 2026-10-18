import Foundation

struct CloudRetrySchedule {
    private(set) var nextAttempt=Date.distantPast
    private var delay:TimeInterval=15
    func allowsAttempt(at now:Date) -> Bool { now >= nextAttempt }
    mutating func record(success:Bool,at now:Date) {
        if success { delay=15;nextAttempt=now }
        else { delay=min(300,delay*2);nextAttempt=now.addingTimeInterval(delay) }
    }
    mutating func reset() { self=Self() }
}
