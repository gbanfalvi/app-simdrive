import Foundation

/// Keeps one accessibility request at a time in flight to a device. CoreSimulatorBridge answers requests one by one and
/// never withdraws one whose sender stopped waiting, so a request sent while another goes unanswered queues behind it
/// (idb, F33). A request counts as in flight until it is answered, however late, and is `abandoned` while its sender
/// has stopped waiting.
final class RequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var inFlight = false
    private var unansweredCount = 0

    /// Requests whose senders stopped waiting and which the guest has not answered yet.
    var abandoned: Int {
        condition.withLock { unansweredCount }
    }

    /// Waits until no request is in flight, then marks one as sent; false when `deadline` passes first.
    func enter(before deadline: Date) -> Bool {
        condition.withLock {
            while inFlight {
                guard condition.wait(until: deadline) else { return false }
            }
            inFlight = true
            return true
        }
    }

    /// The sender stopped waiting for its request, which stays in flight until `answered`.
    func abandon() {
        condition.withLock { unansweredCount += 1 }
    }

    /// The guest answered the request in flight; `wasAbandoned` when its sender had stopped waiting.
    func answered(wasAbandoned: Bool) {
        condition.withLock {
            inFlight = false
            if wasAbandoned { unansweredCount -= 1 }
            condition.broadcast()
        }
    }
}
