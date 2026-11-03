import AppKit
import Testing
import NIO
import Citadel
@testable import SparkMonitor

struct ReconnectTests {
    @Test @MainActor func sleepAndRefreshReplaceCollectorsWithoutClearingHistory() async throws {
        let model = AppModel()
        let state = HostState(.local)
        let disconnected = HostState(HostProfile(name: "Disconnected", host: "unused.invalid", username: "unused"))
        model.hosts = [state, disconnected]
        model.connect(state)
        try await Task.sleep(for: .milliseconds(500))
        let old = state.generation
        model.suspendForSleep()
        #expect(state.status == "disconnected")
        #expect(state.task == nil)
        let savedHistory = state.history.count
        model.resumeFromSleep()
        #expect(state.status == "connecting")
        #expect(state.generation != old)
        #expect(state.history.count == savedHistory)
        #expect(disconnected.task == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(state.live)
        model.hosts = [state]
        let resumed = state.generation
        model.refreshConnections()
        #expect(state.generation != resumed)
        try await Task.sleep(for: .milliseconds(500))
        #expect(state.live)
        state.status = "connecting"; state.connectingSince = .distantPast
        let stalled = state.generation
        model.reconnectStalledCollectors()
        #expect(state.generation != stalled)
        await model.shutdown()
    }
    @Test @MainActor func disconnectErrorsRetryButAuthenticationDoesNot() {
        #expect(SSHPerformanceCollector.isNetworkError(ChannelError.eof))
        #expect(SSHPerformanceCollector.isNetworkError(ChannelError.alreadyClosed))
        #expect(SSHPerformanceCollector.isNetworkError(SFTPError.connectionClosed))
        #expect(!SSHPerformanceCollector.isNetworkError(SSHClientError.allAuthenticationOptionsFailed))
        #expect(!SSHPerformanceCollector.isNetworkError(MonitorError.message("SSH host key not trusted")))
    }
}
