import Foundation

// Firestore's typed REST document representation, shared by the app and tests.
enum FirestoreRecordCodec {
    enum InvalidDocument: LocalizedError {
        case invalid
        var errorDescription: String? { "The cloud record has missing or invalid fields." }
    }
    static func encode(_ record: HouseholdRecord) throws -> [String: Any] {
        guard record.validationError == nil else { throw InvalidDocument.invalid }
        guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.title.count <= 200, record.notes.count <= 10000,
              record.amount.isFinite, record.amount >= 0 else { throw InvalidDocument.invalid }
        var fields: [String: Any] = [
            "id": ["stringValue": record.id.uuidString], "kind": ["stringValue": record.kind.rawValue],
            "title": ["stringValue": record.title], "amount": ["doubleValue": record.amount],
            "dueAt": ["timestampValue": timestamp(record.date)], "category": ["stringValue": record.category],
            "assignee": ["stringValue": record.assignee], "important": ["booleanValue": record.important],
            "completed": ["booleanValue": record.completed], "notes": ["stringValue": record.notes]
        ]
        if let end = record.endDate { fields["endAt"] = ["timestampValue": timestamp(end)] }
        if let reference = record.referenceNumber, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["referenceNumber"] = ["stringValue": reference]
        }
        if let location = record.location { fields["location"] = ["stringValue": location] }
        if let phone = record.contactPhone { fields["contactPhone"] = ["stringValue": phone] }
        if let paidAt = record.paidAt { fields["paidAt"] = ["timestampValue": timestamp(paidAt)] }
        if let latitude = record.latitude, let longitude = record.longitude {
            fields["latitude"] = ["doubleValue": latitude]
            fields["longitude"] = ["doubleValue": longitude]
        }
        if let reminderEnabled = record.reminderEnabled { fields["reminderEnabled"] = ["booleanValue": reminderEnabled] }
        if let reminderDate = record.reminderDate { fields["reminderAt"] = ["timestampValue": timestamp(reminderDate)] }
        return ["fields": fields]
    }
    static func decode(_ document: [String: Any]) throws -> HouseholdRecord {
        guard let fields = document["fields"] as? [String: [String: Any]],
              let id = fields["id"]?["stringValue"] as? String, let uuid = UUID(uuidString: id),
              let rawKind = fields["kind"]?["stringValue"] as? String, let kind = RecordKind(rawValue: rawKind),
              let title = fields["title"]?["stringValue"] as? String,
              let timestamp = fields["dueAt"]?["timestampValue"] as? String, let date = date(timestamp),
              let category = fields["category"]?["stringValue"] as? String,
              let assignee = fields["assignee"]?["stringValue"] as? String,
              let important = fields["important"]?["booleanValue"] as? Bool,
              let completed = fields["completed"]?["booleanValue"] as? Bool,
              let notes = fields["notes"]?["stringValue"] as? String else { throw InvalidDocument.invalid }
        let amount = (fields["amount"]?["doubleValue"] as? NSNumber)?.doubleValue
            ?? (fields["amount"]?["integerValue"] as? String).flatMap(Double.init)
        guard let amount, amount.isFinite, amount >= 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200, notes.count <= 10000 else { throw InvalidDocument.invalid }
        if let name = document["name"] as? String, name.components(separatedBy: "/").last != id { throw InvalidDocument.invalid }
        let endAt = fields["endAt"]?["timestampValue"] as? String
        let end = endAt.flatMap(Self.date)
        guard endAt == nil || (end != nil && end! >= date) else { throw InvalidDocument.invalid }
        let referenceNumber = fields["referenceNumber"]?["stringValue"] as? String
        guard (referenceNumber?.count ?? 0) <= 200 else { throw InvalidDocument.invalid }
        var record = HouseholdRecord(id: uuid, kind: kind, title: title, amount: amount, date: date, category: category, assignee: assignee, important: important, completed: completed, referenceNumber: referenceNumber, notes: notes, endDate: end, location: fields["location"]?["stringValue"] as? String, contactPhone: fields["contactPhone"]?["stringValue"] as? String)
        if let payment = fields["paidAt"] {
            guard let paidAt = payment["timestampValue"] as? String,
                  let paidDate = Self.date(paidAt) else { throw InvalidDocument.invalid }
            record.paidAt = paidDate
        }
        record.cloudRevision = document["updateTime"] as? String
        if let reminder = fields["reminderEnabled"] {
            guard let enabled = reminder["booleanValue"] as? Bool else { throw InvalidDocument.invalid }
            record.reminderEnabled = enabled
        }
        if let reminder = fields["reminderAt"] {
            guard let value = reminder["timestampValue"] as? String, let date = Self.date(value) else { throw InvalidDocument.invalid }
            record.reminderDate = date
        }
        if fields["latitude"] != nil || fields["longitude"] != nil {
            func number(_ key: String) -> Double? {
                (fields[key]?["doubleValue"] as? NSNumber)?.doubleValue ?? (fields[key]?["integerValue"] as? String).flatMap(Double.init)
            }
            guard let latitude = number("latitude"), let longitude = number("longitude") else { throw InvalidDocument.invalid }
            record.latitude = latitude; record.longitude = longitude
        }
        guard record.validationError == nil else { throw InvalidDocument.invalid }
        return record
    }
    static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

@MainActor
final class FirebaseHouseholdAPI {
    private let account: CloudAccount
    init(account: CloudAccount) { self.account = account }
    func save(_ record: HouseholdRecord) async throws {
        _ = try await account.firestoreRequest(path: ["records", record.id.uuidString], method: "PATCH", body: FirestoreRecordCodec.encode(record))
    }
    func record(id: UUID) async throws -> HouseholdRecord {
        try FirestoreRecordCodec.decode(await account.firestoreRequest(path: ["records", id.uuidString]))
    }
    func records() async throws -> [HouseholdRecord] {
        var result: [HouseholdRecord] = []
        var token: String?
        var seenTokens = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await account.firestoreRequest(path: ["records"], query: query)
            result += try (page["documents"] as? [[String: Any]] ?? []).map(FirestoreRecordCodec.decode)
            token = page["nextPageToken"] as? String
            if token?.isEmpty == true { token = nil }
            if let token, !seenTokens.insert(token).inserted { throw FirestoreRecordCodec.InvalidDocument.invalid }
        } while token != nil
        return result.sorted { $0.date < $1.date }
    }
    func delete(id: UUID) async throws {
        _ = try await account.firestoreRequest(path: ["records", id.uuidString], method: "DELETE")
    }
}
