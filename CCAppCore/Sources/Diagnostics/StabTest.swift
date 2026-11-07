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
        let (duration, videos) = blockingLoad(asset)
        guard videos.count == 2 else { print("need two video tracks"); return 1 }

        // Variants: stabiliser configurations plus telemetry time offsets (in frames, fractional allowed).
        struct Variant { let name: String; let stabilizer: Stabilizer?; let offset: Double }
        func make(_ mode: StabilizeMode, up: Stabilizer.UpSource) -> Stabilizer {
            Stabilizer.upSource = up
            defer { Stabilizer.upSource = .orientation }
            return Stabilizer(telemetry: telemetry, duration: duration, mode: mode)
        }
        let env = ProcessInfo.processInfo.environment
        var variants = [Variant(name: "off", stabilizer: nil, offset: 0),
                        Variant(name: "smooth (gravity up)", stabilizer: make(.smooth, up: .gravity), offset: 0),
                        Variant(name: "smooth (orientation up)", stabilizer: make(.smooth, up: .orientation), offset: 0)]
        if env["CC360_SIGMAS"] != nil {
            for sec in [1.5, 3.0] as [Float] {
                Stabilizer.smoothingSeconds = sec
                variants.append(Variant(name: "smooth, heading sigma \(sec) s", stabilizer: make(.smooth, up: .gravity), offset: 0))
            }
            Stabilizer.smoothingSeconds = 0.7
        }
        if env["CC360_SCAN"] != nil {
            for k in stride(from: -1.0, through: 1.0, by: 0.25) where k != 0 {
                variants.append(Variant(name: String(format: "orientation up, offset %+.2f f", k), stabilizer: make(.smooth, up: .orientation), offset: k))
            }
        }

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

            let size = (w: Int(env["CC360_W"] ?? "") ?? 1920, h: (Int(env["CC360_W"] ?? "") ?? 1920) * 9 / 16)
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
                    state.frameTime = t + v.offset / 29.97
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
            print("Image motion of the rendered view by frequency band (RMS, degrees; horizontal / vertical). Zero = perfectly still.")
            // Position series split into bands with gaussian low-passes: >0.1 Hz includes slow sway,
            // 1-3 Hz wobble, and >3 Hz vibration. Sigmas in frames (30 fps).
            func band(_ cum: [Float], from lo: Float, to hi: Float?) -> Float {
                let a = Gaussian.smooth(cum, sigma: lo)
                let b = hi.map { Gaussian.smooth(cum, sigma: $0) } ?? cum
                let d = zip(b, a).map { $0 - $1 }
                let trim = d.dropFirst(60).dropLast(60)   // ignore filter edges
                return (trim.map { $0 * $0 }.reduce(0, +) / Float(max(trim.count, 1))).squareRoot()
            }
            for (i, v) in variants.enumerated() {
                func row(_ lo: Float, _ hi: Float?) -> String {
                    String(format: "%.3f / %.3f", Double(band(xs[i], from: lo, to: hi)) * degPerPx, Double(band(ys[i], from: lo, to: hi)) * degPerPx)
                }
                print("\(v.name)")
                print("    sway   0.1-0.5 Hz: \(row(45, 9))   wobble 0.5-2 Hz: \(row(9, 2.3))   shake >2 Hz: \(row(2.3, nil))")
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
        let (assetSeconds, videos) = blockingLoad(asset)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let stab = Stabilizer(telemetry: telemetry, duration: assetSeconds, mode: .smooth)
        do {
            for (name, s) in [("raw camera frame", Stabilizer?.none), ("level (stabilised)", stab)] {
                let began = Date()
                let obs = try Analyzer.run(asset: asset, videoTracks: videos, duration: assetSeconds, stabilizer: s, range: range, progress: { _ in }, cancel: CancelFlag())
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

/// Duration (seconds) and video tracks of an asset, loaded synchronously for the blocking CLI tools.
private func blockingLoad(_ asset: AVURLAsset) -> (Double, [AVAssetTrack]) {
    nonisolated(unsafe) var result: (Double, [AVAssetTrack]) = (0, [])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let d = (try? await asset.load(.duration).seconds) ?? 0
        let t = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        result = (d, t)
        done.signal()
    }
    done.wait()
    return result
}
