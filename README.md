# CamerApp

A manual-control iPhone camera for night sky, aurora and lightning photography.

## Features

Done:
- Manual ISO, shutter speed, focus and white balance (each with an Auto toggle)
- Lens choice (0.5×, 1×, telephoto, whichever your phone has)
- RAW (DNG) or HEIF output, saved to Photos
- Intervalometer: start delay, interval, number of shots or unlimited
- Red night-vision mode (eye button, top right)

Planned:
- Stacking: Average (aurora) and Brightest-pixel (lightning, star trails)
- Live histogram, focus peaking, magnifier
- Camera Control button support (iPhone 16 and later)
- Automatic lightning detection

Note: iOS limits a single exposure to about 1 second on most iPhones. Longer effective
exposures come from stacking many frames, which is what the stacking modes are for.

## Getting it on your phone (SideStore)

GitHub builds the app on every push (see the **Actions** tab). Pushes to the default
branch also publish `CamerApp.ipa` to the **latest** release.

1. On your iPhone, open this repo's **Releases** page and download `CamerApp.ipa`
   from **Latest build**.
2. Open SideStore, go to **My Apps**, tap **+**, and choose the downloaded `.ipa`.
3. SideStore signs it with your Apple ID. With a free Apple ID, refresh it in
   SideStore at least every 7 days.

The `.ipa` is unsigned on purpose, because SideStore re-signs it for your device.

## Building on a Mac (optional)

```sh
brew install xcodegen
xcodegen generate
open CamerApp.xcodeproj
```
