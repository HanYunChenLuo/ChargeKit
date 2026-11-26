/// Resolves a helper request once. Time is supplied by the caller's monotonic clock.
public struct HelperReplyDeadline {
    public enum Resolution: Equatable {
        case reply
        case timedOut
    }

    private let deadline: UInt64
    private var resolved = false

    public init(deadline: UInt64) {
        self.deadline = deadline
    }

    public mutating func resolve(at now: UInt64, receivedReply: Bool) -> Resolution? {
        guard !resolved, receivedReply || now >= deadline else { return nil }
        resolved = true
        return now >= deadline ? .timedOut : .reply
    }
}