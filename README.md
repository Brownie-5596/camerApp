# CamerApp

A manual-control iPhone camera for night sky, aurora and lightning photography.

## Features

**Exposure, like a real camera**
- ISO and shutter each switch between Auto and Manual, giving Program, shutter-priority,
  ISO-priority and full Manual. The dials click through standard 1/3-stop values.
- Exposure compensation (EV) and a viewfinder-style light meter.
- Manual focus and white balance (Kelvin). Tap the preview to focus; with manual focus a
  tap focuses once and locks (like AF-ON).
- Lens choice (0.5×, 1×, telephoto, whichever your phone has).
- RAW (DNG), HEIF, or RAW+HEIF.

**Long exposures by stacking**
iPhones can only expose for about 1 second at a time. The shutter dial keeps going past that
(2s … 10 min, and BULB). For those speeds the app records continuous frames and combines them:
- **Long exposure**: adds the light together, like a real long exposure. The meter accounts
  for the stack, so auto ISO still gives a correct exposure.
- **Average**: same brightness as one frame, much less noise (aurora, Milky Way).
- **Brightest**: keeps the brightest pixels (star trails, lightning, fireworks).

**Shooting tools**
- Self-timer (2s or 10s) and an intervalometer (delay, interval, number of shots or unlimited).
  The intervalometer works with long exposures too.
- Lightning trigger: watches for sudden flashes and saves them automatically.
- Volume buttons work as a shutter release. On iPhone 16 and later, Camera Control takes a
  photo and adjusts shutter, ISO, EV, focus and white balance.

**Live view**
- Histogram, focus peaking, 5× magnifier, rule-of-thirds grid, horizon level.
- Red night-vision mode to protect your dark adaptation.

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
