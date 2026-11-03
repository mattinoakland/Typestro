# Typestro

A menu-bar app that helps you write better in any Mac app. It never changes what you type on its own: it underlines
what could be better, and you decide.

- **Underlines, by context.** When you pause, or soon after you finish a sentence, Claude reads what you've written and
  underlines it in Typestro's own violet, distinct from the app's spellcheck:
  - a **wave** under a misspelled or wrong word: phonetic spellings ("sirkumstanses"), sound-alikes (their/there,
    by/buy), and real words that don't fit ("piecing the right word");
  - a **dashed line** under a sentence that could read better (Medium and Full). These only appear once you've
    finished the sentence and moved on.
- **Three levels**, under **Suggestions** in the menu. **Light**: spelling and wrong words. **Medium**: adds grammar and
  clarity. **Full**: adds tightening and flow.
- **Preview before you accept.** Hover over or click an underline for a small card showing the change: removed words
  struck through, new words highlighted. **Accept** or **Skip**, and step through alternatives when Claude offers more
  than one. From the keyboard, **Tab** opens the nearest card, **Tab** again accepts, **Esc** skips, **← →** step
  through alternatives.
- **Accept all, undo all.** **⌃⌥A** accepts every suggestion showing in one go. **⌃⌥Z** undoes the last accept,
  a whole batch at once. Before changing anything Typestro re-reads the text, and skips any suggestion whose words
  have changed since. While it edits, keys you press wait and land right after.
- **Where an app won't say where its words are**, the suggestions appear as a small list by the text box instead of
  underlines. Underlines hide while you scroll and come back once the page stops.
- **It learns.** Skip a word suggestion and Typestro stops flagging that word. Skip any suggestion and Claude is told
  to skip ones like it.
- **Dictation.** Hold **Right Option**, talk, let go. OpenAI's GPT Transcribe turns it into text, Claude tidies it to fit
  what's already in the box (punctuation, filler words, "no wait, I mean…"), and it's typed at your cursor. Esc cancels.
  No text box focused? It goes to the clipboard. The hotkey and an optional mic button inside text boxes are under
  **Dictation** in the menu. Needs an OpenAI API key and microphone access.

Typestro never touches password fields, and it's off by default in terminals, code editors and password managers.
You can turn it off per app from the menu. It can also switch off macOS's own autocorrect, capitalization,
predictive text and red spelling underlines while it runs (it asks first, and puts them back when you pause or quit
it); then Claude handles capitalization too. Apps already open may need reopening. Chrome and apps built on it
(Slack, Discord, Claude) keep their own spell-check setting under **Edit → Spelling and Grammar**, which Typestro
leaves alone.

- macOS 14 or later, Apple Silicon or Intel.
- Menu bar only (no Dock icon). Optional launch at login.
- Bring your own keys: a Claude API key for fixes and suggestions, an OpenAI API key for dictation.
  Both are stored in the keychain.

## Download

Releases will be at https://mattmoglia.com/typestro and on this repo's Releases page. Drag `Typestro.app` to
Applications and open it. Releases are signed with a Developer ID and notarized by Apple, so there's no
"unidentified developer" step.

On first launch macOS asks for **Accessibility** (to read and fix the text box you're typing in) and, the first time
you dictate, the **Microphone**. Then add your Claude key (and OpenAI key for dictation) from the menu.

## Build and run

Requires Xcode (command line tools are enough for `swift build`).

```bash
make run
```

That builds a universal `build/Typestro.app`, signs it with your Developer ID (so macOS keeps its Accessibility
and Microphone permissions across rebuilds), and opens it. A sparkles icon appears in the menu bar.

To keep it around permanently:

```bash
make install
```

This copies it to `/Applications` and launches it from there. Launch at login works most reliably from `/Applications`.

Other targets: `make stop`, `make uninstall`, `make clean`, `make test`, `make probe` (runs the review prompt on sample
text at each level and prints what Claude would underline, with timings), `make logs`, `make dist` (a zip to hand someone).

## Menu

Pause (turns off suggestions and dictation), Suggestions (Suggest While Typing on or off, which keeps dictation working;
Light / Medium / Full; Accept All; Undo Last Accept), Let Typestro Handle Autocorrect, turn off in the current app, Claude model (Haiku 5.5 default, for speed and cost), Claude API key, Dictation (hotkey, mic button,
OpenAI API key), Open at Login, Forget Learned Preferences, Send Anonymous Usage Stats, Send Feedback, Website,
Buy Me a Coffee. When a newer version is out, a download link appears at the top.

## Privacy

When you pause or finish a sentence, up to a few thousand characters around your cursor are sent to the Claude API
(Anthropic), along with the app's name, and only if the text has changed since the last check. Without a Claude key,
Typestro does nothing.

Dictation records only while the key is held (or until you click the mic again), sends the audio to OpenAI, and
deletes the recording once it's typed.

Typestro also sends one small anonymous ping when it starts and once a day: a random install ID, the app version,
the macOS version, the CPU type, and the Mac's region setting (a two-letter country code). That's how Matt knows
roughly how many people use it, and how the app learns a newer version exists. Nothing you type or say is part of
it, ever. Turn off **Send Anonymous Usage Stats** in the menu to stop the ping; the update check then runs without
an install ID.

## Releasing (for Matt)

One-time setup is the same as AudioPin's, and already done: the **Developer ID Application** certificate is in the
keychain, and the notary credentials saved as the `AudioPin` profile work for every app on the same Apple ID.
(Set `NOTARY_PROFILE` to use a different one.) The repo needs a GitHub remote for `release.sh` to push to.

Every release is one command:

```bash
make release VERSION=1.0 NOTES="What changed"
```

It stamps the version, builds a universal app, signs it with the Developer ID and hardened runtime, sends it to
Apple for notarization (a few minutes), staples the ticket, zips it, tags the commit, and publishes a GitHub release
with the zip attached. The download page and the in-app update notice read the latest GitHub release through
mattmoglia.com/api/typestro.

## Code

- `Sources/TypestroCore`: text handling, prompts, the Claude and OpenAI clients, keychain (tested in `Tests/`).
- `Sources/Typestro`: key tap, reading and editing the focused field through Accessibility, overlays, dictation,
  macOS autocorrect switch, telemetry, menu.
- `Resources/`: Info.plist, entitlements, icon (`swift scripts/make-icon.swift` redraws it).
- `Sources/TypestroProbe`: the `make probe` tool.
