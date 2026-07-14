import Foundation

public struct ProviderAccountConfiguration: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public var isEnabled: Bool
    public var accountLabel: String
    public var groupID: String?
    public var authMethod: ProviderAuthMethod
    public var oauthClientID: String?
    public var copilotAccountScope: CopilotAccountScope
    public var githubOrganization: String
    public var githubEnterprise: String
    public var githubCLIUsername: String
    public var copilotTotalAllotment: Double?
    public var openCodeWorkspaceId: String

    public init(
        id: String? = nil,
        providerID: ProviderID,
        isEnabled: Bool = true,
        accountLabel: String = "",
        groupID: String? = nil,
        authMethod: ProviderAuthMethod,
        oauthClientID: String? = nil,
        copilotAccountScope: CopilotAccountScope = .personal,
        githubOrganization: String = "",
        githubEnterprise: String = "",
        githubCLIUsername: String = "",
        copilotTotalAllotment: Double? = nil,
        openCodeWorkspaceId: String = ""
    ) {
        self.id = id ?? providerID.rawValue
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.accountLabel = accountLabel
        self.groupID = groupID
        self.authMethod = authMethod
        self.oauthClientID = oauthClientID
        self.copilotAccountScope = copilotAccountScope
        self.githubOrganization = githubOrganization
        self.githubEnterprise = githubEnterprise
        self.githubCLIUsername = githubCLIUsername
        self.copilotTotalAllotment = copilotTotalAllotment
        self.openCodeWorkspaceId = openCodeWorkspaceId
    }

    public var requiresSecret: Bool {
        authMethod.requiresSecret
    }

    public var displayName: String {
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? providerID.displayName : label
    }

    public func withNewAccountID() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(
            id: "\(providerID.rawValue).\(UUID().uuidString)",
            providerID: providerID,
            isEnabled: isEnabled,
            accountLabel: accountLabel,
            groupID: groupID,
            authMethod: authMethod,
            oauthClientID: oauthClientID,
            copilotAccountScope: copilotAccountScope,
            githubOrganization: githubOrganization,
            githubEnterprise: githubEnterprise,
            githubCLIUsername: githubCLIUsername,
            copilotTotalAllotment: copilotTotalAllotment,
            openCodeWorkspaceId: openCodeWorkspaceId
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case isEnabled
        case accountLabel
        case groupID
        case authMethod
        case oauthClientID
        case copilotAccountScope
        case githubOrganization
        case githubEnterprise
        case githubCLIUsername
        case copilotTotalAllotment
        case openCodeWorkspaceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try container.decode(ProviderID.self, forKey: .providerID)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? providerID.rawValue
        self.providerID = providerID
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
        self.groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        self.authMethod = try container.decode(ProviderAuthMethod.self, forKey: .authMethod)
        self.oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID)
        self.copilotAccountScope = try container.decodeIfPresent(CopilotAccountScope.self, forKey: .copilotAccountScope) ?? .personal
        self.githubOrganization = try container.decodeIfPresent(String.self, forKey: .githubOrganization) ?? ""
        self.githubEnterprise = try container.decodeIfPresent(String.self, forKey: .githubEnterprise) ?? ""
        self.githubCLIUsername = try container.decodeIfPresent(String.self, forKey: .githubCLIUsername) ?? ""
        self.copilotTotalAllotment = try container.decodeIfPresent(Double.self, forKey: .copilotTotalAllotment)
        self.openCodeWorkspaceId = try container.decodeIfPresent(String.self, forKey: .openCodeWorkspaceId) ?? ""
    }
}

public struct ProviderAccountGroup: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public static let ungroupedDisplayName = "Ungrouped"
}

public enum CopilotAccountScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal
    case organization

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .personal:
            "Personal User"
        case .organization:
            "Organization"
        }
    }
}

public enum ProviderAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey
    case browserSession
    case codexAuthJSON
    case cliToken
    case oauth

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .apiKey:
            "API Key"
        case .browserSession:
            "Browser Session"
        case .codexAuthJSON:
            "Codex auth.json"
        case .cliToken:
            "CLI Token"
        case .oauth:
            "OAuth"
        }
    }

    public var requiresSecret: Bool {
        switch self {
        case .apiKey, .codexAuthJSON, .cliToken:
            true
        case .browserSession, .oauth:
            false
        }
    }
}

public extension ProviderAccountConfiguration {
    static func defaultConfiguration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        switch providerID {
        case .codex:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .codexAuthJSON)
        case .copilot:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .cliToken)
        case .claude:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .oauth)
        case .openRouter:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .openCodeZen:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .cursor:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        }
    }
}
