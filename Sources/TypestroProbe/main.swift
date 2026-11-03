import Foundation
import TypestroCore

// Runs Typestro's review prompt on sample text at each level and prints what Claude would underline, with timings.
//   swift run typestro-probe [model]
// Uses ANTHROPIC_API_KEY, or the key saved in Typestro's keychain entry.

guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Keychain.read() else {
    print("Set ANTHROPIC_API_KEY, or save a key from Typestro's menu first.")
    exit(1)
}
let model = CommandLine.arguments.dropFirst().first ?? "claude-haiku-5-5"
let client = ClaudeClient(apiKey: key, model: model)
print("Model: \(model)\n")

let samples = [
    "I don't want to decide anything under these sirkumstanses. Can you rekamend a good place for dinner⟦cursor⟧",
    "I need to by a new car before their done with the sale. Its going to be a fenominal quarter if we stay focused.⟦cursor⟧",
    "I'm gonna grab lunch w ur brother lol. Ping Moglia about the Q3 deck.⟦cursor⟧",
    "Hey Sam, thanks for sending the proposal over. I read through it last night and honestly I think the the timeline is not realistic and you need to fix it before we can even talk about budget. Let me know when its ready. I can be their at noon if⟦cursor⟧",
]

for level in Intensity.allCases {
    print("== \(level.title)")
    for text in samples {
        let start = Date()
        do {
            let result = try await client.structured(
                ReviewResult.self,
                system: Prompts.reviewSystem(intensity: level, avoid: [], fixCapitals: true),
                user: Prompts.reviewUser(app: "Messages", text: text),
                schema: Prompts.reviewSchema, timeout: 30)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[\(ms) ms] \(text.replacingOccurrences(of: Prompts.cursor, with: "|"))")
            if result.suggestions.isEmpty { print("  nothing") }
            for s in result.suggestions {
                print("  \(s.kind): \"\(s.original)\" → \(s.replacements.map { "\"\($0)\"" }.joined(separator: " / "))  (\(s.reason))")
            }
        } catch {
            print("error: \(error)")
        }
        print()
    }
}
