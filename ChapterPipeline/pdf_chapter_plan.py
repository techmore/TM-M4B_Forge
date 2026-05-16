#!/usr/bin/env python3
"""
Build M4B Forge chapters from a reference PDF and a Whisper JSON transcript.

Use this when a PDF or ebook has the correct chapter structure. The script
extracts Chapter headings from the PDF, finds their first dated/textual line,
then aligns those starts to timestamps in the Whisper transcript.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any


MONTHS = {
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
}


@dataclass
class PdfChapter:
    index: int
    heading: str
    first_line: str
    date_key: str | None
    date_parts: tuple[str, str, str | None] | None


@dataclass
class TranscriptSegment:
    start: float
    end: float
    text: str
    normalized: str


def timestamp(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    return str(timedelta(seconds=seconds))


def normalize(text: str) -> str:
    text = text.lower()
    text = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", text)
    text = re.sub(r"([a-z]+)(\d)", r"\1 \2", text)
    text = re.sub(r"(\d)([a-z]+)", r"\1 \2", text)
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def roman_to_int(raw: str) -> int | None:
    value = raw.upper().replace("L", "I")
    if value.isdigit():
        return int(value)
    numerals = {"I": 1, "V": 5, "X": 10, "C": 100, "D": 500, "M": 1000}
    total = 0
    previous = 0
    for character in reversed(value):
        current = numerals.get(character)
        if current is None:
            return None
        if current < previous:
            total -= current
        else:
            total += current
            previous = current
    return total or None


def run_pdftotext(pdf_path: Path) -> str:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    with tempfile.NamedTemporaryFile(suffix=".txt") as output:
        subprocess.run(["pdftotext", "-layout", str(pdf_path), output.name], check=True)
        return Path(output.name).read_text(encoding="utf-8", errors="ignore")


def extract_date(line: str) -> tuple[str, tuple[str, str, str | None]] | tuple[None, None]:
    match = re.search(
        r"\b("
        + "|".join(month.capitalize() for month in MONTHS)
        + r")\s*(\d{1,2})(?:st|nd|rd|th)?(?:,\s*(\d{4}))?",
        line,
        flags=re.IGNORECASE,
    )
    if not match:
        return None, None

    month, day, year = match.groups()
    parts = [month, str(int(day))]
    if year:
        parts.append(year)
    return normalize(" ".join(parts)), (normalize(month), str(int(day)), year)


def extract_pdf_chapters(pdf_text: str) -> list[PdfChapter]:
    pattern = re.compile(r"(?m)^\s*Chapter\s+([0-9IVXLCDMl]+)\s*$")
    matches = list(pattern.finditer(pdf_text))
    chapters: list[PdfChapter] = []

    for fallback_index, match in enumerate(matches, start=1):
        index = roman_to_int(match.group(1)) or fallback_index
        body_end = matches[fallback_index].start() if fallback_index < len(matches) else len(pdf_text)
        body = pdf_text[match.end() : body_end]
        lines = [line.strip() for line in body.splitlines() if line.strip()]
        first_line = lines[0] if lines else ""
        date_key, date_parts = extract_date(first_line)
        chapters.append(
            PdfChapter(
                index=index,
                heading=f"Chapter {index}",
                first_line=first_line,
                date_key=date_key,
                date_parts=date_parts,
            )
        )

    return sorted(chapters, key=lambda chapter: chapter.index)


def load_segments(path: Path) -> list[TranscriptSegment]:
    data = json.loads(path.read_text(encoding="utf-8"))
    segments: list[TranscriptSegment] = []
    for raw in data.get("segments", []):
        text = str(raw.get("text", "")).strip()
        if not text:
            continue
        start = float(raw["start"])
        end = float(raw["end"])
        segments.append(TranscriptSegment(start=start, end=end, text=text, normalized=normalize(text)))
    if not segments:
        raise ValueError("Whisper JSON does not contain usable timestamped segments.")
    return segments


def find_epilogue(segments: list[TranscriptSegment], markers: list[str]) -> tuple[float, str] | None:
    normalized_markers = [normalize(marker) for marker in markers if marker.strip()]
    for segment in segments:
        for marker in normalized_markers:
            if marker and marker in segment.normalized:
                return segment.start, marker
    return None


def find_chapter_start(chapter: PdfChapter, segments: list[TranscriptSegment], after: float) -> tuple[float, str]:
    candidates: list[tuple[float, str]] = []

    if chapter.date_key:
        for index, segment in enumerate(segments):
            if segment.start <= after:
                continue
            combined = " ".join(item.normalized for item in segments[index : index + 3])
            if chapter.date_key in combined:
                candidates.append((segment.start, f"matched PDF date marker: {chapter.date_key}"))
                break
            if chapter.date_parts:
                month, day, year = chapter.date_parts
                if month in combined and day in combined and (year is None or year in combined):
                    candidates.append((segment.start, f"matched PDF date parts: {chapter.date_key}"))
                    break
                if month in combined and day in combined:
                    candidates.append((segment.start, f"matched PDF month/day marker: {month} {day}"))
                    break

    first_line_key = normalize(" ".join(chapter.first_line.split()[:10]))
    if first_line_key:
        for segment in segments:
            if segment.start <= after:
                continue
            if first_line_key[:40] in segment.normalized:
                candidates.append((segment.start, "matched PDF opening line"))
                break

    if not candidates:
        raise ValueError(f"Could not align {chapter.heading}: {chapter.first_line}")

    return candidates[0]


def write_outputs(output_stem: Path, chapters: list[dict[str, Any]], duration: float) -> None:
    json_path = Path(f"{output_stem}.chapters.json")
    csv_path = Path(f"{output_stem}.chapters.csv")
    txt_path = Path(f"{output_stem}.chapters.txt")

    payload = {
        "format": "m4b-forge-chapters",
        "source": "pdf-guided",
        "chapter_count": len(chapters),
        "duration": round(duration, 2),
        "duration_timestamp": timestamp(duration),
        "chapters": chapters,
    }
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["title", "start", "timestamp", "reason", "source"])
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
    parser = argparse.ArgumentParser(description="Create M4B Forge chapters by aligning PDF chapter headings to a Whisper transcript.")
    parser.add_argument("pdf", type=Path)
    parser.add_argument("whisper_json", type=Path)
    parser.add_argument("--output-stem", type=Path, default=Path("audiobook_pdf_guided"))
    parser.add_argument("--opening-title", default="Prologue")
    parser.add_argument("--chapter-prefix", default="Chapter")
    parser.add_argument("--epilogue-title", default="Epilogue")
    parser.add_argument("--epilogue-marker", action="append", default=["what follows now is an epilogue"])
    args = parser.parse_args()

    pdf_text = run_pdftotext(args.pdf)
    pdf_chapters = extract_pdf_chapters(pdf_text)
    segments = load_segments(args.whisper_json)
    duration = segments[-1].end

    print(f"pdf chapters: {len(pdf_chapters)}")
    print(f"duration: {timestamp(duration)} | segments: {len(segments)}")

    chapters: list[dict[str, Any]] = [
        {
            "title": args.opening_title,
            "start": 0.0,
            "reason": "opening bookend before first PDF chapter",
            "source": "pdf-guided",
        }
    ]

    after = 1.0
    for pdf_chapter in pdf_chapters:
        start, reason = find_chapter_start(pdf_chapter, segments, after)
        title = f"{args.chapter_prefix} {pdf_chapter.index}"
        chapters.append(
            {
                "title": title,
                "start": round(start, 2),
                "reason": reason,
                "source": "pdf-guided",
            }
        )
        after = start + 30
        print(f"{title}: {timestamp(start)} | {reason}")

    epilogue = find_epilogue(segments, args.epilogue_marker)
    if epilogue:
        start, marker = epilogue
        chapters.append(
            {
                "title": args.epilogue_title,
                "start": round(start, 2),
                "reason": f"matched epilogue marker: {marker}",
                "source": "pdf-guided",
            }
        )
        print(f"{args.epilogue_title}: {timestamp(start)} | marker")

    chapters = sorted(chapters, key=lambda chapter: float(chapter["start"]))
    write_outputs(args.output_stem, chapters, duration)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
