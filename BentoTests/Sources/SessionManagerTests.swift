import Testing
@testable import Bento
import BentoTerminalCore
import Foundation

@Suite("SessionManager Tests")
@MainActor
struct SessionManagerTests {
    private func makeHost(_ name: String) -> Host {
        Host(
            id: UUID(),
            name: name,
            hostname: "relay/\(name)",
            port: 0,
            username: "bento",
            authMethod: .privateKey(keyLabel: "test-\(name)"),
            transport: .relay(daemonID: "d-\(name)", hostFingerprint: "fp", deviceID: "dev")
        )
    }

    /// A manager whose hosts resolve to an isolated in-memory store (no
    /// keychain, no daemon).
    private func makeManager(maxSessions: Int = 5) -> SessionManager {
        let manager = SessionManager(maxSessions: maxSessions)
        let store = AgentWorkspaceStore(persistKey: "session_manager_tests_\(UUID().uuidString)")
        manager.storeProvider = { _ in store }
        return manager
    }

    @Test func viewModelIdentityIsStableAcrossLookups() async throws {
        let manager = makeManager()
        let host = makeHost("alpha")

        let vm1 = manager.viewModel(for: host, sessionName: "main")
        let vm2 = manager.viewModel(for: host, sessionName: "main")

        #expect(vm1 != nil)
        #expect(vm1 === vm2)
    }

    @Test func sameHostDifferentSessionsGetDifferentVMs() async throws {
        let manager = makeManager()
        let host = makeHost("alpha")

        let vmA = manager.viewModel(for: host, sessionName: "main")
        let vmB = manager.viewModel(for: host, sessionName: "scratch")

        #expect(vmA !== vmB)
    }

    @Test func unpairedHostGetsNoViewModel() async throws {
        let manager = SessionManager(maxSessions: 5)
        manager.storeProvider = { _ in nil }
        #expect(manager.viewModel(for: makeHost("alpha"), sessionName: "main") == nil)
    }

    @Test func registrationPopulatesActiveSessions() async throws {
        let manager = makeManager()
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, sessionName: "work")

        // Registration is deferred to next runloop tick.
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.activeSessions.count == 1)
        #expect(manager.activeSessions.first?.key.hostID == host.id)
        #expect(manager.activeSessions.first?.key.sessionName == "work")
    }

    @Test func sessionsForHostFiltersCorrectly() async throws {
        let manager = makeManager()
        let a = makeHost("alpha")
        let b = makeHost("beta")
        _ = manager.viewModel(for: a, sessionName: "main")
        _ = manager.viewModel(for: a, sessionName: "scratch")
        _ = manager.viewModel(for: b, sessionName: "main")
        try await Task.sleep(for: .milliseconds(80))

        let aSessions = manager.sessions(forHostID: a.id)
        let bSessions = manager.sessions(forHostID: b.id)

        #expect(aSessions.count == 2)
        #expect(bSessions.count == 1)
        #expect(Set(aSessions.map { $0.key.sessionName }) == ["main", "scratch"])
    }

    @Test func lruEvictsOldestWhenOverCap() async throws {
        let manager = makeManager(maxSessions: 2)
        let host = makeHost("alpha")

        _ = manager.viewModel(for: host, sessionName: "a")
        try await Task.sleep(for: .milliseconds(20))
        _ = manager.viewModel(for: host, sessionName: "b")
        try await Task.sleep(for: .milliseconds(20))
        _ = manager.viewModel(for: host, sessionName: "c")
        try await Task.sleep(for: .milliseconds(80))

        #expect(manager.activeSessions.count == 2)
        let names = Set(manager.activeSessions.map { $0.key.sessionName })
        #expect(!names.contains("a"))
        #expect(names.contains("b"))
        #expect(names.contains("c"))
        #expect(manager.evictionNotice != nil)
    }

    @Test func disconnectRemovesFromActiveSessions() async throws {
        let manager = makeManager()
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, sessionName: "main")
        try await Task.sleep(for: .milliseconds(50))

        let key = SessionKey(hostID: host.id, sessionName: "main")
        manager.disconnect(key: key)

        #expect(manager.activeSessions.isEmpty)
        #expect(manager.existingViewModel(for: key) == nil)
    }
}
