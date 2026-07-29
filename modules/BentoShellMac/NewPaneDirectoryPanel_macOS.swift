#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import BentoAgentPane
import AppKit

/// The command-selection strip embedded at the bottom of the directory-chooser
/// panel (see `presentNewPaneDirectoryPanel`): a popup of the known agents plus
/// a custom-command field that appears only for "Custom command…", and — when
/// the visible folder has history — up to three "continue a previous session"
/// rows (the CC `/resume` analogue), refreshed as the user navigates.
///
/// This is the whole point of the redesign — the New Window / Split dialog IS a
/// native `NSOpenPanel`. Its folder browser picks the working directory, and
/// this accessory picks what runs in it, so there's no intermediate form and no
/// secondary "Choose…" popup.
final class NewPaneCommandAccessory: NSView, NSOpenSavePanelDelegate {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customField = NSTextField()
    private static let presets = AgentPreset.allCases

    private let resumeHeader = NSTextField(
        labelWithString: "Or continue a previous session in this folder:")
    private let resumeStack = NSStackView()
    private var resumeEntries: [CatalogEntry] = []
    /// Set when a "continue" row is clicked; the presenter cancels the panel
    /// and routes this entry to `onResume` instead of creating a new pane.
    private(set) var resumeChoice: CatalogEntry?
    weak var panel: NSOpenPanel?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 52))

        let label = NSTextField(labelWithString: "Command:")

        popup.addItems(withTitles: Self.presets.map(\.rawValue))
        // Open on the user's default agent (what a command-less pane spawns),
        // not "No agent" — so hitting Create gives the agent you'd expect.
        if let i = Self.presets.firstIndex(of: .defaultSelection) { popup.selectItem(at: i) }
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.setContentHuggingPriority(.required, for: .horizontal)

        customField.placeholderString = "e.g. cursor-agent"
        customField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customField.isHidden = true   // only shown for "Custom command…"
        customField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let commandRow = NSStackView(views: [label, popup, customField])
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 8

        resumeHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resumeHeader.textColor = .secondaryLabelColor
        resumeHeader.isHidden = true
        resumeStack.orientation = .vertical
        resumeStack.alignment = .leading
        resumeStack.spacing = 2

        let outer = NSStackView(views: [commandRow, resumeHeader, resumeStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedPreset: AgentPreset {
        let idx = popup.indexOfSelectedItem
        return Self.presets.indices.contains(idx) ? Self.presets[idx] : .none
    }

    /// nil = a plain shell; otherwise the chosen agent's launch command or the
    /// user's custom command.
    var chosenCommand: String? {
        switch selectedPreset {
        case .none:
            return nil
        case .custom:
            let t = customField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default:
            return selectedPreset.command
        }
    }

    @objc private func popupChanged() {
        let custom = (selectedPreset == .custom)
        customField.isHidden = !custom
        if custom { window?.makeFirstResponder(customField) }
    }

    // MARK: Continue-previous rows

    /// Refresh the resume rows for `directory` (subtree match against the
    /// history catalog, newest first, expired ones skipped).
    func updateResumeRows(for directory: String?) {
        let entries = directory.map { dir in
            Array(AgentWorkspaceStore.shared
                .catalogEntries(cwd: dir, subtree: true)
                .filter { !$0.expired }
                .prefix(3))
        } ?? []
        guard entries.map(\.acpSessionID) != resumeEntries.map(\.acpSessionID) else { return }
        resumeEntries = entries
        resumeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resumeHeader.isHidden = entries.isEmpty
        for (index, entry) in entries.enumerated() {
            resumeStack.addArrangedSubview(resumeButton(entry, tag: index))
        }
        // Resize to fit and re-attach so the open panel relayouts its
        // accessory area for the new row count.
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: 520, height: fittingSize.height))
        if let panel, panel.accessoryView === self {
            panel.accessoryView = nil
            panel.accessoryView = self
        }
    }

    private func resumeButton(_ entry: CatalogEntry, tag: Int) -> NSButton {
        let title = entry.title.isEmpty ? "Untitled" : entry.title
        let agent = SessionHistoryModel.agentName(entry.presetID)
        let when = SessionHistoryView.relativeTime(entry.lastActive)
        let button = NSButton(
            title: "\(title)  ·  \(agent)  ·  \(when)",
            target: self, action: #selector(resumeClicked(_:)))
        button.image = NSImage(systemSymbolName: "arrow.uturn.up.circle",
                               accessibilityDescription: "Continue")
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = tag
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func resumeClicked(_ sender: NSButton) {
        guard resumeEntries.indices.contains(sender.tag) else { return }
        resumeChoice = resumeEntries[sender.tag]
        panel?.cancel(nil)
    }

    /// NSOpenSavePanelDelegate: the browser navigated — rescope the rows.
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        updateResumeRows(for: url?.path)
    }
}

/// Present a native directory-chooser `NSOpenPanel` whose accessory picks the
/// command to run — the dialog itself is the folder browser (no separate form,
/// no secondary "Choose…" step). Seeds at `initialDirectory` (typically the
/// active pane's cwd) so confirming immediately reuses that folder, while the
/// user can still navigate to or create another. `onCreate(path, command)`
/// fires on confirm with the chosen directory and command; nothing on cancel.
/// When `onResume` is provided, folders with session history list up to three
/// "continue a previous session" rows — clicking one closes the panel and
/// fires `onResume(entry)` INSTEAD of creating anything new.
@MainActor
func presentNewPaneDirectoryPanel(
    title: String,
    prompt: String,
    initialDirectory: String?,
    onCreate: @escaping (String?, String?) -> Void,
    onResume: ((CatalogEntry) -> Void)? = nil
) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.title = title
    panel.message = "Choose a working directory, then pick what to run in it."
    panel.prompt = prompt
    let accessory = NewPaneCommandAccessory()
    accessory.panel = panel
    panel.accessoryView = accessory
    panel.isAccessoryViewDisclosed = true
    if let initialDirectory, !initialDirectory.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: (initialDirectory as NSString).expandingTildeInPath)
    }
    if onResume != nil {
        panel.delegate = accessory
        accessory.updateResumeRows(for: initialDirectory ?? NSHomeDirectory())
    }
    let response = panel.runModal()
    if let choice = accessory.resumeChoice {
        onResume?(choice)
        return
    }
    guard response == .OK, let url = panel.url else { return }
    onCreate(url.path, accessory.chosenCommand)
}
#endif
