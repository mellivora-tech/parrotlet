import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 轻量生词本：只做找回、发音、复制、删除和导出，不制造复习压力。
struct WordBookView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var searchText = ""

    private var entries: [WordEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return env.words.entries }
        return env.words.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
            || $0.note.localizedCaseInsensitiveContains(query)
            || $0.context.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField(env.t(.search), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Text(env.words.entries.isEmpty
                     ? env.t(.emptyWordBook)
                     : "\(entries.count) / \(env.words.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu(env.t(.exportWordBook)) {
                    Button("JSON") { export(.json) }
                    Button("CSV") { export(.csv) }
                }
                .controlSize(.small)
                .fixedSize()
            }
            .padding(14)

            if case .recoveryRequired = env.words.persistenceState {
                Text(env.t(.storageRecoveryRequired))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            } else if case .failed = env.words.persistenceState {
                Text(env.t(.storageSaveFailed))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                        Divider().opacity(entry.id == entries.last?.id ? 0 : 1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(env.t(.wordBookTitle))
    }

    private func row(_ entry: WordEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.eaFont(15, .body, weight: .semibold))
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.eaFont(12, .callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                if !entry.context.isEmpty {
                    Text(entry.context)
                        .font(.eaFont(11, .caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Button {
                env.speech.speak(entry.text, token: entry.id.uuidString)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(env.t(.readAloud))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.text)\n\n\(entry.note)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(env.t(.copyExplanation))
            Button(role: .destructive) {
                env.words.remove(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(env.t(.delete))
        }
        .padding(.vertical, 9)
    }

    private static func csv(_ entries: [WordEntry]) -> String {
        let header = "text,note,context,createdAt"
        let rows = entries.map { entry in
            [entry.text, entry.note, entry.context, ISO8601DateFormatter().string(from: entry.createdAt)]
                .map(Self.csvEscape)
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .json ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = "words.\(format.fileExtension)"
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    let data: Data
                    switch format {
                    case .json:
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        data = try encoder.encode(env.words.entries)
                    case .csv:
                        data = Data(Self.csv(env.words.entries).utf8)
                    }
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }
private enum ExportFormat {
    case json, csv

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        }
    }
}

private static func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

}
