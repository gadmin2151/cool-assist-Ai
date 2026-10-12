# Cool Assist Ai Android 2.0.0

## Changes

- New name, shared C/checkmark icon, dark-gray canvas `#202123`, navigation `#191A1D`, panels `#2A2B2F` and primary red `#D60000`. Secondary controls use quiet neutral tones; red remains on the main action, logo and measured waveform.
- A listening screen shows measured microphone levels, elapsed audio time, pause/resume, finish and a timestamp bookmark. Paused audio never animates. Workspace transitions respect the Android animation preference.
- Summary timestamps open the corresponding full transcript. Task proposals still require an explicit tap to add them. Processing can be paused from a meeting's menu while its saved audio and results remain available.
- Audio segmentation prefers a 400 ms quiet gap after six seconds and caps chunks at fourteen seconds. Every PCM sample is preserved, including quiet speech; the last short chunk is finalized on pause/stop. This is an energy-based boundary heuristic, not speaker identification.
- New installations default to `gpt-4o-transcribe`; existing model choices are preserved. Settings offer accuracy/economy presets and a custom model field. Previous transcript text continues to guide subsequent fragments.
- Summary instructions preserve corrections, disagreements, tentative deadlines and open questions. Reduction batches may cite only sources actually supplied in that batch. Full chronological transcript remains in Markdown.
- Fixed a WorkManager continuation race that could strand more than thirty pending fragments on a paused recording.

## Upgrade and data

`applicationId` remains `cc.idomus.meetprotocol`; version code is 20. Use the original release signing key to upgrade the existing app. A new signing key cannot replace a previously installed version. Recordings, SQLite data and Android Keystore credentials keep their existing locations. No schema migration or key re-entry is required by this release.

The release APK contains no API key, signing keystore, personal recordings or meeting database. Audio remains in the private app directory and is sent to OpenAI only for requested processing with the user's saved API key. Android backup remains disabled. API billing is separate from a ChatGPT subscription.

## Validation

- 30 JVM tests passed: sample-accurate three-hour audio, segmentation, waveform pause, work scheduling, mocked HTTP retries/cancellation and summary source boundaries.
- 23 Android instrumentation cases confirmed on an isolated API 35 emulator. The workspace suite was rerun after correcting a confirmation message that could cover a meeting card during quick navigation; all seven workspace cases passed. Capture lifecycle, repository recovery/Keystore and listening controls passed separately.
- Debug/release lint completed without errors; remaining warnings concern dependency updates, explicit SharedPreferences writes and the adaptive-icon resource qualifier.
- The ARM64 graphics library uses 16 KB ELF load alignment. APK signing and zip alignment are checked by the release script.

The signed release APK installed and cold-launched successfully without an app crash. The final release screenshot was interrupted by a System UI ANR on the memory-constrained host; it is not clean visual acceptance of the release build. Clean UI screenshots and the interaction tests came from the debug build. The final dark-gray palette was applied afterward; that color-only update was rebuilt and checked with JVM tests and release lint, without repeating emulator tests.

No paid OpenAI requests or personal API credentials were used in these checks. The application does not promise error-free recognition: room acoustics, language, microphone placement and the selected model affect accuracy. This release does not add phone-call audio capture, screen capture, speaker identity recognition, or Mac synchronization. A local emulator test cannot establish Pixel 8 / Android 17 beta physical audio quality.
