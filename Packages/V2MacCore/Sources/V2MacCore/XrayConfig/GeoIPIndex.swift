import Foundation

/// Reads the protobuf of the core's `.dat` geo files.
public enum GeoIPIndex {
    struct Reader {
        var bytes: ArraySlice<UInt8>

        mutating func varint() -> Int? {
            var value = 0, shift = 0
            while let byte = bytes.first, shift < 64 {
                bytes = bytes.dropFirst()
                value |= Int(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }

        mutating func key() -> (field: Int, wire: Int)? {
            varint().map { ($0 >> 3, $0 & 7) }
        }

        mutating func chunk() -> ArraySlice<UInt8>? {
            guard let length = varint(), length >= 0, length <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(length) }
            return bytes.prefix(length)
        }

        /// The next length-delimited field; other wire types are skipped.
        mutating func message() -> (Int, ArraySlice<UInt8>)? {
            while let (field, wire) = key() {
                switch wire {
                case 2: return chunk().map { (field, $0) }
                case 0: _ = varint()
                default: return nil
                }
            }
            return nil
        }
    }
}
