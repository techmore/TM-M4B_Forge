FFmpeg tool slot for M4B Forge.

The app looks here first for `ffmpeg` and `ffprobe`, then falls back to Homebrew paths for development.

For local development, run:

```sh
../Scripts/install_ffmpeg_resources.sh
```

For distribution, replace these files with static or fully bundled, license-reviewed macOS binaries and include the required FFmpeg notices/licenses in the app package.
