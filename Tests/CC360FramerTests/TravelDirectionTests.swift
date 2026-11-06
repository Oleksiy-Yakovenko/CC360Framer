import XCTest
@testable import CC360Framer

final class TravelDirectionTests: XCTestCase {
    /// Deterministic noise in [-1, 1].
    private struct Noise {
        var s: UInt64 = 12345
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 52) - 1
        }
    }

    private struct Sim {
        var accel: [TravelDirection.Accel] = []
        var up: [SIMD3<Float>] = []
        var gps: [Telemetry.GPSSample] = []
        let upRate = 30.0
    }

    /// A vehicle weaving along a road with a mount offset `theta` (radians, positive = right of the camera front).
    /// Moves while `moving(t)`; GPS samples carry the state of `gpsLag` seconds earlier.
    private func simulate(theta: Double, duration: Double = 120, gpsLag: Double = 0.3, accelNoise: Double = 0.15,
                          moving: (Double) -> Bool = { _ in true }, garbageAccel: Bool = false) -> Sim {
        func speed(_ t: Double) -> Double { moving(t) ? 12 + 5 * sin(2 * .pi * t / 17) : 0 }
        func course(_ t: Double) -> Double { 0.6 * sin(2 * .pi * t / 23) + 0.3 * sin(2 * .pi * t / 11) }
        // Numeric derivatives of the true motion.
        func dv(_ t: Double) -> Double { (speed(t + 0.01) - speed(t - 0.01)) / 0.02 }
        func dc(_ t: Double) -> Double { (course(t + 0.01) - course(t - 0.01)) / 0.02 }
        var sim = Sim()
        var noise = Noise()
        // Integrate position at 100 Hz.
        var x = 0.0, y = 0.0, positions: [(Double, Double)] = []
        for i in 0...Int(duration * 100) {
            let t = Double(i) / 100
            positions.append((x, y))
            x += speed(t) * sin(course(t)) / 100; y += speed(t) * cos(course(t)) / 100
        }
        for i in 0..<Int(duration * 200) {
            let t = Double(i) / 200
            let l = dv(t), lat = speed(t) * dc(t)
            let af = l * cos(theta) - lat * sin(theta), ar = l * sin(theta) + lat * cos(theta)
            var f = SIMD3<Float>(Float(ar), 9.81, Float(af))   // x right, y up, z front; gravity reads +up at rest
            f += SIMD3<Float>(Float(noise.next() * accelNoise), Float(noise.next() * accelNoise), Float(noise.next() * accelNoise))
            if garbageAccel { f = SIMD3<Float>(Float(noise.next() * 3), 9.81, Float(noise.next() * 3)) }
            sim.accel.append(.init(t: t, force: f))
        }
        sim.up = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: Int(duration * 30))
        let originLat = 48.0, originLon = 2.0
        for i in 0..<Int(duration * 10) {
            let t = Double(i) / 10
            let ts = max(t - gpsLag, 0)
            let (px, py) = positions[min(Int(ts * 100), positions.count - 1)]
            sim.gps.append(.init(t: t, latitude: originLat + py / 6_371_000 * 180 / .pi,
                                 longitude: originLon + px / (6_371_000 * cos(originLat * .pi / 180)) * 180 / .pi,
                                 speed2D: speed(ts) + noise.next() * 0.05, fix: 3, dop: 1.2))
        }
        return sim
    }

    private func run(_ s: Sim) -> TravelDirection.Estimate? {
        TravelDirection.estimate(accel: s.accel, up: s.up, upRate: s.upRate, gps: s.gps)
    }

    private func degrees(_ e: TravelDirection.Estimate, at t: Double) -> Double { Double(e.yaw(at: t) ?? 0) * 180 / .pi }

    func testRecoversMountOffsetToTheRight() throws {
        let e = try XCTUnwrap(run(simulate(theta: 35 * .pi / 180)))
        XCTAssertEqual(try XCTUnwrap(e.meanDegrees), 35, accuracy: 4)
        XCTAssertEqual(degrees(e, at: 60), 35, accuracy: 4)
        XCTAssertEqual(e.lag, -0.3, accuracy: 0.25)   // the GPS state is 0.3 s old: the accelerometer is matched 0.3 s earlier
    }

    func testRecoversMountOffsetToTheLeft() throws {
        let e = try XCTUnwrap(run(simulate(theta: -20 * .pi / 180, gpsLag: 0)))
        XCTAssertEqual(degrees(e, at: 30), -20, accuracy: 4)
        XCTAssertEqual(degrees(e, at: 100), -20, accuracy: 4)
    }

    func testStraightMountGivesZero() throws {
        let e = try XCTUnwrap(run(simulate(theta: 0)))
        XCTAssertEqual(try XCTUnwrap(e.meanDegrees), 0, accuracy: 4)
    }

    func testYawNearHalfTurnDoesNotWrapBadly() throws {
        let e = try XCTUnwrap(run(simulate(theta: 172 * .pi / 180)))
        let deg = degrees(e, at: 60)
        XCTAssertEqual(abs(deg), 172, accuracy: 5)   // may be reported as 172 or -188 wrapped, never ~0
        XCTAssertGreaterThan(deg, 0)
    }

    func testBlendAcrossTheWrapPointStaysNearHalfTurn() {
        let w = [TravelDirection.Window(time: 10, yaw: 179 * .pi / 180, coherence: 0.9, samples: 100, accepted: true),
                 TravelDirection.Window(time: 20, yaw: -179 * .pi / 180, coherence: 0.9, samples: 100, accepted: true)]
        let e = TravelDirection.Estimate(windows: w, lag: 0, globalYaw: 0, globalCoherence: 1)
        XCTAssertGreaterThan(abs(degrees(e, at: 15)), 177)
    }

    func testStationaryStretchHoldsLastValue() throws {
        let e = try XCTUnwrap(run(simulate(theta: 30 * .pi / 180, duration: 150, moving: { $0 < 70 })))
        let held = degrees(e, at: 140)
        XCTAssertEqual(held, 30, accuracy: 4)
        XCTAssertEqual(held, degrees(e, at: 149), accuracy: 0.5)
        XCTAssertEqual(degrees(e, at: 0), degrees(e, at: 10), accuracy: 3)   // start is back-filled from the first accepted window
        XCTAssertTrue(e.windows.allSatisfy { $0.time < 90 })   // no window was fitted on standing data
    }

    func testNeverMovingGivesNil() {
        XCTAssertNil(run(simulate(theta: 0.5, moving: { _ in false })))
    }

    func testIncoherentAccelerometerIsRejected() {
        XCTAssertNil(run(simulate(theta: 0.6, garbageAccel: true)))
    }

    func testNoGPSOrAccelGivesNil() {
        var s = simulate(theta: 0.3)
        s.gps = []
        XCTAssertNil(run(s))
        s = simulate(theta: 0.3)
        s.accel = []
        XCTAssertNil(run(s))
    }

    func testUnusableFixesAreIgnored() throws {
        var s = simulate(theta: 25 * .pi / 180)
        for i in 0..<s.gps.count where i < 100 { s.gps[i].fix = 0; s.gps[i].dop = 99.99; s.gps[i].speed2D = 0 }
        let e = try XCTUnwrap(run(s))
        XCTAssertEqual(try XCTUnwrap(e.meanDegrees), 25, accuracy: 4)
    }

    func testTelemetryChannelMappingMatchesRenderAxes() throws {
        // ACCL channels read (9.8 * gravity_y, gravity_x, gravity_z) at rest; with the render mapping the specific force must point up.
        var t = Telemetry(orientation: [], gravity: [])
        let sim = simulate(theta: 40 * .pi / 180)
        let map = Stabilizer.sensorToRender
        // Inverse of the channel mapping used by `analyse(telemetry:)`: force_render = (-c1, -c0, -c2) * map.
        t.accel = sim.accel.map { a in
            let s = a.force * map   // render -> sensor (map is its own inverse)
            return Telemetry.AccelSample(t: a.t, channels: SIMD3(-s.y, -s.x, -s.z))
        }
        t.gravity = sim.up.map { -($0 * map) }   // gravity points down; Stabilizer.up = -(g * map)
        t.gpsSeries = sim.gps
        let e = try XCTUnwrap(TravelDirection.estimate(telemetry: t, duration: 120))
        XCTAssertEqual(try XCTUnwrap(e.meanDegrees), 40, accuracy: 4)
    }

    func testForwardYawNilForCameraFrontAndWithoutEstimate() throws {
        let e = try XCTUnwrap(run(simulate(theta: 0.5)))
        XCTAssertNil(TravelDirection.forwardYaw(mode: .cameraFront, estimate: e, stabilizer: nil))
        XCTAssertNil(TravelDirection.forwardYaw(mode: .travelDirection, estimate: nil, stabilizer: nil))
        let f = try XCTUnwrap(TravelDirection.forwardYaw(mode: .travelDirection, estimate: e, stabilizer: nil))
        XCTAssertEqual(f(60), 0.5, accuracy: 0.07)
        // A level, identity stabiliser keeps the yaw.
        let stab = Stabilizer(telemetry: Telemetry(orientation: [], gravity: []), duration: 10, mode: .off)
        let g = try XCTUnwrap(TravelDirection.forwardYaw(mode: .travelDirection, estimate: e, stabilizer: stab))
        XCTAssertEqual(g(60), f(60), accuracy: 0.01)
    }

    func testSettingsDecodeLeniently() {
        XCTAssertEqual(TravelDirection.ForwardMode(rawValue: "nonsense"), nil)
        let d = UserDefaults(suiteName: "travel-test-\(UUID().uuidString)")!
        XCTAssertEqual(TravelDirection.ForwardMode.loadDefault(d), .travelDirection)
        d.set("cameraFront", forKey: TravelDirection.ForwardMode.defaultsKey)
        XCTAssertEqual(TravelDirection.ForwardMode.loadDefault(d), .cameraFront)
        var p = ProjectSidecar(); p.forwardMode = .cameraFront
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!)?.forwardMode, .cameraFront)
        XCTAssertNil(ProjectSidecar.decode(Data("{}".utf8))?.forwardMode)
        let old = BatchSettings.load(UserDefaults(suiteName: "travel-test-\(UUID().uuidString)")!)
        XCTAssertEqual(old.forwardMode, .travelDirection)
        let data = Data(#"{"style":"Scenery + rider"}"#.utf8)
        XCTAssertEqual(try? JSONDecoder().decode(BatchSettings.self, from: data).forwardMode, .travelDirection)
    }
}
