import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @State private var showAddHost = false
    @State private var selectedHost: Host?
    @State private var showOnboarding = false
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
                ForEach(filteredHosts) { host in
                    HostCardView(host: host)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedHost = host }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        hostStore.delete(filteredHosts[index])
                    }
                }
            }
        }
        .navigationTitle("SpeakTerm")
        .searchable(text: $searchText, prompt: "Search hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Guide") { showOnboarding = true }
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .fullScreenCover(item: $selectedHost) { host in
            TerminalWrapperView(host: host) {
                selectedHost = nil
            }
        }
    }
}

// MARK: - Host Card

struct HostCardView: View {
    let host: Host

    var body: some View {
        HStack(spacing: 12) {
            // Connection status dot
            Circle()
                .fill(host.lastConnected != nil ? Color.green : Color.secondary)
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
