import SwiftUI

/// A sheet to add a company to your home: pick one from the shared catalog, or
/// type a new name to create and track it.
struct CompanyPickerView: View {
    let companies: [CatalogCompany]
    let isLoading: Bool
    let onPick: (CatalogCompany) -> Void
    let onAddCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var filteredCompanies: [CatalogCompany] {
        guard !trimmedSearch.isEmpty else { return companies }
        return companies.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// Offer an "Add …" row when the typed name isn't already in the list.
    private var canAddCustom: Bool {
        !trimmedSearch.isEmpty &&
        !companies.contains { $0.name.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && companies.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading companies…")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(filteredCompanies) { company in
                    Button {
                        onPick(company)
                        dismiss()
                    } label: {
                        companyRow(company)
                    }
                    .tint(.primary)
                }

                if canAddCustom {
                    Button {
                        onAddCustom(trimmedSearch)
                        dismiss()
                    } label: {
                        Label("Add \"\(trimmedSearch)\"", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Add Company")
            .searchable(text: $searchText, prompt: "Search or add a company")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func companyRow(_ company: CatalogCompany) -> some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: company.name, size: Theme.Avatar.small, systemImage: "building.2.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text(company.name)
                if let sector = company.sector, !sector.isEmpty {
                    Text(sector)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
