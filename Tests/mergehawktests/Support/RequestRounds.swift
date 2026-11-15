import XCTest

/// Passes when `keys`, in start order, splits into consecutive chunks whose multisets equal each expected round in
/// order. Requests in one round may start in any order; rounds may not mix.
func assertRequestRounds(
    _ keys: [String],
    _ expected: [[String]],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if let mismatch = requestRoundsMismatch(keys, expected) {
        XCTFail(mismatch, file: file, line: line)
    }
}

/// The reason `keys` doesn't split into `expected`, or nil when it does.
func requestRoundsMismatch(_ keys: [String], _ expected: [[String]]) -> String? {
    let expectedCount = expected.reduce(0) { $0 + $1.count }
    guard keys.count == expectedCount else {
        return "Expected \(expectedCount) requests in rounds \(expected), got \(keys.count): \(keys)"
    }
    var start = 0
    for (index, round) in expected.enumerated() {
        let chunk = Array(keys[start..<(start + round.count)])
        if chunk.sorted() != round.sorted() {
            return "Round \(index + 1) expected \(round.sorted()), got \(chunk.sorted()) in \(keys)"
        }
        start += round.count
    }
    return nil
}
