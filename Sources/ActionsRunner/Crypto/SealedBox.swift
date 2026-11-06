import Foundation
import CryptoKit

/// Implementazione di `crypto_box_seal` di libsodium (X25519 + XSalsa20-Poly1305),
/// richiesta da GitHub per cifrare i secrets dei repository.
/// sealed = epk || crypto_box(m, nonce = BLAKE2b-192(epk || pk), pk, esk)
enum SealedBox {
    static func seal(_ message: Data, recipientPublicKey pk: Data) throws -> Data {
        guard pk.count == 32 else { throw GitHubError(status: 0, message: "La chiave pubblica deve essere di 32 byte") }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let epk = ephemeral.publicKey.rawRepresentation
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let sharedBytes = shared.withUnsafeBytes { Array($0) }
        let key = Salsa20.hsalsa20(key: sharedBytes, nonce: [UInt8](repeating: 0, count: 16))
        let nonce = Blake2b.hash(Array(epk) + Array(pk), outputLength: 24)
        let boxed = SecretBox.seal(Array(message), nonce: nonce, key: key)
        return Data(epk) + Data(boxed)
    }
}

/// crypto_secretbox_xsalsa20poly1305 (formato "easy": MAC(16) || ciphertext).
enum SecretBox {
    static func seal(_ m: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(nonce.count == 24 && key.count == 32)
        let stream = Salsa20.xsalsa20Stream(key: key, nonce: nonce, length: 32 + m.count)
        let polyKey = Array(stream[0..<32])
        var c = [UInt8](repeating: 0, count: m.count)
        for i in 0..<m.count { c[i] = m[i] ^ stream[32 + i] }
        let tag = Poly1305.authenticate(message: c, key: polyKey)
        return tag + c
    }
}

enum Salsa20 {
    private static let sigma: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] // "expand 32-byte k"

    @inline(__always) private static func rotl(_ v: UInt32, _ c: UInt32) -> UInt32 { (v << c) | (v >> (32 - c)) }

    private static func load32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func initialState(key: [UInt8], input: [UInt8]) -> [UInt32] {
        [sigma[0], load32(key, 0), load32(key, 4), load32(key, 8), load32(key, 12), sigma[1],
         load32(input, 0), load32(input, 4), load32(input, 8), load32(input, 12),
         sigma[2], load32(key, 16), load32(key, 20), load32(key, 24), load32(key, 28), sigma[3]]
    }

    private static func doubleRounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            x[4] ^= rotl(x[0] &+ x[12], 7);  x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7);   x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)

            x[1] ^= rotl(x[0] &+ x[3], 7);   x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13);  x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7);   x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13);  x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
    }

    private static func store(_ words: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(words.count * 4)
        for w in words { out += [UInt8(w & 0xff), UInt8((w >> 8) & 0xff), UInt8((w >> 16) & 0xff), UInt8((w >> 24) & 0xff)] }
        return out
    }

    /// Blocco Salsa20 (64 byte) con input di 16 byte (nonce 8 + contatore 8).
    static func block(key: [UInt8], input: [UInt8]) -> [UInt8] {
        let original = initialState(key: key, input: input)
        var x = original
        doubleRounds(&x)
        for i in 0..<16 { x[i] = x[i] &+ original[i] }
        return store(x)
    }

    static func hsalsa20(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var x = initialState(key: key, input: nonce)
        doubleRounds(&x)
        return store([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]])
    }

    static func salsa20Stream(key: [UInt8], nonce8: [UInt8], length: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length + 64)
        var counter: UInt64 = 0
        while out.count < length {
            var input = nonce8
            for i in 0..<8 { input.append(UInt8((counter >> (8 * UInt64(i))) & 0xff)) }
            out += block(key: key, input: input)
            counter += 1
        }
        return Array(out[0..<length])
    }

    static func xsalsa20Stream(key: [UInt8], nonce: [UInt8], length: Int) -> [UInt8] {
        let subkey = hsalsa20(key: key, nonce: Array(nonce[0..<16]))
        return salsa20Stream(key: subkey, nonce8: Array(nonce[16..<24]), length: length)
    }
}

/// Poly1305 (implementazione "donna" a limb da 26 bit).
enum Poly1305 {
    private static func load32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    static func authenticate(message m: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32)
        let r0 = UInt64(load32(key, 0) & 0x3ffffff)
        let r1 = UInt64((load32(key, 3) >> 2) & 0x3ffff03)
        let r2 = UInt64((load32(key, 6) >> 4) & 0x3ffc0ff)
        let r3 = UInt64((load32(key, 9) >> 6) & 0x3f03fff)
        let r4 = UInt64((load32(key, 12) >> 8) & 0x00fffff)
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5
        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
        let mask: UInt64 = 0x3ffffff

        var offset = 0
        while offset < m.count {
            var block = [UInt8](repeating: 0, count: 17)
            let n = min(16, m.count - offset)
            for i in 0..<n { block[i] = m[offset + i] }
            let hibit: UInt64
            if n == 16 { hibit = 1 << 24 } else { block[n] = 1; hibit = 0 }
            h0 += UInt64(load32(block, 0) & 0x3ffffff)
            h1 += UInt64((load32(block, 3) >> 2) & 0x3ffffff)
            h2 += UInt64((load32(block, 6) >> 4) & 0x3ffffff)
            h3 += UInt64((load32(block, 9) >> 6) & 0x3ffffff)
            h4 += UInt64(load32(block, 12) >> 8) | hibit

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
            h0 += c * 5; c = h0 >> 26; h0 &= mask
            h1 += c
            offset += 16
        }

        // riduzione completa
        var c = h1 >> 26; h1 &= mask
        h2 += c; c = h2 >> 26; h2 &= mask
        h3 += c; c = h3 >> 26; h3 &= mask
        h4 += c; c = h4 >> 26; h4 &= mask
        h0 += c * 5; c = h0 >> 26; h0 &= mask
        h1 += c

        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        let g4 = h4 &+ c &- (1 << 26)

        // se g4 è "negativo" (bit 63 impostato) si tiene h, altrimenti g
        let useG: UInt64 = (g4 >> 63) == 0 ? ~UInt64(0) : 0
        h0 = (h0 & ~useG) | (g0 & useG)
        h1 = (h1 & ~useG) | (g1 & useG)
        h2 = (h2 & ~useG) | (g2 & useG)
        h3 = (h3 & ~useG) | (g3 & useG)
        h4 = (h4 & ~useG) | (g4 & mask & useG)

        let w0 = (h0 | (h1 << 26)) & 0xffffffff
        let w1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff
        let w2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff
        let w3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff

        var f = w0 + UInt64(load32(key, 16))
        let o0 = f & 0xffffffff
        f = w1 + UInt64(load32(key, 20)) + (f >> 32)
        let o1 = f & 0xffffffff
        f = w2 + UInt64(load32(key, 24)) + (f >> 32)
        let o2 = f & 0xffffffff
        f = w3 + UInt64(load32(key, 28)) + (f >> 32)
        let o3 = f & 0xffffffff

        var out: [UInt8] = []
        for w in [o0, o1, o2, o3] {
            out += [UInt8(w & 0xff), UInt8((w >> 8) & 0xff), UInt8((w >> 16) & 0xff), UInt8((w >> 24) & 0xff)]
        }
        return out
    }
}

/// BLAKE2b (RFC 7693), senza chiave, lunghezza di output variabile.
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    private static func compress(_ h: inout [UInt64], _ block: [UInt8], _ t: UInt64, _ last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var w: UInt64 = 0
            for b in 0..<8 { w |= UInt64(block[i * 8 + b]) << (8 * UInt64(b)) }
            m[i] = w
        }
        var v = h + iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 63)
        }
        for r in 0..<12 {
            let s = sigma[r % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]])
            g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]])
            g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]])
            g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]])
            g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    static func hash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        precondition(outputLength >= 1 && outputLength <= 64)
        var h = iv
        h[0] ^= 0x01010000 ^ UInt64(outputLength)
        var t: UInt64 = 0
        var offset = 0
        // tutti i blocchi pieni tranne l'ultimo
        while input.count - offset > 128 {
            t += 128
            compress(&h, Array(input[offset..<(offset + 128)]), t, false)
            offset += 128
        }
        var last = [UInt8](repeating: 0, count: 128)
        let remaining = input.count - offset
        for i in 0..<remaining { last[i] = input[offset + i] }
        t += UInt64(remaining)
        compress(&h, last, t, true)
        var out: [UInt8] = []
        for w in h { for b in 0..<8 { out.append(UInt8((w >> (8 * UInt64(b))) & 0xff)) } }
        return Array(out[0..<outputLength])
    }
}
