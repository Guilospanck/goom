<p align="center"><img src="Resources/AppIcon.png" alt="Goom icon" width="128" height="128"></p>

<h1 align="center">Goom</h1>

A small, local-first Loom-style screen recorder for macOS that lives in the menu bar. Record your screen, a window or a region with system audio, microphone and an optional camera bubble, and get a plain MP4 in `~/Movies/Goom`. No account, no cloud upload.

- Records your main display, a single window, or a dragged region, plus system audio + microphone to `~/Movies/Goom/*.mp4`
- Optional floating camera bubble, composited into the video only where it overlaps what you're recording (screen, window or region); right-click it to change its size or shape, even mid-recording. Click the menu bar icon while recording to stop with selectable shape (circle, rounded square, wide) and size
- Choose the camera and microphone (including external and iPhone Continuity devices), plus resolution, frame rate, codec and audio quality under "Devices & quality" in the popover; choices are remembered
- Optional big on-screen 3-2-1 countdown (toggle in the popover), elapsed timer in the menu bar, ⇧⌘R to start/stop (when the menu is open)
- Library window to play, share, reveal and trash recordings

## Install

    brew install --cask guilospanck/tap/goom

The app is ad-hoc signed (not notarized); the cask clears the download quarantine so Gatekeeper lets it launch.

## Build & run (macOS 15+, Xcode command line tools)

    ./scripts/build-app.sh && open build/Goom.app

On first run, grant Screen Recording, Camera and Microphone, then relaunch if prompted.
Set your own bundle id in `Resources/Info.plist`.

## Development

    just run          # build and open
    just install      # build and install to /Applications (keeps permissions stable)
    just uninstall    # quit and remove from /Applications (recordings are kept)

## Releasing

    just release 1.1 "optional release notes"

Bumps the version in `Resources/Info.plist`, builds, tags `v1.1`, pushes, publishes a GitHub Release with `Goom-1.1.zip`, and updates the cask in `Guilospanck/homebrew-tap`. Needs `gh` (authenticated) and push access to the tap.

`just tag 1.1` is the CI alternative: it bumps, tags and pushes, then you start the manual Release workflow from the Actions tab with that tag. Run `just setup-tap-key` once beforehand to give CI push access to the tap.
