# Fetch for macOS

**Paste a link. Choose what to save. Fetch brings it to your Mac.**

Fetch is a download helper for Apple Silicon Macs. It saves website files, YouTube videos or audio, and torrents in one place. Think of it as a small delivery desk: add your links, watch each delivery, and pause or continue when you need to.

Built with SwiftUI and AppKit, Fetch feels at home on macOS. Its appearance follows your Mac's light or dark mode and chosen accent color.

![Fetch running on macOS in dark mode, with its sidebar, search bar and new-download button](artifacts/macos-ready.png)

## What you can do

- **Save files:** paste an HTTP or HTTPS link. Fetch can download large files in several pieces when the website supports it.
- **Save YouTube media:** choose a video or just its audio. Pick the video quality and file type separately.
- **Download torrents:** paste a magnet or torrent link, or open a `.torrent` file.
- **Stay in control:** pause, resume, cancel or retry downloads. Search your list, filter it, and set a speed limit.
- **Find your files:** show finished downloads in Finder or save a copy somewhere else. Removing a history entry keeps the downloaded file.

Video formats: **MP4, WebM and MKV**. Audio formats: **MP3, M4A, FLAC, WAV and Opus**. Available video quality depends on the source.

## Get started

This repository contains the app's source, artwork, screenshots and build tools. To make your own app, follow [Build from source](#build-from-source).

The tested app bundle needs **an Apple Silicon Mac running macOS 27 or later**. The Swift source targets macOS 14, but the engines used in the tested bundle require macOS 27. Supporting earlier systems requires compatible engine and library builds.

After building:

1. Open `release/Fetch.app`, or copy it into Applications first.
2. Press **Command-N** and paste a link. For YouTube, choose video or audio and your preferred format.
3. Use **Show in Finder** when the download finishes.

The finished bundle includes Node, aria2, yt-dlp, FFmpeg and ffprobe. It can run without Homebrew, Python, Node or the source folder installed separately. Local builds are ad-hoc signed and signature-checked; they do not have an Apple Developer ID signature or notarization.

## A few useful shortcuts

| Shortcut | Action |
| --- | --- |
| Command-N | Add a download |
| Command-F | Search downloads |
| Command-comma | Open settings |
| Option-Command-I | Show or hide file details |
| Option-Command-P | Pause the selected download |
| Option-Command-R | Resume or retry the selected download |
| Shift-Command-O | Open the download folder |

Settings control the number of simultaneous downloads, connections and speed limit. A speed limit of zero means unlimited. Connection changes apply to new transfers. The global speed limit affects file and torrent transfers immediately, and new YouTube transfers.

Closing the window keeps downloads running. **Command-Q** saves your history and pauses unfinished work. Reopen Fetch and resume those downloads when ready. Save Copy runs in the background, and quitting waits for active copies to finish.

<details>
<summary>See Fetch in light mode</summary>

![Fetch in light mode, showing a completed test download and its status](artifacts/macos-light.png)

Screenshots show the real app. The light-mode download is a controlled test file, with no personal download history.

</details>

## Your files and privacy

Downloaded files stay in `~/Downloads/Fetch/<transfer-id>/`. Settings and history live in `~/Library/Application Support/Fetch/state.json`. Service diagnostics live in that folder's `logs/service.log`.

Fetch uses a private local service on `127.0.0.1` with a random port and a fresh session token each time. API requests need that token, and writes also require a CSRF key. Host, origin and file-containment checks protect the service.

Downloads connect to their source websites, YouTube or torrent peers. BitTorrent can upload pieces while downloading; completed transfers do not keep seeding. This desktop app has its own storage and does not import the original web app's history automatically.

Local download history, credentials, build output, runtime data and raw logs are excluded from this repository. Test fixtures use disposable data.

## Build from source

Build on Apple Silicon with macOS Command Line Tools, Python 3, Node, aria2 and FFmpeg/ffprobe installed. Network access is needed to fetch the official yt-dlp release and license files. The Node dependency versions are pinned in `backend/package-lock.json`.

```bash
git clone https://github.com/rakidoodle/fetch-macos.git
cd fetch-macos
cd backend
npm ci --omit=dev --ignore-scripts
cd ..
python3 scripts/bundle.py
```

The scripts default to the stable SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Set `FETCH_BUILD_SDK` to a compatible installed SDK when needed. The build was verified with Command Line Tools; the tested preview macOS 27 SDK lacked the SwiftUI macro plugin.

The packager copies the engines, relocates their non-system libraries, verifies yt-dlp's official SHA-256 checksum, and signs and checks the app. It determines the bundle's minimum macOS version from the actual engine binaries. A prior successful build is kept as `release/Fetch.previous.app` during rebuilding.

To create a local disk image after packaging:

```bash
bash scripts/make-dmg.sh
```

Review the exact bundled components' license and corresponding-source requirements before redistributing a binary. See [third-party notices](THIRD_PARTY.md).

## Tested behavior

**28 automated tests passed: 11 Swift tests and 17 engine/API tests.** Additional checks exercised the real macOS interface, exact downloaded bytes, torrents, pause/resume, restart recovery and live YouTube video/audio downloads. Light and dark text contrast, bundle signatures and the installer were checked too.

See the [verification report](artifacts/VERIFICATION.md) for tested flows and limits. These results describe the tested build; websites, network conditions and future tool versions can change behavior.

Run the checks **after packaging finishes**:

```bash
bash scripts/test.sh
```

The script uses Swift Testing from Command Line Tools and supplies its framework and plugin paths. To include the live YouTube checks:

```bash
FETCH_LIVE_TESTS=1 bash scripts/test.sh
```

Live checks use Blender's public Big Buck Bunny video and inspect the output with the bundled ffprobe.

## Credits

Fetch builds on the download engine from [Fetch Download Manager](https://github.com/rakidoodle/fetch-download-manager). Native interface decisions are in [DESIGN.md](DESIGN.md).

The app icon and empty-library illustration were generated with the built-in ImageGen tool. [Generation prompts](Assets/generation-prompts.json) are included. The iconset, `.icns` and favicons derive from the generated master; regenerating those exports requires Python with Pillow. Interface glyphs use SF Symbols.

The original support link is preserved: [Feed my Baby](https://www.paypal.com/paypalme/ruffytrinidad).
