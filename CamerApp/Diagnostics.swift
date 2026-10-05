import Foundation

/// Catches camera errors that would otherwise crash the app, and remembers the last crash
/// so it can be shown on the next launch.
enum Diagnostics {
    private static let crashKey = "diagnostics.lastCrash"

    /// Runs `block`; if AVFoundation throws an exception, returns its description instead of crashing.
    @discardableResult
    static func guarded(_ step: String, _ block: () -> Void) -> String? {
        guard let reason = ExceptionCatcher.catching(block) else { return nil }
        let message = "\(step): \(reason)"
        UserDefaults.standard.set(message, forKey: "diagnostics.lastError")
        return message
    }

    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(12).joined(separator: "\n")
            UserDefaults.standard.set("\(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)",
                                      forKey: "diagnostics.lastCrash")
            UserDefaults.standard.synchronize()
        }
    }

    /// The crash from the previous run, if any. Reading it clears it.
    static func takeLastCrash() -> String? {
        let crash = UserDefaults.standard.string(forKey: crashKey)
        UserDefaults.standard.removeObject(forKey: crashKey)
        return crash
    }
}
