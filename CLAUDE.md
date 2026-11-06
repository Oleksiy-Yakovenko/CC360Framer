# CC360Framer

macOS app (SwiftPM executable, Swift 5 mode, macOS 14+) that opens GoPro Max 2 `.360` files, plays them with mouse look, auto-reframes around subjects and exports a flat video. See `README.md` for the user-facing description.

## Build, run, CLI
Build instructions (command line and Xcode), usage and all command-line tools / `CC360_*` environment variables are in `README.md`; keep them there and update them when behaviour changes.

Notes for working here:
- Headless/CLI modes only worked reliably through the built `.app` binary (`CC360Framer.app/Contents/MacOS/CC360Framer`). A `.build/debug` run from a sandboxed shell printed nothing; if a batch run is silent, retry with the sandbox disabled.
- Commits end with the `Co-Authored-By` line given by the session. `.gitignore` excludes `.build/`, `*.app`, `*.360`, `*.reframe.json`, `*.analysis.json`, `*.location.json`.
- Never do direct UI testing, inspection, accessibility testing or debugging of the running app (launching it to look at windows, screenshots, UI scripting, accessibility inspection). Only do it when the user explicitly asks. Verify with `swift test` and the headless CLI tools in `README.md` instead.
- Never write into the user's footage folder (`~/Movies/GoPro/...`); symlink the video and copy sidecars into the scratchpad.

## Architecture (`Sources/CC360Framer/`)
Folders: `App/` (`main.swift`, `App.swift`), `UI/` (view controllers, `ViewKit.swift`), `Model/` (`PlayerModel.swift`), `Media/` (`StackCompositor`, `Telemetry`, `Stabilizer`), `Rendering/` (`Renderer`, `Projection`, `LocationOverlay`), `Reframing/` (`Analyzer`, `Styles`, `CameraPath`), `Export/` (`Exporter`), `Diagnostics/` (`Snapshot`, `StabTest`, `Pacing`). Files are referenced below by name only.

- `main.swift`: dispatches CLI modes, otherwise `CC360FramerApp.main()`.
- `App.swift`: `AppDelegate` (window, menu, open/export actions) and `CC360FramerApp.main()`. The UI is AppKit (no SwiftUI), one view controller per area, all subclasses of `ModelViewController` (`ViewKit.swift`: subscribes to `PlayerModel.objectWillChange`, calls `refresh()`):
  `MainViewController.swift` (`NSSplitViewController` left sidebar | centre | right inspector, window toolbar with tracking separators, file drop), `LeftSidebarViewController` (Auto, analysis, path style, stabilise, location), `RightSidebarViewController` (export preset), `PlayerViewController` (Metal `LookView` + error banner), `TransportViewController` (play, seekbar, keyframe ticks, audio toggles), `KeyframeViewController` (keyframe edit buttons, status line). Keyboard shortcuts (space, K, Delete) are menu key equivalents.
- `PlayerModel.swift`: central `ObservableObject`. Opening, playback, audio track toggles, keyframes, style/stabilisation state, sidecar load/save, `analyze()`, `buildPath()`, `export`, `runBatch`. `style` is persisted in `UserDefaults` (`pathStyle`).
- `StackCompositor.swift`: custom `AVVideoCompositing` that stacks both lens tracks (track 0 on top) into one 5888x3840 420 full-range frame. AVFoundation rejects `.360`, so the file is opened through a temporary `.mp4` symlink (`playableURL`).
- `Renderer.swift` / `Projection.swift`: Metal view and runtime-compiled shader. Maps a rectilinear view (yaw, pitch, vertical fov, stabiliser basis) onto the two-ring EAC layout; feathered 64 px tile overlaps; display-link driven; `ViewState` and `Uniforms` (Swift and MSL layouts must match).
- `Telemetry.swift`: MP4 `moov` walker and GPMF parser for the `gpmd` track (`CORI`, `GRAV`, `IORI`), one sample per frame.
- `Stabilizer.swift`: per-frame virtual camera basis from gyro/gravity-anchored orientation (modes off/level/smooth); `toVirtual`/`toBody` convert directions. Axis mapping `sensorToRender = (1,-1,1)` was calibrated visually; do not change it without re-checking max-lean and max-pitch frames.
- `Analyzer.swift`: renders 8 level horizon views (512x512, fov 90) from quarter-res decoded frames every 6th frame; Vision person and saliency requests; stores detections in body frame (mode independent) as `[Observation]`.
- `Styles.swift`: `PathStyle` (`.follow`, `.scenery`) and `SceneryPlanner` (forward, side glances, rare rider shots: at most 2, at least 60 s apart, only when no side slot is interesting; candidates near the rider are ignored).
- `CameraPath.swift`: `PathBuilder` (grid, median, Gaussian smoothing, speed limit, keyframe decimation) and Hermite `CameraPath`.
- `Exporter.swift`: reads the composition, reprojects with Metal per frame, writes HEVC + AAC (presets 1080p, 4K, 1080x1920).
- `LocationOverlay.swift`: `PlaceInfo` (first GPS fix, `CLGeocoder` reverse geocode, cached as `<file>.location.json`) and the title card bitmap (`LocationOverlay.alpha(at:)`: 10 s with fades). `Renderer.setOverlay` composites it in a second Metal pass, so preview and export share the code. GPS comes from `Telemetry.gps` (`GPS5`/`GPS9`).
- `Snapshot.swift`, `StabTest.swift` (also `AnalysisCompare`), `Pacing.swift`: test and diagnostic tooling.

Sidecars next to the video: `<file>.analysis.json` (raw detections), `<file>.reframe.json` (keyframes) and `<file>.location.json` (place names).

## File format facts
- Each track is 5888x1920, a ring of three 90° EAC faces (tiles 992/3904/992, 64 px overlap). Track 0 ring about the vertical axis (front = yaw 0); track 1 ring about the horizontal axis (rider in its "back" face, stored rotated 90°).
- Telemetry: `CORI` orientation quaternion, `GRAV` gravity, `IORI` roll-only image orientation (applied forward). Fov is vertical, default 70°.
- Remaining ~0.7° wobble at 0.5-2 Hz is translation parallax; rotation cannot remove it.

## Tests
XCTest target `Tests/CC360FramerTests` (`@testable import CC360Framer`), run with `swift test`. It covers the pure logic: `CameraPath`/`PathBuilder`, `PathStyle`/`SceneryPlanner`, `Stabilizer`/`Gaussian`, overlay alpha/placement.
- **Add test coverage for every piece of new or changed logic** (anything not tied to Metal, AVFoundation or UI), in the matching `*Tests.swift` file. Fix bugs with a regression test.
- **Always run `swift test` to verify your work** before finishing or committing, and report failures honestly. Do not commit with failing tests.

Things unit tests cannot cover are still verified by the CLI tools in `README.md` and by eye:
- Stabiliser: `--stab-test` on a clip with a static start (`GS010068.360`) and `--snapshot` at max-lean (110.38 s of `GS010074.360`) and max-pitch (51.99 s) for horizon check.
- Analysis/paths: `CC360_BATCH` with a scratch copy of the video symlink and cached `.analysis.json` (never write into the user's footage folder); check keyframe timeline (Follow: constant fov 70, mostly pointing at the rider; Scenery: fov 55-70, 0-2 rider shots) and extract export frames at keyframe times.
- Telemetry: `--telemetry` should report one sample per video frame.
- Test footage is large and untracked: `GS010074.360` (project folder), `GS010068.360` (under `~/Movies/GoPro/`).
