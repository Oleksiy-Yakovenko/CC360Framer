# CC360Framer

macOS app that opens GoPro `.360` files, auto-reframes them around a detected subject, and exports a flat video.

    ./build.sh && open CC360Framer.app        # or: open -a Xcode Package.swift

- **Look:** drag to look around, scroll/pinch to zoom, double-click to reset.
- **Analyse:** finds the subject (Vision person detection on 8 projected views), builds a smoothed camera path of editable keyframes (diamonds under the seekbar). Saved next to the video as `<file>.reframe.json`.
- **Edit:** `K` sets a keyframe from the current view, click a diamond to select it, `Delete` removes it. Dragging the view switches off Auto; press Auto to follow the path again.
- **Export:** HEVC + AAC, 1080p / 4K 16:9 or 1080×1920 9:16, using the audio tracks currently toggled on.

Debugging: `CC360_DEBUG=1` autoplays and logs frame rate; `CC360_BATCH=out.mp4` (with a file argument) runs analyse + export headless;
`--snapshot stacked.png prefix` renders projection test images.

Not implemented: GoPro GPMF telemetry (HiLight tags, accelerometer) — AVFoundation does not expose that track, so it needs its own MP4 parser.
