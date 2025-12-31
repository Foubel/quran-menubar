#!/usr/bin/env python3
"""Download the 114 Mishary Rashid Al-Afasy surahs as MP3 into Resources/Audio.

The script scrapes https://quranicaudio.com/quran/5 to discover the current
download URLs served by QuranicAudio. This avoids relying on hard-coded
endpoints that occasionally change naming conventions.
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from urllib import request, error

RECITER_PAGE = "https://quranicaudio.com/quran/5"
RETRY_LIMIT = 3
CHUNK_SIZE = 1 << 15  # 32 KiB

ROOT = Path(__file__).resolve().parents[1]
SURAH_LIST = ROOT / "QuranMenubar" / "Sources" / "SurahList.json"
AUDIO_DIR = ROOT / "QuranMenubar" / "Resources" / "Audio"


def load_surahs() -> list[dict]:
    data = json.loads(SURAH_LIST.read_text(encoding="utf-8"))
    surahs = []
    for entry in data:
        number = int(entry["number"])
        filename = entry["audioFile"]
        surahs.append({"number": number, "filename": filename})
    return surahs


def download_file(url: str, destination: Path) -> None:
    for attempt in range(1, RETRY_LIMIT + 1):
        try:
            req = request.Request(url, headers={
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            })
            with request.urlopen(req) as response, destination.open("wb") as fh:
                if response.status != 200:
                    raise RuntimeError(f"HTTP {response.status}")
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    fh.write(chunk)
            return
        except (error.URLError, error.HTTPError, RuntimeError) as exc:
            if destination.exists():
                destination.unlink(missing_ok=True)
            if attempt == RETRY_LIMIT:
                raise RuntimeError(f"Failed to download {url}: {exc}") from exc
            sleep_seconds = 2 * attempt
            print(
                f"Retry {attempt}/{RETRY_LIMIT} for {url} after error: {exc}. "
                f"Waiting {sleep_seconds}s…",
                file=sys.stderr,
            )
            time.sleep(sleep_seconds)


def discover_urls() -> dict[int, str]:
    req = request.Request(RECITER_PAGE, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    })
    with request.urlopen(req) as response:
        html = response.read().decode("utf-8", errors="replace")

    pattern = re.compile(r"https://[^\"']+?/([0-9]{3})\.mp3")
    urls = {}
    for match in pattern.finditer(html):
        num = int(match.group(1))
        urls[num] = match.group(0)

    if len(urls) < 114:
        raise RuntimeError(
            f"Expected at least 114 MP3 links on the reciter page; found {len(urls)}."
        )
    return urls


def main() -> int:
    surahs = load_surahs()
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)

    try:
        url_map = discover_urls()
    except Exception as exc:  # pragma: no cover - network path
        print(f"Unable to discover MP3 URLs: {exc}", file=sys.stderr)
        return 1

    missing = [entry for entry in surahs if not (AUDIO_DIR / entry["filename"]).exists()]
    if not missing:
        print("All surah files already present. Nothing to download.")
        return 0

    total = len(missing)
    print(f"Downloading {total} surah MP3 files to {AUDIO_DIR}…")

    for index, entry in enumerate(missing, start=1):
        number = entry["number"]
        filename = entry["filename"]
        try:
            url = url_map[number]
        except KeyError:
            print(f"No download URL discovered for surah {number:03d}; skipping.", file=sys.stderr)
            return 1
        destination = AUDIO_DIR / filename
        print(f"[{index}/{total}] {filename} ← {url}")
        try:
            download_file(url, destination)
        except RuntimeError as exc:
            print(f"Error downloading {filename}: {exc}", file=sys.stderr)
            return 1

    print("Download completed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
