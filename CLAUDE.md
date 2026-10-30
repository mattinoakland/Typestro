# Typestro

macOS menu bar app (Swift, SwiftUI/AppKit, no dependencies) that fixes typing in any app by context with Claude,
suggests edits on pause, and does hold-to-talk dictation (OpenAI GPT Transcribe + Claude cleanup). See README.md.

- Build: `make run` (SwiftPM + build.sh assembles a universal `build/Typestro.app`, Developer ID signed). `make install`
  puts it in /Applications. No .xcodeproj; open Package.swift in Xcode to edit.
- Local builds are signed with the Developer ID on purpose: Accessibility and Microphone permissions are tied to the
  signature, and ad-hoc builds lose them on every rebuild.
- `Resources/Info.plist` and `Resources/Typestro.entitlements` (microphone) are copied/applied by build.sh. `LSUIElement`
  makes it menu-bar only. Release: `make release VERSION=x NOTES="..."` (release.sh, notary profile `AudioPin`).
- Settings live in UserDefaults (domain `com.mattmoglia.typestro`); API keys in the keychain (service
  `com.mattmoglia.typestro`, accounts `anthropic-api-key` and `openai-api-key`).
- Never call `Keychain` from the app's main thread; go through `KeyStore`. The key tap runs on the main thread, so a
  keychain password prompt there freezes all typing, including in the prompt. Keys are read once in the background
  at launch, and the tap doesn't start until that finishes.
- Text fields are read and edited through Accessibility (FocusedField.swift). Web content (browsers, Electron apps)
  claims accessibility edits succeed without doing them, so edits there are typed as keystrokes (backspace + retype).
- Prompts are in `Sources/TypestroCore/Prompts.swift`; `make probe` runs them on sample sentences.
- The update check and usage ping go to `https://mattmoglia.com/api/typestro` (served by the portfolio repo, like
  AudioPin's `/api/audiopin`).
- Logs: `make logs`.
