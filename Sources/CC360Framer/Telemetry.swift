import Foundation

/// Per-frame motion data from the GoPro metadata track (`gpmd`), in the camera's sensor axes.
/// AVFoundation does not expose that track, so the MP4 container is read directly.
struct Telemetry {
    /// Camera orientation relative to the first frame, quaternion (w, x, y, z).
    var orientation: [SIMD4<Float>]
    /// Gravity direction in camera axes (unit-ish; points down).
    var gravity: [SIMD3<Float>]

    var count: Int { min(orientation.count, gravity.count) }

    /// nil when the file has no usable telemetry.
    static func load(url: URL) -> Telemetry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let moov = readMoov(fh), let samples = gpmdSamples(moov) else { return nil }
        var t = Telemetry(orientation: [], gravity: [])
        for (offset, size) in samples {
            guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.read(upToCount: size), data.count == size else { continue }
            parseGPMF([UInt8](data), into: &t)
        }
        return t.count > 0 ? t : nil
    }

    // MARK: MP4

    private struct Atom { let type: String; let payload: Range<Int> }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[i + $1]) }
    }

    private static func atoms(_ b: [UInt8], _ r: Range<Int>) -> [Atom] {
        var out: [Atom] = []
        var p = r.lowerBound
        while p + 8 <= r.upperBound {
            var size = be32(b, p)
            var header = 8
            if size == 1, p + 16 <= r.upperBound { size = Int(be64(b, p + 8)); header = 16 }
            if size == 0 { size = r.upperBound - p }
            guard size >= header, p + size <= r.upperBound else { break }
            out.append(Atom(type: String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self), payload: (p + header)..<(p + size)))
            p += size
        }
        return out
    }

    /// Reads the `moov` box (the sample tables) without touching the multi-gigabyte `mdat`.
    private static func readMoov(_ fh: FileHandle) -> [UInt8]? {
        guard let end = try? fh.seekToEnd() else { return nil }
        var pos: UInt64 = 0
        while pos + 8 <= end {
            guard (try? fh.seek(toOffset: pos)) != nil, let head = try? fh.read(upToCount: 16), head.count >= 8 else { return nil }
            let h = [UInt8](head)
            var size = UInt64(be32(h, 0))
            var header: UInt64 = 8
            if size == 1, h.count >= 16 { size = be64(h, 8); header = 16 }
            if size == 0 { size = end - pos }
            guard size >= header else { return nil }
            if String(decoding: h[4..<8], as: UTF8.self) == "moov" {
                guard (try? fh.seek(toOffset: pos + header)) != nil,
                      let d = try? fh.read(upToCount: Int(size - header)) else { return nil }
                return [UInt8](d)
            }
            pos += size
        }
        return nil
    }

    /// (file offset, size) of every sample of the `gpmd` track.
    private static func gpmdSamples(_ moov: [UInt8]) -> [(UInt64, Int)]? {
        func child(_ parent: Range<Int>, _ type: String) -> Atom? { atoms(moov, parent).first { $0.type == type } }
        for trak in atoms(moov, 0..<moov.count) where trak.type == "trak" {
            guard let mdia = child(trak.payload, "mdia"), let minf = child(mdia.payload, "minf"),
                  let stbl = child(minf.payload, "stbl"), let stsd = child(stbl.payload, "stsd"),
                  stsd.payload.count >= 16,
                  String(decoding: moov[(stsd.payload.lowerBound + 12)..<(stsd.payload.lowerBound + 16)], as: UTF8.self) == "gpmd",
                  let stsz = child(stbl.payload, "stsz"), let stsc = child(stbl.payload, "stsc") else { continue }
            let co64 = child(stbl.payload, "co64")
            guard let stco = child(stbl.payload, "stco") ?? co64 else { continue }

            var s = stsz.payload.lowerBound + 4
            let fixed = be32(moov, s), n = be32(moov, s + 4)
            s += 8
            let sizes = (0..<n).map { fixed != 0 ? fixed : be32(moov, s + $0 * 4) }

            var c = stsc.payload.lowerBound + 4
            let entries = be32(moov, c)
            c += 4
            let runs = (0..<entries).map { (first: be32(moov, c + $0 * 12), per: be32(moov, c + $0 * 12 + 4)) }

            var o = stco.payload.lowerBound + 4
            let chunks = be32(moov, o)
            o += 4
            let offsets: [UInt64] = (0..<chunks).map { co64 != nil && stco.type == "co64" ? be64(moov, o + $0 * 8) : UInt64(be32(moov, o + $0 * 4)) }

            var out: [(UInt64, Int)] = []
            var sample = 0
            for (ci, chunkOffset) in offsets.enumerated() {
                let per = runs.last { $0.first <= ci + 1 }?.per ?? 1
                var off = chunkOffset
                for _ in 0..<per where sample < sizes.count {
                    out.append((off, sizes[sample]))
                    off += UInt64(sizes[sample])
                    sample += 1
                }
            }
            return out
        }
        return nil
    }

    // MARK: GPMF

    private struct KLV { let key: String; let type: UInt8; let size: Int; let repeats: Int; let data: Range<Int> }

    private static func klvs(_ b: [UInt8], _ r: Range<Int>) -> [KLV] {
        var out: [KLV] = []
        var p = r.lowerBound
        while p + 8 <= r.upperBound {
            let size = Int(b[p + 5]), rep = Int(b[p + 6]) << 8 | Int(b[p + 7])
            let len = size * rep
            guard p + 8 + len <= r.upperBound else { break }
            out.append(KLV(key: String(decoding: b[p..<(p + 4)], as: UTF8.self), type: b[p + 4], size: size, repeats: rep, data: (p + 8)..<(p + 8 + len)))
            p += 8 + (len + 3) / 4 * 4
        }
        return out
    }

    private static func int16s(_ b: [UInt8], _ k: KLV, _ i: Int, _ n: Int) -> [Float] {
        (0..<n).map { c in
            let o = k.data.lowerBound + i * k.size + c * 2
            return Float(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1])))
        }
    }

    private static func parseGPMF(_ b: [UInt8], into t: inout Telemetry) {
        for devc in klvs(b, 0..<b.count) where devc.key == "DEVC" {
            for strm in klvs(b, devc.data) where strm.key == "STRM" {
                let items = klvs(b, strm.data)
                guard let scal = items.first(where: { $0.key == "SCAL" }) else { continue }
                let scale = max(int16s(b, scal, 0, 1)[0], 1)
                for k in items where (k.key == "CORI" || k.key == "GRAV") && k.type == UInt8(ascii: "s") {
                    for i in 0..<k.repeats {
                        let v = int16s(b, k, i, k.size / 2).map { $0 / scale }
                        if k.key == "CORI", v.count == 4 { t.orientation.append(SIMD4(v[0], v[1], v[2], v[3])) }
                        if k.key == "GRAV", v.count == 3 { t.gravity.append(SIMD3(v[0], v[1], v[2])) }
                    }
                }
            }
        }
    }
}
