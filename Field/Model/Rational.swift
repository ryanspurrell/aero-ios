import Foundation

/// An exact fraction, so a flow of 0.1 L/min or a volume is never a binary approximation. The Lean file uses `ℚ`
/// (FieldSample.lean, `Sample.before`, `volume`); this is the same arithmetic on integers. Division by zero gives 0, as
/// division does in Lean's `ℚ`, so `dueRun` agrees with the Lean definition for a flow that is not above zero.
struct Rat: Hashable, Comparable, Codable, ExpressibleByIntegerLiteral {
    let num: Int
    let den: Int   // always above 0

    init(_ n: Int, _ d: Int = 1) {
        if d == 0 { num = 0; den = 1; return }
        let g = Rat.gcd(abs(n), abs(d))
        let s = d < 0 ? -1 : 1
        num = s * n / max(g, 1)
        den = abs(d) / max(g, 1)
    }

    init(integerLiteral value: Int) { self.init(value) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(try c.decode(Int.self, forKey: .num), try c.decode(Int.self, forKey: .den))
    }
    private enum Keys: String, CodingKey { case num, den }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    static func + (a: Rat, b: Rat) -> Rat { Rat(a.num * b.den + b.num * a.den, a.den * b.den) }
    static func - (a: Rat, b: Rat) -> Rat { Rat(a.num * b.den - b.num * a.den, a.den * b.den) }
    static func * (a: Rat, b: Rat) -> Rat { Rat(a.num * b.num, a.den * b.den) }
    static func / (a: Rat, b: Rat) -> Rat { b.num == 0 ? Rat(0) : Rat(a.num * b.den, a.den * b.num) }
    static func < (a: Rat, b: Rat) -> Bool { a.num * b.den < b.num * a.den }

    var magnitude: Rat { Rat(abs(num), den) }

    /// `⌈x⌉₊`: the least whole number at or above x, and 0 for anything at or below 0 (Lean's `Nat.ceil`).
    var ceilNat: Int { num <= 0 ? 0 : (num + den - 1) / den }

    /// Reads a decimal a person types ("2", "2.5", "0.45", "2,5"). Up to 6 digits after the point; no sign, no exponent.
    /// Anything else gives nil, and the screen says what a flow looks like.
    static func parse(_ text: String) -> Rat? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1 else { return nil }
        let parts = t.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let whole = parts[0], frac = parts.count > 1 ? parts[1] : ""
        guard whole.allSatisfy({ $0.isASCII && $0.isNumber }), frac.allSatisfy({ $0.isASCII && $0.isNumber }),
              !(whole.isEmpty && frac.isEmpty), frac.count <= 6, whole.count <= 9 else { return nil }
        var den = 1
        for _ in 0..<frac.count { den *= 10 }
        guard let n = Int(whole + frac) else { return nil }
        return Rat(n, den)
    }

    /// "2", "2.5", "0.45". Exact when the fraction ends within `maxDigits` places; otherwise "about 1.33".
    func text(maxDigits: Int = 3) -> String {
        let sign = num < 0 ? "-" : ""
        let n = abs(num)
        var d = den, twos = 0, fives = 0
        while d % 2 == 0 { d /= 2; twos += 1 }
        while d % 5 == 0 { d /= 5; fives += 1 }
        let digits = max(twos, fives)
        let exact = d == 1 && digits <= maxDigits
        let places = exact ? digits : 2
        var scale = 1
        for _ in 0..<places { scale *= 10 }
        let scaled = exact ? n * scale / den : (n * scale * 2 + den) / (den * 2)   // exact, or rounded to 2 places
        let whole = scaled / scale, frac = scaled % scale
        var s = "\(whole)"
        if places > 0 {
            var f = String(frac)
            while f.count < places { f = "0" + f }
            while f.hasSuffix("0") { f.removeLast() }
            if !f.isEmpty { s += "." + f }
        }
        return (exact ? "" : "about ") + sign + s
    }
}
