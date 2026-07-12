import Foundation

public protocol UsageProvider: Sendable {
    var providerID: ProviderID { get }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult
}
