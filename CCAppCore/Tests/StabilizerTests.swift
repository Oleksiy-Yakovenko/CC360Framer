import XCTest
import simd
@testable import CCAppCore

final class StabilizerTests: XCTestCase {
    private func telemetry(frames n: Int = 60, gravity g: SIMD3<Float> = [0, 1, 0]) -> Telemetry {
        Telemetry(orientation: Array(repeating: SIMD4<Float>(1, 0, 0, 0), count: n),
                  gravity: Array(repeating: g, count: n),
                  imageOrientation: Array(repeating: SIMD4<Float>(1, 0, 0, 0), count: n))
    }

    func testGaussianSmoothPreservesConstantAndSmoothsSpike() {
        XCTAssertEqual(Gaussian.smooth([2, 2, 2, 2, 2], sigma: 1), [2, 2, 2, 2, 2])
        let out = Gaussian.smooth([0, 0, 0, 10, 0, 0, 0], sigma: 1)
        XCTAssertLessThan(out[3], 10)
        XCTAssertGreaterThan(out[2], 0)
        XCTAssertEqual(Gaussian.smooth([1, 5], sigma: 0), [1, 5])
        XCTAssertEqual(Gaussian.smooth([], sigma: 3), [])
    }

    func testOffModeIsIdentity() {
        let s = Stabilizer(telemetry: telemetry(), duration: 2, mode: .off)
        let b = s.basis(at: 1)
        XCTAssertEqual(b.forward, [0, 0, 1])
        let r = s.toBody(yaw: 0.4, pitch: 0.2, at: 1)
        XCTAssertEqual(r.yaw, 0.4, accuracy: 1e-5)
        XCTAssertEqual(r.pitch, 0.2, accuracy: 1e-5)
    }

    func testLevelModeOnUprightStaticCameraIsIdentity() {
        let s = Stabilizer(telemetry: telemetry(), duration: 2, mode: .level)
        let b = s.basis(at: 0.7)
        XCTAssertEqual(simd_length(b.up - [0, 1, 0]), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(b.forward - [0, 0, 1]), 0, accuracy: 1e-4)
    }

    func testBasisIsOrthonormalAndRoundTrips() {
        let g = simd_normalize(SIMD3<Float>(0.3, 0.9, 0.2)) // tilted camera
        for mode in [StabilizeMode.level, .smooth] {
            let s = Stabilizer(telemetry: telemetry(gravity: g), duration: 2, mode: mode)
            let b = s.basis(at: 0.93)
            XCTAssertEqual(simd_dot(b.right, b.up), 0, accuracy: 1e-4)
            XCTAssertEqual(simd_dot(b.up, b.forward), 0, accuracy: 1e-4)
            XCTAssertEqual(simd_length(b.forward), 1, accuracy: 1e-4)
            let body = s.toBody(yaw: 0.6, pitch: -0.3, at: 0.93)
            let back = s.toVirtual(yaw: body.yaw, pitch: body.pitch, at: 0.93)
            XCTAssertEqual(back.yaw, 0.6, accuracy: 1e-4)
            XCTAssertEqual(back.pitch, -0.3, accuracy: 1e-4)
        }
    }

    func testTimeBeyondRangeIsClamped() {
        let s = Stabilizer(telemetry: telemetry(), duration: 2, mode: .level)
        let a = s.basis(at: -3), b = s.basis(at: 100)
        XCTAssertEqual(simd_length(a.up - [0, 1, 0]), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(b.up - [0, 1, 0]), 0, accuracy: 1e-4)
    }
}
