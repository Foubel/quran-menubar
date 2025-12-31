# Quran Menubar

A minimal macOS menu‑bar app to listen to the Quran with multiple reciters. The UI follows macOS conventions and keeps controls compact and fast.

## Features

- **Menubar‑only**: no Dock presence, no main window.
- **Multiple reciters**: choose from an online catalog of imams/reciters.
- **On‑demand downloads**: a surah is fetched when you play it, then cached locally.
- **Offline playback**: once cached, it plays without internet.
- **Quick controls**: searchable surah list, play/pause, previous/next, and a seek slider with remaining time.
- **Global hotkeys**:
  - `⌥⌘P` : Play/Pause
  - `⌥⌘→` : Next Surah
  - `⌥⌘←` : Previous Surah
- **Smart resume**: remembers last surah and playback position.
- **macOS integration**: media center controls, global hotkeys, light/dark adaptation.

## Installation

### Option 1 — GitHub Releases (recommended)

1. Go to the repository **Releases** page.
2. Download the latest `.zip` or `.dmg`.
3. Drag `QuranMenubar.app` into **Applications**.
4. Open the app. If macOS blocks it (unsigned app), go to **System Settings → Privacy & Security** and click **Open Anyway**.

> Note: The app is not notarized (Apple Developer account required), so macOS will show a Gatekeeper warning. This is expected.

### Option 2 — Build from source

1. Open `QuranMenubar/` in Xcode.
2. Select the **QuranMenubar** target (macOS 13+).
3. Build & Run (`⌘R`).

> The app is marked as `LSUIElement` in `Info.plist`, so it won’t appear in the Dock. Use the menu bar icon.

## Usage

1. Choose a **reciter** from the dropdown.
2. Play a surah: the audio downloads if needed.
3. (Optional) **Download all (this reciter)** caches all 114 surahs for the selected reciter.
4. (Optional) **Clear cache** removes all downloaded surahs for the current reciter.
5. (Optional) **Clear all cache** removes all downloaded surahs for all reciters.

## Data & storage

- Audio files are downloaded and cached in:
  `~/Library/Application Support/QuranMenubar/Audio/<reciter>/`
- Cache stays local. No personal data is sent.
- Reciter list and MP3 files are provided by QuranicAudio.
- The app shows cache size for the current reciter and the total cache size.

## Manual checks

- Switch reciters and verify playback and downloads.
- Disconnect internet after downloading and confirm offline playback.
- Verify global hotkeys while the popover is closed.

## Project structure

```
QuranMenubar/
├── Info.plist
├── Sources/
│   ├── Assets.xcassets/
│   ├── MenuController.swift
│   ├── QuranMenubarApp.swift
│   ├── QuranPlayer.swift
│   └── SurahList.json
└── SPECIFICATIONS.md
```
