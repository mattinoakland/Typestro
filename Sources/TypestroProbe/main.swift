import Foundation
import TypestroCore

// Runs Typestro's prompts against sample sentences and prints what Claude would change, with timings.
//   swift run typestro-probe [model]
// Uses ANTHROPIC_API_KEY, or the key saved in Typestro's keychain entry.

guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Keychain.read() else {
    print("Set ANTHROPIC_API_KEY, or save a key from Typestro's menu first.")
    exit(1)
}
let model = CommandLine.arguments.dropFirst().first ?? "claude-opus-5-5"
let client = ClaudeClient(apiKey: key, model: model)
print("Model: \(model)\n")

let spelling: [(earlier: String, focus: String)] = [
    ("", "I don't want to decide anything under these sirkumstanses "),
    ("", "Can you rekamend a good place for dinner "),
    ("", "I need to by a new car before their done with the sale."),
    ("Hey team,", "Its going to be a fenominal quarter if we stay focused."),
    ("", "We should meat at the libary around noon."),
    ("", "The resturant was definatly worth it."),
    ("", "I'm gonna grab lunch w ur brother lol."),
    ("", "Ping Moglia about the Q3 deck."),
    ("", "it's thinking for me and looking at the context and piecing the right word."),
    ("", "I can type fast without worrying about screwing up the words."),
]

for c in spelling {
    let start = Date()
    do {
        let result = try await client.structured(
            SpellingResult.self, system: Prompts.spellingSystem(fixCapitals: true),
            user: Prompts.spellingUser(app: "Messages", earlier: c.earlier, focus: c.focus),
            schema: Prompts.spellingSchema)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let fixes = result.corrections.map { "\($0.original) → \($0.replacement)\($0.certain ? "" : " (unsure)")" }
        print("[\(ms) ms] \(c.focus)\n         \(fixes.isEmpty ? "no change" : fixes.joined(separator: ", "))\n")
    } catch {
        print("error: \(error)\n")
    }
}

let drafts = [
    "Hey Sam, thanks for sending the proposal over. I read through it last night and honestly I think the the timeline is not realistic and you need to fix it before we can even talk about budget. Let me know when its ready.⟦cursor⟧",
    "Quick update on the move: we signed the lease yesterday and the movers are booked for the 14th, so the office will be closed that whole week.⟦cursor⟧",
]
for (level, text) in [(Intensity.full, drafts[0]), (.medium, drafts[1])] {
    let start = Date()
    do {
        let result = try await client.structured(
            SuggestionResult.self, system: Prompts.suggestionSystem(intensity: level, avoid: []),
            user: Prompts.suggestionUser(app: "Mail", text: text),
            schema: Prompts.suggestionSchema, timeout: 30)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[\(ms) ms] suggestions (\(level.rawValue)):")
        if result.suggestions.isEmpty { print("  none") }
        for s in result.suggestions { print("  \"\(s.original)\" → \"\(s.replacement)\"  (\(s.reason))") }
        print()
    } catch {
        print("error: \(error)\n")
    }
}
