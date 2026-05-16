# M4B Forge Build and Distribution

M4B Forge is a native SwiftUI macOS 14+ app that converts ordered MP3/M4A chapter files into a single tagged `.m4b` audiobook.

## Local Build

1. Install FFmpeg for development:

   ```sh
   brew install ffmpeg
   ```

2. Open the project:

   ```sh
   open TM-Ebook_Converter.xcodeproj
   ```

3. Select the `TM-Ebook_Converter` scheme and run. The product name is `M4B Forge`.

Command-line build:

```sh
xcodebuild -project TM-Ebook_Converter.xcodeproj -scheme TM-Ebook_Converter -destination 'platform=macOS' build
```

## FFmpeg Packaging

The app currently resolves tools in this order:

1. Bundled app resources in `Resources/Tools/ffmpeg` and `Resources/Tools/ffprobe`
2. Bundled app resources named `ffmpeg` and `ffprobe`
3. `/opt/homebrew/bin`
4. `/usr/local/bin`
5. `/usr/bin`

For local development, this repository includes `Scripts/install_ffmpeg_resources.sh`:

```sh
Scripts/install_ffmpeg_resources.sh
```

For a self-contained release, add static `ffmpeg` and `ffprobe` binaries to the app target resources. Keep licensing visible in the app and distribution materials. If LGPL compliance is required, prefer dynamic linking or provide relinkable object files according to the FFmpeg build configuration.

The Homebrew binaries copied by the script are useful for local packaging tests, but they are not a substitute for a final static or fully bundled distribution build because they may depend on Homebrew dynamic libraries.

## Production Behaviors

- FFmpeg progress is parsed from `-progress pipe:1`, so queue progress and ETA are based on encoded timestamps.
- Queue cancellation terminates the active FFmpeg process and leaves source files untouched.
- Existing exports are not overwritten unless the project or default overwrite toggle is enabled.
- Saved projects persist security-scoped bookmarks for imported files, covers, and output folders for sandboxed app relaunches.
- Single-file chaptering uses a chunked waveform analyzer that downsamples audio into fixed-size peak data without loading the full source into memory.

## Code Signing

Set your Team in Xcode, then archive:

```sh
xcodebuild archive \
  -project TM-Ebook_Converter.xcodeproj \
  -scheme TM-Ebook_Converter \
  -destination 'generic/platform=macOS' \
  -archivePath build/M4BForge.xcarchive
```

Export a Developer ID signed app using an `ExportOptions.plist`, then notarize:

```sh
xcrun notarytool submit build/M4BForge.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple "M4B Forge.app"
```

## PKG

Create a signed installer package:

```sh
productbuild \
  --component "M4B Forge.app" /Applications \
  --sign "Developer ID Installer: Your Name (TEAMID)" \
  build/M4BForge.pkg
```

Then notarize and staple the package:

```sh
xcrun notarytool submit build/M4BForge.pkg --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple build/M4BForge.pkg
```

## App Icon Direction

Use a dark graphite anvil or forge stamp shaped like an audiobook bookmark, with a copper-gold waveform flowing into a compact `M4B` file badge. It should read clearly at 32 px, avoid tiny text except the file badge, and work on both light and dark macOS backgrounds.
