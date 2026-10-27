import Foundation

@MainActor
final class FamilyAPI {
    private let account: CloudAccount
    init(account: CloudAccount) { self.account = account }
    private var root: String { "projects/\(account.projectID)/databases/(default)/documents/" }
    private func string(_ value: String) -> [String: Any] { ["stringValue": value] }
    private func fields(_ document: [String: Any]) throws -> [String: [String: Any]] {
        guard let fields = document["fields"] as? [String: [String: Any]] else { throw URLError(.cannotParseResponse) }
        return fields
    }
    private func value(_ fields: [String: [String: Any]], _ key: String) throws -> String {
        guard let value = fields[key]?["stringValue"] as? String else { throw URLError(.cannotParseResponse) }
        return value
    }
    private func id(_ document: [String: Any]) throws -> String {
        guard let name = document["name"] as? String, let id = name.split(separator: "/").last else { throw URLError(.cannotParseResponse) }
        return String(id)
    }
    private func write(_ path: String, fields: [String: Any], timestamp: String? = nil, create: Bool = true) -> [String: Any] {
        var result: [String: Any] = ["update": ["name": root + path, "fields": fields], "currentDocument": ["exists": !create]]
        if let timestamp { result["updateTransforms"] = [["fieldPath": timestamp, "setToServerValue": "REQUEST_TIME"]] }
        return result
    }
    private func commit(_ writes: [[String: Any]]) async throws {
        _ = try await account.documentRequest(path: [], method: "POST", body: ["writes": writes], operation: "commit")
    }
    private func list(_ path: [String]) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []; var token: String?; var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await account.documentRequest(path: path, query: query)
            result += page["documents"] as? [[String: Any]] ?? []
            token = page["nextPageToken"] as? String
            if token == "" { token = nil }
            if let token, !seen.insert(token).inserted { throw URLError(.cannotParseResponse) }
        } while token != nil
        return result
    }
    private func queryInvites(_ key: String, value: String) async throws -> [FamilyInvitation] {
        let filters: [[String: Any]] = [(key, value), ("status", "pending")].map {
            ["fieldFilter": ["field": ["fieldPath": $0.0], "op": "EQUAL", "value": string($0.1)]]
        }
        let response = try await account.documentRequest(path: [], method: "POST", body: ["structuredQuery": ["from": [["collectionId": "familyInvites"]], "where": ["compositeFilter": ["op": "AND", "filters": filters]]]], operation: "runQuery")
        return try (response["documents"] as? [[String: Any]] ?? []).compactMap { document in
            let f = try fields(document)
            guard let raw = f["expiresAt"]?["timestampValue"] as? String, let date = Self.date(raw) else { throw URLError(.cannotParseResponse) }
            guard date > Date() else { return nil }
            return FamilyInvitation(id: try id(document), familyID: try self.value(f, "familyID"), familyName: try self.value(f, "familyName"), email: try self.value(f, "email"), expiresAt: date)
        }
    }
    func families() async throws -> [SharedFamily] {
        let uid = account.userID
        let indexes = try await list(["users", uid, "families"])
        var families: [SharedFamily] = []
        for index in indexes {
            let familyID = try value(fields(index), "familyID")
            do {
                let document = try await account.documentRequest(path: ["families", familyID])
                let f = try fields(document)
                families.append(SharedFamily(id: familyID, name: try value(f, "name"), ownerID: try value(f, "ownerID"), currency: try value(f, "currency")))
            } catch {
                // Revoked membership leaves only an opaque personal index; never show cached family data.
                if [403, 404].contains((error as NSError).code) { continue }
                throw error
            }
        }
        return families.sorted { $0.name < $1.name }
    }
    func create(name: String, displayName: String, currency: String) async throws -> SharedFamily {
        guard account.emailVerified else { throw FamilyError.invalid("Verify your account email before creating a shared family.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw FamilyError.invalid("Enter a family name up to 100 characters.") }
        let familyID = UUID().uuidString; let uid = account.userID
        let family = SharedFamily(id: familyID, name: name, ownerID: uid, currency: currency)
        try await commit([
            write("families/" + familyID, fields: ["name": string(name), "ownerID": string(uid), "currency": string(currency)], timestamp: "createdAt"),
            write("families/\(familyID)/members/\(uid)", fields: ["uid": string(uid), "email": string(account.email.lowercased()), "displayName": string(Self.displayName(displayName, email: account.email)), "role": string("owner")], timestamp: "joinedAt"),
            write("users/\(uid)/families/\(familyID)", fields: ["familyID": string(familyID)])
        ])
        return family
    }
    func incomingInvites() async throws -> [FamilyInvitation] {
        guard account.emailVerified else { return [] }
        return try await queryInvites("email", value: account.email.lowercased())
    }
    func sentInvites(familyID: String) async throws -> [FamilyInvitation] {
        try await queryInvites("inviterID", value: account.userID).filter { $0.familyID == familyID }
    }
    func invite(email: String, family: SharedFamily) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard InputValidation.email(email), email != account.email.lowercased() else { throw FamilyError.invalid("Enter another family member’s account email.") }
        let members = try await members(familyID: family.id)
        guard !members.contains(where: { $0.email.lowercased() == email }) else { throw FamilyError.invalid("This account is already a member.") }
        let pending = try await sentInvites(familyID: family.id)
        guard !pending.contains(where: { $0.email == email }) else { throw FamilyError.invalid("An invitation is already waiting for this email.") }
        try await commit([write("familyInvites/" + UUID().uuidString, fields: [
            "familyID": string(family.id), "familyName": string(family.name), "inviterID": string(account.userID), "email": string(email), "status": string("pending"),
            "expiresAt": ["timestampValue": FirestoreRecordCodec.timestamp(Date().addingTimeInterval(6 * 86400))]
        ], timestamp: "createdAt")])
    }
    func accept(_ invite: FamilyInvitation, displayName: String) async throws {
        guard invite.canAccept(email: account.email, verified: account.emailVerified) else { throw FamilyError.invalid("This invitation has expired, or you must verify and sign in with its matching email.") }
        let uid = account.userID
        var invitation = write("familyInvites/" + invite.id, fields: ["status": string("accepted"), "acceptedBy": string(uid)], create: false)
        invitation["updateMask"] = ["fieldPaths": ["status", "acceptedBy"]]
        var index = write("users/\(uid)/families/\(invite.familyID)", fields: ["familyID": string(invite.familyID)])
        index.removeValue(forKey: "currentDocument")
        try await commit([
            invitation,
            write("families/\(invite.familyID)/members/\(uid)", fields: ["uid": string(uid), "email": string(account.email.lowercased()), "displayName": string(Self.displayName(displayName, email: account.email)), "role": string("member"), "inviteID": string(invite.id)], timestamp: "joinedAt"),
            index
        ])
    }
    func cancel(_ invite: FamilyInvitation) async throws {
        var update = write("familyInvites/" + invite.id, fields: ["status": string("cancelled")], create: false)
        update["updateMask"] = ["fieldPaths": ["status"]]
        try await commit([update])
    }
    func members(familyID: String) async throws -> [FamilyMember] {
        try await list(["families", familyID, "members"]).map { document in
            let f = try fields(document)
            return FamilyMember(id: try value(f, "uid"), email: try value(f, "email"), displayName: try value(f, "displayName"), role: try value(f, "role"))
        }.sorted { $0.role == "owner" && $1.role != "owner" || ($0.role == $1.role && $0.email < $1.email) }
    }
    func remove(member: FamilyMember, familyID: String) async throws {
        guard member.role != "owner" else { throw FamilyError.invalid("The family owner cannot be removed.") }
        _ = try await account.documentRequest(path: ["families", familyID, "members", member.id], method: "DELETE")
        if member.id == account.userID { _ = try await account.documentRequest(path: ["users", member.id, "families", familyID], method: "DELETE") }
    }
    func rename(family: SharedFamily, name: String) async throws {
        guard family.ownerID == account.userID else { throw FamilyError.invalid("Only the household owner can rename this family.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw FamilyError.invalid("Enter a household name up to 100 characters.") }
        var operation = write("families/\(family.id)", fields: ["name": string(name)], create: false)
        operation["updateMask"] = ["fieldPaths": ["name"]]
        try await commit([operation])
    }
    func records(familyID: String) async throws -> [HouseholdRecord] {
        try await list(["families", familyID, "records"]).map(FirestoreRecordCodec.decode).sorted { $0.date < $1.date }
    }
    func save(_ record: HouseholdRecord, familyID: String) async throws {
        var saved = record
        if saved.kind != .expense {
            let activeEmails = try await members(familyID: familyID).map { $0.email.lowercased() }
            guard saved.assignee == "Everyone" || activeEmails.contains(saved.assignee.lowercased()) else {
                throw FamilyError.invalid("Choose an active member of this household, or Everyone.")
            }
        }
        if saved.kind == .bill {
            if saved.completed && saved.paidAt == nil { saved.paidAt = Date() }
            if !saved.completed { saved.paidAt = nil }
        }
        _ = try await account.documentRequest(path: ["families", familyID, "records", record.id.uuidString], method: "PATCH", body: FirestoreRecordCodec.encode(saved), query: [record.cloudRevision.map { URLQueryItem(name: "currentDocument.updateTime", value: $0) } ?? URLQueryItem(name: "currentDocument.exists", value: "false")])
    }
    func delete(_ record: HouseholdRecord, familyID: String) async throws {
        _ = try await account.documentRequest(path: ["families", familyID, "records", record.id.uuidString], method: "DELETE", query: record.cloudRevision.map { [URLQueryItem(name: "currentDocument.updateTime", value: $0)] } ?? [])
    }
    func messages(familyID: String, limit: Int = 100) async throws -> [FamilyMessage] {
        let safeLimit = min(max(limit, 1), 500)
        let response = try await account.documentRequest(path: ["families", familyID], method: "POST", body: ["structuredQuery": ["from": [["collectionId": "messages"]], "orderBy": [["field": ["fieldPath": "createdAt"], "direction": "DESCENDING"]], "limit": safeLimit]], operation: "runQuery")
        return try (response["documents"] as? [[String: Any]] ?? []).map { document in
            let f = try fields(document)
            guard let raw = f["createdAt"]?["timestampValue"] as? String, let date = Self.date(raw) else { throw URLError(.cannotParseResponse) }
            return FamilyMessage(id: try id(document), authorID: try value(f, "authorID"), authorName: try value(f, "authorName"), text: try value(f, "text"), date: date)
        }.reversed()
    }
    func send(text: String, displayName: String, familyID: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { throw FamilyError.invalid("Enter a message up to 4,000 characters.") }
        try await commit([write("families/\(familyID)/messages/" + UUID().uuidString, fields: ["authorID": string(account.userID), "authorName": string(Self.displayName(displayName, email: account.email)), "text": string(text)], timestamp: "createdAt")])
    }
    func announcements(familyID: String) async throws -> [FamilyAnnouncement] {
        let values = try await list(["families", familyID, "announcements"]).map { document in
            let f = try fields(document)
            guard let created = f["createdAt"]?["timestampValue"] as? String, let date = Self.date(created),
                  let important = f["important"]?["booleanValue"] as? Bool else { throw URLError(.cannotParseResponse) }
            return FamilyAnnouncement(id: try id(document), title: try value(f, "title"), body: try value(f, "body"), authorID: try value(f, "authorID"), authorName: try value(f, "authorName"), createdAt: date, important: important, revision: document["updateTime"] as? String)
        }
        return FamilyAnnouncement.ordered(values)
    }
    func saveAnnouncement(_ value: FamilyAnnouncement, familyID: String) async throws {
        if let error = value.validationError { throw FamilyError.invalid(error) }
        var fields: [String: Any] = ["title": string(value.title.trimmingCharacters(in: .whitespacesAndNewlines)), "body": string(value.body.trimmingCharacters(in: .whitespacesAndNewlines)), "authorID": string(value.authorID), "authorName": string(value.authorName), "important": ["booleanValue": value.important]]
        if value.revision != nil { fields["createdAt"] = ["timestampValue": FirestoreRecordCodec.timestamp(value.createdAt)] }
        var operation = write("families/\(familyID)/announcements/\(value.id)", fields: fields, timestamp: value.revision == nil ? "createdAt" : nil, create: value.revision == nil)
        if let revision = value.revision {
            operation["currentDocument"] = ["updateTime": revision]
            // Preserve the server's original timestamp precision and immutable authorship.
            operation["updateMask"] = ["fieldPaths": ["title", "body", "important"]]
        }
        try await commit([operation])
    }
    func deleteAnnouncement(_ value: FamilyAnnouncement, familyID: String) async throws {
        _ = try await account.documentRequest(path: ["families", familyID, "announcements", value.id], method: "DELETE", query: value.revision.map { [URLQueryItem(name: "currentDocument.updateTime", value: $0)] } ?? [])
    }
    private static func displayName(_ name: String, email: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? email : cleaned).prefix(100))
    }
    private static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]; return parser.date(from: value)
    }
}
