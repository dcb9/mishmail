import Foundation

/// Gmail's per-user quota tier.
///
/// On 1 May 2026 Google cut the per-user limit for **new** Cloud projects to
/// 6,000 units a minute (from 15,000) and raised the price of the methods
/// MishMail leans on: `messages.get` is 20 units, or 60 when `format` is
/// `full`/`raw`/`html` — which is what a first sync uses. Projects that
/// already used the API between November 2025 and April 2026 keep 15,000.
///
/// The client cannot read a project's quota, and every MishMail user creates
/// their own OAuth client, so this is a setting. `standard` is the safe
/// default: a new user is on a new project and overspending earns 403s.
/// <https://developers.google.com/workspace/gmail/api/reference/quota>
///
/// Refill runs at 90% of the ceiling and burst capacity is six seconds of
/// refill, so even a minute that starts with a full bucket stays under the
/// limit: `capacity + 60 * refill` is 5,940 (standard) and 14,850 (legacy).
enum GmailQuotaTier: String, CaseIterable, Identifiable {
    /// Projects created on or after 1 May 2026.
    case standard
    /// Projects grandfathered at the old 15,000 units a minute.
    case legacy

    static let defaultsKey = "gmail.quotaTier"

    var id: String { rawValue }

    /// What the current setting says. Read on every use so flipping it in
    /// Settings takes effect without a relaunch.
    static var current: GmailQuotaTier {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .standard
        }
        return GmailQuotaTier(rawValue: raw) ?? .standard
    }

    var unitsPerMinute: Int {
        switch self {
        case .standard: return 6_000
        case .legacy: return 15_000
        }
    }

    var title: String {
        switch self {
        case .standard: return "6,000 units a minute (new projects)"
        case .legacy: return "15,000 units a minute (existing projects)"
        }
    }

    /// 90% of the ceiling, in units per second.
    var refillPerSecond: Int { unitsPerMinute * 9 / 10 / 60 }
    /// Six seconds of refill: enough to send a batch of full messages without
    /// stalling, small enough that a full bucket plus a minute of refill still
    /// stays under the limit (540 + 60×90 = 5,940 of 6,000).
    var capacity: Int { refillPerSecond * 6 }
}

/// Token bucket for Gmail's per-user quota.
///
/// A history catch-up that fires batches back to back spends faster than the
/// per-minute allowance. Gmail answers the one that crosses the line with 403
/// `rateLimitExceeded` and drops the HTTP/3 connection, which fails every
/// other in-flight get too. The engine then refuses to advance the history
/// id, and the next pass replays the same range and hits the same wall —
/// forever. Pacing the spend below the allowance, in smaller batches, keeps a
/// pass under the ceiling.
///
/// Pure value type so the pacing math is unit-tested; `GmailClient` owns one
/// per account (the limit is per user) and sleeps for the delay it returns.
struct GmailQuotaBucket {
    /// `messages.get` costs 20 units for `metadata`/`minimal`.
    static let messageGetUnits = 20
    /// …and 60 for `full`, `raw` or `html`, which is what body fetches use.
    static let messageGetFullUnits = 60
    /// Two seconds of refill at the standard tier.
    static let defaultCapacity = GmailQuotaTier.standard.capacity
    /// 90% of the standard tier's 6,000 units a minute.
    static let defaultRefillPerSecond = GmailQuotaTier.standard.refillPerSecond
    /// Which tier this bucket was built for, so `GmailClient` can notice a
    /// settings change and rebuild. Nil for a bucket with explicit numbers.
    let tier: GmailQuotaTier?
    let capacity: Int
    let refillPerSecond: Int
    /// Units still spendable at `lastRefill`. May go negative: a spend that
    /// had to wait is charged at the time it was told to wait until.
    private var tokens: Double
    private var lastRefill: Date?
    private var blockedUntil: Date?

    init(tier: GmailQuotaTier = .standard) {
        self.tier = tier
        self.capacity = tier.capacity
        self.refillPerSecond = tier.refillPerSecond
        self.tokens = Double(capacity)
        self.blockedUntil = nil
    }

    init(capacity: Int, refillPerSecond: Int) {
        self.tier = nil
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
        self.blockedUntil = nil
    }

    /// Cost of `count` message gets. `fullFormat` must match the format the
    /// caller will request: Gmail charges 60, not 20, for a full body.
    static func units(forMessageGets count: Int, fullFormat: Bool = true) -> Int {
        count * (fullFormat ? messageGetFullUnits : messageGetUnits)
    }

    /// Longest penalty the bucket keeps: the longest wait honored from a
    /// Gmail body plus the retry jitter. A clock jump or a bad stamp can then
    /// never park the account for longer.
    static let maxPenalty: TimeInterval = GmailRateLimit.maxWait + 1

    /// Seconds left in the current penalty, or zero when none is active.
    /// Clears an expired penalty and clamps one that lies further ahead than
    /// `maxPenalty` (the clock jumped back, or a bad stamp got through).
    mutating func penaltyRemaining(now: Date) -> TimeInterval {
        guard let until = blockedUntil else { return 0 }
        if until <= now {
            blockedUntil = nil
            return 0
        }
        let limit = now.addingTimeInterval(Self.maxPenalty)
        if until > limit {
            blockedUntil = limit
            if let last = lastRefill, last > limit { lastRefill = limit }
        }
        return blockedUntil!.timeIntervalSince(now)
    }

    /// Reserves `units` and returns how long the caller must wait before
    /// sending. Zero when the bucket has room now.
    ///
    /// Under a penalty the spend is reserved at the moment the penalty ends,
    /// so callers parked behind it are released one refill apart instead of
    /// all together. A single delay never exceeds `GmailRateLimit.maxWait`.
    mutating func delayBeforeSpending(units: Int, now: Date) -> TimeInterval {
        let penalty = penaltyRemaining(now: now)
        let start = now.addingTimeInterval(penalty)
        if let last = lastRefill {
            let elapsed = max(0, start.timeIntervalSince(last))
            tokens = min(Double(capacity), tokens + elapsed * Double(refillPerSecond))
            // A clock that jumped back must not stretch the next refill.
            lastRefill = min(max(last, start), now.addingTimeInterval(Self.maxPenalty))
        } else {
            lastRefill = start
        }
        tokens -= Double(units)
        // Deficit refills at `refillPerSecond`; the caller sleeps that long.
        let deficit = tokens < 0 ? -tokens / Double(refillPerSecond) : 0
        return min(penalty + deficit, GmailRateLimit.maxWait)
    }

    /// Blocks every caller until Gmail's penalty window or the local retry
    /// backoff expires. The client owns this bucket, so unrelated requests for
    /// the same account observe the same penalty. Gmail refused the last
    /// spend, so the bucket restarts empty when the penalty ends.
    mutating func block(until: Date) {
        if self.blockedUntil == nil || until > self.blockedUntil! {
            self.blockedUntil = until
        }
        tokens = min(tokens, 0)
        if lastRefill == nil || until > lastRefill! {
            lastRefill = until
        }
    }
}

/// Gmail's quota error names the moment the window reopens:
/// `"User-rate limit exceeded.  Retry after 2026-09-16T03:57:19.386Z"`.
enum GmailRateLimit {
    /// Longest wait honored from the body. A skewed clock or a far-future
    /// timestamp must not park the sync for minutes.
    static let maxWait: TimeInterval = 30

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    /// Seconds to wait before retrying, from the "Retry after <ISO 8601>"
    /// phrase in the error body. Nil when the body names no time.
    static func retryAfter(body: String, now: Date = Date()) -> TimeInterval? {
        guard let range = body.range(of: #"Retry after ([0-9T:.\-]+Z)"#, options: .regularExpression) else {
            return nil
        }
        let stamp = String(body[range]).replacingOccurrences(of: "Retry after ", with: "")
        guard let date = fractional.date(from: stamp) ?? whole.date(from: stamp) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maxWait)
    }
}

/// Delay before retrying a failed `messages.get`.
///
/// A dropped connection is back within a fraction of a second. A rate limit
/// is not: Gmail keeps answering 403 until its window reopens, so those
/// retries wait for the time Gmail names, or whole seconds when it names
/// none. Sub-second retries only burn the attempts and the whole pass.
enum GmailRetryBackoff {
    static func delay(attempt: Int, kind: MessageFetchFailureKind,
                      retryAfter: TimeInterval? = nil,
                      jitter: TimeInterval = 0) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .rateLimited:
            let scheduled = 2.0 * Double(1 << attempt)   // 2s, 4s, 8s
            base = max(scheduled, retryAfter ?? 0)
        default:
            base = 0.2 * Double(1 << attempt)   // 0.2s, 0.4s
        }
        return base + max(0, jitter)
    }

    /// Small decorrelation jitter prevents several callers released by the
    /// same quota penalty from forming another synchronized burst.
    static func jitter() -> TimeInterval {
        Double.random(in: 0...0.25)
    }
}

/// Cuts a history catch-up into slices the engine can commit one at a time.
///
/// History used to be fetched as one unit, and the new history id recorded
/// only when every message in it had landed. A rate limit anywhere in the
/// run recorded nothing, and the next pass replayed the same range — for
/// days, growing as it went. Each slice ends on a record id that is a valid
/// `startHistoryId`, so the engine saves it after the slice's messages are
/// flushed and a later failure loses one slice, not the pass.
enum HistorySlicer {
    struct Record: Equatable {
        let id: String
        /// Messages the record adds (full fetch).
        let addedIds: [String]
        /// Messages whose labels the record changes (fetch when not cached).
        let labelChangedIds: [String]
        /// Messages the record deletes. They cost no API call, but each one is
        /// a bound SQL variable and a row write, so they count toward the
        /// budget: one slice must not carry an unbounded delete.
        var deletedIds: [String] = []
        /// Position in the caller's array, so the engine can map back.
        var index: Int = 0

        var messageCount: Int { addedIds.count + labelChangedIds.count + deletedIds.count }
    }

    struct Slice: Equatable {
        let records: [Record]
        var lastRecordId: String { records.last?.id ?? "" }
    }

    /// Groups records in order until a slice holds `maxMessages` or more.
    /// A record is never split, so one oversized record forms its own slice.
    static func slices(_ records: [Record], maxMessages: Int) -> [Slice] {
        var result: [Slice] = []
        var current: [Record] = []
        var count = 0
        for record in records {
            if !current.isEmpty, count + record.messageCount > maxMessages {
                result.append(Slice(records: current))
                current = []
                count = 0
            }
            current.append(record)
            count += record.messageCount
        }
        if !current.isEmpty { result.append(Slice(records: current)) }
        return result
    }
}
