import Foundation

/// A company from the shared catalog, used when picking one to add to your list.
struct CatalogCompany: Identifiable, Decodable {
    let id: String
    let name: String
    let sector: String?
}
