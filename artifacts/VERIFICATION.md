# Fetch verification

Verified on 14 October 2026 using an Apple Silicon Mac running macOS 27.0.1. No unresolved application errors were observed in the checks below. This is evidence for tested flows, not a guarantee against every possible bug or future source-host change.

## Automated checks

Evidence filenames below refer to local verification logs. Raw logs are excluded from GitHub to keep machine paths and runtime details private. The test scripts are included so checks can be repeated.

| Check | Result | Evidence |
| --- | --- | --- |
| Native Swift build | Passed, arm64 | `bundle.log` |
| Swift model, validation, lifecycle permissions, filtering/sorting, formatting, file containment, atomic export, YouTube metadata and theme contrast | **11 passed, 0 failed** | `swift-tests.log` |
| Original engine/API tests plus independent YouTube format/resolution tests | **17 passed, 0 failed** | `final-checks.log` |
| Packaged native Swift client and authenticated service | Passed | `native-integration.log` |
| Real YouTube pause/resume, MP4 video/audio and 360p resolution cap | Passed | `live-media.log` |
| Real YouTube MP3 extraction/conversion | Passed | `live-media.log` |
| Bundled M4A, FLAC, WAV and Opus audio encoders | Passed | `live-media.log` |
| Production npm audit | **0 reported vulnerabilities** | `npm-audit.json` |
| Bundle architecture, dylib relocation and code signature | Passed | `bundle-audit.txt` |
| Installer disk image | Created and checksum-verified | `dmg.log` |
| Transfers directly from the read-only installer image | All packaged integration checks passed; mounted app signature verified; image detached | `installer-integration.log` |

The segmented HTTP tests compare full downloaded bytes with deterministic source bytes. They exercise multiple range connections, no-range fallback, redirects, tiny files, pause/resume, queue concurrency, cancellation/retry, HTTP failures, truncated responses, safe history removal, persistence and restart recovery. BitTorrent upload, magnet metadata and remote torrent URL tests use an actual peer and tracker with verified payload hashes.

The packaged integration uses the actual Swift client and bundled engines. It verifies bootstrap, settings, pause, service shutdown/restart, resumption, byte integrity, torrent upload, magnets and history removal. Separate API checks reject missing/wrong session tokens, absent CSRF keys, hostile origins, rebinding Host headers and malformed JSON; health and missing-endpoint responses are also checked.

Live media tests use the public Blender Big Buck Bunny video. The bundled ffprobe confirms video/audio streams, resolution and the MP3 codec. All additional audio-format outputs are encoded with the bundled FFmpeg and inspected with ffprobe. Video format/resolution selector combinations are unit-tested; every quality/container combination is not separately downloaded from YouTube.

## Native UI checks

The app was launched and operated through its actual macOS interface in isolated temporary storage:

- Light and dark appearances; final semantic supporting/error text meets at least 4.5:1 on native content/window surfaces in both appearances.
- Empty-link validation, real direct-file download, progress and completed-file details.
- Command-N, Command-F, Command-comma and Option-Command-I.
- Search with no results, reset, source category filtering and completed-state filtering; sort choices are present and ordering is unit-tested.
- YouTube detection, independent resolution/container controls and the five audio format choices.
- Native torrent file picker, import and a real torrent transfer.
- Settings save, speed limit, all three engine-readiness rows.
- Retry after a controlled connection failure, pause through the Downloads menu, cancellation and confirmation before history removal.
- Native Save Copy, including the final background-copy implementation. Both copies exactly matched the 25,165,824-byte original.
- Show in Finder selected the correct downloaded file in its transfer directory.
- Quit paused unfinished transfers and saved history. Reopening a closed main window worked.
- Final production startup uses ordinary Application Support/Downloads storage and follows the Mac's appearance, without the test theme overrides.

An intentional HTTP 404 fixture verified the error/retry layout without an application crash. Published screenshots show the actual app, including a controlled test transfer in light mode. The original DL Manager project's source and saved data were not changed.

## Fixes made during verification

- Replaced the toolbar's SwiftUI text field with NSSearchField to make Command-F focus reliably.
- Gave transfer rows explicit state-appropriate height to prevent clipping when status changes.
- Wrapped inspector values and keyed its identity to the selected transfer.
- Increased supporting/error text contrast using dynamic semantic colors, with light/dark tests.
- Moved file export off the main thread, staged before replacement and waited for copies during quit.
- Preserved audio/video/quality/container metadata in native decoding and used the correct audio glyph.
- Fixed the controlled HTTP fixture's interval cleanup so it never writes after response completion.

## Practical limits

This self-contained bundle requires **Apple Silicon and macOS 27+**, matching the actual minimum deployment targets of the bundled engines. Earlier macOS versions were not tested or claimed. Source code targets macOS 14; supporting earlier systems requires compatible engine/library builds.

The app is locally ad-hoc signed and verified. It has no Developer ID signature or Apple notarization. This repository publishes source, artwork and screenshots. Prebuilt engine bundles are not included.

External hosts can deny requests, change formats, require authentication or restrict automation. Network restrictions, file moves, disk-full conditions and source availability can still produce recoverable transfer errors. No test can prove that every future URL or every possible system state is bug-free.
