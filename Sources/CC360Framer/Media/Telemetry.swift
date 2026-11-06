import Foundation

/// Per-frame motion data from the GoPro metadata track (`gpmd`), in the camera's sensor axes.
/// AVFoundation does not expose that track, so the MP4 container is read directly.
struct Telemetry {
    /// Camera orientation relative to the first frame, quaternion (w, x, y, z).
    var orientation: [SIMD4<Float>]
    /// Gravity direction in camera axes (unit-ish; points down).
    var gravity: [SIMD3<Float>]
    /// Image orientation relative to the camera body, quaternion (w, x, y, z); a roll-only correction in these files.
    var imageOrientation: [SIMD4<Float>] = []

    /// First GPS position with a lock, if the file has one.
    var gps: GPSFix?
    /// Altitudes of the first locked fixes; the very first fix is often off by tens of metres while the receiver settles.
    var altitudes: [Double] = []
    static let altitudeWindow = 20

    /// Replaces the first fix's altitude with the median of the first locked fixes.
    mutating func settleAltitude() {
        guard gps != nil, !altitudes.isEmpty else { return }
        let sorted = altitudes.sorted()
        gps?.altitude = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    struct GPSFix: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        /// Metres (GPS height, field 2 of GPS5/GPS9); nil when the stream has none.
        var altitude: Double?
    }

    /// One accelerometer reading: the three `ACCL` channels in m/s^2 exactly as stored (channel order is the camera's
    /// `ORIN`, not x/y/z; `TravelDirection` maps them to render axes), at `t` seconds from the start of the clip.
    struct AccelSample: Equatable {
        var t: Double
        var channels: SIMD3<Float>
    }

    /// One GPS fix of the full series (about 10 Hz), with the receiver quality.
    struct GPSSample: Equatable {
        var t: Double
        var latitude: Double
        var longitude: Double
        /// Ground speed in m/s.
        var speed2D: Double
        /// 0 = none, 2 = 2D, 3 = 3D.
        var fix: Int
        /// Dilution of precision (99.99 while unlocked).
        var dop: Double
        /// Locked with a trustworthy geometry (the first rows of a clip are often unlocked with dop ~ 99).
        var isUsable: Bool { fix >= 2 && dop < 5 }
    }

    /// ~197 Hz accelerometer series; sample times follow the `gpmd` packet timing.
    var accel: [AccelSample] = []
    /// Every GPS fix of the clip (GPS9, or GPS5 on older cameras), unlike `gps` which is only the first lock.
    var gpsSeries: [GPSSample] = []

    var count: Int { min(orientation.count, gravity.count) }

    /// nil when the file has no usable telemetry.
    static func load(url: URL) -> Telemetry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let moov = readMoov(fh), let samples = gpmdSamples(moov) else { return nil }
        var t = Telemetry(orientation: [], gravity: [], imageOrientation: [])
        for p in samples {
            guard (try? fh.seek(toOffset: p.offset)) != nil, let data = try? fh.read(upToCount: p.size), data.count == p.size else { continue }
            parseGPMF([UInt8](data), into: &t, start: p.start, span: p.span)
        }
        t.settleAltitude()
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

    /// One `gpmd` packet: where it is in the file and which stretch of the clip (seconds) it covers.
    private struct Packet { var offset: UInt64; var size: Int; var start: Double; var span: Double }

    /// Every sample (packet) of the `gpmd` track with its timing from `stts` and the `mdhd` time scale.
    private static func gpmdSamples(_ moov: [UInt8]) -> [Packet]? {
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

            // Packet timing: durations from stts in media time units (1 s packets when the box is missing).
            var scale = 1000.0
            if let mdhd = child(mdia.payload, "mdhd"), mdhd.payload.count >= 24 {
                let at = mdhd.payload.lowerBound
                scale = Double(be32(moov, at + (moov[at] == 1 ? 20 : 12)))
            }
            var durations: [Double] = []
            if let stts = child(stbl.payload, "stts"), stts.payload.count >= 8 {
                let base = stts.payload.lowerBound + 4
                let count = min(be32(moov, base), (stts.payload.count - 8) / 8)
                for e in 0..<count {
                    let n = be32(moov, base + 4 + e * 8), delta = be32(moov, base + 8 + e * 8)
                    durations.append(contentsOf: [Double](repeating: Double(delta) / max(scale, 1), count: min(n, sizes.count)))
                    if durations.count >= sizes.count { break }
                }
            }
            var starts: [Double] = []
            var clock = 0.0
            for i in 0..<sizes.count {
                starts.append(clock)
                clock += i < durations.count ? durations[i] : 1
            }

            var out: [Packet] = []
            var sample = 0
            for (ci, chunkOffset) in offsets.enumerated() {
                let per = runs.last { $0.first <= ci + 1 }?.per ?? 1
                var off = chunkOffset
                for _ in 0..<per where sample < sizes.count {
                    out.append(Packet(offset: off, size: sizes[sample], start: starts[sample],
                                      span: sample < durations.count ? durations[sample] : 1))
                    off += UInt64(sizes[sample])
                    sample += 1
                }
            }
            return out
        }
        return nil
    }

    // MARK: GPMF

    struct KLV { let key: String; let type: UInt8; let size: Int; let repeats: Int; let data: Range<Int> }

    static func klvs(_ b: [UInt8], _ r: Range<Int>) -> [KLV] {
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

    /// Big-endian signed 32-bit values at `offset` (bytes from `base`).
    private static func int32(_ b: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))
    }

    /// First position with a 2D/3D lock from a `GPS5` (older cameras, lock in `GPSF`) or `GPS9` (lock in the sample) stream.
    static func parseGPS(_ b: [UInt8], _ items: [KLV], into t: inout Telemetry) {
        guard t.gps == nil || t.altitudes.count < Telemetry.altitudeWindow, let scal = items.first(where: { $0.key == "SCAL" }), scal.type == UInt8(ascii: "l") else { return }
        let scales = (0..<scal.repeats).map { Double(int32(b, scal.data.lowerBound + $0 * 4)) }
        guard let lat = scales.first, scales.count >= 2 else { return }
        func scale(_ i: Int) -> Double { max(scales.count > i ? scales[i] : lat, 1) }
        let fix = items.first { $0.key == "GPSF" }.map { Int(int32(b, $0.data.lowerBound)) } ?? 3
        for k in items where k.key == "GPS5" || k.key == "GPS9" {
            for i in 0..<k.repeats {
                let o = k.data.lowerBound + i * k.size
                guard k.size >= 8 else { continue }
                var locked = fix >= 2
                if k.key == "GPS9", k.size >= 32 { locked = (Int(b[o + 30]) << 8 | Int(b[o + 31])) >= 2 }
                let la = Double(int32(b, o)) / scale(0), lo = Double(int32(b, o + 4)) / scale(1)
                if locked, la != 0 || lo != 0, abs(la) <= 90, abs(lo) <= 180 {
                    let alt: Double? = k.size >= 12 && scales.count > 2 ? Double(int32(b, o + 8)) / scale(2) : nil
                    if t.gps == nil { t.gps = GPSFix(latitude: la, longitude: lo, altitude: alt) }
                    if let alt { t.altitudes.append(alt) }
                    if t.altitudes.count >= Telemetry.altitudeWindow { return }
                }
            }
        }
    }

    /// Series samples of one stream are spread evenly over the packet (`start`, `span` in seconds from the clip start).
    private static func sampleTime(_ i: Int, of n: Int, start: Double, span: Double) -> Double {
        start + (Double(i) + 0.5) / Double(max(n, 1)) * span
    }

    private static func uint16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }

    /// Appends the whole GPS series of a packet: `GPS9` (lat, lon, alt, speed2d, speed3d, days, secs, dop, fix) or
    /// `GPS5` (lat, lon, alt, speed2d, speed3d with `GPSF`/`GPSP` for the packet).
    private static func parseGPSSeries(_ b: [UInt8], _ items: [KLV], into t: inout Telemetry, start: Double, span: Double) {
        guard let scal = items.first(where: { $0.key == "SCAL" }), scal.type == UInt8(ascii: "l") else { return }
        let scales = (0..<scal.repeats).map { Double(int32(b, scal.data.lowerBound + $0 * 4)) }
        guard scales.count >= 4 else { return }
        let packetFix = items.first { $0.key == "GPSF" }.map { Int(int32(b, $0.data.lowerBound)) } ?? 3
        let packetDop = items.first { $0.key == "GPSP" }.map { Double(uint16(b, $0.data.lowerBound)) / 100 } ?? 0
        for k in items where (k.key == "GPS9" && k.size >= 32) || (k.key == "GPS5" && k.size >= 20) {
            for i in 0..<k.repeats {
                let o = k.data.lowerBound + i * k.size
                var fix = packetFix, dop = packetDop
                if k.key == "GPS9" { dop = Double(uint16(b, o + 28)) / max(scales.count > 7 ? scales[7] : 100, 1); fix = uint16(b, o + 30) }
                t.gpsSeries.append(GPSSample(t: sampleTime(i, of: k.repeats, start: start, span: span),
                                             latitude: Double(int32(b, o)) / max(scales[0], 1), longitude: Double(int32(b, o + 4)) / max(scales[1], 1),
                                             speed2D: Double(int32(b, o + 12)) / max(scales[3], 1), fix: fix, dop: dop))
            }
        }
    }

    /// Parses one `gpmd` packet. `start`/`span` (seconds) place the time series (ACCL, GPS) in the clip.
    static func parseGPMF(_ b: [UInt8], into t: inout Telemetry, start: Double = 0, span: Double = 0) {
        for devc in klvs(b, 0..<b.count) where devc.key == "DEVC" {
            for strm in klvs(b, devc.data) where strm.key == "STRM" {
                let items = klvs(b, strm.data)
                parseGPS(b, items, into: &t)
                parseGPSSeries(b, items, into: &t, start: start, span: span)
                guard let scal = items.first(where: { $0.key == "SCAL" }) else { continue }
                let scale = max(int16s(b, scal, 0, 1)[0], 1)
                for k in items where k.key == "ACCL" && k.type == UInt8(ascii: "s") && k.size >= 6 {
                    for i in 0..<k.repeats {
                        let v = int16s(b, k, i, 3).map { $0 / scale }
                        t.accel.append(AccelSample(t: sampleTime(i, of: k.repeats, start: start, span: span), channels: SIMD3(v[0], v[1], v[2])))
                    }
                }
                for k in items where (k.key == "CORI" || k.key == "GRAV" || k.key == "IORI") && k.type == UInt8(ascii: "s") {
                    for i in 0..<k.repeats {
                        let v = int16s(b, k, i, k.size / 2).map { $0 / scale }
                        if k.key == "CORI", v.count == 4 { t.orientation.append(SIMD4(v[0], v[1], v[2], v[3])) }
                        if k.key == "IORI", v.count == 4 { t.imageOrientation.append(SIMD4(v[0], v[1], v[2], v[3])) }
                        if k.key == "GRAV", v.count == 3 { t.gravity.append(SIMD3(v[0], v[1], v[2])) }
                    }
                }
            }
        }
    }
}
