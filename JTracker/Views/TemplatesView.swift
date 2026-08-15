import SwiftUI

/// The Templates tab: manage reusable mail presets.
struct TemplatesView: View {
    @Environment(TemplateStore.self) private var store

    @State private var isAdding = false
    @State private var editingTemplate: MailTemplate?
    @State private var isSelecting = false
    @State private var selection = Set<MailTemplate.ID>()
    @State private var confirmingDelete = false

    @ViewBuilder
    private func templateRows(_ templates: [MailTemplate]) -> some View {
        ForEach(templates) { template in
            if isSelecting {
                TemplateRow(template: template)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                TemplateRow(template: template)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .contentShape(Rectangle())
                    .onTapGesture { editingTemplate = template }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await store.delete(template) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func enterSelection() {
        selection = []
        withAnimation { isSelecting = true }
    }

    private func exitSelection() {
        withAnimation { isSelecting = false }
        selection = []
    }

    private func deleteSelected() {
        let toDelete = store.templates.filter { selection.contains($0.id) }
        Task {
            for template in toDelete {
                await store.delete(template)
            }
        }
        exitSelection()
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.templates.isEmpty {
                    if store.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List(selection: $selection) {
                        Section { templateRows(store.templates) }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        GlassDoneButton { exitSelection() }
                    } else {
                        Menu {
                            Button {
                                isAdding = true
                            } label: {
                                Label("New Template", systemImage: "plus")
                            }
                            if !store.templates.isEmpty {
                                Button {
                                    enterSelection()
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .selectionActions(
                isSelecting: isSelecting,
                count: selection.count,
                noun: SelectionNoun(singular: "template", plural: "templates"),
                confirmingDelete: $confirmingDelete
            ) { deleteSelected() }
            .sheet(isPresented: $isAdding) {
                TemplateEditorView(existing: nil) { new in
                    Task { await store.save(new) }
                }
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditorView(existing: template) { updated in
                    Task { await store.save(updated) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Templates", systemImage: "doc.plaintext.fill")
        } description: {
            Text("Save reusable presets with placeholders to speed up cold mails.")
        } actions: {
            Button {
                isAdding = true
            } label: {
                Label("New Template", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A template row: a document-icon tile, the name, and a subject preview.
private struct TemplateRow: View {
    let template: MailTemplate

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: Theme.Avatar.medium, height: Theme.Avatar.medium)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.headline)
                Text(template.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TemplatesView()
        .environment(TemplateStore())
}
