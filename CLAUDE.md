# CC360Framer

macOS app (SwiftPM executable, Swift 5 mode, macOS 14+) that opens GoPro Max 2 `.360` files, plays them with mouse look, auto-reframes around subjects and exports a flat video. See `README.md` for the user-facing description.

## Build and run
Command line:
- `./build.sh`: release build wrapped as ad-hoc signed `CC360Framer.app`. Run with `open CC360Framer.app` or `CC360Framer.app/Contents/MacOS/CC360Framer file.360`.
- `swift build` (debug) or `swift build -c release`; the binary is `.build/debug/CC360Framer` or `.build/release/CC360Framer`. Run with `swift run CC360Framer file.360`. The bare binary has no app bundle, so prefer the `.app` for GUI and batch runs.

Xcode:
- `open -a Xcode Package.swift` (or double-click `Package.swift`). Xcode opens the SwiftPM package directly; there is no `.xcodeproj`.
- Select the `CC360Framer` scheme and "My Mac" as the destination, then Product > Run (Cmd+R) or Build (Cmd+B).
- To pass a file or environment variables: Product > Scheme > Edit Scheme > Run > Arguments (the `.360` path under "Arguments Passed On Launch", `CC360_*` under "Environment Variables").
- Xcode runs the unbundled binary, so use `./build.sh` when you need the real `.app`.

Notes:
- Headless/CLI modes only worked reliably through the built `.app` binary. A `.build/debug` run from a sandboxed shell printed nothing; if a batch run is silent, retry with the sandbox disabled.
- Commits end with the `Co-Authored-By` line given by the session. `.gitignore` excludes `.build/`, `*.app`, `*.360`, `*.reframe.json`, `*.analysis.json`.

## Architecture (`Sources/CC360Framer/`)
- `main.swift`: dispatches CLI modes, otherwise `CC360FramerApp.main()`.
- `App.swift`: SwiftUI `ContentView` (controls, seekbar with keyframe ticks, pickers, Re-analyse confirmation), `MetalView` wrapper, `CC360FramerApp`.
- `PlayerModel.swift`: central `ObservableObject`. Opening, playback, audio track toggles, keyframes, style/stabilisation state, sidecar load/save, `analyze()`, `buildPath()`, `export`, `runBatch`. `style` is persisted in `UserDefaults` (`pathStyle`).
- `StackCompositor.swift`: custom `AVVideoCompositing` that stacks both lens tracks (track 0 on top) into one 5888x3840 420 full-range frame. AVFoundation rejects `.360`, so the file is opened through a temporary `.mp4` symlink (`playableURL`).
- `Renderer.swift` / `Projection.swift`: Metal view and runtime-compiled shader. Maps a rectilinear view (yaw, pitch, vertical fov, stabiliser basis) onto the two-ring EAC layout; feathered 64 px tile overlaps; display-link driven; `ViewState` and `Uniforms` (Swift and MSL layouts must match).
- `Telemetry.swift`: MP4 `moov` walker and GPMF parser for the `gpmd` track (`CORI`, `GRAV`, `IORI`), one sample per frame.
- `Stabilizer.swift`: per-frame virtual camera basis from gyro/gravity-anchored orientation (modes off/level/smooth); `toVirtual`/`toBody` convert directions. Axis mapping `sensorToRender = (1,-1,1)` was calibrated visually; do not change it without re-checking max-lean and max-pitch frames.
- `Analyzer.swift`: renders 8 level horizon views (512x512, fov 90) from quarter-res decoded frames every 6th frame; Vision person and saliency requests; stores detections in body frame (mode independent) as `[Observation]`.
- `Styles.swift`: `PathStyle` (`.follow`, `.scenery`) and `SceneryPlanner` (forward, side glances, rare rider shots: at most 2, at least 60 s apart, only when no side slot is interesting; candidates near the rider are ignored).
- `CameraPath.swift`: `PathBuilder` (grid, median, Gaussian smoothing, speed limit, keyframe decimation) and Hermite `CameraPath`.
- `Exporter.swift`: reads the composition, reprojects with Metal per frame, writes HEVC + AAC (presets 1080p, 4K, 1080x1920).
- `Snapshot.swift`, `StabTest.swift` (also `AnalysisCompare`), `Pacing.swift`: test and diagnostic tooling.

Sidecars next to the video: `<file>.analysis.json` (raw detections) and `<file>.reframe.json` (keyframes).

## File format facts
- Each track is 5888x1920, a ring of three 90° EAC faces (tiles 992/3904/992, 64 px overlap). Track 0 ring about the vertical axis (front = yaw 0); track 1 ring about the horizontal axis (rider in its "back" face, stored rotated 90°).
- Telemetry: `CORI` orientation quaternion, `GRAV` gravity, `IORI` roll-only image orientation (applied forward). Fov is vertical, default 70°.
- Remaining ~0.7° wobble at 0.5-2 Hz is translation parallax; rotation cannot remove it.

## Command line
- `CC360Framer [file.360]`: open a file on launch.
- `--telemetry file.360`: print parsed telemetry counts and first/last samples.
- `--snapshot stacked.png prefix`: render projection test images. Env: `CC360_TELEMETRY=file.360`, `CC360_TIME=sec`, `CC360_MODE=level|smooth`, `CC360_AXES=1,-1,1`.
- `--stab-test file.360 [start] [length]`: residual shake per band (sway 0.1-0.5, wobble 0.5-2, shake >2 Hz) per stabilisation mode, plus telemetry/video time offset. Env knobs `CC360_SIGMAS`, `CC360_SCAN`, `CC360_W`.
- `--analysis-compare file.360 [start] [length]`: analysis on raw versus level frames.
- Environment: `CC360_DEBUG=1` autoplay and frame-rate log; `CC360_PACING=sec` frame pacing report then exit (`CC360_NOPLAY` skips play); `CC360_NOBLIT` skips compositor blits; `CC360_BATCH=out.mp4` headless analyse (or build from cached analysis) plus export, with `CC360_STYLE=scenery` and `CC360_NO_ANALYSIS=1` (plain stabilised export, no keyframes). Batch prints the keyframe list (first 400) and progress.

## Tests
There is no XCTest target. Verification is by the CLI tools above and by eye:
- Stabiliser: `--stab-test` on a clip with a static start (`GS010068.360`) and `--snapshot` at max-lean (110.38 s of `GS010074.360`) and max-pitch (51.99 s) for horizon check.
- Analysis/paths: `CC360_BATCH` with a scratch copy of the video symlink and cached `.analysis.json` (never write into the user's footage folder); check keyframe timeline (Follow: constant fov 70, mostly pointing at the rider; Scenery: fov 55-70, 0-2 rider shots) and extract export frames at keyframe times.
- Telemetry: `--telemetry` should report one sample per video frame.
- Test footage is large and untracked: `GS010074.360` (project folder), `GS010068.360` (under `~/Movies/GoPro/`).
