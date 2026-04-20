import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @State private var showAddHost = false
    @State private var selectedHost: Host?

    var body: some View {
        Group {
            if hostStore.hosts.isEmpty {
                emptyState
            } else {
                hostList
            }
        }
        .navigationTitle("SpeakTerm")
        .toolbar {
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
        .fullScreenCover(item: $selectedHost) { host in
            TerminalWrapperView(host: host) {
                selectedHost = nil
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Hosts", systemImage: "server.rack")
        } description: {
            Text("Add a remote server to get started.")
        } actions: {
            Button("Add Host") {
                showAddHost = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var hostList: some View {
        List {
            ForEach(hostStore.hosts) { host in
                HostCardView(host: host)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedHost = host
                    }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    hostStore.delete(hostStore.hosts[index])
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Host Card

struct HostCardView: View {
    let host: Host

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.headline)

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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
