import AVFoundation
import Vision
import Metal

/// Headless shake measurement: `CC360Framer --stab-test file.360 [startSeconds] [lengthSeconds]`.
/// Renders a fixed forward view with each stabilisation mode, measures frame-to-frame image shift with Vision,
/// and reports the residual high-frequency jitter (what remains after removing 1 s trends).
enum StabTest {
    static func run(args: [String]) -> Int32 {
        guard let path = args.first, let device = MTLCreateSystemDefaultDevice() else { print("usage: --stab-test file.360 [start] [length]"); return 1 }
        let start = args.count > 1 ? Double(args[1]) ?? 60 : 60
        let length = args.count > 2 ? Double(args[2]) ?? 20 : 20
        let url = URL(fileURLWithPath: path)
        guard let telemetry = Telemetry.load(url: url) else { print("no telemetry"); return 1 }

        let link = FileManager.default.temporaryDirectory.appendingPathComponent("stabtest-\(getpid()).mp4")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        let asset = AVURLAsset(url: link)
        let duration = asset.duration.seconds
        let videos = asset.tracks(withMediaType: .video)
        guard videos.count == 2 else { print("need two video tracks"); return 1 }

        // Variants: modes plus time offsets (in frames) of the telemetry against the video.
        struct Variant { let name: String; let stabilizer: Stabilizer?; let offset: Int }
        let smooth = Stabilizer(telemetry: telemetry, duration: duration, mode: .smooth)
        var variants = [Variant(name: "off", stabilizer: nil, offset: 0),
                        Variant(name: "level", stabilizer: Stabilizer(telemetry: telemetry, duration: duration, mode: .level), offset: 0)]
        for k in [-6, -4, -3, -2, -1, 0, 1, 2, 3, 4, 6] { variants.append(Variant(name: "smooth offset \(k)f", stabilizer: smooth, offset: k)) }

        do {
            let state = ViewState()
            let renderer = try Renderer(device: device, state: state, pixelFormat: .bgra8Unorm)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Layout.trackWidth / 4, kCVPixelBufferHeightKey as String: Layout.trackHeight / 4,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            let outs = videos.map { AVAssetReaderTrackOutput(track: $0, outputSettings: settings) }
            outs.forEach { reader.add($0) }
            guard reader.startReading() else { print("cannot read: \(String(describing: reader.error))"); return 1 }

            let size = (w: 480, h: 270)
            func makeTarget() -> (CVPixelBuffer, MTLTexture, CVMetalTexture) {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, size.w, size.h, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
                let (cv, tex) = renderer.makeTexture(from: pb!)!
                return (pb!, tex, cv)
            }
            let targets = variants.map { _ in [makeTarget(), makeTarget()] }
            var xs = [[Float]](repeating: [], count: variants.count), ys = xs
            var cumX = [Float](repeating: 0, count: variants.count), cumY = cumX
            var n = 0
            while let a = outs[0].copyNextSampleBuffer(), let b = outs[1].copyNextSampleBuffer() {
                guard let pa = CMSampleBufferGetImageBuffer(a), let pb = CMSampleBufferGetImageBuffer(b), renderer.setStacked(pa, pb) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(a).seconds
                for (i, v) in variants.enumerated() {
                    state.stabilizer = v.stabilizer
                    state.frameTime = t + Double(v.offset) / 29.97
                    let cur = targets[i][n % 2], prev = targets[i][(n + 1) % 2]
                    renderer.renderSync(to: cur.1, yaw: 0, pitch: 0, fov: 70)
                    if n > 0 {
                        let req = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: prev.0)
                        try? VNImageRequestHandler(cvPixelBuffer: cur.0, options: [:]).perform([req])
                        if let o = req.results?.first as? VNImageTranslationAlignmentObservation {
                            cumX[i] += Float(o.alignmentTransform.tx); cumY[i] += Float(o.alignmentTransform.ty)
                        }
                    }
                    xs[i].append(cumX[i]); ys[i].append(cumY[i])
                }
                n += 1
            }
            let degPerPx = 70.0 / Double(size.h)
            print("frames: \(n)  view 70° vertical, \(size.w)x\(size.h), \(String(format: "%.3f", degPerPx))°/px")
            print("residual = per-frame image shift minus its 0.15 s gaussian trend, trimmed to the central 90%")
            for (i, v) in variants.enumerated() {
                // Steps between consecutive frames; high-pass at ~0.15 s so real turns (slow) drop out and shake stays.
                func residual(_ cum: [Float]) -> (rms: Float, p90: Float) {
                    let steps = zip(cum.dropFirst(), cum).map { $0 - $1 }
                    let low = Gaussian.smooth(steps, sigma: 4.5)
                    let r = zip(steps, low).map { abs($0 - $1) }.sorted()
                    let kept = r.prefix(Int(Float(r.count) * 0.9))
                    return ((kept.map { $0 * $0 }.reduce(0, +) / Float(max(kept.count, 1))).squareRoot(), r[Int(Float(r.count) * 0.9)])
                }
                let h = residual(xs[i]), vv = residual(ys[i])
                print(String(format: "%-20@ horizontal %.2f px (%.3f°)   vertical %.2f px (%.3f°)", v.name as NSString,
                             h.rms, Double(h.rms) * degPerPx, vv.rms, Double(vv.rms) * degPerPx))
            }
            return 0
        } catch { print("error: \(error)"); return 1 }
    }
}

/// `CC360Framer --analysis-compare file.360 [start] [length]`: runs the analyser on the raw camera frame and on
/// the level (stabilised) frame over the same stretch and compares what it finds.
enum AnalysisCompare {
    static func run(args: [String]) -> Int32 {
        guard let path = args.first else { print("usage: --analysis-compare file.360 [start] [length]"); return 1 }
        let start = args.count > 1 ? Double(args[1]) ?? 40 : 40
        let length = args.count > 2 ? Double(args[2]) ?? 40 : 40
        let url = URL(fileURLWithPath: path)
        guard let telemetry = Telemetry.load(url: url) else { print("no telemetry"); return 1 }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("acmp-\(getpid()).mp4")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        let asset = AVURLAsset(url: link)
        let videos = asset.tracks(withMediaType: .video)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let stab = Stabilizer(telemetry: telemetry, duration: asset.duration.seconds, mode: .smooth)
        do {
            for (name, s) in [("raw camera frame", Stabilizer?.none), ("level (stabilised)", stab)] {
                let began = Date()
                let obs = try Analyzer.run(asset: asset, videoTracks: videos, stabilizer: s, range: range, progress: { _ in }, cancel: CancelFlag())
                let withPeople = obs.filter { !$0.people.isEmpty }
                let top = obs.compactMap { $0.people.max { $0.score < $1.score } }
                // The rider is rigid with the camera, so its body-frame direction should barely move: spread = stability.
                let ref = top.sorted { $0.yaw < $1.yaw }[top.count / 2]
                let near = top.filter { abs(wrapAngle($0.yaw - ref.yaw)) < 40 * .pi / 180 }
                func sd(_ v: [Float]) -> Float { let m = v.reduce(0, +) / Float(max(v.count, 1)); return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(max(v.count, 1))).squareRoot() * 180 / .pi }
                let sal = obs.flatMap(\.salient)
                print(String(format: "%@: %d samples, people in %.0f%%, rider-like top detections %d (yaw sd %.1f°, pitch sd %.1f°), mean top score %.3f, people/sample %.2f, salient/sample %.2f (mean score %.2f), %.0fs",
                             name, obs.count, 100 * Double(withPeople.count) / Double(max(obs.count, 1)), near.count,
                             sd(near.map(\.yaw)), sd(near.map(\.pitch)), top.map(\.score).reduce(0, +) / Float(max(top.count, 1)),
                             Double(obs.flatMap(\.people).count) / Double(max(obs.count, 1)), Double(sal.count) / Double(max(obs.count, 1)),
                             sal.map(\.score).reduce(0, +) / Float(max(sal.count, 1)), Date().timeIntervalSince(began)))
            }
            return 0
        } catch { print("error: \(error)"); return 1 }
    }
}
