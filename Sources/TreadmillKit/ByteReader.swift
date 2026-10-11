import Foundation

/// Reads little-endian integers off the front of a buffer, returning `nil` once it runs out.
struct ByteReader {
    private var bytes: Data.SubSequence

    init(_ data: Data) { bytes = data[...] }

    mutating func skip(_ count: Int) { bytes = bytes.dropFirst(count) }

    mutating func unsigned(byteCount: Int) -> Int? {
        guard bytes.count >= byteCount else { return nil }
        defer { skip(byteCount) }
        return bytes.prefix(byteCount).reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func signed16() -> Int? {
        unsigned(byteCount: 2).map { Int(Int16(truncatingIfNeeded: $0)) }
    }
}
