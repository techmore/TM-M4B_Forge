# M4B Forge Chapter Pipeline

This is the optional offline automation path for M4B Forge. The app remains fully manual, but this pipeline can create a first-pass chapter list from a long MP3/M4A audiobook transcript so the user can import it into M4B Forge, audition chapter transitions, and manually correct anything that needs human judgment.

The pipeline is privacy-first:

- Audio and transcripts stay local.
- Whisper transcription runs locally with `mlx_whisper`.
- Chapter reasoning runs locally through Ollama.
- Outputs are plain JSON/CSV/TXT files compatible with M4B Forge chapter import.

## What It Produces

For an input transcript such as `book.json`, the pipeline writes:

- `book.chapters.json` - preferred import format for M4B Forge.
- `book.chapters.csv` - spreadsheet-friendly review format.
- `book.chapters.txt` - quick human-readable timestamp list.
- `chapter_work/` - prompts, model responses, parsed checkpoints, and errors for debugging/resume.

The JSON shape is:

```json
{
  "format": "m4b-forge-chapters",
  "chapter_count": 12,
  "duration": 12345.67,
  "duration_timestamp": "3:25:46",
  "chapters": [
    {
      "title": "Prologue",
      "start": 0,
      "reason": "manual bookend",
      "source_chunk": -1
    }
  ]
}
```

## Install

From the repo root:

```bash
Scripts/setup_chapter_pipeline.sh
```

This installs/checks:

- Homebrew packages: `ollama`
- Python virtual environment: `ChapterPipeline/.venv`
- Python package: `mlx-whisper`
- A default Ollama model, currently `qwen3.5:9b`

Apple Silicon is strongly recommended for `mlx_whisper`.

## Full Workflow

### Best Path When You Have a PDF or Ebook

When a reference PDF has the real chapter layout, use it as the source of truth. This avoids turning every dated diary entry or scene break into a chapter.

```bash
python3 ChapterPipeline/pdf_chapter_plan.py "/path/to/book.pdf" book.json \
  --output-stem book_pdf_guided \
  --opening-title Prologue
```

This extracts `Chapter 1`, `Chapter II`, `Chapter III`, and similar headings from the PDF, aligns each chapter start to the Whisper transcript, then adds the opening bookend and any detected epilogue marker.

Import `book_pdf_guided.chapters.json` into M4B Forge.

### Transcript-Only Path

1. Transcribe the audiobook:

```bash
source ChapterPipeline/.venv/bin/activate

mlx_whisper "/path/to/book.mp3" \
  --model mlx-community/whisper-large-v3-turbo \
  --language en \
  -f json \
  --word-timestamps True \
  --output-name "book" \
  --condition-on-previous-text False \
  --no-speech-threshold 0.8 \
  --compression-ratio-threshold 2.0 \
  --hallucination-silence-threshold 2.0 \
  --logprob-threshold -1.0
```

2. Start Ollama if it is not already running:

```bash
ollama serve
```

3. Generate chapter candidates:

```bash
python3 ChapterPipeline/audiobook_chapter_pipeline.py book.json \
  --output-stem book \
  --work-dir chapter_work/book \
  --mode dates \
  --heuristic-first \
  --add-prologue
```

4. Import `book.chapters.json` into M4B Forge.

5. Use M4B Forge to audition transitions, scrub the full timeline, rename chapters, add metadata/cover art, and export the final `.m4b`.

## Fast Deterministic Pass

Use this when the book has obvious chapter markers, dates, or structural phrases and you want a quick first pass without Ollama:

```bash
python3 ChapterPipeline/audiobook_chapter_pipeline.py book.json \
  --output-stem book \
  --work-dir chapter_work/book \
  --mode dates \
  --no-llm \
  --add-prologue
```

## Modes

- `sections` - chapter/part/book/section markers only.
- `dates` - date markers plus major section starts. Good for diary-style books.
- `dense` - more aggressive; useful when the book has many topic shifts but requires more manual cleanup.

## Prologue and Epilogue

Use `--add-prologue` to ensure a `Prologue` marker at `00:00:00`.

The pipeline automatically recognizes common epilogue phrases, including:

```text
what follows now is an epilogue
```

You can add more phrases:

```bash
python3 ChapterPipeline/audiobook_chapter_pipeline.py book.json \
  --output-stem book \
  --epilogue-marker "this is the epilogue" \
  --epilogue-marker "epilogue begins"
```

Or manually force the epilogue start:

```bash
python3 ChapterPipeline/audiobook_chapter_pipeline.py book.json \
  --output-stem book \
  --epilogue-start 35118.04
```

## Debugging Stuck Runs

Every chunk writes files under `chapter_work/`:

- `chunk_001.prompt.txt` - what was sent to Ollama.
- `chunk_001.raw.txt` - raw model response.
- `chunk_001.chapters.json` - parsed checkpoint.
- `chunk_001.error.txt` - error details if parsing/model call failed.

Re-run without `--overwrite` to resume from checkpoints. Add `--overwrite` to reprocess all chunks.

Use `--max-chunks 2 --dry-run` to inspect prompts without calling Ollama.
