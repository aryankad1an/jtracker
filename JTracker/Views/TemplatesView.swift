import SwiftUI

/// The Templates tab: manage reusable mail presets.
struct TemplatesView: View {
    @Environment(TemplateStore.self) private var store

    @State private var isAdding = false
    @State private var editingTemplate: MailTemplate?
    @State private var isSelecting = false
    @State private var selection = Set<MailTemplate.ID>()
    @State private var confirmingDelete = false
    @State private var searchText = ""

    /// Templates matching the search, by name, subject, or body — the body counts
    /// because "the one that mentions the referral" is how you actually remember
    /// a template you wrote weeks ago.
    private var filtered: [MailTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.templates }
        return store.templates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.subject.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func templateRows(_ templates: [MailTemplate]) -> some View {
        ForEach(templates) { template in
            TemplateRow(template: template)
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.gutter,
                                          bottom: 4, trailing: Theme.Space.gutter))
                // Templates get the card press treatment for the first time here:
                // the row used to be a bare tap gesture, so it was the one list in
                // the app that didn't answer a finger.
                .selectableRow(isSelecting: isSelecting) {
                    beginSelection(with: template.id)
                } onTap: {
                    editingTemplate = template
                }
                .swipeActions(edge: .trailing) {
                    if !isSelecting {
                        Button(role: .destructive) {
                            Haptics.thud()
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
        Haptics.press()
        withAnimation(Theme.Motion.bouncy) { isSelecting = true }
    }

    /// Entered by holding a row, with that row already picked.
    private func beginSelection(with id: MailTemplate.ID) {
        selection = [id]
        withAnimation(Theme.Motion.bouncy) { isSelecting = true }
    }

    private func exitSelection() {
        Haptics.tap(0.5)
        withAnimation(Theme.Motion.bouncy) { isSelecting = false }
        selection = []
    }

    private func deleteSelected() {
        Haptics.thud()
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
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        Section { templateRows(filtered) }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.paper)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                    // Templates are per-account, not per-device — pull to sync in
                    // whatever another of the user's signed-in clients has saved.
                    .refreshable { await store.refresh() }
                    // A template saved on another device arriving mid-pull should
                    // spring into the list, not blink into it.
                    .animation(Theme.Motion.bouncy, value: filtered.map(\.id))
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search templates")
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
                        .accessibilityLabel("More actions")
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
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
    }
}

#Preview {
    TemplatesView()
        .environment(TemplateStore())
}
