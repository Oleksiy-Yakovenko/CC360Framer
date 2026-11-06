# CC360Framer

macOS app that opens GoPro `.360` files (tested with Max 2), plays them with mouse look, auto-reframes them around a detected subject and exports a flat video. Requires macOS 14+.

## Build and run

Command line:

    ./build.sh && open CC360Framer.app
    CC360Framer.app/Contents/MacOS/CC360Framer GS010074.360     # open a file on launch

`./build.sh` makes a release build wrapped as an ad-hoc signed `CC360Framer.app`. You can also use `swift build` (or `swift build -c release`) and `swift run CC360Framer file.360`; these run the bare binary without an app bundle.

Run the unit tests with `swift test`.

Xcode:

- `open -a Xcode Package.swift` (there is no `.xcodeproj`; Xcode opens the SwiftPM package directly).
- Pick the `CC360Framer` scheme and "My Mac", then Cmd+B to build or Cmd+R to run.
- To open a file or set `CC360_*` variables: Product > Scheme > Edit Scheme > Run > Arguments / Environment Variables.

## Using the app

- **Open:** File > Open (multiple files allowed), drag one or more `.360` files onto a window, double-click a `.360` once the app is built with `build.sh` (it declares the type), or pass one as an argument. Every file opens in its own window with its own settings; opening a file that is already open just brings its window forward, and an empty window is reused first. Menu items and shortcuts act on the front window.
- **Look:** drag to look around, scroll/pinch to zoom, double-click to reset. Audio tracks are toggled individually in the right sidebar's Audio tab.
- **Analyse:** projects 8 views around the horizon, detects people and (on the side views) salient objects, and stores the raw detections next to the video (`CC360Framer.sidecars/<file>.analysis.json`). A path style turns them into a smoothed camera path of editable keyframes (diamonds under the seekbar), saved as `CC360Framer.sidecars/<file>.reframe.json`. Sidecars live in a `CC360Framer.sidecars` folder created next to the video on first save; sidecars from older versions next to the video are still read (never written). Re-analyse asks for confirmation because it takes minutes.
- **Style** (drop-down, remembered between launches): *Follow subject* keeps the main subject (the rider) in view. *Scenery + rider* looks forward along the direction of travel and glances at objects on the sides. The rider is shown rarely: at most twice per clip, at least a minute apart, and only when nothing else is interesting. Switching style regenerates the path from the stored detections without re-analysing (it asks first if you have hand-edited keyframes: use **Build path**).
- **Stabilise** (drop-down, default *Level + smooth*): uses the camera's own motion data (`GRAV` gravity and `CORI` orientation from the file's `gpmd` track) to keep the horizon level and remove shake. *Level* locks the horizon only; *Level + smooth* also smooths the heading. Look directions and keyframes are relative to this stabilised camera, so pitch 0 is the horizon. Field of view defaults to 70° vertical (wider looks stretched at the edges). Works without analysing.
- **Location card:** the first GPS fix in the file is reverse-geocoded (needs network once; cached as `CC360Framer.sidecars/<file>.location.json`) and shown for the first 10 seconds (placement: any corner, top/bottom middle or centre; plus font, size, text colour and outline, all in the right sidebar's Location tab and saved per video in `CC360Framer.sidecars/<file>.project.json`; changes can be undone) as country, place name, coordinates and altitude (when the GPS reports one), in both the preview and the export. Files without a GPS lock show nothing.
- **Edit:** `K` sets a keyframe from the current view, click a diamond to select it, `Delete` removes it. Dragging the view switches off Auto; press Auto to follow the path again. Delete key and Clear keys ask for confirmation. Edit > Undo / Redo (Cmd-Z, Shift-Cmd-Z) cover keyframe changes, Build path and the location card placement. Space, K and Delete are ignored while a text field is being edited.
- **Inspector:** select a keyframe and edit its time, yaw, pitch and field of view numerically in the right sidebar's Inspector tab (Enter commits; undoable; keyframes are re-sorted).
- **Export:** HEVC or H.264 + AAC in an MP4 or MOV container, using the audio tracks currently toggled on. The right sidebar's Export tab sets format, codec, rate control (average bitrate in Mbps, empty = automatic: 20 Mbps up to ~3 MP and 50 Mbps above; or an encoder quality level), resolution (short side 720p / 1080p / 1440p / 4K, or a custom width), aspect ratio (16:9, 9:16, 1:1, 4:5, 4:3 or custom w:h; the output size is rounded to even pixels and shown in the tab) and the cut crossfade length. The settings are saved per video in the project sidecar and as the default for other videos. "Show export frame" outlines the exported area in the preview and dims the rest (preview only, never in the file; with the same vertical field of view, a different aspect ratio changes the horizontal extent). Press Export… in the toolbar to write the file. The sidebars can be hidden with the toolbar toggles (left: ⌃⌘S, right: ⌥⌘2).

Limits: rotation compensation cannot remove shake caused by camera translation (small residual wobble at 0.5–2 Hz). HiLight tags and gyro/accelerometer data are not used yet (only orientation, gravity and the first GPS fix).

## Command line tools and debugging

- `--telemetry file.360`: print parsed telemetry counts and first/last samples.
- `--telemetry` also prints the first GPS fix with its altitude (median of the first locked fixes, GPS height in metres).
- `--snapshot stacked.png prefix`: render projection test images. Env: `CC360_TELEMETRY=file.360 CC360_TIME=sec CC360_MODE=level|smooth CC360_AXES=1,-1,1` to apply stabilisation.
- `--stab-test file.360 [start] [length]`: measure residual shake per stabilisation mode and the telemetry/video time offset (env `CC360_SIGMAS`, `CC360_SCAN`, `CC360_W`).
- `--analysis-compare file.360 [start] [length]`: compare analysis on the raw versus level frame.
- `CC360_BATCH=out.mp4` with a file argument: headless analyse (or build from cached analysis) and export. Add `CC360_STYLE=scenery` for the scenery style, `CC360_NO_ANALYSIS=1` for a plain stabilised export without keyframes.
- `CC360_EXPORT_SETTINGS='{"container":"mov","codec":"h264","aspect":"1:1","resolution":"720p"}'` with `CC360_BATCH`: export with these `ExportSettings` (JSON, any subset of the fields; the rest come from the saved settings).
- `CC360_FORCE_SYMLINK=1` opens `.360` files through a temporary `.mp4` symlink instead of directly (the fallback path).
- `CC360_DEBUG=1` autoplays and logs frame rate; `CC360_PACING=sec` reports frame pacing then exits (`CC360_NOPLAY=1` skips play); `CC360_NOBLIT=1` skips compositor blits.
