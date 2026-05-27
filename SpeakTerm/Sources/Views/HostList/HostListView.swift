import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showAddHost = false
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
        .navigationTitle("SpeakTerm")
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
                Button(action: { showAddHost = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                HostEditView(mode: .add) { host in
                    hostStore.add(host)
                }
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
