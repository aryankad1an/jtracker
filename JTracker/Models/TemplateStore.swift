import Foundation
import Observation

/// The user's mail templates, stored in Supabase keyed by their Gmail address,
/// so they load on any device after signing in. Every change writes through and
/// then refetches, so on-screen state always mirrors the database.
@Observable
final class TemplateStore {
    private(set) var templates: [MailTemplate] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private var email: String?

    /// Load this user's templates from the database.
    func load(email: String) async {
        self.email = email
        isLoading = true
        defer { isLoading = false }
        do {
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Create or update a template (both are an upsert on its id).
    func save(_ template: MailTemplate) async {
        guard let email else { return }
        do {
            try await SupabaseAPI.upsertTemplate(userEmail: email, template: template)
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ template: MailTemplate) async {
        guard let email else { return }
        do {
            try await SupabaseAPI.deleteTemplate(id: template.id)
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
