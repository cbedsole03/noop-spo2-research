import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawOutboxTests: XCTestCase {
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02, 0x0F, 0x01, 0x02, 0x03],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24, 0x03, 0x0A],
        [],                                   // empty frame must survive the round-trip
    ]
    private func meta(_ id: String, capturedAt: Int = 5000, synced: Bool = false) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 31538447, wall: 1736365593),
                     capturedAt: capturedAt, startTs: 1736365593, endTs: 1736365600,
                     frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
    }

    func testEnqueueThenRawFramesRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("b1"), frames: frames)
        let got = try await store.rawFrames(batchId: "b1")
        XCTAssertEqual(got, frames)
    }

    func testRawFramesUnknownBatchIsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let got = try await store.rawFrames(batchId: "nope")
        XCTAssertEqual(got, [])
    }

    func testPendingExcludesSyncedAndRespectsLimitAndOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("old", capturedAt: 100), frames: frames)
        try await store.enqueueRawBatch(meta("mid", capturedAt: 200), frames: frames)
        try await store.enqueueRawBatch(meta("new", capturedAt: 300), frames: frames)
        try await store.markRawBatchSynced(batchId: "mid", at: 999)

        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.map { $0.batchId }, ["old", "new"])   // mid synced; oldest first

        let limited = try await store.pendingRawBatches(limit: 1)
        XCTAssertEqual(limited.map { $0.batchId }, ["old"])
    }

    func testMetaRoundTripsThroughPending() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let m = meta("b1")
        try await store.enqueueRawBatch(m, frames: frames)
        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0], m)
    }

    func testRoundTripLargeBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // 200 frames x 24 bytes → packed >> (byteSize + 256) hint; exercises the truncation path.
        let manyFrames = (0..<200).map { i in [UInt8](repeating: UInt8(i & 0xFF), count: 24) }
        let byteSize = manyFrames.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "big", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: manyFrames.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: manyFrames)
        let gotLarge = try await store.rawFrames(batchId: "big")
        XCTAssertEqual(gotLarge, manyFrames)
    }

    func testRoundTripHighlyCompressibleBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // All-zero frames compress to a tiny blob but decompress LARGE — the worst case for
        // any fixed-size decode buffer heuristic.
        let zeros = (0..<300).map { _ in [UInt8](repeating: 0, count: 64) }
        let byteSize = zeros.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "z", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: zeros.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: zeros)
        let gotZeros = try await store.rawFrames(batchId: "z")
        XCTAssertEqual(gotZeros, zeros)
    }

    func testWhoop4Spo2CandidateBackfillEnrichesExistingRowAndIsIdempotent() async throws {
        let hex =
            "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
            "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
            "200364006400b80bb80b000000000000c25c1a88"
        var frame: [UInt8] = stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
        frame[5] = 12
        frame[84] = 0x20
        frame[85] = 96
        frame[86] = 98
        let length = Int(frame[1]) | (Int(frame[2]) << 8)
        let checksum = crc32(frame, 4, length)
        frame[length] = UInt8(checksum & 0xff)
        frame[length + 1] = UInt8((checksum >> 8) & 0xff)
        frame[length + 2] = UInt8((checksum >> 16) & 0xff)
        frame[length + 3] = UInt8((checksum >> 24) & 0xff)

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 1_700_000_000, red: 18_000, ir: 17_000)]),
            deviceId: "dev1")
        let batch = RawBatchMeta(
            batchId: "whoop4-v12", deviceId: "dev1",
            clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1_700_000_001,
            startTs: 1_700_000_000, endTs: 1_700_000_000,
            frameCount: 1, byteSize: frame.count)
        try await store.enqueueRawBatch(batch, frames: [frame])

        let firstChanged = try await store.backfillWhoop4Spo2CandidatesFromRawBatches()
        XCTAssertEqual(firstChanged, 1)
        let rows = try await store.spo2Samples(
            deviceId: "dev1", from: 1_700_000_000, to: 1_700_000_000, limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].red, 18_000)
        XCTAssertEqual(rows[0].ir, 17_000)
        XCTAssertEqual(rows[0].auxByte85, 96)
        XCTAssertEqual(rows[0].auxByte86, 98)
        let secondChanged = try await store.backfillWhoop4Spo2CandidatesFromRawBatches()
        XCTAssertEqual(secondChanged, 0)
    }
}
