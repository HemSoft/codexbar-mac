import Foundation

public struct LocalCredentialDiscovery: Sendable {
    public struct Result: Equatable, Sendable {
        public let codexAuthAvailable: Bool
        public let githubUsernames: [String]
        public let claudeOAuthAvailable: Bool

        public init(
            codexAuthAvailable: Bool,
            githubUsernames: [String],
            claudeOAuthAvailable: Bool
        ) {
            self.codexAuthAvailable = codexAuthAvailable
            self.githubUsernames = githubUsernames
            self.claudeOAuthAvailable = claudeOAuthAvailable
        }
    }

    public static func discover(
        codexAuthPath: String = defaultCodexAuthPath(),
        claudeCredentialsPath: String = defaultClaudeCredentialsPath(),
        ghStatusRunner: (@Sendable () throws -> (exitCode: Int32, stdout: String, stderr: String))? = nil
    ) -> Result {
        let runner = ghStatusRunner ?? { try runGitHubAuthStatus() }
        return Result(
            codexAuthAvailable: CodexCredentialsParser.parseAuthFile(at: codexAuthPath) != nil,
            githubUsernames: discoverGitHubUsernames(using: runner),
            claudeOAuthAvailable: hasClaudeOAuthCredentials(at: claudeCredentialsPath)
        )
    }

    public static func defaultCodexAuthPath() -> String {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("auth.json")
                .path
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
            .path
    }

    public static func defaultClaudeCredentialsPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
            .path
    }

    private static func hasClaudeOAuthCredentials(at path: String) -> Bool {
        guard let credentials = ClaudeCredentialsParser.parseCredentialsFile(at: path),
              let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return false
        }

        return true
    }

    private static func discoverGitHubUsernames(
        using runner: @Sendable () throws -> (exitCode: Int32, stdout: String, stderr: String)
    ) -> [String] {
        guard let result = try? runner(), result.exitCode == 0 else {
            return []
        }

        return extractGitHubUsernames(from: result.stdout + "\n" + result.stderr)
    }

    static func extractGitHubUsernames(from output: String) -> [String] {
        var usernames: [String] = []
        var seen = Set<String>()

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.localizedCaseInsensitiveContains("Logged in to github.com") else {
                continue
            }

            guard let username = extractUsername(from: trimmed)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !username.isEmpty else {
                continue
            }

            let key = username.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            usernames.append(username)
        }

        return usernames
    }

    static func extractUsername(from line: String) -> String? {
        if let accountRange = line.range(of: "account ", options: .caseInsensitive) {
            let rest = line[accountRange.upperBound...]
            if let end = rest.firstIndex(where: { $0.isWhitespace }) {
                return String(rest[..<end])
            }
            return String(rest)
        }

        if let asRange = line.range(of: " as ", options: .caseInsensitive) {
            let rest = line[asRange.upperBound...]
            if let end = rest.firstIndex(where: { $0.isWhitespace }) {
                return String(rest[..<end])
            }
            return String(rest)
        }

        return nil
    }

    private static func runGitHubAuthStatus() throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try ShellCommand.run(
            executable: "/usr/bin/env",
            arguments: ["gh", "auth", "status", "--hostname", "github.com"],
            timeout: 10
        )
    }
}

enum ShellCommand {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw ShellCommandError.timedOut
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

enum ShellCommandError: Error {
    case timedOut
}
