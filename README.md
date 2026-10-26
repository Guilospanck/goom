# Goom

A small Loom-style screen recorder for macOS (menu bar app).

- Records your main display, a single window, or a dragged region, plus system audio + microphone to `~/Movies/Goom/*.mp4`
- Optional floating camera bubble, composited into the video only where it overlaps what you're recording (screen, window or region); right-click it to change its size or shape, even mid-recording. Click the menu bar icon while recording to stop with selectable shape (circle, rounded square, wide) and size
- Choose the camera and microphone (including external and iPhone Continuity devices), plus resolution, frame rate, codec and audio quality under "Devices & quality" in the popover; choices are remembered
- Optional big on-screen 3-2-1 countdown (toggle in the popover), elapsed timer in the menu bar, ⇧⌘R to start/stop (when the menu is open)
- Library window to play, share, reveal and trash recordings

## Build & run (macOS 15+, Xcode command line tools)

    ./scripts/build-app.sh && open build/Goom.app

On first run, grant Screen Recording, Camera and Microphone, then relaunch if prompted.
Set your own bundle id in `Resources/Info.plist`.
