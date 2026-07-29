import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import ACPKit
import SwiftUI

// The elicitation card: the agent asking the user structured questions
// (Claude Code's AskUserQuestion arrives as a form-mode elicitation/create).
// Single-select questions answer on tap; multi-select / multi-question /
// free-text forms collect state and submit. Skip = decline.

struct AcpElicitationCard: View {
    @ObservedObject var session: AgentSessionViewModel
    let prompt: ElicitationPrompt

    @State private var selections: [String: Set<String>] = [:]
    @State private var texts: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]

    private var fields: [ElicitationForm.Field] { prompt.form?.fields ?? [] }

    /// One single-select question (custom "Other" companions aside): tapping
    /// an option answers immediately, the Claude-CLI feel. Any typed text
    /// switches to explicit submit so the user's words can't be lost.
    private var isInstant: Bool {
        let primary = fields.filter { !$0.isCustomCompanion }
        guard primary.count == 1, case .select = primary[0].kind else { return false }
        return texts.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(AcpPalette.awaiting)
                Text("Agent asks")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }

            Text(prompt.request.message)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)

            if fields.isEmpty {
                // Unparseable / non-form request: all we can do honestly.
                HStack(spacing: 8) {
                    Button("OK") { session.respondElicitation(.accept([:])) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Skip") { session.respondElicitation(.decline) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                ForEach(fields, id: \.key) { field in
                    fieldView(field)
                }
                if !isInstant {
                    HStack(spacing: 8) {
                        Button("Submit") { submit() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("⌘⏎")
                        Button("Skip") { session.respondElicitation(.decline) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AcpPalette.awaiting.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Fields

    @ViewBuilder
    private func fieldView(_ field: ElicitationForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = field.title, !title.isEmpty, !field.isCustomCompanion {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let detail = field.detail, !detail.isEmpty, !field.isCustomCompanion {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            switch field.kind {
            case .select(let options):
                optionList(field: field, options: options, multi: false)
            case .multiSelect(let options):
                optionList(field: field, options: options, multi: true)
            case .text:
                TextField(
                    field.isCustomCompanion ? "Other — type your own answer" : (field.title ?? "Answer"),
                    text: textBinding(field.key), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
            case .number:
                TextField(field.title ?? "Number", text: textBinding(field.key))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 140)
            case .boolean:
                Toggle(field.title ?? field.key, isOn: boolBinding(field.key))
                    .font(.system(size: 12))
            }
        }
    }

    private func optionList(field: ElicitationForm.Field, options: [ElicitationForm.Option], multi: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.value) { option in
                optionRow(field: field, option: option, multi: multi)
            }
        }
    }

    @ViewBuilder
    private func optionRow(field: ElicitationForm.Field, option: ElicitationForm.Option, multi: Bool) -> some View {
        let selected = selections[field.key]?.contains(option.value) ?? false
        Button {
            if multi {
                var set = selections[field.key] ?? []
                if selected { set.remove(option.value) } else { set.insert(option.value) }
                selections[field.key] = set
            } else if isInstant {
                session.respondElicitation(.accept([field.key: .string(option.value)]))
            } else {
                selections[field.key] = [option.value]
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: multi
                        ? (selected ? "checkmark.square.fill" : "square")
                        : (selected ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(option.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                if selected, let preview = option.preview, !preview.isEmpty {
                    AcpMonoBlock(text: preview, maxHeight: 140)
                        .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selected ? Color.accentColor.opacity(0.10) : AcpPalette.codeBackground,
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private func submit() {
        var content: [String: JSONValue] = [:]
        for field in fields {
            switch field.kind {
            case .select:
                if let value = selections[field.key]?.first {
                    content[field.key] = .string(value)
                }
            case .multiSelect(let options):
                if let set = selections[field.key], !set.isEmpty {
                    // Preserve the option order the agent declared.
                    let ordered = options.map(\.value).filter(set.contains)
                    content[field.key] = .array(ordered.map { .string($0) })
                }
            case .text:
                let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { content[field.key] = .string(text) }
            case .number:
                if let number = Double((texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)) {
                    content[field.key] = .number(number)
                }
            case .boolean:
                if let value = bools[field.key] { content[field.key] = .bool(value) }
            }
        }
        session.respondElicitation(.accept(content))
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { bools[key] ?? false }, set: { bools[key] = $0 })
    }
}
