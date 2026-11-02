import Foundation

package enum GenieRuntimeLauncher {
    /// poller.run を起動する。初回の一覧が反映され、まだ止まっていなければ watch を始める。
    package static func launch(
        poller: GeniePoller,
        stop: StopSignal,
        startWatch: @escaping @Sendable () async -> Void
    ) -> (poller: Task<Void, Never>, supervisor: Task<Void, Never>) {
        let pollerTask = Task { await poller.run() }
        let supervisor = Task {
            let initial = await poller.waitForInitialChatList()
            if initial == .applied && !stop.isStopped {
                await startWatch()
            }
        }
        return (pollerTask, supervisor)
    }
}
