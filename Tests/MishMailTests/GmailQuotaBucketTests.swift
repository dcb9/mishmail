import XCTest

/// Gmail's per-user limit is 6,000 quota units a minute for Cloud projects
/// created on or after 1 May 2026 (15,000 for older ones), and a full-format
/// `messages.get` costs 60 units. A pass that fires batches back to back
/// spends faster than that and trips a 403 rateLimitExceeded. The bucket
/// paces requests so a pass stays under the ceiling.
final class GmailQuotaBucketTests: XCTestCase {
    func testFullBucketSpendsWithoutDelay() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 0, accuracy: 0.001)
    }

    func testSecondFullBatchWaitsOneSecond() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 1.0, accuracy: 0.001)
    }

    func testRefillAfterOneSecondClearsTheWait() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0.addingTimeInterval(1)),
                       0, accuracy: 0.001)
    }

    func testSmallSpendsAccumulate() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<50 { _ = bucket.delayBeforeSpending(units: 5, now: t0) }  // 250 units
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: t0), 0.02, accuracy: 0.001)
    }

    func testDelayedSpendIsChargedAtTheWaitedTime() {
        // Ask for 250 twice at t0: the second must wait 1s. A third ask at
        // t0 must wait a further second (2s), not reuse the first wait.
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 2.0, accuracy: 0.001)
    }

    /// The default tier must stay under 6,000 units a minute even for a
    /// minute that starts with a full bucket: the burst plus everything the
    /// refill adds over the following 60 seconds.
    func testDefaultsStayUnderTheNewPerUserLimit() {
        let bucket = GmailQuotaBucket()
        XCTAssertEqual(bucket.tier, .standard)
        XCTAssertEqual(bucket.refillPerSecond, 90)
        XCTAssertEqual(bucket.capacity, 540)
        XCTAssertLessThanOrEqual(
            bucket.capacity + 60 * bucket.refillPerSecond,
            GmailQuotaTier.standard.unitsPerMinute)
    }

    /// The legacy tier is for grandfathered projects only, but it must be
    /// consistent with the 15,000 it advertises.
    func testLegacyTierStaysUnderFifteenThousand() {
        let bucket = GmailQuotaBucket(tier: .legacy)
        XCTAssertLessThanOrEqual(
            bucket.capacity + 60 * bucket.refillPerSecond,
            GmailQuotaTier.legacy.unitsPerMinute)
        XCTAssertGreaterThan(bucket.refillPerSecond, GmailQuotaBucket.defaultRefillPerSecond)
    }

    /// A single batch must not spend more than the burst capacity, or every
    /// batch would start by waiting for a refill that cannot arrive.
    func testBatchFitsWithinTheBurstCapacity() {
        let bucket = GmailQuotaBucket()
        let batchCost = GmailQuotaBucket.units(forMessageGets: GmailClient.batchGetChunkSize)
        XCTAssertLessThanOrEqual(batchCost, bucket.capacity)
    }

    func testMessageGetCosts() {
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 1), 60)
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 8), 480)
        // metadata/minimal are the cheap formats.
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 1, fullFormat: false), 20)
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 50, fullFormat: false), 1_000)
    }

    /// The per-method table from
    /// https://developers.google.com/workspace/gmail/api/reference/quota
    /// as of the 1 May 2026 change.
    func testEndpointCosts() {
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/profile"), 1)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/history"), 2)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/labels"), 1)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/labels"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/send"), 100)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/m1/modify"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/m1/trash"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/m1/untrash"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/threads/t1/modify"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/threads/t1/trash"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/drafts"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/drafts"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "DELETE", path: "/drafts/d1"), 10)
    }

    /// `messages.get` is 20 units for metadata and 60 for a full body — the
    /// regression the issue reported (it was charged 5 for both).
    func testMessageGetCostsDependOnFormat() {
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1",
                                            format: "metadata"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1",
                                            format: "minimal"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1",
                                            format: "full"), 60)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1",
                                            format: "raw"), 60)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1",
                                            format: "html"), 60)
    }

    func testAttachmentAndThreadGetsUseTheNewPrices() {
        XCTAssertEqual(GmailClient.quotaCost(method: "GET",
                                             path: "/messages/m1/attachments/a1"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/threads/t1"), 40)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/threads/t1",
                                             format: "full"), 120)
    }

    /// The tier is a setting; an unknown or absent value must fall back to
    /// the safe (new-project) default rather than the generous one.
    func testUnknownTierFallsBackToStandard() {
        let key = GmailQuotaTier.defaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(GmailQuotaTier.current, .standard)
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(GmailQuotaTier.current, .standard)
        UserDefaults.standard.set(GmailQuotaTier.legacy.rawValue, forKey: key)
        XCTAssertEqual(GmailQuotaTier.current, .legacy)
    }

    func testPenaltyBlocksAllCallersUntilItExpires() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(4))
        XCTAssertEqual(bucket.penaltyRemaining(now: t0), 4, accuracy: 0.001)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: t0), 4.02, accuracy: 0.001)
        XCTAssertEqual(bucket.penaltyRemaining(now: t0.addingTimeInterval(4)), 0, accuracy: 0.001)
    }

    /// Callers parked behind one penalty used to get the same wake time and
    /// no reservation, so they all fired together and tripped the limit
    /// again. Each reservation now lands one refill after the previous one.
    func testCallersParkedBehindAPenaltyAreReleasedInSequence() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(4))
        let delays = (0..<3).map { _ in bucket.delayBeforeSpending(units: 50, now: t0) }
        XCTAssertEqual(delays[0], 4.25, accuracy: 0.001)
        XCTAssertEqual(delays[1], 4.5, accuracy: 0.001)
        XCTAssertEqual(delays[2], 4.75, accuracy: 0.001)
    }

    /// The client parks until the penalty ends, then reserves. The bucket
    /// restarts empty, so waking callers still queue behind each other.
    func testReservingAfterThePenaltyStartsFromAnEmptyBucket() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(2))
        let wake = t0.addingTimeInterval(2)
        XCTAssertEqual(bucket.penaltyRemaining(now: wake), 0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 50, now: wake), 0.25, accuracy: 0.001)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 50, now: wake), 0.5, accuracy: 0.001)
    }

    /// A clock that jumped (or a far-future stamp) must not park the account
    /// past the longest wait Gmail can ask for.
    func testFarFuturePenaltyIsClamped() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(3_600))
        XCTAssertEqual(bucket.penaltyRemaining(now: t0), GmailQuotaBucket.maxPenalty, accuracy: 0.001)
        XCTAssertLessThanOrEqual(bucket.delayBeforeSpending(units: 5, now: t0), GmailRateLimit.maxWait)
        // Once the clamped penalty ends the bucket works normally again.
        let later = t0.addingTimeInterval(GmailQuotaBucket.maxPenalty + 10)
        XCTAssertEqual(bucket.penaltyRemaining(now: later), 0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: later), 0, accuracy: 0.001)
    }

    func testSingleDelayIsCappedAtMaxWait() {
        var bucket = GmailQuotaBucket(capacity: 10, refillPerSecond: 1)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 10_000, now: t0),
                       GmailRateLimit.maxWait, accuracy: 0.001)
    }
}
