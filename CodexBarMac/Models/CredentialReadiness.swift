import Foundation

public enum CredentialReadiness: Equatable, Sendable {
    case keychainSaved
    case localCLIReady(description: String)
    case missing
}
