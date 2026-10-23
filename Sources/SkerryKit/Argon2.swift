import Foundation

/// Blake2b is the hash Argon2 is built on, RFC 7693, implemented here because CryptoKit
/// does not provide it. One-shot, unkeyed, variable digest length up to 64 bytes.
/// Verified against the RFC test vectors in the kit test suite.
enum Blake2b {
    /// Initialization vector, the SHA-512 constants.
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b,
        0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f,
        0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    /// Message schedule permutations; rounds beyond ten repeat from the top.
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
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    /// Hashes data to a digest of 1 through 64 bytes.
    static func hash(_ data: Data, digestLength: Int) -> Data {
        precondition((1...64).contains(digestLength), "digest length out of range")
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(digestLength)

        let bytes = [UInt8](data)
        var offset = 0
        var counter: UInt64 = 0

        // Every full block except a final one compresses mid-stream.
        while bytes.count - offset > 128 {
            counter &+= 128
            compress(&h, block: Array(bytes[offset..<offset + 128]), counter: counter, last: false)
            offset += 128
        }
        var final = Array(bytes[offset...])
        counter &+= UInt64(final.count)
        final.append(contentsOf: [UInt8](repeating: 0, count: 128 - final.count))
        compress(&h, block: final, counter: counter, last: true)

        var out = Data(capacity: 64)
        for word in h {
            withUnsafeBytes(of: word.littleEndian) { out.append(contentsOf: $0) }
        }
        return out.prefix(digestLength)
    }

    /// The compression function F.
    private static func compress(
        _ h: inout [UInt64], block: [UInt8], counter: UInt64, last: Bool
    ) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in (0..<8).reversed() {
                word = (word << 8) | UInt64(block[i * 8 + j])
            }
            m[i] = word
        }
        var v = h + iv
        v[12] ^= counter
        // Message lengths stay under 2^64 here, so the high counter word is zero.
        if last { v[14] = ~v[14] }

        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    /// The G mixing function.
    private static func mix(
        _ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    /// Rotates a 64-bit word right.
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }
}

/// Argon2id is the memory-hard password hash of RFC 9106, the KDF that wraps the vault
/// master key in version 3 keyfiles. Memory-hardness is what makes GPU and ASIC guessing
/// expensive, which PBKDF2 cannot offer.
///
/// Implemented from the RFC because no system framework provides it, and gated on the
/// RFC's own test vector in the kit test suite: if the vector fails, the suite fails.
public enum Argon2id {
    /// Derives a key from a password.
    ///
    /// - Parameters:
    ///   - password: Secret input.
    ///   - salt: Random salt, at least 8 bytes.
    ///   - memoryKiB: Memory cost in KiB; 65536 is the vault default.
    ///   - iterations: Passes over memory; 3 is the vault default.
    ///   - parallelism: Lanes; 4 is the vault default.
    ///   - outputLength: Derived key length in bytes.
    public static func deriveKey(
        password: Data, salt: Data, memoryKiB: Int, iterations: Int,
        parallelism: Int, outputLength: Int
    ) -> Data {
        derive(
            password: password, salt: salt, secret: Data(), associated: Data(),
            memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism,
            outputLength: outputLength
        )
    }

    /// Full-parameter derivation, exposed within the module for the RFC test vector.
    /// The fill loop runs on raw buffers because the memory-hard core moves gigabytes;
    /// bounds come from the parameter math above it, never from input data.
    static func derive(
        password: Data, salt: Data, secret: Data, associated: Data,
        memoryKiB: Int, iterations: Int, parallelism: Int, outputLength: Int
    ) -> Data {
        let lanes = max(parallelism, 1)
        let passes = max(iterations, 1)
        // Memory rounds down to a multiple of 4 * lanes, minimum 8 * lanes.
        let requested = max(memoryKiB, 8 * lanes)
        let blockCount = 4 * lanes * (requested / (4 * lanes))
        let laneLength = blockCount / lanes
        let segmentLength = laneLength / 4

        // H0 commits to every parameter and input.
        var seed = Data()
        appendLE32(&seed, UInt32(lanes))
        appendLE32(&seed, UInt32(outputLength))
        appendLE32(&seed, UInt32(requested))
        appendLE32(&seed, UInt32(passes))
        appendLE32(&seed, 0x13)
        appendLE32(&seed, 2)
        appendLE32(&seed, UInt32(password.count))
        seed.append(password)
        appendLE32(&seed, UInt32(salt.count))
        seed.append(salt)
        appendLE32(&seed, UInt32(secret.count))
        seed.append(secret)
        appendLE32(&seed, UInt32(associated.count))
        seed.append(associated)
        let h0 = Blake2b.hash(seed, digestLength: 64)

        let words = blockCount * 128
        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: words)
        memory.initialize(repeating: 0, count: words)
        let scratchR = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        let scratchQ = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        let addresses = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        let addressInput = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        let addressMid = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        let zero = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
        zero.initialize(repeating: 0, count: 128)
        defer {
            // The working memory held key-derived state; zero it before freeing.
            memory.update(repeating: 0, count: words)
            memory.deallocate()
            for pointer in [scratchR, scratchQ, addresses, addressInput, addressMid, zero] {
                pointer.update(repeating: 0, count: 128)
                pointer.deallocate()
            }
        }

        for lane in 0..<lanes {
            for column in 0..<2 {
                var input = h0
                appendLE32(&input, UInt32(column))
                appendLE32(&input, UInt32(lane))
                writeBlock(
                    variableHash(input, length: 1024),
                    to: memory + (lane * laneLength + column) * 128
                )
            }
        }

        for pass in 0..<passes {
            for slice in 0..<4 {
                for lane in 0..<lanes {
                    fillSegment(
                        memory: memory, pass: pass, lane: lane, slice: slice,
                        lanes: lanes, laneLength: laneLength, segmentLength: segmentLength,
                        passes: passes, blockCount: blockCount,
                        scratchR: scratchR, scratchQ: scratchQ, addresses: addresses,
                        addressInput: addressInput, addressMid: addressMid, zero: zero
                    )
                }
            }
        }

        var final = [UInt8](repeating: 0, count: 1024)
        for lane in 0..<lanes {
            let block = memory + (lane * laneLength + laneLength - 1) * 128
            final.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: UInt64.self)
                for i in 0..<128 {
                    out[i] = lane == 0 ? block[i].littleEndian : out[i] ^ block[i].littleEndian
                }
            }
        }
        return variableHash(Data(final), length: outputLength)
    }

    /// Fills one segment of one lane for one pass.
    private static func fillSegment(
        memory: UnsafeMutablePointer<UInt64>, pass: Int, lane: Int, slice: Int,
        lanes: Int, laneLength: Int, segmentLength: Int, passes: Int, blockCount: Int,
        scratchR: UnsafeMutablePointer<UInt64>, scratchQ: UnsafeMutablePointer<UInt64>,
        addresses: UnsafeMutablePointer<UInt64>, addressInput: UnsafeMutablePointer<UInt64>,
        addressMid: UnsafeMutablePointer<UInt64>, zero: UnsafeMutablePointer<UInt64>
    ) {
        // Argon2id: the first two slices of the first pass use data-independent
        // addressing; everything after uses data-dependent addressing.
        let independent = pass == 0 && slice < 2
        var addressBlockCounter: UInt64 = 0
        var addressIndex = 128

        let start = pass == 0 && slice == 0 ? 2 : 0

        for index in start..<segmentLength {
            let currentOffset = lane * laneLength + slice * segmentLength + index
            let previousOffset = currentOffset % laneLength == 0
                ? currentOffset + laneLength - 1
                : currentOffset - 1

            let j1: UInt64
            let j2: UInt64
            if independent {
                if addressIndex >= 128 {
                    addressBlockCounter += 1
                    addressInput.update(repeating: 0, count: 128)
                    addressInput[0] = UInt64(pass)
                    addressInput[1] = UInt64(lane)
                    addressInput[2] = UInt64(slice)
                    addressInput[3] = UInt64(blockCount)
                    addressInput[4] = UInt64(passes)
                    addressInput[5] = 2
                    addressInput[6] = addressBlockCounter
                    compress(
                        dest: addressMid, x: zero, y: addressInput, xorDest: false,
                        r: scratchR, q: scratchQ
                    )
                    compress(
                        dest: addresses, x: zero, y: addressMid, xorDest: false,
                        r: scratchR, q: scratchQ
                    )
                    addressIndex = 0
                }
                let word = addresses[addressIndex]
                addressIndex += 1
                j1 = word & 0xFFFF_FFFF
                j2 = word >> 32
            } else {
                let word = memory[previousOffset * 128]
                j1 = word & 0xFFFF_FFFF
                j2 = word >> 32
            }

            let refLane = pass == 0 && slice == 0
                ? lane
                : Int(j2 % UInt64(lanes))

            // Size of the window the reference block may come from.
            let sameLane = refLane == lane
            var area: Int
            if pass == 0 {
                if slice == 0 {
                    area = index - 1
                } else if sameLane {
                    area = slice * segmentLength + index - 1
                } else {
                    area = slice * segmentLength - (index == 0 ? 1 : 0)
                }
            } else if sameLane {
                area = laneLength - segmentLength + index - 1
            } else {
                area = laneLength - segmentLength - (index == 0 ? 1 : 0)
            }

            // The RFC's non-uniform mapping biases toward recent blocks.
            let x = (j1 &* j1) >> 32
            let y = (UInt64(area) &* x) >> 32
            let z = UInt64(area) - 1 - y

            let startPosition = pass == 0 ? 0 : (slice + 1) * segmentLength % laneLength
            let refIndex = (startPosition + Int(z)) % laneLength
            let refOffset = refLane * laneLength + refIndex

            compress(
                dest: memory + currentOffset * 128,
                x: memory + previousOffset * 128,
                y: memory + refOffset * 128,
                xorDest: pass > 0,
                r: scratchR, q: scratchQ
            )
        }
    }

    /// The Argon2 compression function G over two 1024-byte blocks, writing into dest.
    /// With xorDest, the result folds into what dest already holds, the later-pass rule.
    private static func compress(
        dest: UnsafeMutablePointer<UInt64>, x: UnsafePointer<UInt64>,
        y: UnsafePointer<UInt64>, xorDest: Bool,
        r: UnsafeMutablePointer<UInt64>, q: UnsafeMutablePointer<UInt64>
    ) {
        for i in 0..<128 {
            let mixed = x[i] ^ y[i]
            r[i] = mixed
            q[i] = mixed
        }
        for i in 0..<8 {
            roundRow(q, i * 16)
        }
        for i in 0..<8 {
            roundColumn(q, i)
        }
        if xorDest {
            for i in 0..<128 { dest[i] ^= q[i] ^ r[i] }
        } else {
            for i in 0..<128 { dest[i] = q[i] ^ r[i] }
        }
    }

    /// The P permutation over 16 consecutive words starting at base.
    @inline(__always)
    private static func roundRow(_ v: UnsafeMutablePointer<UInt64>, _ base: Int) {
        gB(v, base, base + 4, base + 8, base + 12)
        gB(v, base + 1, base + 5, base + 9, base + 13)
        gB(v, base + 2, base + 6, base + 10, base + 14)
        gB(v, base + 3, base + 7, base + 11, base + 15)
        gB(v, base, base + 5, base + 10, base + 15)
        gB(v, base + 1, base + 6, base + 11, base + 12)
        gB(v, base + 2, base + 7, base + 8, base + 13)
        gB(v, base + 3, base + 4, base + 9, base + 14)
    }

    /// The P permutation over one column pair group.
    @inline(__always)
    private static func roundColumn(_ v: UnsafeMutablePointer<UInt64>, _ pair: Int) {
        let base = 2 * pair
        let i0 = base, i1 = base + 1
        let i2 = base + 16, i3 = base + 17
        let i4 = base + 32, i5 = base + 33
        let i6 = base + 48, i7 = base + 49
        let i8 = base + 64, i9 = base + 65
        let i10 = base + 80, i11 = base + 81
        let i12 = base + 96, i13 = base + 97
        let i14 = base + 112, i15 = base + 113
        gB(v, i0, i4, i8, i12)
        gB(v, i1, i5, i9, i13)
        gB(v, i2, i6, i10, i14)
        gB(v, i3, i7, i11, i15)
        gB(v, i0, i5, i10, i15)
        gB(v, i1, i6, i11, i12)
        gB(v, i2, i7, i8, i13)
        gB(v, i3, i4, i9, i14)
    }

    /// The BlaMka G function.
    @inline(__always)
    private static func gB(
        _ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int
    ) {
        v[a] = blaMka(v[a], v[b])
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = blaMka(v[c], v[d])
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = blaMka(v[a], v[b])
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = blaMka(v[c], v[d])
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    /// a + b + 2 * low32(a) * low32(b), all wrapping.
    @inline(__always)
    private static func blaMka(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let low = (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF)
        return a &+ b &+ 2 &* low
    }

    /// Rotates a 64-bit word right.
    @inline(__always)
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    /// Writes 1024 hash bytes into a block pointer as little-endian words.
    private static func writeBlock(_ data: Data, to block: UnsafeMutablePointer<UInt64>) {
        let bytes = [UInt8](data)
        for i in 0..<128 {
            var word: UInt64 = 0
            for j in (0..<8).reversed() {
                word = (word << 8) | UInt64(bytes[i * 8 + j])
            }
            block[i] = word
        }
    }

    /// The variable-length hash H' built on Blake2b.
    private static func variableHash(_ input: Data, length: Int) -> Data {
        var prefixed = Data()
        appendLE32(&prefixed, UInt32(length))
        prefixed.append(input)
        if length <= 64 {
            return Blake2b.hash(prefixed, digestLength: length)
        }
        var out = Data()
        var v = Blake2b.hash(prefixed, digestLength: 64)
        out.append(v.prefix(32))
        var remaining = length - 32
        while remaining > 64 {
            v = Blake2b.hash(v, digestLength: 64)
            out.append(v.prefix(32))
            remaining -= 32
        }
        out.append(Blake2b.hash(v, digestLength: remaining))
        return out
    }

    /// Appends a little-endian 32-bit value.
    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
