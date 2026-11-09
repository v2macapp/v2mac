/// The address arithmetic needed by IPv6 rules, including on macOS 14.
struct IPAddressBits: Sendable, Comparable, ExpressibleByIntegerLiteral {
    var high: UInt64
    var low: UInt64

    init<T: BinaryInteger>(_ value: T) { high = 0; low = UInt64(value) }
    init(integerLiteral value: UInt64) { self.init(value) }
    private init(high: UInt64, low: UInt64) { self.high = high; self.low = low }
    static let max = Self(high: .max, low: .max)
    var trailingZeroBitCount: Int { low == 0 ? 64 + high.trailingZeroBitCount : low.trailingZeroBitCount }

    static func < (a: Self, b: Self) -> Bool { a.high == b.high ? a.low < b.low : a.high < b.high }
    static prefix func ~ (a: Self) -> Self { Self(high: ~a.high, low: ~a.low) }
    static func & (a: Self, b: Self) -> Self { Self(high: a.high & b.high, low: a.low & b.low) }
    static func | (a: Self, b: Self) -> Self { Self(high: a.high | b.high, low: a.low | b.low) }
    static func + (a: Self, b: Self) -> Self {
        let (low, carry) = a.low.addingReportingOverflow(b.low)
        return Self(high: a.high &+ b.high &+ (carry ? 1 : 0), low: low)
    }
    static func - (a: Self, b: Self) -> Self {
        let (low, borrow) = a.low.subtractingReportingOverflow(b.low)
        return Self(high: a.high &- b.high &- (borrow ? 1 : 0), low: low)
    }
    static func << (a: Self, n: Int) -> Self {
        precondition(n >= 0)
        if n >= 128 { return 0 }
        if n >= 64 { return Self(high: a.low << (n - 64), low: 0) }
        if n == 0 { return a }
        return Self(high: (a.high << n) | (a.low >> (64 - n)), low: a.low << n)
    }
    static func >> (a: Self, n: Int) -> Self {
        precondition(n >= 0)
        if n >= 128 { return 0 }
        if n >= 64 { return Self(high: 0, low: a.high >> (n - 64)) }
        if n == 0 { return a }
        return Self(high: a.high >> n, low: (a.low >> n) | (a.high << (64 - n)))
    }
}
