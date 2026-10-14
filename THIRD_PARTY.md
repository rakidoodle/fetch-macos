# Third-party components

This local build preserves the download engine from the owner's DL Manager project. It bundles Node.js (MIT and included third-party notices), Express (MIT; LICENSE files in node_modules), aria2 (GPLv2 or later), yt-dlp (Unlicense, with additional licenses in the standalone binary), and FFmpeg/ffprobe (LGPL/GPL according to build configuration). The generated app contains full primary license texts under Contents/Resources/Licenses and a runtime manifest with exact binary versions, checksums and copied dylib origins.

Corresponding engine source and build instructions:

- Node: https://github.com/nodejs/node and https://nodejs.org/en/download
- aria2: https://github.com/aria2/aria2
- yt-dlp: https://github.com/yt-dlp/yt-dlp/releases (the checksum-verified macOS standalone artifact)
- FFmpeg: https://ffmpeg.org/download.html and https://github.com/FFmpeg/FFmpeg
- Homebrew source recipes and patches for the bundled aria2/FFmpeg dependencies: https://github.com/Homebrew/homebrew-core/tree/main/Formula

This repository publishes Fetch's source, artwork and build tools. Download-engine executables and library binaries are not checked into Git. The v1.0.0 GitHub release includes the DMG and a companion engine-source archive with versioned upstream sources, Homebrew build recipes and patches. Fetch's application source is available from the release tag. The bundled engines run as separate processes; their source code has not been modified. Library install names are relocated and binaries are ad-hoc signed for the app bundle.

Primary component license texts are included in the app under Contents/Resources/Licenses. Source archives retain upstream notices. The release's SHA256SUMS.txt lists asset checksums. The bundle script does not add DRM or restrictions on these components. Future redistributions must retain applicable notices and provide corresponding source for the exact component builds.
