# RokidLiveView

*日本語版: [README.ja.md](README.ja.md)*

A macOS app that **composites the Rokid Glasses camera feed with the glasses display in real time**.

It reproduces the "black = see-through" look with a screen blend, so you can put the wearer's
point of view on a projector or into a Zoom screen share as it happens.

```
[glasses] --scrcpy(display)--> ┐
                               ├--> ScreenCaptureKit --> screen blend --> preview / mp4
[glasses] --scrcpy(camera)---> ┘
```

## This is an approximation, not what the wearer actually sees

The output is **tuned to resemble** the wearer's view. It is not a faithful reproduction, and it
should not be used to judge how readable or visible something really is on the device.

- The glasses are an **optical see-through** display: the real impression depends on ambient
  brightness and on how the eye adapts, neither of which a camera sensor reproduces.
- The camera's field of view and the eye's do not match, so where the HUD sits relative to the
  scene is a **hand-tuned approximation** (`hudFrac`, `hudDX`, `hudDY`).
- The green monochrome look is **emulated** from the framebuffer with a tint plus gain, rather than
  captured from the actual optics.
- `hudDensity` deliberately departs from physical see-through — it darkens the background under the
  HUD so text stays legible in a video. The real device cannot darken anything.

Treat it as a communication tool for demos and recordings, not as a measurement.

## Requirements

- macOS 14 or later
- `scrcpy` — tested with 3.3.1. The app needs `--video-source=camera`, which older builds may lack
- `ffmpeg` — used to mux the audio into the recording
- `adb` — from the Android SDK platform-tools, or `brew install --cask android-platform-tools`
- **Screen Recording permission** (System Settings → Privacy & Security → Screen Recording)

Verified against Rokid Glasses firmware 1.21. The three executables are looked up at their usual
locations (see the table under [Configuration](#configuration)); if yours live somewhere else, point
at them with `scrcpyPath` / `ffmpegPath` / `adbPath`.

## Usage

```bash
./build.sh          # build and install to ~/Applications/RokidLiveView.app
./build.sh --run    # install and launch
```

1. Connect the glasses over adb (the app finds them automatically)
2. Launch the app and press **Start**
   - Two scrcpy windows appear (one for the display, one for the camera)
   - The status turns to *Running* and the composite shows up in the preview
3. **Record** / **Stop Recording** writes to `~/Movies/RokidLiveView/live-*.av.mp4`
   - Once the file is finalized, Finder opens with it selected
4. **Full Screen** sends it to a projector or an external display

### Window placement

**Do not minimize the two scrcpy windows.** Capture holds at roughly 30fps even when they are
fully covered by other windows (measured), but minimizing them stops the frames.

For projector use, the natural split is "laptop screen = the two scrcpy windows + the controls"
and "external display = preview in full screen". In Zoom, share the preview window.

### Smoke test

```bash
open -a ~/Applications/RokidLiveView.app --args --selftest
```

Runs start → window discovery → compositing → still capture → 6s recording → quit without any
manual input, including recovery from a killed scrcpy. Results land in `~/Movies/RokidLiveView/selftest.log`
and `selftest-*.png` next to it.

## Configuration

There is no settings UI. Override the defaults through UserDefaults
(see [Config.swift](Sources/RokidLiveView/Config.swift)). Values are read once at launch, so
**restart the app** after changing them.

```bash
defaults write com.hacha.rokidliveview hudFrac -float 0.6       # HUD height / output height
defaults write com.hacha.rokidliveview hudDY -float 200         # HUD vertical offset (down is positive)
defaults write com.hacha.rokidliveview hudGain -float 1.8       # brighter HUD
defaults write com.hacha.rokidliveview hudDensity -float 0.5    # back toward see-through
defaults write com.hacha.rokidliveview serial -string XXXX      # use a different pair of glasses
defaults delete com.hacha.rokidliveview hudGain                 # back to the default
```

| Key | Default | Meaning |
|---|---|---|
| `serial` | auto-detected | Glasses serial. Found via `adb devices -l` (`model:RG_glasses`); set this when several devices are attached |
| `hudFrac` | `0.40` | HUD height / output height |
| `hudDX` | `0` | HUD horizontal offset from center, in px |
| `hudDY` | `360` | HUD vertical offset from center, in px (down is positive) |
| `hudTint` | `00ff44` | HUD tint color. `none` keeps the original colors |
| `hudGain` | `1.5` | HUD brightness gain, applied after tinting |
| `hudDensity` | `1.0` | HUD density, 0…1. Darkens the background under the HUD before blending. 0 favors see-through |
| `scrcpyPath` / `ffmpegPath` | `/opt/homebrew/bin`, then `/usr/local/bin` | Executable locations. The first one that exists wins |
| `adbPath` | `~/Library/Android/sdk/platform-tools/adb`, then the two directories above | Executable location for adb. Set this when adb is installed somewhere else |
| `outputDirectory` | `~/Movies/RokidLiveView` | Where recordings go |

### When the HUD looks fainter than the real thing

Raise `hudGain`. The glasses framebuffer is **already drawn in green** (text pixels average
RGB = 80.7, 201.9, 101.0, measured), and the luma conversion behind the tinting step — the
equivalent of ffmpeg's `hue=s=0` — costs the green coefficient of 0.587 (peak G of the text drops
from 255 to 186.2). A gain of about 1.37 restores that loss; push higher to emphasize it further.

Setting `hudTint` to `none` also restores the brightness, but the original green carries R and B
components so it ends up looking washed out. To stay close to the real green, keep the tinting and
tune `hudGain` instead.

### When it needs more *density*, not more brightness

Raise `hudDensity`. A screen blend (`1-(1-a)(1-b)`) **can only lighten the background**, so the
brighter the background, the more the green washes toward white. Raising `hudGain` there only adds
blowout — it cannot make the color deeper.

`hudDensity` uses the HUD luminance as a mask and **darkens the background under it first**.
Subtracting R and B is what makes the green stand out. Where the HUD is black (i.e. see-through)
the mask is 0, so the background is left untouched.

Note this is a trade-off against see-through: at higher values, bright HUD areas effectively get a
dark backing plate. The mask is per-pixel, so text deepens while empty areas stay transparent.

```bash
defaults write com.hacha.rokidliveview hudDensity -float 1.0   # densest (background nearly replaced)
defaults write com.hacha.rokidliveview hudDensity -float 0.0   # physically see-through          
```

## Known issues

### scrcpy can die when adb servers fight over the device

Other tools that bundle their own adb — IDEs, game engines, Android tooling — take over the adb
server when their version differs from the one already running. At that moment scrcpy fails to
start with `could not install *smartsocket* listener: Address already in use`, and the glasses
briefly disappear from `adb devices`.

- The app detects the scrcpy exit, restarts it, and **re-attaches the capture** (up to 5 times).
  The restarted window gets a new windowID, so without re-attaching, the video would freeze on the
  last frame. `--selftest` verifies this recovery automatically
- **Quitting anything else that talks to adb before a demo is the reliable fix**
- Do not run `adb kill-server` — it takes scrcpy and friends down with it. Wait a few seconds and
  it recovers on its own
- If they must coexist, switch to wireless adb (`adb tcpip 5555` → `adb connect <ip>:5555`); over
  TCP several adb servers can hold the device in parallel

Separating the servers with `ANDROID_ADB_SERVER_PORT` does *not* help. Only one adb server can
claim a USB device (`LIBUSB_ERROR_ACCESS`), so the fight just moves elsewhere.

### Screen Recording permission can reset on every build

TCC ties the grant to the app's signature *and* its location. `build.sh` picks up an Apple
Development certificate automatically and installs to `~/Applications/RokidLiveView.app`, which
keeps the grant. Without a certificate it falls back to an ad-hoc signature, and macOS may ask for
permission again after every build.

### Force-quitting the app leaves scrcpy running

A normal exit (closing the window, or **Stop**) cleans scrcpy up, but a force quit or a crash can leave
it behind. Kill it with `pkill -f "window-title=RLV-"`.

### Quality is capped by the scrcpy window size

Capture resolution equals the window's size in real pixels. By default the camera window is
540x960 pt captured at Retina 2x, so the composite is 1080x1920. For more, enlarge `cameraWindow`
in [Config.swift](Sources/RokidLiveView/Config.swift) — at the cost of screen real estate.

## Design notes

- **Why capture the scrcpy windows**: a window always holds its last frame, so compositing is just
  "take the latest frame from each source, every time". That removes the birthtime-based alignment
  an offline pipeline needs to sync the two recordings. The camera side is already drawn upright by
  scrcpy's `--orientation=270`, so no transpose is needed either.
- **Why not composite live with ffmpeg alone**: the glasses display sends no frames while it is
  static (VFR), so `blend`'s framesync waits for both inputs to advance and the whole video stalls.
- **SCK does not attach pixels to unchanged frames** (status=idle). Holding on to the last pixel
  buffer received is therefore mandatory.
- **Color management is disabled** (`workingColorSpace = NSNull`). CoreImage converts to a linear
  space before blending by default, which would not match ffmpeg's screen blend in gamma space.
- **The composite is a screen blend (`1-(1-a)(1-b)`), not an alpha blend.** Black contributes
  nothing, which is what makes it see-through. The flip side is that bright backgrounds crush
  toward white — `hudGain` and `hudDensity` exist to compensate.
- **Recording is fixed 30fps CFR.** The preview runs at 60fps, but the real camera is around 30fps
  so duplicate frames are never written. Audio is captured separately by a third scrcpy process
  (the glasses mic) and muxed in with ffmpeg on stop, with the startup delay corrected via
  `-itsoffset`.

## Notes

Not affiliated with or endorsed by Rokid. "Rokid" and "Rokid Glasses" belong to their respective
owners; this is an independent tool built against the device over `adb` and scrcpy.

## License

MIT — see [LICENSE](LICENSE).
