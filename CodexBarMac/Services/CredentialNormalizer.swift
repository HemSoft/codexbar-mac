import Foundation

enum CredentialNormalizer {
    /// Trims whitespace, strips surrounding quotes, and removes common
    /// `Authorization:` / `Bearer ` prefixes from pasted API credentials.
    static func normalizedBearerKey(from storedSecret: String?) -> String? {
        guard var key = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }

        if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
            key.removeFirst()
            key.removeLast()
        }

        let authorizationPrefix = "authorization:"
        if key.lowercased().hasPrefix(authorizationPrefix) {
            key = String(key.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if key.lowercased().hasPrefix(bearerPrefix) {
            key = String(key.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return key.isEmpty ? nil : key
    }
}
