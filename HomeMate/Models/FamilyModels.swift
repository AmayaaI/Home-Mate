import Foundation

struct SharedFamily: Identifiable, Equatable {
    var id: String
    var name: String
    var ownerID: String
    var currency: String
}
struct FamilyMember: Identifiable {
    var id: String
    var email: String
    var displayName: String
    var role: String
}

/// Keeps the cloud-safe email identifier separate from the name shown in the UI.
enum AssignmentDisplay {
    static func label(
        for assignee: String,
        accountEmail: String,
        localName: String,
        members: [FamilyMember] = [],
        shared: Bool
    ) -> String {
        // Private records belong to this account; legacy names may predate profile edits.
        guard shared else { return "Me" }
        let value = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare("Everyone") == .orderedSame { return "Everyone" }
        if value.caseInsensitiveCompare("Me") == .orderedSame { return "Me" }

        if shared {
            if !accountEmail.isEmpty, value.caseInsensitiveCompare(accountEmail) == .orderedSame { return "Me" }
            if let member = members.first(where: { $0.email.caseInsensitiveCompare(value) == .orderedSame }) {
                let name = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? member.email : name
            }
        }
        return value.isEmpty ? "Unassigned" : value
    }
}
struct FamilyInvitation: Identifiable {
    var id: String
    var familyID: String
    var familyName: String
    var email: String
    var expiresAt: Date

    func canAccept(email accountEmail: String, verified: Bool, now: Date = Date()) -> Bool {
        verified && expiresAt > now && email.lowercased() == accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
struct FamilyMessage: Identifiable {
    var id: String
    var authorID: String
    var authorName: String
    var text: String
    var date: Date
}

enum FamilyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct FamilyAnnouncement: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var title = ""
    var body = ""
    var authorID: String
    var authorName: String
    var createdAt = Date()
    var important = false
    var revision: String?
    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 { return "Enter a title of 1–200 characters." }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || body.count > 10000 { return "Enter a message of 1–10,000 characters." }
        return nil
    }
    static func ordered(_ values: [FamilyAnnouncement]) -> [FamilyAnnouncement] {
        values.sorted { lhs, rhs in
            if lhs.important != rhs.important { return lhs.important && !rhs.important }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
