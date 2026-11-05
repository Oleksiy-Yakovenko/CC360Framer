# CC360Framer

macOS app that opens GoPro `.360` files, auto-reframes them around a detected subject, and exports a flat video.

    ./build.sh && open CC360Framer.app        # or: open -a Xcode Package.swift

- **Look:** drag to look around, scroll/pinch to zoom, double-click to reset.
- **Analyse:** projects 8 views around the horizon, detects people and (on the side views) salient objects, and stores the raw detections next to the video (`<file>.analysis.json`). A path style then turns them into a smoothed camera path of editable keyframes (diamonds under the seekbar), saved as `<file>.reframe.json`.
- **Style** (drop-down): *Follow subject* keeps the main subject (the rider) in view. *Scenery + rider* looks forward along the direction of travel, glances at objects on the sides, and swings round to show the rider about every 25–30 s. Switching style regenerates the path from the stored detections without re-analysing (it asks first if you have hand-edited keyframes: use **Build path**).
- **Stabilise** (drop-down, default *Level + smooth*): uses the camera's own motion data (`GRAV` gravity and `CORI` orientation from the file's `gpmd` track) to keep the horizon level and remove shake. *Level* locks the horizon only; *Level + smooth* also smooths the heading. Look directions and keyframes are relative to this stabilised camera, so pitch 0 is the horizon. Field of view defaults to 70° vertical (wider looks stretched at the edges).
- **Edit:** `K` sets a keyframe from the current view, click a diamond to select it, `Delete` removes it. Dragging the view switches off Auto; press Auto to follow the path again.
- **Export:** HEVC + AAC, 1080p / 4K 16:9 or 1080×1920 9:16, using the audio tracks currently toggled on.

Debugging: `CC360_DEBUG=1` autoplays and logs frame rate; `CC360_BATCH=out.mp4` (with a file argument, optional `CC360_STYLE=scenery`) runs analyse + export headless;
`--snapshot stacked.png prefix` renders projection test images (env `CC360_TELEMETRY=file.360 CC360_TIME=sec CC360_MODE=level|smooth CC360_AXES=1,-1,1` to apply stabilisation);
`--analysis-compare file.360 [start] [length]` compares analysis on the raw vs level frame; `CC360_NO_ANALYSIS=1` with `CC360_BATCH` exports a stabilised default view without any analysis;
`--telemetry file.360` prints the parsed telemetry; `--stab-test file.360 [start] [length]` measures residual shake per stabilisation mode and telemetry/video time offset.

Not used yet: HiLight tags, GPS and gyro/accelerometer from the telemetry (only orientation and gravity are read).
