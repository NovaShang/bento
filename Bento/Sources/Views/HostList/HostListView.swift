import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var relayStore: RelayDaemonStore
    @State private var showAddHost = false
    @State private var showRelayPair = false
    @State private var relayPairPrefill: PendingRelayPair?
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var editingHost: Host?
    @State private var searchText = ""

    private var filteredHosts: [Host] {
        if searchText.isEmpty { return hostStore.hosts }
        return hostStore.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ActiveSessionsStrip()

            if !relayStore.daemons.isEmpty {
                Section("My Computers") {
                    ForEach(relayStore.daemons) { daemon in
                        // Synthesize a Host so the entire downstream pipeline
                        // (HostSessionsView → TerminalViewModel → tmux picker
                        // → multi-pane) is identical to a direct-SSH host.
                        NavigationLink(value: HostNavigation.sessions(Host.fromRelayDaemon(daemon))) {
                            RelayDaemonRow(daemon: daemon)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                relayStore.delete(daemon)
                            } label: {
                                Label("Unpair", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if filteredHosts.isEmpty && !hostStore.hosts.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if hostStore.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a remote server to get started.")
                } actions: {
                    Button("Add Host") { showAddHost = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(filteredHosts) { host in
                        NavigationLink(value: HostNavigation.sessions(host)) {
                            HostCardView(
                                host: host,
                                isConnected: sessionManager.activeSessions.contains(where: { $0.key.hostID == host.id })
                            )
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingHost = host
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editingHost = host
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                hostStore.delete(host)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            hostStore.delete(filteredHosts[index])
                        }
                    }
                } header: {
                    if !sessionManager.activeSessions.isEmpty {
                        Text("All Hosts")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = sessionManager.evictionNotice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        sessionManager.evictionNotice = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sessionManager.evictionNotice)
        .navigationTitle("Bento")
        .searchable(text: $searchText, prompt: "Search hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Guide") { showOnboarding = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddHost = true
                    } label: {
                        Label("Add SSH host…", systemImage: "server.rack")
                    }
                    Button {
                        showRelayPair = true
                    } label: {
                        Label("Pair Mac via relay…", systemImage: "macbook.and.iphone")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("plus")
            }
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                HostEditView(mode: .add) { host in
                    hostStore.add(host)
                }
            }
        }
        .sheet(isPresented: $showRelayPair) {
            RelayPairView(prefill: relayPairPrefill)
        }
        .onChange(of: relayStore.pendingPair) { _, new in
            guard let new else { return }
            relayPairPrefill = new
            showRelayPair = true
            relayStore.pendingPair = nil
        }
        .onAppear {
            // If a deep link fired before this view materialized, consume it now.
            if let pending = relayStore.pendingPair {
                relayPairPrefill = pending
                showRelayPair = true
                relayStore.pendingPair = nil
            }
        }
        .sheet(item: $editingHost) { host in
            NavigationStack {
                HostEditView(mode: .edit(host)) { updated in
                    hostStore.update(updated)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}

/// Navigation destinations from the host list. Using a typed enum keeps the
/// NavigationStack path serializable in case we ever restore navigation.
enum HostNavigation: Hashable {
    case sessions(Host)
}

// MARK: - Relay Daemon Row

/// RelayDaemonRow is the My Computers list item. Tap → opens a relay-routed
/// session (SSH-over-WSS lands in a follow-up; for now it shows a placeholder).
struct RelayDaemonRow: View {
    let daemon: RelayDaemon

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(daemon.displayName).font(.body.weight(.medium))
                Text("via relay · paired \(daemon.pairedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Host Card

struct HostCardView: View {
    let host: Host
    var isConnected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Connection status dot: green = live SSH session in SessionManager
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body.weight(.medium))

                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let lastConnected = host.lastConnected {
                Text(lastConnected, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
