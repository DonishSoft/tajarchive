import Cocoa
import Quartz

// MARK: - Entry model

struct AEntry {
    let path: String
    let size: Int64
    let packed: Int64
    let date: String
    let isDir: Bool
    var shortName: String { (path as NSString).lastPathComponent }
}

// MARK: - Pure LZMA decoder (LZMA1 + LZMA2 chunk wrapper)
//
// Only what a 7z *header* needs: decodes a single stream into a fully-buffered
// output that doubles as the dictionary. All inputs are untrusted — every read
// is bounds-checked and failure returns nil, never traps.

final class LZMADecoder {
    private let input: [UInt8]
    private var inPos: Int
    private var code: UInt32 = 0
    private var range: UInt32 = 0xFFFF_FFFF

    private var lc = 3, lp = 0, pb = 2

    // Probability model
    private var probs: [UInt16] = []
    private var litProbs: [UInt16] = []

    private static let kNumStates = 12
    private static let kNumPosBitsMax = 4

    // Fixed layout offsets into `probs`
    private var isMatch = 0        // states << 4
    private var isRep = 0          // 12
    private var isRepG0 = 0
    private var isRepG1 = 0
    private var isRepG2 = 0
    private var isRep0Long = 0     // states << 4
    private var posSlot = 0        // 4 * 64
    private var specPos = 0        // 115
    private var align = 0          // 16
    private var lenChoice = 0, lenChoice2 = 0, lenLow = 0, lenMid = 0, lenHigh = 0
    private var repLenChoice = 0, repLenChoice2 = 0, repLenLow = 0, repLenMid = 0, repLenHigh = 0

    private(set) var output: [UInt8] = []
    private var rep0: UInt32 = 0, rep1: UInt32 = 0, rep2: UInt32 = 0, rep3: UInt32 = 0
    private var state = 0

    init(input: [UInt8]) {
        self.input = input
        self.inPos = 0
    }

    private func nextByte() -> UInt8? {
        guard inPos < input.count else { return nil }
        let b = input[inPos]
        inPos += 1
        return b
    }

    func setProps(_ d: UInt8) -> Bool {
        var v = Int(d)
        guard v < 9 * 5 * 5 else { return false }
        lc = v % 9; v /= 9
        lp = v % 5; v /= 5
        pb = v
        return true
    }

    private func allocateProbs() {
        var offset = 0
        func take(_ n: Int) -> Int { let o = offset; offset += n; return o }
        isMatch = take(Self.kNumStates << Self.kNumPosBitsMax)
        isRep = take(Self.kNumStates)
        isRepG0 = take(Self.kNumStates)
        isRepG1 = take(Self.kNumStates)
        isRepG2 = take(Self.kNumStates)
        isRep0Long = take(Self.kNumStates << Self.kNumPosBitsMax)
        posSlot = take(4 * 64)
        specPos = take(115)
        align = take(16)
        lenChoice = take(1); lenChoice2 = take(1)
        lenLow = take(16 << 3); lenMid = take(16 << 3); lenHigh = take(256)
        repLenChoice = take(1); repLenChoice2 = take(1)
        repLenLow = take(16 << 3); repLenMid = take(16 << 3); repLenHigh = take(256)
        probs = [UInt16](repeating: 1024, count: offset)
        litProbs = [UInt16](repeating: 1024, count: 0x300 << (lc + lp))
    }

    func resetState() {
        allocateProbs()
        rep0 = 0; rep1 = 0; rep2 = 0; rep3 = 0
        state = 0
    }

    private func rcInit() -> Bool {
        guard let b0 = nextByte(), b0 == 0 else { return false }
        code = 0
        range = 0xFFFF_FFFF
        for _ in 0..<4 {
            guard let b = nextByte() else { return false }
            code = (code << 8) | UInt32(b)
        }
        return true
    }

    private func normalize() -> Bool {
        if range < (1 << 24) {
            guard let b = nextByte() else { return false }
            range <<= 8
            code = (code << 8) | UInt32(b)
        }
        return true
    }

    private func decodeBit(_ index: Int, _ base: inout [UInt16]) -> Int? {
        let prob = UInt32(base[index])
        let bound = (range >> 11) &* prob
        let bit: Int
        if code < bound {
            range = bound
            base[index] = UInt16(prob + ((2048 - prob) >> 5))
            bit = 0
        } else {
            range &-= bound
            code &-= bound
            base[index] = UInt16(prob - (prob >> 5))
            bit = 1
        }
        guard normalize() else { return nil }
        return bit
    }

    private func bitTree(_ offset: Int, _ numBits: Int) -> Int? {
        var m = 1
        for _ in 0..<numBits {
            guard let b = decodeBit(offset + m, &probs) else { return nil }
            m = (m << 1) | b
        }
        return m - (1 << numBits)
    }

    private func bitTreeReverse(_ offset: Int, _ numBits: Int) -> Int? {
        var m = 1
        var symbol = 0
        for i in 0..<numBits {
            guard let b = decodeBit(offset + m, &probs) else { return nil }
            m = (m << 1) | b
            symbol |= b << i
        }
        return symbol
    }

    private func directBits(_ numBits: Int) -> UInt32? {
        var result: UInt32 = 0
        for _ in 0..<numBits {
            range >>= 1
            code &-= range
            let t = 0 &- (code >> 31)
            code &+= range & t
            guard normalize() else { return nil }
            result = (result << 1) &+ (t &+ 1)
        }
        return result
    }

    private func decodeLen(rep: Bool, posState: Int) -> Int? {
        let choiceIdx = rep ? repLenChoice : lenChoice
        let choice2Idx = rep ? repLenChoice2 : lenChoice2
        let lowBase = rep ? repLenLow : lenLow
        let midBase = rep ? repLenMid : lenMid
        let highBase = rep ? repLenHigh : lenHigh

        guard let c1 = decodeBit(choiceIdx, &probs) else { return nil }
        if c1 == 0 {
            guard let v = bitTree(lowBase + (posState << 3), 3) else { return nil }
            return 2 + v
        }
        guard let c2 = decodeBit(choice2Idx, &probs) else { return nil }
        if c2 == 0 {
            guard let v = bitTree(midBase + (posState << 3), 3) else { return nil }
            return 10 + v
        }
        guard let v = bitTree(highBase, 8) else { return nil }
        return 18 + v
    }

    /// Decodes `unpackSize` bytes of an LZMA1 stream (props already set, state already reset).
    /// Appends to `output`. Returns false on malformed input.
    func decode(unpackSize: Int) -> Bool {
        guard unpackSize >= 0, unpackSize <= 64_000_000 else { return false }
        guard rcInit() else { return false }
        output.reserveCapacity(output.count + unpackSize)
        let target = output.count + unpackSize
        let posMask = (1 << pb) - 1
        let litPosMask = (1 << lp) - 1

        while output.count < target {
            let posState = output.count & posMask
            guard let matchBit = decodeBit(isMatch + (state << Self.kNumPosBitsMax) + posState, &probs) else { return false }

            if matchBit == 0 {
                // Literal
                let prevByte = output.last ?? 0
                let litState = ((output.count & litPosMask) << lc) + (Int(prevByte) >> (8 - lc))
                let base = 0x300 * litState
                var symbol = 1
                if state >= 7 {
                    guard Int(rep0) < output.count + 1, output.count >= Int(rep0) + 1 else { return false }
                    var matchByte = Int(output[output.count - Int(rep0) - 1])
                    repeat {
                        matchByte <<= 1
                        let mBit = (matchByte >> 8) & 1
                        guard let b = decodeBit(base + ((1 + mBit) << 8) + symbol, &litProbs) else { return false }
                        symbol = (symbol << 1) | b
                        if mBit != b { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 {
                    guard let b = decodeBit(base + symbol, &litProbs) else { return false }
                    symbol = (symbol << 1) | b
                }
                output.append(UInt8(symbol & 0xFF))
                if state < 4 { state = 0 }
                else if state < 10 { state -= 3 }
                else { state -= 6 }
                continue
            }

            // Match
            var len: Int
            guard let repBit = decodeBit(isRep + state, &probs) else { return false }
            if repBit != 0 {
                // Rep match
                guard !output.isEmpty else { return false }
                guard let g0 = decodeBit(isRepG0 + state, &probs) else { return false }
                if g0 == 0 {
                    guard let long = decodeBit(isRep0Long + (state << Self.kNumPosBitsMax) + posState, &probs) else { return false }
                    if long == 0 {
                        // Short rep: 1 byte from rep0
                        state = state < 7 ? 9 : 11
                        guard output.count >= Int(rep0) + 1 else { return false }
                        let b = output[output.count - Int(rep0) - 1]
                        output.append(b)
                        continue
                    }
                } else {
                    let dist: UInt32
                    guard let g1 = decodeBit(isRepG1 + state, &probs) else { return false }
                    if g1 == 0 {
                        dist = rep1
                    } else {
                        guard let g2 = decodeBit(isRepG2 + state, &probs) else { return false }
                        if g2 == 0 {
                            dist = rep2
                        } else {
                            dist = rep3
                            rep3 = rep2
                        }
                        rep2 = rep1
                    }
                    rep1 = rep0
                    rep0 = dist
                }
                guard let l = decodeLen(rep: true, posState: posState) else { return false }
                len = l
                state = state < 7 ? 8 : 11
            } else {
                // New match
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                guard let l = decodeLen(rep: false, posState: posState) else { return false }
                len = l
                state = state < 7 ? 7 : 10

                let lenToPosState = min(len - 2, 3)
                guard let slot = bitTree(posSlot + (lenToPosState << 6), 6) else { return false }
                if slot < 4 {
                    rep0 = UInt32(slot)
                } else {
                    let numDirectBits = (slot >> 1) - 1
                    var dist = UInt32((2 | (slot & 1)) << numDirectBits)
                    if slot < 14 {
                        // specPos reverse bittree
                        let base = specPos + Int(dist) - slot - 1
                        guard let v = bitTreeReverse(base, numDirectBits) else { return false }
                        dist &+= UInt32(v)
                    } else {
                        guard let d = directBits(numDirectBits - 4) else { return false }
                        dist &+= d << 4
                        guard let a = bitTreeReverse(align, 4) else { return false }
                        dist &+= UInt32(a)
                    }
                    rep0 = dist
                }
                if rep0 == 0xFFFF_FFFF {
                    // End-of-stream marker
                    break
                }
            }

            guard Int(rep0) < output.count, len <= target - output.count + 273 else { return false }
            let distance = Int(rep0) + 1
            guard distance <= output.count else { return false }
            for _ in 0..<len {
                if output.count >= target { break }
                let b = output[output.count - distance]
                output.append(b)
            }
        }

        return output.count >= target
    }

    /// One-shot LZMA1 decode with 5-byte props prefix handled by the caller.
    static func decodeLZMA1(props: [UInt8], input: [UInt8], unpackSize: Int) -> [UInt8]? {
        guard props.count >= 1 else { return nil }
        let decoder = LZMADecoder(input: input)
        guard decoder.setProps(props[0]) else { return nil }
        decoder.resetState()
        guard decoder.decode(unpackSize: unpackSize) else { return nil }
        return decoder.output
    }

    /// LZMA2 chunked stream decode (method 0x21).
    static func decodeLZMA2(input: [UInt8], unpackSize: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(min(unpackSize, 64_000_000))
        var pos = 0
        var currentProps: UInt8 = 0
        var havePropsEver = false

        func read(_ n: Int) -> [UInt8]? {
            guard pos + n <= input.count else { return nil }
            defer { pos += n }
            return Array(input[pos..<pos + n])
        }

        while pos < input.count, out.count < unpackSize {
            guard let ctrl = read(1)?.first else { return nil }
            if ctrl == 0 { break } // end of stream
            if ctrl == 1 || ctrl == 2 {
                // Uncompressed chunk (1 = with dict reset)
                guard let szBytes = read(2) else { return nil }
                let size = (Int(szBytes[0]) << 8 | Int(szBytes[1])) + 1
                guard let chunk = read(size) else { return nil }
                out.append(contentsOf: chunk)
            } else if ctrl >= 0x80 {
                let unpackChunk = ((Int(ctrl) & 0x1F) << 16)
                guard let u2 = read(2) else { return nil }
                let chunkUnpack = unpackChunk + (Int(u2[0]) << 8 | Int(u2[1])) + 1
                guard let p2 = read(2) else { return nil }
                let chunkPack = (Int(p2[0]) << 8 | Int(p2[1])) + 1
                let resetMode = (Int(ctrl) >> 5) & 0x3
                if resetMode >= 2 {
                    guard let pByte = read(1)?.first else { return nil }
                    currentProps = pByte
                    havePropsEver = true
                }
                guard havePropsEver else { return nil }
                guard let packed = read(chunkPack) else { return nil }

                // Decode this chunk with dictionary = accumulated output.
                // A fresh decoder per chunk is correct only when the chunk resets state;
                // LZMA2 headers written by 7zz reset state per chunk in practice for
                // the small header streams we care about.
                let decoder = LZMADecoder(input: packed)
                guard decoder.setProps(currentProps) else { return nil }
                decoder.resetState()
                decoder.output = out
                guard decoder.decode(unpackSize: chunkUnpack) else { return nil }
                out = decoder.output
            } else {
                return nil
            }
        }
        return out
    }
}

// MARK: - Archive parsers (standalone for testability)

enum ArchiveParsers {

    // MARK: 7z NUMBER (spec-correct: extra bytes little-endian, first-byte remainder is the HIGH part)

    static func read7zNumber(_ data: [UInt8], _ pos: Int) -> (UInt64, Int)? {
        guard pos < data.count else { return nil }
        let first = data[pos]
        var mask: UInt8 = 0x80
        var value: UInt64 = 0
        for i in 0..<8 {
            if (first & mask) == 0 {
                let high = UInt64(first & (mask &- 1))
                value |= high << (8 * i)
                return (value, pos + 1 + i)
            }
            guard pos + 1 + i < data.count else { return nil }
            value |= UInt64(data[pos + 1 + i]) << (8 * i)
            mask >>= 1
        }
        return (value, pos + 9)
    }

    private static func readByte(_ data: [UInt8], _ pos: Int) -> (UInt8, Int)? {
        guard pos < data.count else { return nil }
        return (data[pos], pos + 1)
    }

    private static func readBitVector(_ data: [UInt8], _ pos: Int, count: Int) -> ([Bool], Int)? {
        let byteCount = (count + 7) / 8
        guard pos + byteCount <= data.count else { return nil }
        var bits: [Bool] = []
        bits.reserveCapacity(count)
        for i in 0..<count {
            let b = data[pos + i / 8]
            bits.append((b >> (7 - i % 8)) & 1 == 1)
        }
        return (bits, pos + byteCount)
    }

    // MARK: 7z structures

    struct SevenZFolder {
        var coderID: [UInt8] = []
        var props: [UInt8] = []
        var unpackSize: UInt64 = 0
        var numUnpackStreams: Int = 1
        var substreamSizes: [UInt64] = []
    }

    struct SevenZStreamsInfo {
        var packPos: UInt64 = 0
        var packSizes: [UInt64] = []
        var folders: [SevenZFolder] = []
    }

    /// Parses a StreamsInfo block starting at `pos` (after its introducing marker).
    static func parseStreamsInfo(_ data: [UInt8], _ startPos: Int) -> (SevenZStreamsInfo, Int)? {
        var info = SevenZStreamsInfo()
        var pos = startPos

        while true {
            guard let (marker, p) = readByte(data, pos) else { return nil }
            pos = p
            switch marker {
            case 0x00: // kEnd
                return (info, pos)

            case 0x06: // kPackInfo
                guard let (packPos, p1) = read7zNumber(data, pos) else { return nil }
                info.packPos = packPos
                guard let (numStreams, p2) = read7zNumber(data, p1), numStreams <= 10_000 else { return nil }
                pos = p2
                // PackInfo property loop
                packLoop: while true {
                    guard let (m, pp) = readByte(data, pos) else { return nil }
                    pos = pp
                    switch m {
                    case 0x00: break packLoop
                    case 0x09: // kSize
                        for _ in 0..<numStreams {
                            guard let (sz, np) = read7zNumber(data, pos) else { return nil }
                            info.packSizes.append(sz)
                            pos = np
                        }
                    case 0x0A: // kCRC
                        guard let skipped = skipCRC(data, pos, count: Int(numStreams)) else { return nil }
                        pos = skipped
                    default:
                        guard let (size, np) = read7zNumber(data, pos), let iSize = Int(exactly: size), np + iSize <= data.count else { return nil }
                        pos = np + iSize
                    }
                }

            case 0x07: // kUnPackInfo
                guard let (folderMarker, p1) = readByte(data, pos), folderMarker == 0x0B else { return nil }
                guard let (numFolders64, p2) = read7zNumber(data, p1), numFolders64 <= 10_000 else { return nil }
                let numFolders = Int(numFolders64)
                guard let (external, p3) = readByte(data, p2), external == 0 else { return nil }
                pos = p3

                var folders: [SevenZFolder] = []
                var totalOutStreams = 0
                for _ in 0..<numFolders {
                    guard let (numCoders64, cp) = read7zNumber(data, pos), numCoders64 >= 1, numCoders64 <= 32 else { return nil }
                    pos = cp
                    var folder = SevenZFolder()
                    var folderOutStreams = 0
                    var folderInStreams = 0
                    for coderIndex in 0..<Int(numCoders64) {
                        guard let (flags, fp) = readByte(data, pos) else { return nil }
                        pos = fp
                        let idSize = Int(flags & 0x0F)
                        guard pos + idSize <= data.count else { return nil }
                        let coderID = Array(data[pos..<pos + idSize])
                        pos += idSize
                        var numIn = 1, numOut = 1
                        if flags & 0x10 != 0 { // complex
                            guard let (nIn, ip) = read7zNumber(data, pos), let (nOut, op) = read7zNumber(data, ip),
                                  nIn <= 64, nOut <= 64 else { return nil }
                            numIn = Int(nIn); numOut = Int(nOut)
                            pos = op
                        }
                        var props: [UInt8] = []
                        if flags & 0x20 != 0 { // attributes
                            guard let (propSize, pp) = read7zNumber(data, pos), let iProp = Int(exactly: propSize),
                                  pp + iProp <= data.count, iProp <= 1024 else { return nil }
                            props = Array(data[pp..<pp + iProp])
                            pos = pp + iProp
                        }
                        if coderIndex == 0 {
                            folder.coderID = coderID
                            folder.props = props
                        }
                        folderOutStreams += numOut
                        folderInStreams += numIn
                    }
                    // Bind pairs
                    let numBindPairs = folderOutStreams - 1
                    for _ in 0..<numBindPairs {
                        guard let (_, b1) = read7zNumber(data, pos), let (_, b2) = read7zNumber(data, b1) else { return nil }
                        pos = b2
                    }
                    // Packed stream indices when a folder consumes several
                    let numPackedStreams = folderInStreams - numBindPairs
                    if numPackedStreams > 1 {
                        for _ in 0..<numPackedStreams {
                            guard let (_, ip) = read7zNumber(data, pos) else { return nil }
                            pos = ip
                        }
                    }
                    totalOutStreams += folderOutStreams
                    folders.append(folder)
                }

                // kCodersUnpackSize
                guard let (sizeMarker, sp) = readByte(data, pos), sizeMarker == 0x0C else { return nil }
                pos = sp
                var allUnpackSizes: [UInt64] = []
                for _ in 0..<totalOutStreams {
                    guard let (sz, up) = read7zNumber(data, pos) else { return nil }
                    allUnpackSizes.append(sz)
                    pos = up
                }
                // The folder's final unpack size is its LAST out-stream size (single-coder: the only one).
                // With one coder per folder (our decode target) sizes align 1:1.
                var sizeIndex = 0
                for i in 0..<folders.count {
                    folders[i].unpackSize = sizeIndex < allUnpackSizes.count ? allUnpackSizes[sizeIndex] : 0
                    sizeIndex += 1
                }
                info.folders = folders

                // Optional kCRC then kEnd
                unpackTail: while true {
                    guard let (m, mp) = readByte(data, pos) else { return nil }
                    pos = mp
                    switch m {
                    case 0x00: break unpackTail
                    case 0x0A:
                        guard let skipped = skipCRC(data, pos, count: folders.count) else { return nil }
                        pos = skipped
                    default:
                        guard let (size, np) = read7zNumber(data, pos), let iSize = Int(exactly: size), np + iSize <= data.count else { return nil }
                        pos = np + iSize
                    }
                }

            case 0x08: // kSubStreamsInfo
                var numUnpackStreams = info.folders.map { _ in 1 }
                subLoop: while true {
                    guard let (m, mp) = readByte(data, pos) else { return nil }
                    pos = mp
                    switch m {
                    case 0x0D: // kNumUnpackStream
                        numUnpackStreams = []
                        for _ in info.folders {
                            guard let (n, np) = read7zNumber(data, pos), n <= 1_000_000 else { return nil }
                            numUnpackStreams.append(Int(n))
                            pos = np
                        }
                    case 0x09: // kSize: numUnpackStreams[i]-1 sizes per folder; last derived
                        for (i, count) in numUnpackStreams.enumerated() where i < info.folders.count {
                            var sizes: [UInt64] = []
                            var sum: UInt64 = 0
                            if count > 0 {
                                for _ in 0..<(count - 1) {
                                    guard let (sz, np) = read7zNumber(data, pos) else { return nil }
                                    sizes.append(sz)
                                    sum &+= sz
                                    pos = np
                                }
                                let last = info.folders[i].unpackSize >= sum ? info.folders[i].unpackSize - sum : 0
                                sizes.append(last)
                            }
                            info.folders[i].substreamSizes = sizes
                            info.folders[i].numUnpackStreams = count
                        }
                    case 0x0A: // kCRC — digest count varies; skip conservatively
                        let totalStreams = numUnpackStreams.reduce(0, +)
                        guard let skipped = skipCRC(data, pos, count: totalStreams) else { return nil }
                        pos = skipped
                    case 0x00:
                        // Folders without explicit kSize get their single size
                        for i in 0..<info.folders.count where info.folders[i].substreamSizes.isEmpty {
                            info.folders[i].numUnpackStreams = numUnpackStreams.indices.contains(i) ? numUnpackStreams[i] : 1
                            if info.folders[i].numUnpackStreams == 1 {
                                info.folders[i].substreamSizes = [info.folders[i].unpackSize]
                            }
                        }
                        break subLoop
                    default:
                        guard let (size, np) = read7zNumber(data, pos), let iSize = Int(exactly: size), np + iSize <= data.count else { return nil }
                        pos = np + iSize
                    }
                }

            default:
                // Unknown block: cannot reliably skip — bail out
                return nil
            }
        }
    }

    private static func skipCRC(_ data: [UInt8], _ startPos: Int, count: Int) -> Int? {
        var pos = startPos
        guard let (allDefined, p) = readByte(data, pos) else { return nil }
        pos = p
        var defined = count
        if allDefined == 0 {
            guard let (bits, bp) = readBitVector(data, pos, count: count) else { return nil }
            pos = bp
            defined = bits.filter { $0 }.count
        }
        guard pos + defined * 4 <= data.count else { return nil }
        return pos + defined * 4
    }

    // MARK: 7z top-level

    static func parse7z(_ url: URL) -> [AEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 32), headerData.count == 32 else { return [] }
        let sig: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        let head = [UInt8](headerData)
        guard Array(head[0..<6]) == sig else { return [] }

        func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) }
            return v
        }
        let nextOffset = le64(head, 12)
        let nextSize = le64(head, 20)
        guard nextSize > 0, nextSize < 16_000_000,
              let iNextSize = Int(exactly: nextSize),
              let absOffset = UInt64(exactly: 32).flatMap({ base -> UInt64? in
                  let (sum, overflow) = base.addingReportingOverflow(nextOffset)
                  return overflow ? nil : sum
              }) else { return [] }

        try? handle.seek(toOffset: absOffset)
        guard let raw = try? handle.read(upToCount: iNextSize), raw.count == iNextSize else { return [] }
        var header = [UInt8](raw)

        if header.first == 0x17 {
            // Encoded header: parse its StreamsInfo, fetch + decode the packed blob
            guard let (streams, _) = parseStreamsInfo(header, 1),
                  let folder = streams.folders.first,
                  let packSize = streams.packSizes.first,
                  let iPackSize = Int(exactly: packSize), iPackSize < 16_000_000,
                  let unpackSize = Int(exactly: folder.unpackSize), unpackSize < 16_000_000 else { return [] }

            let blobOffset = 32 &+ streams.packPos
            try? handle.seek(toOffset: blobOffset)
            guard let packedData = try? handle.read(upToCount: iPackSize), packedData.count == iPackSize else { return [] }
            let packed = [UInt8](packedData)

            let decoded: [UInt8]?
            if folder.coderID == [0x03, 0x01, 0x01] {
                decoded = LZMADecoder.decodeLZMA1(props: folder.props, input: packed, unpackSize: unpackSize)
            } else if folder.coderID == [0x21] {
                decoded = LZMADecoder.decodeLZMA2(input: packed, unpackSize: unpackSize)
            } else if folder.coderID == [0x00] {
                decoded = packed // Copy coder
            } else {
                decoded = nil // AES-encrypted header (0x06F10701) or unknown — cannot list
            }
            guard let headerBytes = decoded, headerBytes.first == 0x01 else { return [] }
            header = headerBytes
        }

        guard header.first == 0x01 else { return [] }
        return parse7zHeaderBlock(header)
    }

    /// Parses a decoded (0x01 kHeader) block into entries.
    static func parse7zHeaderBlock(_ data: [UInt8]) -> [AEntry] {
        var pos = 1
        var mainStreams: SevenZStreamsInfo? = nil

        while pos < data.count {
            guard let (marker, p) = readByte(data, pos) else { return [] }
            pos = p
            switch marker {
            case 0x00:
                return []
            case 0x02: // kArchiveProperties
                propLoop: while true {
                    guard let (t, tp) = readByte(data, pos) else { return [] }
                    pos = tp
                    if t == 0 { break propLoop }
                    guard let (size, np) = read7zNumber(data, pos), let iSize = Int(exactly: size), np + iSize <= data.count else { return [] }
                    pos = np + iSize
                }
            case 0x03: // kAdditionalStreamsInfo — parse (skip) with the same walker
                guard let (_, np) = parseStreamsInfo(data, pos) else { return [] }
                pos = np
            case 0x04: // kMainStreamsInfo
                guard let (streams, np) = parseStreamsInfo(data, pos) else { return [] }
                mainStreams = streams
                pos = np
            case 0x05: // kFilesInfo
                return parseFilesInfo(data, pos, mainStreams: mainStreams)
            default:
                guard let (size, np) = read7zNumber(data, pos), let iSize = Int(exactly: size), np + iSize <= data.count else { return [] }
                pos = np + iSize
            }
        }
        return []
    }

    private static func parseFilesInfo(_ data: [UInt8], _ startPos: Int, mainStreams: SevenZStreamsInfo?) -> [AEntry] {
        var pos = startPos
        guard let (numFiles64, p) = read7zNumber(data, pos), numFiles64 <= 1_000_000 else { return [] }
        let numFiles = Int(numFiles64)
        pos = p

        var emptyStream = [Bool](repeating: false, count: numFiles)
        var emptyFile: [Bool] = []
        var names: [String] = []
        var mtimes: [Date?] = Array(repeating: nil, count: numFiles)

        fileProps: while true {
            guard let (type64, tp) = read7zNumber(data, pos) else { return [] }
            pos = tp
            if type64 == 0x00 { break fileProps }
            guard let (size64, sp) = read7zNumber(data, pos), let size = Int(exactly: size64),
                  sp + size <= data.count else { return [] }
            let propStart = sp
            pos = sp + size

            switch type64 {
            case 0x0E: // kEmptyStream
                if let (bits, _) = readBitVector(data, propStart, count: numFiles) {
                    emptyStream = bits
                }
            case 0x0F: // kEmptyFile
                let emptyCount = emptyStream.filter { $0 }.count
                if let (bits, _) = readBitVector(data, propStart, count: emptyCount) {
                    emptyFile = bits
                }
            case 0x11: // kName
                var np = propStart
                guard let (external, ep) = readByte(data, np), external == 0 else { break }
                np = ep
                var current: [UInt8] = []
                while np + 1 < propStart + size {
                    let lo = data[np], hi = data[np + 1]
                    np += 2
                    if lo == 0 && hi == 0 {
                        let name = String(bytes: current, encoding: .utf16LittleEndian) ?? "?"
                        names.append(name)
                        current = []
                        if names.count >= 100_000 { break }
                    } else {
                        current.append(lo)
                        current.append(hi)
                    }
                }
            case 0x14: // kMTime
                var np = propStart
                guard let (allDefined, ap) = readByte(data, np) else { break }
                np = ap
                var defined = [Bool](repeating: true, count: numFiles)
                if allDefined == 0 {
                    guard let (bits, bp) = readBitVector(data, np, count: numFiles) else { break }
                    defined = bits
                    np = bp
                }
                guard let (external, ep) = readByte(data, np), external == 0 else { break }
                np = ep
                for i in 0..<numFiles where defined[i] {
                    guard np + 8 <= propStart + size else { break }
                    var filetime: UInt64 = 0
                    for b in 0..<8 { filetime |= UInt64(data[np + b]) << (8 * b) }
                    np += 8
                    let unix = Double(filetime) / 10_000_000.0 - 11_644_473_600.0
                    if unix > 0 && unix < 4_102_444_800 { // sane range up to 2100
                        mtimes[i] = Date(timeIntervalSince1970: unix)
                    }
                }
            default:
                break
            }
        }

        // Assemble entries
        let substreamSizes: [UInt64] = mainStreams?.folders.flatMap { folder -> [UInt64] in
            folder.substreamSizes.isEmpty ? [folder.unpackSize] : folder.substreamSizes
        } ?? []

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var entries: [AEntry] = []
        var sizeCursor = 0
        var emptyCursor = 0
        for i in 0..<numFiles {
            let name = i < names.count ? names[i] : "?"
            let displayName = name.replacingOccurrences(of: "\\", with: "/")
            var isDir = false
            var size: Int64 = 0
            if emptyStream[i] {
                let isEmptyFile = emptyCursor < emptyFile.count ? emptyFile[emptyCursor] : false
                emptyCursor += 1
                isDir = !isEmptyFile
            } else {
                if sizeCursor < substreamSizes.count {
                    size = Int64(clamping: substreamSizes[sizeCursor])
                }
                sizeCursor += 1
            }
            let dateString = mtimes.indices.contains(i) ? (mtimes[i].map { df.string(from: $0) } ?? "") : ""
            entries.append(AEntry(path: displayName, size: size, packed: 0, date: dateString, isDir: isDir))
            if entries.count >= 2000 { break }
        }
        return entries
    }

    // MARK: TAR

    static func parseTar(_ url: URL) -> [AEntry] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 512 else { return [] }
        var entries: [AEntry] = []
        var offset = 0
        var pendingLongName: String? = nil
        var zeroBlocks = 0
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        func cString(_ start: Int, _ maxLen: Int) -> String {
            let end = min(start + maxLen, data.count)
            var bytes: [UInt8] = []
            for i in start..<end {
                if data[i] == 0 { break }
                bytes.append(data[i])
            }
            return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? "?"
        }
        func octal(_ start: Int, _ len: Int) -> Int64 {
            let s = cString(start, len).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            return Int64(s, radix: 8) ?? 0
        }

        while offset + 512 <= data.count, entries.count < 2000 {
            // Zero-block check
            var allZero = true
            for i in offset..<offset + 512 where data[i] != 0 { allZero = false; break }
            if allZero {
                zeroBlocks += 1
                if zeroBlocks >= 2 { break }
                offset += 512
                continue
            }
            zeroBlocks = 0

            let sizeVal = octal(offset + 124, 12)
            guard sizeVal >= 0 else { break }
            let typeflag = data[offset + 156]
            var name = cString(offset, 100)
            // ustar prefix
            let magic = cString(offset + 257, 6)
            if magic.hasPrefix("ustar") {
                let prefix = cString(offset + 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            if let long = pendingLongName {
                name = long
                pendingLongName = nil
            }

            let dataBlocks = (Int(sizeVal) + 511) / 512
            let contentStart = offset + 512

            switch typeflag {
            case UInt8(ascii: "L"): // GNU long name
                if contentStart + Int(sizeVal) <= data.count {
                    pendingLongName = cString(contentStart, Int(sizeVal))
                }
            case UInt8(ascii: "5"): // directory
                let mtime = octal(offset + 136, 12)
                let ds = mtime > 0 ? df.string(from: Date(timeIntervalSince1970: TimeInterval(mtime))) : ""
                entries.append(AEntry(path: name.hasSuffix("/") ? String(name.dropLast()) : name, size: 0, packed: 0, date: ds, isDir: true))
            case 0, UInt8(ascii: "0"): // regular file
                let mtime = octal(offset + 136, 12)
                let ds = mtime > 0 ? df.string(from: Date(timeIntervalSince1970: TimeInterval(mtime))) : ""
                entries.append(AEntry(path: name, size: sizeVal, packed: 0, date: ds, isDir: false))
            default:
                break // symlinks, pax headers, etc. — skipped in the listing
            }

            guard dataBlocks >= 0, offset + 512 + dataBlocks * 512 > offset else { break }
            offset += 512 + dataBlocks * 512
        }
        return entries
    }

    // MARK: GZ

    static func parseGz(_ url: URL) -> [AEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024), head.count >= 10,
              head[0] == 0x1F, head[1] == 0x8B else { return [] }

        let flags = head[3]
        var pos = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard pos + 2 <= head.count else { return [] }
            let xlen = Int(head[pos]) | Int(head[pos + 1]) << 8
            pos += 2 + xlen
        }
        var originalName: String? = nil
        if flags & 0x08 != 0, pos < head.count { // FNAME
            var bytes: [UInt8] = []
            while pos < head.count, head[pos] != 0 {
                bytes.append(head[pos])
                pos += 1
            }
            originalName = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        }

        // ISIZE: last 4 bytes (mod 2^32)
        var size: Int64 = 0
        if let fileSize = try? handle.seekToEnd(), fileSize >= 4 {
            try? handle.seek(toOffset: fileSize - 4)
            if let tail = try? handle.read(upToCount: 4), tail.count == 4 {
                let isize = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
                size = Int64(isize)
            }
        }

        let stem = url.deletingPathExtension().lastPathComponent
        return [AEntry(path: originalName ?? stem, size: size, packed: 0, date: "", isDir: false)]
    }

    // MARK: ZIP (with ZIP64)

    static func parseZip(_ url: URL) -> [AEntry] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 22 else { return [] }

        func r16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func r32(_ o: Int) -> UInt32 { UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24 }
        func r64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[o + i]) << (8 * i) }
            return v
        }

        var eocd = -1
        let scanStart = data.count - 22
        let scanEnd = max(0, data.count - 65557)
        var i = scanStart
        while i >= scanEnd {
            if data[i] == 0x50 && data[i + 1] == 0x4b && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        var count = r16(eocd + 10)
        var cdStart = Int(r32(eocd + 16))

        // ZIP64: locator sits 20 bytes before EOCD
        if count == 0xFFFF || cdStart == 0xFFFFFFFF {
            let locPos = eocd - 20
            if locPos >= 0, data[locPos] == 0x50, data[locPos + 1] == 0x4b, data[locPos + 2] == 0x06, data[locPos + 3] == 0x07 {
                let eocd64Offset64 = r64(locPos + 8)
                if let eocd64Offset = Int(exactly: eocd64Offset64), eocd64Offset + 56 <= data.count,
                   data[eocd64Offset] == 0x50, data[eocd64Offset + 1] == 0x4b,
                   data[eocd64Offset + 2] == 0x06, data[eocd64Offset + 3] == 0x06 {
                    if let c = Int(exactly: r64(eocd64Offset + 32)) { count = c }
                    if let s = Int(exactly: r64(eocd64Offset + 48)) { cdStart = s }
                }
            }
        }

        var off = cdStart
        var result: [AEntry] = []
        var iter = 0
        while iter < min(count, 2000) {
            iter += 1
            guard off + 46 <= data.count,
                  data[off] == 0x50, data[off + 1] == 0x4b, data[off + 2] == 1, data[off + 3] == 2 else { break }
            var packed = Int64(r32(off + 20))
            var unpacked = Int64(r32(off + 24))
            let nl = r16(off + 28)
            let el = r16(off + 30)
            let cl = r16(off + 32)
            let mt = UInt16(r16(off + 12))
            let md = UInt16(r16(off + 14))
            let flags = r16(off + 8)
            guard off + 46 + nl + el <= data.count else { break }
            let nameData = data[(off + 46)..<(off + 46 + nl)]
            let nm = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "?"

            // ZIP64 extra field for saturated values
            if unpacked == 0xFFFFFFFF || packed == 0xFFFFFFFF {
                var ep = off + 46 + nl
                let extraEnd = ep + el
                while ep + 4 <= extraEnd {
                    let tag = r16(ep)
                    let sz = r16(ep + 2)
                    if tag == 0x0001 {
                        var fp = ep + 4
                        if unpacked == 0xFFFFFFFF, fp + 8 <= extraEnd { unpacked = Int64(clamping: r64(fp)); fp += 8 }
                        if packed == 0xFFFFFFFF, fp + 8 <= extraEnd { packed = Int64(clamping: r64(fp)) }
                        break
                    }
                    ep += 4 + sz
                }
            }

            let encrypted = flags & 0x1 != 0
            let displayName = encrypted ? nm + " 🔒" : nm
            result.append(AEntry(path: displayName, size: unpacked, packed: packed, date: dosDate(md, mt), isDir: nm.hasSuffix("/")))
            off += 46 + nl + el + cl
        }
        return result
    }

    static func dosDate(_ d: UInt16, _ t: UInt16) -> String {
        let dy = d & 0x1F, mn = (d >> 5) & 0xF, yr = (d >> 9) & 0x7F, mi = (t >> 5) & 0x3F, hr = (t >> 11) & 0x1F
        return dy > 0 ? String(format: "%d-%02d-%02d %02d:%02d", Int(yr) + 1980, mn, dy, hr, mi) : ""
    }

    // MARK: TAJ

    static func parseTaj(_ url: URL) -> [AEntry] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 48,
              data[0] == 0x54, data[1] == 0x41, data[2] == 0x4A, data[3] == 0x02 else { return [] }

        func r16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func r32(_ o: Int) -> UInt32 { UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24 }
        func r64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[o + i]) << (8 * i) }
            return v
        }

        let flags = r16(4 + 2)
        let encrypted = flags & 0x1 != 0
        let fc = Int(r32(12))
        guard let tOff = Int(exactly: r64(36)), tOff >= 48, tOff < data.count, fc <= 1_000_000 else { return [] }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var result: [AEntry] = []
        var o = tOff
        for _ in 0..<fc {
            guard o + 2 <= data.count else { break }
            let pl = r16(o); o += 2
            guard o + pl <= data.count else { break }
            let p = String(data: data[o..<o + pl], encoding: .utf8) ?? "?"; o += pl
            guard o + 29 <= data.count else { break }
            guard let sz = Int64(exactly: r64(o)) else { break }
            o += 8
            let md = r64(o); o += 8
            o += 2 // permissions
            let isDir = data[o] == 1; o += 1
            let bc = Int(r32(o)); o += 4
            guard bc >= 0, bc <= 10_000_000, o + bc * 4 + 4 <= data.count else { break }
            o += bc * 4 + 4
            var ds = ""
            if md > 0, md < 4_102_444_800 {
                ds = df.string(from: Date(timeIntervalSince1970: TimeInterval(md)))
            }
            let displayName = encrypted && !isDir ? p + " 🔒" : p
            result.append(AEntry(path: displayName, size: sz, packed: 0, date: ds, isDir: isDir))
            if result.count >= 2000 { break }
        }
        return result
    }
}

// MARK: - Preview controller

class PreviewViewController: NSViewController, QLPreviewingController {

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        var entries: [AEntry] = []

        switch ext {
        case "zip":
            entries = ArchiveParsers.parseZip(url)
        case "taj":
            entries = ArchiveParsers.parseTaj(url)
        case "7z":
            entries = ArchiveParsers.parse7z(url)
        case "tar":
            entries = ArchiveParsers.parseTar(url)
        case "gz", "tgz":
            entries = ArchiveParsers.parseGz(url)
        default:
            break // bz2, xz, rar: no native parser — honest stub below
        }

        if entries.isEmpty {
            entries = [AEntry(path: url.lastPathComponent, size: fileSize, packed: 0, date: "", isDir: false)]
        }

        buildUI(name: url.lastPathComponent, entries: entries, archiveExt: ext, fellBack: entries.count == 1 && entries[0].path == url.lastPathComponent)
        handler(nil)
    }

    // MARK: - UI

    /// Strings come from this extension's own Localizable.strings (it runs outside the app).
    private func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    private func L(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    private func buildUI(name: String, entries: [AEntry], archiveExt: String, fellBack: Bool) {
        // The controller may be reused for successive previews — start clean.
        view.subviews.forEach { $0.removeFromSuperview() }

        let scroll = NSScrollView(frame: view.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = NSTextView(frame: view.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        let s = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 16, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 11)
        let hdrFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        s.append(str(name + "\n", titleFont, .labelColor))

        let nf = entries.filter { !$0.isDir }.count
        let nd = entries.filter { $0.isDir }.count
        let tot = entries.reduce(Int64(0)) { $0 + $1.size }
        if !fellBack {
            s.append(str(L("Files: %d   Folders: %d   Size: %@", nf, nd, fmt(tot)) + "\n\n", subFont, .secondaryLabelColor))
            s.append(str(lpad(L("Name"), 42) + rpad(L("Size"), 9) + "  " + L("Modified") + "\n", hdrFont, .secondaryLabelColor))
            s.append(str(String(repeating: "─", count: 70) + "\n", monoFont, .separatorColor))

            // Group each folder with its contents, whatever order the archive stores them in.
            let ordered = entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for entry in ordered.prefix(300) {
                let icon = entry.isDir ? "📁 " : "📄 "
                var nm = icon + entry.shortName
                if nm.count > 40 { nm = String(nm.prefix(37)) + "…" }
                let sz = entry.isDir ? rpad("—", 9) : rpad(fmt(entry.size), 9)
                let dt = String(entry.date.prefix(16))

                s.append(str(lpad(nm, 42), monoFont, entry.isDir ? .systemBlue : .labelColor))
                s.append(str(sz + "  ", monoFont, .secondaryLabelColor))
                s.append(str(dt + "\n", monoFont, .tertiaryLabelColor))
            }

            if entries.count > 300 {
                s.append(str("\n" + L("…and %d more", entries.count - 300) + "\n", subFont, .tertiaryLabelColor))
            }
        } else {
            s.append(str(fmt(tot) + "\n\n", subFont, .secondaryLabelColor))
            s.append(str(L("Open the archive in TajArchive to see its contents.") + "\n", subFont, .secondaryLabelColor))
        }

        tv.textStorage?.setAttributedString(s)
        scroll.documentView = tv
        view.addSubview(scroll)
    }

    private func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    private func str(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
    }
    private func fmt(_ b: Int64) -> String { b <= 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    private func rpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
}
