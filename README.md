# M4B Forge

A native SwiftUI app for macOS 14 and later that converts ordered MP3/M4A chapter files into a single tagged `.m4b` audiobook. It uses FFmpeg and ffprobe for conversion.

## Build

```sh
brew install ffmpeg
open TM-Ebook_Converter.xcodeproj
```

Select the `TM-Ebook_Converter` scheme and run. The product name is `M4B Forge`. From the command line:

```sh
xcodebuild -project TM-Ebook_Converter.xcodeproj -scheme TM-Ebook_Converter -destination 'platform=macOS' build
```

See [Docs/BUILD_AND_DISTRIBUTION.md](Docs/BUILD_AND_DISTRIBUTION.md) for FFmpeg packaging and distribution notes.

## Layout

| Path | What it is |
|---|---|
| `TM-Ebook_Converter/` | App source: models, services, view models, views |
| `TM-Ebook_Converter.xcodeproj/` | Xcode project |
| `TM-Ebook_ConverterTests/`, `TM-Ebook_ConverterUITests/` | Test targets |
| `ChapterPipeline/` | Optional offline Python pipeline that drafts a chapter list from a transcript using local Whisper and Ollama. See its [README](ChapterPipeline/README.md) |
| `Scripts/` | Setup scripts for bundled FFmpeg tools and the chapter pipeline |
| `Docs/` | Build and distribution notes |
| `Design/` | App icon source |

Part of [Techmore](https://techmore.github.io/pages/repos/).
