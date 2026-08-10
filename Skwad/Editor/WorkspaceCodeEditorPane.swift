import SwiftUI

struct WorkspaceCodeEditorPane: View {
    @Bindable var model: WorkspaceFileEditorModel
    let onSave: () -> Void

    // Wrapping is the better default in a side panel: the pane is narrow, and long
    // lines otherwise require horizontal scrolling to read at all.
    @State private var wrapsLines = true

    private var language: CodeLanguage {
        CodeLanguage(path: model.relativePath ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar

            CodeEditorView(
                text: $model.text,
                language: language,
                wrapsLines: wrapsLines
            )

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Label(language.displayName, systemImage: language.iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: Capsule())

            Text(model.relativePath ?? "")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if model.hasUnsavedChanges {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }

            Spacer(minLength: 8)

            Button("Toggle line wrapping", systemImage: wrapsLines ? "text.justify.left" : "arrow.right.to.line") {
                wrapsLines.toggle()
            }
            .labelStyle(.iconOnly)
            .help(wrapsLines ? "Disable line wrapping" : "Wrap long lines")

            Button("Reload", systemImage: "arrow.counterclockwise", action: model.reload)
                .labelStyle(.iconOnly)
                .disabled(!model.hasUnsavedChanges)
                .help("Discard edits and reload from the worktree")

            Button("Save", systemImage: "square.and.arrow.down", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 46)
        // No tinted band: its top edge read as a stray grey line drawn across the
        // pane at the height of the language chip. One divider below is the boundary.
        .overlay(alignment: .bottom) { Divider() }
    }

    private func save() {
        if model.save() {
            onSave()
        }
    }
}
