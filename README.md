# CC360Framer

macOS app that opens GoPro `.360` files, auto-reframes them around a detected subject, and exports a flat video.

    ./build.sh && open CC360Framer.app        # or: open -a Xcode Package.swift

- **Look:** drag to look around, scroll/pinch to zoom, double-click to reset.
- **Analyse:** projects 8 views around the horizon, detects people and (on the side views) salient objects, and stores the raw detections next to the video (`<file>.analysis.json`). A path style then turns them into a smoothed camera path of editable keyframes (diamonds under the seekbar), saved as `<file>.reframe.json`.
- **Style** (drop-down): *Follow subject* keeps the main subject (the rider) in view. *Scenery + rider* looks forward along the direction of travel, glances at objects on the sides, and swings round to show the rider about every 25–30 s. Switching style regenerates the path from the stored detections without re-analysing (it asks first if you have hand-edited keyframes: use **Build path**).
- **Edit:** `K` sets a keyframe from the current view, click a diamond to select it, `Delete` removes it. Dragging the view switches off Auto; press Auto to follow the path again.
- **Export:** HEVC + AAC, 1080p / 4K 16:9 or 1080×1920 9:16, using the audio tracks currently toggled on.

Debugging: `CC360_DEBUG=1` autoplays and logs frame rate; `CC360_BATCH=out.mp4` (with a file argument, optional `CC360_STYLE=scenery`) runs analyse + export headless;
`--snapshot stacked.png prefix` renders projection test images.

Not implemented: GoPro GPMF telemetry (HiLight tags, accelerometer) — AVFoundation does not expose that track, so it needs its own MP4 parser.
