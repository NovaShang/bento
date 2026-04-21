import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @State private var showAddHost = false
    @State private var selectedHost: Host?
    @State private var showOnboarding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                searchPill
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)

                if hostStore.hosts.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    hostSections
                }

                footer
            }
        }
        .background(Color(.systemGroupedBackground))
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

    // MARK: - Header (iOS Large Title style)

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button("Guide") { showOnboarding = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.stAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())

                Button(action: { showAddHost = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.stAccent)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Text("SpeakTerm")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Search Pill (decorative)

    private var searchPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Search hosts, workspaces")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Host Sections

    private var hostSections: some View {
        ForEach(hostStore.hosts) { host in
            VStack(alignment: .leading, spacing: 0) {
                // Section header
                hostSectionHeader(host: host)

                // Workspace row (single host = single workspace for now)
                Button {
                    selectedHost = host
                } label: {
                    hostRow(host: host)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 22)
        }
    }

    private func hostSectionHeader(host: Host) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(host.lastConnected != nil ? Color.stGreen : Color.stInkMute)
                .frame(width: 6, height: 6)
                .shadow(color: host.lastConnected != nil ? Color.stGreen.opacity(0.6) : .clear, radius: 2)

            Text(host.displayName.uppercased())
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text("· \(host.username)@\(host.hostname)")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
    }

    private func hostRow(host: Host) -> some View {
        HStack(spacing: 12) {
            // Workspace thumbnail
            WorkspaceThumbnail()

            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)

                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lastConnected = host.lastConnected {
                Text(lastConnected, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .padding(.horizontal, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Hosts")
                .font(.headline)
            Text("Add a remote server to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Host") { showAddHost = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        Text("SpeakTerm 0.2")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }
}

// MARK: - Workspace Thumbnail

/// Mini pane-split thumbnail showing workspace state
struct WorkspaceThumbnail: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(.tertiarySystemGroupedBackground))
            .frame(width: 42, height: 42)
            .overlay(
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(STTheme.TermDark.bgWorking))
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(STTheme.TermDark.bgWorking))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(STTheme.TermDark.bgIdle))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.stLineO, lineWidth: 0.5)
            )
    }
}

// MARK: - Host Card (legacy, kept for compatibility)

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
