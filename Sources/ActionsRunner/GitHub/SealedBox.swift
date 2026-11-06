import CryptoKit
import Foundation

/// `crypto_box_seal` di libsodium, richiesto da GitHub per cifrare i secrets
/// (https://docs.github.com/rest/guides/encrypting-secrets-for-the-rest-api).
/// X25519 da CryptoKit; HSalsa20/XSalsa20, Poly1305 e BLAKE2b implementati qui (nessuna dipendenza).
/// L'implementazione è il porting 1:1 di un riferimento verificato contro libsodium (crypto_box_seal_open).
enum SealedBox {
    struct SealError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Cifra `message` per la chiave pubblica (32 byte) del repository.
    static func seal(_ message: Data, recipientPublicKey pk: Data) throws -> Data {
        guard pk.count == 32 else { throw SealError(message: "chiave pubblica non valida (\(pk.count) byte)") }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let epk = eph.publicKey.rawRepresentation
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk)
        let secret = try eph.sharedSecretFromKeyAgreement(with: recipient)
        let shared = secret.withUnsafeBytes { [UInt8]($0) }
        let k = hsalsa20(key: shared, input: [UInt8](repeating: 0, count: 16))
        let nonce = blake2b([UInt8](epk) + [UInt8](pk), outLength: 24)
        return epk + Data(secretbox([UInt8](message), nonce: nonce, key: k))
    }

    // MARK: Salsa20

    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]

    @inline(__always) private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    private static func appendLE32(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }

    private static func salsaRounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            // colonne
            x[4] ^= rotl(x[0] &+ x[12], 7); x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7); x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)
            // righe
            x[1] ^= rotl(x[0] &+ x[3], 7); x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13); x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7); x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13); x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
    }

    private static func initState(key: [UInt8], input: [UInt8]) -> [UInt32] {
        let k = (0..<8).map { le32(key, 4 * $0) }
        let n = (0..<4).map { le32(input, 4 * $0) }
        return [sigma[0], k[0], k[1], k[2], k[3], sigma[1], n[0], n[1], n[2], n[3],
                sigma[2], k[4], k[5], k[6], k[7], sigma[3]]
    }

    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x = initState(key: key, input: input)
        salsaRounds(&x)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for i in [0, 5, 10, 15, 6, 7, 8, 9] { appendLE32(x[i], to: &out) }
        return out
    }

    static func salsa20Stream(key: [UInt8], nonce8: [UInt8], length: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length + 64)
        var counter: UInt64 = 0
        while out.count < length {
            var input = nonce8
            for i in 0..<8 { input.append(UInt8((counter >> (8 * UInt64(i))) & 0xFF)) }
            let s = initState(key: key, input: input)
            var x = s
            salsaRounds(&x)
            for i in 0..<16 { appendLE32(x[i] &+ s[i], to: &out) }
            counter += 1
        }
        return Array(out.prefix(length))
    }

    // MARK: Poly1305 (variante "donna" a 26 bit)

    static func poly1305(key: [UInt8], message m: [UInt8]) -> [UInt8] {
        let mask: UInt64 = 0x3FF_FFFF
        let r0 = UInt64(le32(key, 0)) & 0x3FF_FFFF
        let r1 = (UInt64(le32(key, 3)) >> 2) & 0x3FF_FF03
        let r2 = (UInt64(le32(key, 6)) >> 4) & 0x3FF_C0FF
        let r3 = (UInt64(le32(key, 9)) >> 6) & 0x3F0_3FFF
        let r4 = (UInt64(le32(key, 12)) >> 8) & 0x00F_FFFF
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5
        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
        var off = 0
        while off < m.count {
            var blk = Array(m[off..<min(off + 16, m.count)])
            let hibit: UInt64
            if blk.count < 16 {
                blk.append(1)
                while blk.count < 16 { blk.append(0) }
                hibit = 0
            } else {
                hibit = 1 << 24
            }
            off += 16
            h0 += UInt64(le32(blk, 0)) & mask
            h1 += (UInt64(le32(blk, 3)) >> 2) & mask
            h2 += (UInt64(le32(blk, 6)) >> 4) & mask
            h3 += (UInt64(le32(blk, 9)) >> 6) & mask
            h4 += (UInt64(le32(blk, 12)) >> 8) | hibit
            let d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
            var c = d0 >> 26; h0 = d0 & mask
            d1 += c; c = d1 >> 26; h1 = d1 & mask
            d2 += c; c = d2 >> 26; h2 = d2 & mask
            d3 += c; c = d3 >> 26; h3 = d3 & mask
            d4 += c; c = d4 >> 26; h4 = d4 & mask
            h0 += c * 5; c = h0 >> 26; h0 &= mask; h1 += c
        }
        var c = h1 >> 26; h1 &= mask; h2 += c
        c = h2 >> 26; h2 &= mask; h3 += c
        c = h3 >> 26; h3 &= mask; h4 += c
        c = h4 >> 26; h4 &= mask; h0 += c * 5
        c = h0 >> 26; h0 &= mask; h1 += c
        var g0 = h0 + 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 + c; c = g1 >> 26; g1 &= mask
        var g2 = h2 + c; c = g2 >> 26; g2 &= mask
        var g3 = h3 + c; c = g3 >> 26; g3 &= mask
        var g4 = (h4 &+ c &- (1 << 26)) & 0xFFFF_FFFF
        let sel = ((g4 >> 31) &- 1) & 0xFFFF_FFFF
        g0 &= sel; g1 &= sel; g2 &= sel; g3 &= sel; g4 &= sel
        let nsel = ~sel & 0xFFFF_FFFF
        h0 = (h0 & nsel) | g0; h1 = (h1 & nsel) | g1; h2 = (h2 & nsel) | g2
        h3 = (h3 & nsel) | g3; h4 = (h4 & nsel) | g4
        h0 = (h0 | (h1 << 26)) & 0xFFFF_FFFF
        h1 = ((h1 >> 6) | (h2 << 20)) & 0xFFFF_FFFF
        h2 = ((h2 >> 12) | (h3 << 14)) & 0xFFFF_FFFF
        h3 = ((h3 >> 18) | (h4 << 8)) & 0xFFFF_FFFF
        var f = h0 + UInt64(le32(key, 16)); h0 = f & 0xFFFF_FFFF
        f = h1 + UInt64(le32(key, 20)) + (f >> 32); h1 = f & 0xFFFF_FFFF
        f = h2 + UInt64(le32(key, 24)) + (f >> 32); h2 = f & 0xFFFF_FFFF
        f = h3 + UInt64(le32(key, 28)) + (f >> 32); h3 = f & 0xFFFF_FFFF
        var out: [UInt8] = []
        for v in [h0, h1, h2, h3] { appendLE32(UInt32(v), to: &out) }
        return out
    }

    // MARK: BLAKE2b

    private static let iv: [UInt64] = [
        0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
        0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179,
    ]
    private static let sig: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    @inline(__always) private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    static func blake2b(_ data: [UInt8], outLength: Int) -> [UInt8] {
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLength)
        var t: UInt64 = 0

        func compress(_ block: [UInt8], last: Bool) {
            var m = [UInt64](repeating: 0, count: 16)
            for i in 0..<16 {
                var w: UInt64 = 0
                for j in 0..<8 { w |= UInt64(block[8 * i + j]) << (8 * UInt64(j)) }
                m[i] = w
            }
            var v = h + iv
            v[12] ^= t
            if last { v[14] = ~v[14] }
            func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
                v[a] = v[a] &+ v[b] &+ x; v[d] = rotr64(v[d] ^ v[a], 32)
                v[c] = v[c] &+ v[d]; v[b] = rotr64(v[b] ^ v[c], 24)
                v[a] = v[a] &+ v[b] &+ y; v[d] = rotr64(v[d] ^ v[a], 16)
                v[c] = v[c] &+ v[d]; v[b] = rotr64(v[b] ^ v[c], 63)
            }
            for r in 0..<12 {
                let s = sig[r % 10]
                g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
                g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
                g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
                g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
            }
            for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
        }

        var off = 0
        while data.count - off > 128 {
            t += 128
            compress(Array(data[off..<(off + 128)]), last: false)
            off += 128
        }
        var rest = Array(data[off...])
        t += UInt64(rest.count)
        rest += [UInt8](repeating: 0, count: 128 - rest.count)
        compress(rest, last: true)
        var out: [UInt8] = []
        for x in h { for j in 0..<8 { out.append(UInt8((x >> (8 * UInt64(j))) & 0xFF)) } }
        return Array(out.prefix(outLength))
    }

    // MARK: secretbox (XSalsa20-Poly1305), formato "easy": tag || testo cifrato

    static func secretbox(_ m: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        let sub = hsalsa20(key: key, input: Array(nonce[0..<16]))
        let ks = salsa20Stream(key: sub, nonce8: Array(nonce[16..<24]), length: 32 + m.count)
        var c = [UInt8](repeating: 0, count: m.count)
        for i in 0..<m.count { c[i] = m[i] ^ ks[32 + i] }
        return poly1305(key: Array(ks[0..<32]), message: c) + c
    }
}
