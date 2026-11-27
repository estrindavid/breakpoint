import Foundation

/// Ed25519 (RFC 8032) in plain Swift, for platforms without CryptoKit (Windows).
///
/// A direct transcription of TweetNaCl's `crypto_sign` (public domain): field elements are 16
/// signed 64-bit limbs of 16 bits. Verification is what the app needs (an update is installed only
/// with a valid release signature, SPEC §2.11); signing exists for tests and the harness's
/// throwaway keys. Verification also rejects a non-canonical `S` (≥ L), as CryptoKit does.
/// Tests check it against RFC 8032 §7.1 and, on Apple platforms, against CryptoKit.
public enum Ed25519 {
    public static let publicKeyBytes = 32
    public static let seedBytes = 32
    public static let signatureBytes = 64

    /// The public key of a 32-byte private key (the seed, as `rawRepresentation` is in CryptoKit).
    public static func publicKey(seed: [UInt8]) -> [UInt8]? {
        guard seed.count == seedBytes else { return nil }
        var d = SHA2.sha512(seed)
        clamp(&d)
        var p = Point()
        scalarBase(&p, Array(d[0..<32]))
        return pack(p)
    }

    public static func sign(_ message: [UInt8], seed: [UInt8]) -> [UInt8]? {
        guard let publicKey = publicKey(seed: seed) else { return nil }
        var d = SHA2.sha512(seed)
        clamp(&d)
        var r = SHA2.sha512(Array(d[32..<64]) + message)
        reduce(&r)
        var p = Point()
        scalarBase(&p, Array(r[0..<32]))
        let rBytes = pack(p)
        var h = SHA2.sha512(rBytes + publicKey + message)
        reduce(&h)
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<32 { x[i] = Int64(r[i]) }
        for i in 0..<32 { for j in 0..<32 { x[i + j] += Int64(h[i]) * Int64(d[j]) } }
        var s = [UInt8](repeating: 0, count: 32)
        modL(&s, &x)
        return rBytes + s
    }

    public static func isValid(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count == signatureBytes, publicKey.count == publicKeyBytes else { return false }
        let s = Array(signature[32..<64])
        guard isCanonicalScalar(s) else { return false }
        var q = Point()
        guard unpackNegative(&q, publicKey) else { return false }
        var h = SHA2.sha512(Array(signature[0..<32]) + publicKey + message)
        reduce(&h)
        var p = Point()
        scalarMult(&p, &q, Array(h[0..<32]))
        var sb = Point()
        scalarBase(&sb, s)
        add(&p, sb)
        return constantTimeEqual(pack(p), Array(signature[0..<32]))
    }

    /// Fresh random seed (tests and throwaway keys).
    public static func randomSeed() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<seedBytes).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    // MARK: Field arithmetic (mod 2^255 - 19)

    typealias FieldElement = [Int64]

    static let gf0: FieldElement = Array(repeating: 0, count: 16)
    static let gf1: FieldElement = [1] + Array(repeating: 0, count: 15)
    static let curveD: FieldElement = [0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
                                       0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203]
    static let curveD2: FieldElement = [0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
                                        0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406]
    static let baseX: FieldElement = [0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
                                      0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169]
    static let baseY: FieldElement = [0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
                                      0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666]
    static let sqrtM1: FieldElement = [0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
                                       0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83]
    /// The group order L, little-endian.
    static let orderL: [Int64] = [0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2,
                                  0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

    static func carry(_ o: inout FieldElement) {
        for i in 0..<16 {
            o[i] += 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] += c - 1
            } else {
                o[0] += 38 * (c - 1)
            }
            o[i] -= c << 16
        }
    }

    /// Swaps `p` and `q` when `b` is 1, in constant time.
    static func select(_ p: inout FieldElement, _ q: inout FieldElement, _ b: Int64) {
        let mask = ~(b - 1)
        for i in 0..<16 {
            let t = mask & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    static func pack25519(_ n: FieldElement) -> [UInt8] {
        var t = n
        carry(&t); carry(&t); carry(&t)
        var m = gf0
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xffff
            select(&t, &m, 1 - b)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i] & 0xff)
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    static func unpack25519(_ n: [UInt8]) -> FieldElement {
        var o = gf0
        for i in 0..<16 { o[i] = Int64(n[2 * i]) + (Int64(n[2 * i + 1]) << 8) }
        o[15] &= 0x7fff
        return o
    }

    static func notEqual(_ a: FieldElement, _ b: FieldElement) -> Bool {
        !constantTimeEqual(pack25519(a), pack25519(b))
    }

    static func parity(_ a: FieldElement) -> UInt8 { pack25519(a)[0] & 1 }

    static func addF(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var o = gf0
        for i in 0..<16 { o[i] = a[i] + b[i] }
        return o
    }

    static func subF(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var o = gf0
        for i in 0..<16 { o[i] = a[i] - b[i] }
        return o
    }

    static func mulF(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var t = [Int64](repeating: 0, count: 31)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for i in 0..<16 {
                    let ai = a[i]
                    for j in 0..<16 { t[i + j] += ai * b[j] }
                }
            }
        }
        for i in 0..<15 { t[i] += 38 * t[i + 16] }
        var o = Array(t[0..<16])
        carry(&o)
        carry(&o)
        return o
    }

    static func squareF(_ a: FieldElement) -> FieldElement { mulF(a, a) }

    static func invert(_ i: FieldElement) -> FieldElement {
        var c = i
        for a in stride(from: 253, through: 0, by: -1) {
            c = squareF(c)
            if a != 2 && a != 4 { c = mulF(c, i) }
        }
        return c
    }

    static func pow2523(_ i: FieldElement) -> FieldElement {
        var c = i
        for a in stride(from: 250, through: 0, by: -1) {
            c = squareF(c)
            if a != 1 { c = mulF(c, i) }
        }
        return c
    }

    // MARK: Points (extended coordinates X, Y, Z, T)

    struct Point {
        var x = Ed25519.gf0
        var y = Ed25519.gf1
        var z = Ed25519.gf1
        var t = Ed25519.gf0
    }

    static func add(_ p: inout Point, _ q: Point) {
        let a = mulF(subF(p.y, p.x), subF(q.y, q.x))
        let b = mulF(addF(p.x, p.y), addF(q.x, q.y))
        let c = mulF(mulF(p.t, q.t), curveD2)
        var d = mulF(p.z, q.z)
        d = addF(d, d)
        let e = subF(b, a)
        let f = subF(d, c)
        let g = addF(d, c)
        let h = addF(b, a)
        p.x = mulF(e, f)
        p.y = mulF(h, g)
        p.z = mulF(g, f)
        p.t = mulF(e, h)
    }

    static func conditionalSwap(_ p: inout Point, _ q: inout Point, _ b: Int64) {
        select(&p.x, &q.x, b)
        select(&p.y, &q.y, b)
        select(&p.z, &q.z, b)
        select(&p.t, &q.t, b)
    }

    static func pack(_ p: Point) -> [UInt8] {
        let zi = invert(p.z)
        let tx = mulF(p.x, zi)
        let ty = mulF(p.y, zi)
        var r = pack25519(ty)
        r[31] ^= parity(tx) << 7
        return r
    }

    static func scalarMult(_ p: inout Point, _ q: inout Point, _ s: [UInt8]) {
        p = Point(x: gf0, y: gf1, z: gf1, t: gf0)
        for i in stride(from: 255, through: 0, by: -1) {
            let b = Int64((s[i / 8] >> UInt8(i & 7)) & 1)
            conditionalSwap(&p, &q, b)
            add(&q, p)
            add(&p, p)
            conditionalSwap(&p, &q, b)
        }
    }

    static func scalarBase(_ p: inout Point, _ s: [UInt8]) {
        var q = Point(x: baseX, y: baseY, z: gf1, t: mulF(baseX, baseY))
        scalarMult(&p, &q, s)
    }

    /// Decodes `p` and negates it (as TweetNaCl's `unpackneg`). False for a point off the curve.
    static func unpackNegative(_ r: inout Point, _ p: [UInt8]) -> Bool {
        r.z = gf1
        r.y = unpack25519(p)
        var num = squareF(r.y)
        var den = mulF(num, curveD)
        num = subF(num, r.z)
        den = addF(r.z, den)
        let den2 = squareF(den)
        let den4 = squareF(den2)
        let den6 = mulF(den4, den2)
        var t = mulF(den6, num)
        t = mulF(t, den)
        t = pow2523(t)
        t = mulF(t, num)
        t = mulF(t, den)
        t = mulF(t, den)
        r.x = mulF(t, den)
        var check = mulF(squareF(r.x), den)
        if notEqual(check, num) { r.x = mulF(r.x, sqrtM1) }
        check = mulF(squareF(r.x), den)
        if notEqual(check, num) { return false }
        if parity(r.x) == (p[31] >> 7) { r.x = subF(gf0, r.x) }
        r.t = mulF(r.x, r.y)
        return true
    }

    // MARK: Scalars (mod L)

    static func clamp(_ d: inout [UInt8]) {
        d[0] &= 248
        d[31] &= 127
        d[31] |= 64
    }

    static func modL(_ r: inout [UInt8], _ x: inout [Int64]) {
        for i in stride(from: 63, through: 32, by: -1) {
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                x[j] += carry - 16 * x[i] * orderL[j - (i - 32)]
                carry = (x[j] + 128) >> 8
                x[j] -= carry << 8
                j += 1
            }
            x[j] += carry
            x[i] = 0
        }
        var carry: Int64 = 0
        for j in 0..<32 {
            x[j] += carry - (x[31] >> 4) * orderL[j]
            carry = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] -= carry * orderL[j] }
        for i in 0..<32 {
            x[i + 1] += x[i] >> 8
            r[i] = UInt8(truncatingIfNeeded: x[i] & 255)
        }
    }

    /// Reduces a 64-byte hash mod L in place; the result is in the first 32 bytes.
    static func reduce(_ r: inout [UInt8]) {
        var x = r.map { Int64($0) }
        for i in 0..<64 { r[i] = 0 }
        modL(&r, &x)
    }

    /// `s < L` (little-endian), so a signature cannot be altered by adding L.
    static func isCanonicalScalar(_ s: [UInt8]) -> Bool {
        for i in stride(from: 31, through: 0, by: -1) {
            let a = Int64(s[i]), l = orderL[i]
            if a < l { return true }
            if a > l { return false }
        }
        return false
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
