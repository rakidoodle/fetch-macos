# Third-party components

This local build preserves the download engine from the owner's DL Manager project. It bundles Node.js (MIT and included third-party notices), Express (MIT; LICENSE files in node_modules), aria2 (GPLv2 or later), yt-dlp (Unlicense, with additional licenses in the standalone binary), and FFmpeg/ffprobe (LGPL/GPL according to build configuration). The generated app contains full primary license texts under Contents/Resources/Licenses and a runtime manifest with exact binary versions, checksums and copied dylib origins.

Corresponding engine source and build instructions:

- Node: https://github.com/nodejs/node and https://nodejs.org/en/download
- aria2: https://github.com/aria2/aria2
- yt-dlp: https://github.com/yt-dlp/yt-dlp/releases (the checksum-verified macOS standalone artifact)
- FFmpeg: https://ffmpeg.org/download.html and https://github.com/FFmpeg/FFmpeg
- Homebrew source recipes and patches for the bundled aria2/FFmpeg dependencies: https://github.com/Homebrew/homebrew-core/tree/main/Formula

This repository publishes Fetch's source, artwork and build tools. Download-engine executables and library binaries are not checked in. Before redistributing a built app, fulfill all corresponding-source and license obligations for the exact engine and library builds. The bundle script does not add DRM or restrictions on those components.
