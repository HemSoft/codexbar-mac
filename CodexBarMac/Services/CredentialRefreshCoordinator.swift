import Foundation

actor CredentialRefreshCoordinator<Result: Sendable> {
    private var inFlightTasks: [String: Task<Result, Never>] = [:]

    func run(
        for account: String,
        operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        if let task = inFlightTasks[account] {
            return await task.value
        }

        let task = Task { await operation() }
        inFlightTasks[account] = task
        let result = await task.value
        inFlightTasks[account] = nil
        return result
    }
}
