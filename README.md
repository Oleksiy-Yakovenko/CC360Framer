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
- **Location card:** the first GPS fix in the file is reverse-geocoded (needs network once; cached as `CC360Framer.sidecars/<file>.location.json`) and shown for the first 10 seconds (placement: any corner, top/bottom middle or centre; plus font, size, text colour and outline, all in the right sidebar's Location tab and saved per video in `CC360Framer.sidecars/<file>.project.json`; changes can be undone) as country, place name, coordinates and altitude (when the GPS reports one), in both the preview and the export. Files without a GPS lock show nothing. **Location card keyframes:** the bottom bar's popup has a *Location cards* timeline (Add card at the playhead, Delete, Clear, previous/next; diamonds under the seekbar). Each card keyframe shows the card for 10 s (with fades) from its time with its own placement (default: the Location tab's; edit time and placement in the Inspector tab); the look stays global. Without card keyframes the automatic card at 0 s is shown (switch it off with *Automatic card at start* in the Location tab); once at least one card keyframe exists only the keyframes are used (add one at 0 s to keep a card at the start). A later card keyframe replaces an earlier one that is still visible. Card times are source times, so they work with cuts, and are saved in the project sidecar (`locationCards`, `autoLocationCard`).
- **Captions:** the bottom bar's popup has a *Captions* timeline (Add caption = 3 s at the playhead, Delete, Clear, previous/next; bars with draggable edges under the seekbar, like cuts; captions do not overlap). The Inspector tab edits start/end, the text (several lines) and per-caption overrides of placement, font, size (% of the frame's short side), text colour, outline colour and outline width (% of the font size); empty/Default fields inherit. The default look (placement, font, size, colours, outline; default bottom centre, bold white with a black outline, 5.5 % of the short side) is edited in the Export tab's *Captions* section, saved per video (`captions`, `captionStyle` in the project sidecar) and as the app default for other videos. Captions fade in and out over 0.2 s, are shown together with the location card, use source time (so they follow the cuts) and appear identically in the preview and the export. Lines are only broken where you type a line break; text wider than 90 % of the frame is scaled down.
- **Edit:** `K` sets a keyframe from the current view, click a diamond to select it, `Delete` removes it. Dragging the view switches off Auto; press Auto to follow the path again. Delete key and Clear keys ask for confirmation. Edit > Undo / Redo (Cmd-Z, Shift-Cmd-Z) cover keyframe changes, Build path and the location card placement. Space, K and Delete are ignored while a text field is being edited.
- **Timelines:** the popup at the bottom left picks the active timeline: *Keyframes* (camera) or *Cuts* (parts removed from the export). The seekbar markers, the Add / Delete / Clear buttons (with confirmation for delete and clear), previous/next and the Inspector tab all follow the selection. Cuts are bars under the seekbar: *Add cut* creates a 3 s cut at the playhead (clamped to the clip, never overlapping another cut), click a bar to select it and jump to its start, drag its left or right handle to resize (it stops at neighbouring cuts), or type start and end in the Inspector. Everything is undoable and saved per video in the project sidecar.
- **Cuts in the export:** cut regions are removed from the exported video and audio; the output PTS stay contiguous. At each cut between two kept parts the crossfade length from the Export tab (0 = hard cut) is a real dissolve: the end of the earlier part and the start of the later part overlap by that length (video blended, audio volume ramps), so only kept footage is ever shown and every interior cut makes the output shorter by the crossfade (`output = source - cuts - crossfades`). The crossfade is limited to half the length of each neighbouring kept part; a cut at the very start or end has no dissolve. Camera path, stabiliser, location card timing and telemetry use the source time of each output frame.
- **Preview with cuts applied** (checkbox in the Export tab, saved per video): playback jumps over the cut regions (no crossfade in the preview) and stops at the end of the clip; the seekbar still shows the whole source video and you can scrub into a cut.
- **Inspector:** select a keyframe and edit its time, yaw, pitch and field of view numerically in the right sidebar's Inspector tab (Enter commits; undoable; keyframes are re-sorted).
- **Export:** HEVC or H.264 + AAC in an MP4 or MOV container, using the audio tracks currently toggled on. The right sidebar's Export tab sets format, codec, rate control (average bitrate in Mbps, empty = automatic: 20 Mbps up to ~3 MP and 50 Mbps above; or an encoder quality level), resolution (short side 720p / 1080p / 1440p / 4K, or a custom width), aspect ratio (16:9, 9:16, 1:1, 4:5, 4:3 or custom w:h; the output size is rounded to even pixels and shown in the tab) and the cut crossfade length. The settings are saved per video in the project sidecar and as the default for other videos. "Show export frame" outlines the exported area in the preview and dims the rest (preview only, never in the file; with the same vertical field of view, a different aspect ratio changes the horizontal extent). **Global FOV** (checkbox and 20-140° slider, saved per video and as default) replaces the field of view of every keyframe in the preview, the export and batch runs; while it is on, scroll and pinch zoom in the preview are disabled (the slider is the control). Press Export… in the toolbar to write the file. The sidebars can be hidden with the toolbar toggles (left: ⌃⌘S, right: ⌥⌘2).

Limits: rotation compensation cannot remove shake caused by camera translation (small residual wobble at 0.5–2 Hz). HiLight tags and gyro/accelerometer data are not used yet (only orientation, gravity and the first GPS fix).

## Batch processing

File > Batch Processing... (Shift-Cmd-B) or the toolbar button opens one shared window. Drop `.360` files or folders on the list (folders are searched recursively, duplicates ignored) or use Add...; drag rows to reorder, Remove/Delete removes the selected rows, Clear empties the list. Start processes the files one after another; Pause finishes the current file and stops (Resume continues, failed files are retried).

- Force re-analyse: analyse again and rebuild the camera path. Off: an existing analysis is reused and existing keyframes (also hand-edited) are kept; files without analysis are analysed.
- Export: off = only analyse and build the path (keyframes are saved as usual).
- Path style, output folder (required for export, never defaults to the footage folder; exported as `<name>-reframed.<ext>`, `-2`, `-3`... on collisions) and the export settings (same editor as the Export tab, stored separately from per-video settings) apply to the whole batch.
- Cuts, captions, location cards and the global fov of each file come from its own sidecars; sidecars are written next to each source file as usual.

## Command line tools and debugging

- `--batch-run [--out DIR] [--force] [--no-export] [--style follow|scenery] [--settings EXPORT_JSON] FILE_OR_FOLDER...`: the batch engine without UI (settings are not saved).

- `--telemetry file.360`: print parsed telemetry counts and first/last samples.
- `--telemetry` also prints the first GPS fix with its altitude (median of the first locked fixes, GPS height in metres).
- `--snapshot stacked.png prefix`: render projection test images. Env: `CC360_TELEMETRY=file.360 CC360_TIME=sec CC360_MODE=level|smooth CC360_AXES=1,-1,1` to apply stabilisation.
- `--stab-test file.360 [start] [length]`: measure residual shake per stabilisation mode and the telemetry/video time offset (env `CC360_SIGMAS`, `CC360_SCAN`, `CC360_W`).
- `--analysis-compare file.360 [start] [length]`: compare analysis on the raw versus level frame.
- `CC360_BATCH=out.mp4` with a file argument: headless analyse (or build from cached analysis) and export. Add `CC360_STYLE=scenery` for the scenery style, `CC360_NO_ANALYSIS=1` for a plain stabilised export without keyframes.
- `CC360_EXPORT_SETTINGS='{"container":"mov","codec":"h264","aspect":"1:1","resolution":"720p"}'` with `CC360_BATCH`: export with these `ExportSettings` (JSON, any subset of the fields; the rest come from the saved settings).
- `CC360_GLOBAL_FOV=deg` with `CC360_BATCH`: export with the global fov override set to this vertical fov (not saved).
- `CC360_FORCE_SYMLINK=1` opens `.360` files through a temporary `.mp4` symlink instead of directly (the fallback path).
- `CC360_DEBUG=1` autoplays and logs frame rate; `CC360_PACING=sec` reports frame pacing then exits (`CC360_NOPLAY=1` skips play); `CC360_NOBLIT=1` skips compositor blits.
