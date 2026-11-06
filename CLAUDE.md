# CC360Framer

macOS app (SwiftPM executable, Swift 5 mode, macOS 14+) that opens GoPro Max 2 `.360` files, plays them with mouse look, auto-reframes around subjects and exports a flat video. See `README.md` for the user-facing description.

## Build, run, CLI
Build instructions (command line and Xcode), usage and all command-line tools / `CC360_*` environment variables are in `README.md`; keep them there and update them when behaviour changes.

Notes for working here:
- Headless/CLI modes only worked reliably through the built `.app` binary (`CC360Framer.app/Contents/MacOS/CC360Framer`). A `.build/debug` run from a sandboxed shell printed nothing; if a batch run is silent, retry with the sandbox disabled.
- Commits end with the `Co-Authored-By` line given by the session. `.gitignore` excludes `.build/`, `*.app`, `*.360`, `*.sidecars/`, `*.project.json` and the legacy `*.reframe.json`, `*.analysis.json`, `*.location.json`.
- Never do direct UI testing, inspection, accessibility testing or debugging of the running app (launching it to look at windows, screenshots, UI scripting, accessibility inspection). Only do it when the user explicitly asks. Verify with `swift test` and the headless CLI tools in `README.md` instead.
- Never write into the user's footage folder (`~/Movies/GoPro/...`); symlink the video and copy the `CC360Framer.sidecars` folder into the scratchpad next to the symlink (sidecars resolve relative to the unresolved path, so batch/CLI runs write only there).

## Architecture (`Sources/CC360Framer/`)
Folders: `App/` (`main.swift`, `App.swift`), `UI/` (view controllers, `ViewKit.swift`), `Model/` (`PlayerModel.swift`), `Media/` (`StackCompositor`, `Telemetry`, `Stabilizer`), `Rendering/` (`Renderer`, `Projection`, `LocationOverlay`), `Reframing/` (`Analyzer`, `Styles`, `CameraPath`), `Export/` (`Exporter`), `Diagnostics/` (`Snapshot`, `StabTest`, `Pacing`). Files are referenced below by name only.

- `main.swift`: dispatches CLI modes, otherwise `CC360FramerApp.main()`.
- `App.swift`: `DocumentWindowController` (one window + its own `PlayerModel` per file; `isEmpty`/`openedURL` are set when open starts so duplicate open requests do not race) and `AppDelegate` (list of controllers, `current` = key window, `open(urls:)` reuses an empty window, focuses an already-open file, else makes a new window; menu and open/export actions act on `current`) and `CC360FramerApp.main()`. CLI/headless modes still use the first argument only. The UI is AppKit (no SwiftUI), one view controller per area, all subclasses of `ModelViewController` (`ViewKit.swift`: subscribes to `PlayerModel.objectWillChange`, calls `refresh()`):
  `MainViewController.swift` (`NSSplitViewController` left sidebar | centre | right inspector, window toolbar with tracking separators, file drop), `LeftSidebarViewController` (Auto, analysis, path style, stabilise), `RightSidebarViewController.swift` (a `Kit.TabContainer` of `ExportTab`, `LocationTab` (placement + `LocationCardStyle` controls), `InspectorTab` (selected keyframe, `KeyframeEdit`) and `AudioTab` view controllers), `PlayerViewController` (Metal `LookView` + error banner), `TransportViewController` (play, seekbar, keyframe ticks), `KeyframeViewController` (keyframe edit buttons, status line). Keyboard shortcuts (space, K, Delete) are menu key equivalents.
- `PlayerModel.swift`: central `ObservableObject`. Opening, playback, audio track toggles, keyframes, style/stabilisation state, sidecar load/save, `analyze()`, `buildPath()`, `export`, `runBatch`. `style` is persisted in `UserDefaults` (`pathStyle`). Per-file `cardStyle`/`overlayPlacement` are saved via `saveProject()` into `ProjectSidecar` (`Model/ProjectSidecar.swift`, all fields optional so later phases extend it); `setCardStyle` is undoable (shared undo manager, edits of one control within 1 s coalesce); `editSelectedKey` applies Inspector edits.
- `StackCompositor.swift`: custom `AVVideoCompositing` that stacks both lens tracks (track 0 on top) into one 5888x3840 420 full-range frame. AVFoundation rejects the `.360` extension (`-11828 Cannot Open`), but `AVURLAsset(url:, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])` opens it directly (verified: playback, analysis reader and export all work), so `PlayerModel.loadAsset` uses that first and falls back to a temporary `.mp4` symlink in a per-model unique temp dir (`playableURL`; `CC360_FORCE_SYMLINK=1` forces the fallback). The Diagnostics CLI tools still use their own symlinks. `build.sh`'s Info.plist declares the `dev.cc360framer.gopro-360` type (extension 360, conforms to `public.movie`) and `CFBundleDocumentTypes`; the open panel accepts `[.movie, .data]`.
- `Renderer.swift` / `Projection.swift`: Metal view and runtime-compiled shader. Maps a rectilinear view (yaw, pitch, vertical fov, stabiliser basis) onto the two-ring EAC layout; feathered 64 px tile overlaps; display-link driven; `ViewState` and `Uniforms` (Swift and MSL layouts must match).
- `Telemetry.swift`: MP4 `moov` walker and GPMF parser for the `gpmd` track (`CORI`, `GRAV`, `IORI`), one sample per frame.
- `Stabilizer.swift`: per-frame virtual camera basis from gyro/gravity-anchored orientation (modes off/level/smooth); `toVirtual`/`toBody` convert directions. Axis mapping `sensorToRender = (1,-1,1)` was calibrated visually; do not change it without re-checking max-lean and max-pitch frames.
- `Analyzer.swift`: renders 8 level horizon views (512x512, fov 90) from quarter-res decoded frames every 6th frame; Vision person and saliency requests; stores detections in body frame (mode independent) as `[Observation]`.
- `Styles.swift`: `PathStyle` (`.follow`, `.scenery`) and `SceneryPlanner` (forward, side glances, rare rider shots: at most 2, at least 60 s apart, only when no side slot is interesting; candidates near the rider are ignored).
- `CameraPath.swift`: `PathBuilder` (grid, median, Gaussian smoothing, speed limit, keyframe decimation) and Hermite `CameraPath`.
- `Exporter.swift`: reads the composition, reprojects with Metal per frame, writes HEVC + AAC (presets 1080p, 4K, 1080x1920).
- `LocationOverlay.swift`: `PlaceInfo` (first GPS fix, `CLGeocoder` reverse geocode, cached via `Sidecar`, kind `location`) and the title card bitmap (`LocationOverlay.alpha(at:)`: 10 s with fades). `Renderer.setOverlay` composites it in a second Metal pass, so preview and export share the code. GPS comes from `Telemetry.gps` (`GPS5`/`GPS9`, `parseGPMF` is internal for tests); its altitude (field 2) is the median of the first 20 locked fixes (`settleAltitude`) because the first fix is often off. `PlaceInfo.altitude` is optional and refreshed from telemetry on open, so old location caches keep working.
- `Snapshot.swift`, `StabTest.swift` (also `AnalysisCompare`), `Pacing.swift`: test and diagnostic tooling.

Sidecars (`Model/Sidecar.swift`: `Sidecar.url/read/write`) live in `CC360Framer.sidecars/` next to the video, named `<video file name>.<kind>.json`: `analysis` (raw detections), `reframe` (keyframes), `location` (place names), `project` (per-file settings, `ProjectSidecar`). The folder is created on save, never on load; loading falls back read-only to the legacy file next to the video (`<file>.<kind>.json`). All sidecar IO goes through `Sidecar`.

## File format facts
- Each track is 5888x1920, a ring of three 90° EAC faces (tiles 992/3904/992, 64 px overlap). Track 0 ring about the vertical axis (front = yaw 0); track 1 ring about the horizontal axis (rider in its "back" face, stored rotated 90°).
- Telemetry: `CORI` orientation quaternion, `GRAV` gravity, `IORI` roll-only image orientation (applied forward). Fov is vertical, default 70°.
- Remaining ~0.7° wobble at 0.5-2 Hz is translation parallax; rotation cannot remove it.

## UI conventions
- No subtitle/caption labels in the sidebars. Explanations go in the tooltip (`toolTip`) of the title label (`Kit.title(_, tip:)`) or of the control.
- Build controls with the `Kit` helpers in `ViewKit.swift` (labeled rows, colour well, font popup, `TabContainer`).
- Destructive actions (clear, delete) ask for confirmation with an `NSAlert` and are undoable through `PlayerModel.undoManager`.

## Tests
XCTest target `Tests/CC360FramerTests` (`@testable import CC360Framer`), run with `swift test`. It covers the pure logic: `CameraPath`/`PathBuilder`, `PathStyle`/`SceneryPlanner`, `Stabilizer`/`Gaussian`, overlay alpha/placement.
- **Add test coverage for every piece of new or changed logic** (anything not tied to Metal, AVFoundation or UI), in the matching `*Tests.swift` file. Fix bugs with a regression test.
- **Always run `swift test` to verify your work** before finishing or committing, and report failures honestly. Do not commit with failing tests.

Things unit tests cannot cover are still verified by the CLI tools in `README.md` and by eye:
- Stabiliser: `--stab-test` on a clip with a static start (`GS010068.360`) and `--snapshot` at max-lean (110.38 s of `GS010074.360`) and max-pitch (51.99 s) for horizon check.
- Analysis/paths: `CC360_BATCH` with a scratch copy of the video symlink and cached `.analysis.json` (never write into the user's footage folder); check keyframe timeline (Follow: constant fov 70, mostly pointing at the rider; Scenery: fov 55-70, 0-2 rider shots) and extract export frames at keyframe times.
- Telemetry: `--telemetry` should report one sample per video frame.
- Test footage is large and untracked: `GS010074.360` (project folder), `GS010068.360` (under `~/Movies/GoPro/`).
