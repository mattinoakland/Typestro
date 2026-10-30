import Foundation

/// Keeps the API keys in memory and is the only thing the app uses to reach the keychain.
///
/// macOS can answer a keychain call with a password prompt, and the call doesn't return until that's dealt
/// with. The key tap runs on the main thread, so a keychain call there freezes every keystroke on the Mac,
/// including the ones going into the prompt. So all keychain work happens on this queue, and reading a key
/// only ever looks at memory.
public final class KeyStore: @unchecked Sendable {
    private let read: @Sendable (String) -> String?
    private let write: @Sendable (String, String) -> Bool
    private let queue = DispatchQueue(label: "com.mattmoglia.typestro.keychain")
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    private var loaded = false

    public init(
        read: @escaping @Sendable (String) -> String? = { Keychain.read($0) },
        write: @escaping @Sendable (String, String) -> Bool = { Keychain.save($0, $1) }
    ) {
        self.read = read
        self.write = write
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// False until `load` finishes, which takes as long as you leave a keychain prompt on screen.
    public var isLoaded: Bool { locked { loaded } }

    public func key(_ account: String) -> String? { locked { keys[account] } }

    /// Reads the keys once, off the main thread, then calls `completion` on the main thread.
    public func load(_ accounts: [String], completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            for account in accounts {
                let value = read(account)
                locked { keys[account] = value }
            }
            locked { loaded = true }
            Task { @MainActor in completion() }
        }
    }

    /// Saves off the main thread, then reports on the main thread whether it worked.
    public func save(_ value: String, _ account: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let saved = write(value, account)
            if saved { locked { keys[account] = value } }
            Task { @MainActor in completion(saved) }
        }
    }
}
