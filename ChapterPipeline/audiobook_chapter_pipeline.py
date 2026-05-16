#!/usr/bin/env python3
"""
Build M4B Forge chapter candidates from an mlx-whisper JSON transcript.

This script is designed for long audiobooks:
- chunks by real timestamps, not guessed segment counts
- logs visible progress and ETA
- checkpoints every Ollama response so runs can resume
- asks the model for strict JSON, then validates/parses it
- writes M4B Forge compatible JSON and CSV chapter files
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any


@dataclass
class Segment:
    start: float
    end: float
    text: str


@dataclass
class Chunk:
    index: int
    start: float
    end: float
    core_start: float
    core_end: float
    segments: list[Segment]


def timestamp(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    return str(timedelta(seconds=seconds))


def load_segments(path: Path) -> list[Segment]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)

    raw_segments = data.get("segments")
    if not isinstance(raw_segments, list) or not raw_segments:
        raise ValueError("Whisper JSON does not contain a non-empty 'segments' array.")

    segments: list[Segment] = []
    for raw in raw_segments:
        try:
            start = float(raw["start"])
            end = float(raw["end"])
            text = str(raw.get("text", "")).strip()
        except (KeyError, TypeError, ValueError):
            continue
        if end > start and text:
            segments.append(Segment(start=start, end=end, text=text))

    if not segments:
        raise ValueError("No usable timestamped transcript segments found.")

    return segments


def build_chunks(segments: list[Segment], chunk_minutes: float, overlap_minutes: float) -> list[Chunk]:
    total = segments[-1].end
    chunk_seconds = chunk_minutes * 60
    overlap_seconds = overlap_minutes * 60
    step = max(60, chunk_seconds - overlap_seconds)

    chunks: list[Chunk] = []
    core_start = 0.0
    index = 1
    while core_start < total:
        core_end = min(total, core_start + chunk_seconds)
        chunk_start = max(0.0, core_start - overlap_seconds)
        chunk_end = min(total, core_end + overlap_seconds)
        chunk_segments = [segment for segment in segments if segment.end >= chunk_start and segment.start <= chunk_end]
        chunks.append(Chunk(index=index, start=chunk_start, end=chunk_end, core_start=core_start, core_end=core_end, segments=chunk_segments))
        index += 1
        core_start += step

    return chunks


def build_prompt(chunk: Chunk, mode: str) -> str:
    transcript = "\n".join(f"[{timestamp(segment.start)}] {segment.text}" for segment in chunk.segments)
    focus = {
        "sections": "major section or chapter starts",
        "dates": "dated entries, major section starts, and chapter-like breaks",
        "dense": "all plausible chapter starts, including dated entries and major topic shifts",
    }[mode]

    return f"""/no_think
You are preparing chapter markers for an audiobook.

Find {focus} in this timestamped transcript chunk.

Return ONLY valid JSON with this exact shape:
{{
  "chapters": [
    {{"title": "Short chapter title", "start": 123.45, "reason": "brief evidence"}}
  ]
}}

Rules:
- start must be seconds from the beginning of the full audiobook.
- Use the timestamp nearest where the section begins.
- Prefer concise listener-facing titles.
- Do not include duplicate chapters.
- Do not include commentary outside JSON.

Chunk covered by this request:
- transcript range: {timestamp(chunk.start)} to {timestamp(chunk.end)}
- trusted non-overlap range: {timestamp(chunk.core_start)} to {timestamp(chunk.core_end)}

Transcript:
{transcript}
"""


def call_ollama(model: str, prompt: str, num_ctx: int, timeout: int) -> str:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {
            "temperature": 0.0,
            "num_ctx": num_ctx,
        },
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    return str(body.get("message", {}).get("content", ""))


def extract_json_object(text: str) -> dict[str, Any]:
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL | re.IGNORECASE).strip()
    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start >= 0 and end > start:
        parsed = json.loads(cleaned[start : end + 1])
        if isinstance(parsed, dict):
            return parsed

    raise ValueError("Ollama response did not contain parseable JSON.")


def normalize_chapters(parsed: dict[str, Any], chunk: Chunk) -> list[dict[str, Any]]:
    raw_chapters = parsed.get("chapters", [])
    if not isinstance(raw_chapters, list):
        return []

    chapters: list[dict[str, Any]] = []
    for raw in raw_chapters:
        if not isinstance(raw, dict):
            continue
        title = str(raw.get("title") or raw.get("chapter") or "").strip()
        if not title:
            title = "Chapter"
        try:
            start = float(raw.get("start"))
        except (TypeError, ValueError):
            continue

        # Keep only the non-overlap range for this chunk to avoid duplicated overlap results.
        if start < chunk.core_start or start > chunk.core_end:
            continue

        chapters.append(
            {
                "title": title,
                "start": round(max(0.0, start), 2),
                "reason": str(raw.get("reason", "")).strip(),
                "source_chunk": chunk.index,
            }
        )

    return chapters


def dedupe_chapters(chapters: list[dict[str, Any]], tolerance_seconds: float) -> list[dict[str, Any]]:
    sorted_chapters = sorted(chapters, key=lambda item: float(item["start"]))
    deduped: list[dict[str, Any]] = []
    for chapter in sorted_chapters:
        if deduped and abs(float(chapter["start"]) - float(deduped[-1]["start"])) <= tolerance_seconds:
            # Prefer the more specific title.
            if len(str(chapter["title"])) > len(str(deduped[-1]["title"])):
                deduped[-1] = chapter
            continue
        deduped.append(chapter)
    return deduped


def find_marker_start(segments: list[Segment], markers: list[str]) -> tuple[float, str] | None:
    normalized_markers = [marker.strip().lower() for marker in markers if marker.strip()]
    if not normalized_markers:
        return None

    for segment in segments:
        text = segment.text.lower()
        for marker in normalized_markers:
            if marker in text:
                return segment.start, marker

    return None


def add_bookends(
    chapters: list[dict[str, Any]],
    total_duration: float,
    add_prologue: bool,
    prologue_title: str,
    epilogue_start: float | None,
    epilogue_title: str,
    epilogue_reason: str = "manual bookend",
) -> list[dict[str, Any]]:
    result = list(chapters)
    if add_prologue and not any(float(chapter["start"]) <= 1 for chapter in result):
        result.append(
            {
                "title": prologue_title,
                "start": 0.0,
                "reason": "manual bookend",
                "source_chunk": -1,
            }
        )

    if epilogue_start is not None:
        bounded_start = max(0.0, min(float(epilogue_start), total_duration))
        nearby_index = next((index for index, chapter in enumerate(result) if abs(float(chapter["start"]) - bounded_start) <= 30), None)
        if nearby_index is not None and epilogue_reason != "manual bookend":
            result[nearby_index] = {
                "title": epilogue_title,
                "start": round(bounded_start, 2),
                "reason": epilogue_reason,
                "source_chunk": -1,
            }
        elif nearby_index is None:
            result.append(
                {
                    "title": epilogue_title,
                    "start": round(bounded_start, 2),
                    "reason": epilogue_reason,
                    "source_chunk": -1,
                }
            )

    return sorted(result, key=lambda chapter: float(chapter["start"]))


def heuristic_chapters(segments: list[Segment], mode: str) -> list[dict[str, Any]]:
    patterns = []
    if mode in {"dates", "dense"}:
        patterns.append(
            re.compile(
                r"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+"
                r"\d{1,2}(?:st|nd|rd|th)?(?:,\s*\d{4})?",
                re.IGNORECASE,
            )
        )
    if mode in {"sections", "dense"}:
        patterns.append(re.compile(r"\b(?:chapter|part|book|section)\s+(?:[ivxlcdm]+|\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b", re.IGNORECASE))

    chapters: list[dict[str, Any]] = []
    for segment in segments:
        for pattern in patterns:
            match = pattern.search(segment.text)
            if not match:
                continue
            title = match.group(0).strip()
            chapters.append(
                {
                    "title": title,
                    "start": round(segment.start, 2),
                    "reason": "matched transcript marker",
                    "source_chunk": 0,
                }
            )
            break

    return dedupe_chapters(chapters, tolerance_seconds=45)


def write_outputs(output_stem: Path, chapters: list[dict[str, Any]], total_duration: float) -> None:
    json_path = output_stem.with_suffix(".chapters.json")
    csv_path = output_stem.with_suffix(".chapters.csv")
    txt_path = output_stem.with_suffix(".chapters.txt")

    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(
            {
                "format": "m4b-forge-chapters",
                "chapter_count": len(chapters),
                "duration": round(total_duration, 2),
                "duration_timestamp": timestamp(total_duration),
                "chapters": chapters,
            },
            handle,
            ensure_ascii=False,
            indent=2,
        )

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["title", "start", "timestamp", "reason", "source_chunk"])
        writer.writeheader()
        for chapter in chapters:
            writer.writerow({**chapter, "timestamp": timestamp(float(chapter["start"]))})

    with txt_path.open("w", encoding="utf-8") as handle:
        for chapter in chapters:
            handle.write(f"[{timestamp(float(chapter['start']))}] {chapter['title']}\n")

    print(f"wrote {json_path}")
    print(f"wrote {csv_path}")
    print(f"wrote {txt_path}")
    print(f"chapter_count: {len(chapters)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract audiobook chapter candidates from Whisper JSON via Ollama.")
    parser.add_argument("whisper_json", type=Path)
    parser.add_argument("--model", default="qwen3.5:9b")
    parser.add_argument("--output-stem", type=Path, default=Path("audiobook"))
    parser.add_argument("--work-dir", type=Path, default=Path("chapter_work"))
    parser.add_argument("--chunk-minutes", type=float, default=8)
    parser.add_argument("--overlap-minutes", type=float, default=1)
    parser.add_argument("--mode", choices=["sections", "dates", "dense"], default="dates")
    parser.add_argument("--num-ctx", type=int, default=8192)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--max-chunks", type=int, default=0, help="Debug limit; 0 means all chunks.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-llm", action="store_true", help="Use deterministic transcript patterns only.")
    parser.add_argument("--heuristic-first", action="store_true", help="Seed output with deterministic transcript pattern matches before LLM chunks.")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--dedupe-seconds", type=float, default=45)
    parser.add_argument("--add-prologue", action="store_true", help="Insert a Prologue chapter at 00:00:00 when no chapter starts there.")
    parser.add_argument("--prologue-title", default="Prologue")
    parser.add_argument("--epilogue-start", type=float, default=None, help="Optional epilogue start time in seconds.")
    parser.add_argument(
        "--epilogue-marker",
        action="append",
        default=["what follows now is an epilogue"],
        help="Transcript phrase that marks the epilogue start. Can be repeated. Use --no-auto-epilogue-marker to disable defaults.",
    )
    parser.add_argument("--no-auto-epilogue-marker", action="store_true", help="Disable automatic epilogue marker phrase detection.")
    parser.add_argument("--epilogue-title", default="Epilogue")
    args = parser.parse_args()

    started = time.time()
    args.work_dir.mkdir(parents=True, exist_ok=True)

    segments = load_segments(args.whisper_json)
    chunks = build_chunks(segments, args.chunk_minutes, args.overlap_minutes)
    if args.max_chunks:
        chunks = chunks[: args.max_chunks]

    total_duration = segments[-1].end
    print(f"input: {args.whisper_json}")
    print(f"duration: {timestamp(total_duration)} | segments: {len(segments)} | chunks: {len(chunks)}")
    print(f"model: {args.model} | mode: {args.mode} | work dir: {args.work_dir}")

    epilogue_start = args.epilogue_start
    epilogue_reason = "manual bookend"
    if epilogue_start is None and not args.no_auto_epilogue_marker:
        marker_match = find_marker_start(segments, args.epilogue_marker)
        if marker_match is not None:
            epilogue_start, marker = marker_match
            epilogue_reason = f"matched epilogue marker: {marker}"
            print(f"epilogue marker: {timestamp(epilogue_start)} | {marker}")

    all_chapters: list[dict[str, Any]] = []

    if args.no_llm or args.heuristic_first:
        heuristic = heuristic_chapters(segments, args.mode)
        print(f"heuristic: {len(heuristic)} chapter candidates")
        all_chapters.extend(heuristic)
        if args.no_llm:
            chapters = dedupe_chapters(all_chapters, args.dedupe_seconds)
            chapters = add_bookends(chapters, total_duration, args.add_prologue, args.prologue_title, epilogue_start, args.epilogue_title, epilogue_reason)
            write_outputs(args.output_stem, chapters, total_duration)
            print(f"done: {len(chapters)} chapters | elapsed {timestamp(time.time() - started)}")
            return 0

    for position, chunk in enumerate(chunks, start=1):
        chunk_prefix = args.work_dir / f"chunk_{chunk.index:03d}"
        prompt_path = chunk_prefix.with_suffix(".prompt.txt")
        raw_path = chunk_prefix.with_suffix(".raw.txt")
        parsed_path = chunk_prefix.with_suffix(".chapters.json")
        error_path = chunk_prefix.with_suffix(".error.txt")

        progress = chunk.core_start / max(total_duration, 1) * 100
        elapsed = time.time() - started
        eta = elapsed / max(position - 1, 1) * (len(chunks) - position + 1) if position > 1 else 0
        print(
            f"[{progress:5.1f}%] chunk {position}/{len(chunks)} "
            f"{timestamp(chunk.core_start)}-{timestamp(chunk.core_end)} "
            f"segments={len(chunk.segments)} eta={timestamp(eta)}",
            flush=True,
        )

        if parsed_path.exists() and not args.overwrite:
            parsed = json.loads(parsed_path.read_text(encoding="utf-8"))
            chapters = parsed.get("chapters", [])
            print(f"  resume: {len(chapters)} chapters from checkpoint")
            all_chapters.extend(chapters)
            continue

        prompt = build_prompt(chunk, args.mode)
        prompt_path.write_text(prompt, encoding="utf-8")

        if args.dry_run:
            print(f"  dry run: wrote {prompt_path}")
            continue

        try:
            raw = call_ollama(args.model, prompt, args.num_ctx, args.timeout)
            raw_path.write_text(raw, encoding="utf-8")
            parsed = extract_json_object(raw)
            chapters = normalize_chapters(parsed, chunk)
            parsed_path.write_text(json.dumps({"chapters": chapters}, ensure_ascii=False, indent=2), encoding="utf-8")
            if error_path.exists():
                error_path.unlink()
            print(f"  ok: {len(chapters)} chapter candidates")
            all_chapters.extend(chapters)
        except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError) as error:
            error_path.write_text(str(error), encoding="utf-8")
            print(f"  error: {error} (saved {error_path})", file=sys.stderr)

    chapters = dedupe_chapters(all_chapters, args.dedupe_seconds)
    chapters = add_bookends(chapters, total_duration, args.add_prologue, args.prologue_title, epilogue_start, args.epilogue_title, epilogue_reason)
    write_outputs(args.output_stem, chapters, total_duration)
    print(f"done: {len(chapters)} chapters | elapsed {timestamp(time.time() - started)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
