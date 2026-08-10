# FluoScan v0.1 — Flutter Web

FluoScan is a browser-based reader for fluorescent screen-printed 1D barcodes. It follows the same architecture as the pH-meterV2 project: Flutter Web source in GitHub, deployed through GitHub Pages, and opened on the phone in Chrome/Edge rather than installed as a native APK.

## What v0.1 does

- Uses the phone/browser camera through `getUserMedia`.
- Provides presets for DiABP, DiANBP, DiASF, and AUTO.
- Samples several narrow horizontal bands so rough printed edges are not averaged over the full barcode height.
- Suppresses the blue UV background using colour-weighted fluorescence scores.
- Uses Otsu thresholding plus several nearby threshold attempts.
- Reconstructs the fluorescent pattern as a conventional black-bar / white-space barcode.
- Sends only that reconstructed image to ZXing for Code 128 decoding.
- Includes the three supplied barcode crops as built-in test samples.
- Can also open any barcode photograph from the device.

## First local run

From the project folder:

```bash
flutter pub get
flutter run -d chrome
```

Camera access normally works on `localhost`. Allow camera permission when asked.

## GitHub Pages workflow

Create a public GitHub repository, for example `FluoScan`, and push this project to its `main` branch.

Build the web version with the repository path as the base href:

```bash
flutter build web --release --base-href /FluoScan/
```

Then publish the contents of `build/web` to a `gh-pages` branch, as with pH-meterV2. In GitHub Settings > Pages, choose the `gh-pages` branch as the source if it is not selected automatically.

The site will then be available at:

`https://<username>.github.io/FluoScan/`

GitHub Pages is HTTPS, which is required for browser camera access on a phone.

## How to test the physical prints

1. Open FluoScan on the phone.
2. Use the external UV excitation source.
3. Avoid direct UV glare into the camera.
4. Keep the barcode horizontal and fill most of the guide rectangle.
5. Start with the matching material preset; then try AUTO.
6. If the live frame does not decode, use **Choose image** on a straight-on photograph. This helps separate optical/printing limitations from live-camera limitations.

## Research interpretation

A successful FluoScan read demonstrates machine decoding after fluorescence-specific optical preprocessing. It should not be described as direct compatibility with a conventional retail/laser barcode scanner. For publication, record the excitation source, camera distance, angle, preset, and success/failure rate.
