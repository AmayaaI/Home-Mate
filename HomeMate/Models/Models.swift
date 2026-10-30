import Foundation

 enum RecordKind: String, Codable, CaseIterable, Identifiable {
    case task = "Tasks", bill = "Bills", maintenance = "Maintenance", expense = "Expenses", event = "Events"
    var id: String { rawValue }
    var icon: String {
        switch self { case .task: "checklist"; case .bill: "doc.text"; case .maintenance: "wrench.and.screwdriver"; case .expense: "creditcard"; case .event: "person.3" }
    }
}

/// The Tasks tab deliberately treats maintenance as household work alongside tasks.
/// Keeping this query outside SwiftUI makes the same rules testable for private and shared homes.
enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All Accessible Tasks", mine = "Assigned to Me", pending = "Pending", important = "Important", overdue = "Overdue", completed = "Completed"
    var id: String { rawValue }

    func includes(_ record: HouseholdRecord, shared: Bool, accountEmail: String, localName: String, now: Date = Date()) -> Bool {
        guard record.kind == .task || record.kind == .maintenance else { return false }
        switch self {
        case .all: return true
        case .mine:
            let assignee = record.assignee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if shared { return assignee == accountEmail.lowercased() || assignee == "everyone" }
            return assignee == "me" || assignee == localName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() || assignee == "everyone"
        case .pending: return !record.completed && record.date >= now
        case .important: return !record.completed && record.important
        case .overdue: return !record.completed && record.date < now
        case .completed: return record.completed
        }
    }
}

/// Bill-specific states keep payment work visible without mixing paid records
/// into the upcoming and overdue lists.
enum BillFilter: String, CaseIterable, Identifiable {
    case all = "All Bills", toPay = "To Pay", overdue = "Overdue", upcoming = "Upcoming", paid = "Paid"
    var id: String { rawValue }

    func includes(_ record: HouseholdRecord, now: Date = Date()) -> Bool {
        guard record.kind == .bill else { return false }
        switch self {
        case .all: return true
        case .toPay: return !record.completed
        case .overdue: return !record.completed && record.date < now
        case .upcoming: return !record.completed && record.date >= now
        case .paid: return record.completed
        }
    }
}
struct HouseholdRecord: Identifiable, Codable {
    var id = UUID()
    var kind: RecordKind
    var title: String
    var amount: Double = 0
    var date = Date()
    var category = "Other"
    var assignee = "Me"
    var important = false
    var completed = false
    /// The bill or provider's own reference, separate from free-form notes.
    var referenceNumber: String?
    var notes = ""
    var endDate: Date?
    var location: String?
    var contactPhone: String?
    var paidAt: Date?
    var cloudRevision: String?
    var latitude: Double?
    var longitude: Double?
    /// nil preserves the existing household-level reminder behaviour for older records.
    var reminderEnabled: Bool?
    /// nil preserves the automatic reminder timing for older records.
    var reminderDate: Date?
    var priority: Int {
        (date < Date() ? 50 : 0) + (important ? 30 : 0) + (date.timeIntervalSinceNow < 172800 ? 20 : 0) + (amount > 10000 ? 10 : 0)
    }
}

enum ReminderSchedule {
    static func defaultDate(for record: HouseholdRecord, now: Date = Date()) -> Date? {
        guard record.kind != .expense, record.date > now else { return nil }
        let oneDayBefore = record.date.addingTimeInterval(-86_400)
        if oneDayBefore > now { return oneDayBefore }
        return now.addingTimeInterval(record.date.timeIntervalSince(now) / 2)
    }

    static func date(for record: HouseholdRecord, now: Date = Date()) -> Date? {
        guard !record.completed, record.kind != .expense, record.reminderEnabled != false else { return nil }
        if let custom = record.reminderDate {
            return custom > now && custom < record.date ? custom : nil
        }
        return defaultDate(for: record, now: now)
    }
}
struct HouseholdProfile: Codable {
    var name = ""
    var household = "My Home"
    var members = "Me"
    var currency = "LKR"
    var reminders = true
    var onboarded = false
    var personalDetails: PersonalDetails?
    var memberNames: [String] {
        var seen = Set<String>()
        return members.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct PersonalDetails: Codable {
    var fullName = ""
    var nickname = ""
    var email = ""
    var countryCode = "+94"
    var phone = ""
    var nic = ""
    var role = "Member"
    var emergencyName = ""
    var emergencyPhone = ""
    var avatarData: Data?
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var author: String
    var text: String
    var date = Date()
    var isMine = true
    var isSample = false
    var photoData: Data?
    var audioFile: String?
    var audioData: Data?
    var recordID: UUID?
    var replyPreview: String?
    var reaction: String?
}

// Calendar math is separate from the UI so month boundaries are easy to verify.
struct CalendarMonth {
    var date: Date
    var calendar = Calendar.current
    var start: Date { calendar.dateInterval(of: .month, for: date)!.start }
    var days: [Date] {
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let cells = ((offset + count + 6) / 7) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }
    func moving(_ offset: Int, preserving selected: Date) -> Date {
        let next = calendar.date(byAdding: .month, value: offset, to: start)!
        let day = min(calendar.component(.day, from: selected), calendar.range(of: .day, in: .month, for: next)!.count)
        return calendar.date(byAdding: .day, value: day - 1, to: next)!
    }
}

struct HouseholdPreferences: Codable, Equatable {
    var appearance: String?
    var privateNotices: [FamilyAnnouncement]?
    var resolvedPrivateNotices: [FamilyAnnouncement] {
        if let privateNotices { return FamilyAnnouncement.ordered(privateNotices) }
        guard !bulletinTitle.isEmpty || !bulletinBody.isEmpty else { return [] }
        return [FamilyAnnouncement(id: "legacy-private-bulletin", title: bulletinTitle, body: bulletinBody,
                                   authorID: "", authorName: "Me", createdAt: .distantPast, revision: "private")]
    }
    mutating func setPrivateNotices(_ values: [FamilyAnnouncement]) {
        privateNotices = FamilyAnnouncement.ordered(values)
        bulletinTitle = privateNotices?.first?.title ?? ""
        bulletinBody = privateNotices?.first?.body ?? ""
        bulletinLiked = false
        bulletinAcknowledged = false
    }

    var monthlyBudget = 0.0
    var bulletinTitle = ""
    var bulletinBody = ""
    var bulletinLiked = false
    var bulletinAcknowledged = false
}

enum InputValidation {
    static func email(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= 254 && value.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func phone(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        guard (7...15).contains(digits.count), trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || "+ -()".contains($0) }) else { return false }
        return !trimmed.dropFirst().contains("+")
    }
    static func mobile(_ number: String, countryCode: String) -> Bool {
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if number.isEmpty { return true }
        let code = countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: #"^\+[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil,
              phone(number), !number.contains("+") else { return false }
        let digits = number.filter { $0.isASCII && $0.isNumber }
        if code == "+94" {
            return digits.range(of: #"^(07[0-9]{8}|7[0-9]{8})$"#, options: .regularExpression) != nil
        }
        if code == "+1" { return digits.count == 10 }
        return (7...15).contains(code.dropFirst().count + digits.count)
    }

}
extension HouseholdRecord {
    /// Entry validation only: loading legacy/future records must not invalidate the entire store.
    func expenseDateError(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard kind == .expense else { return nil }
        guard date.timeIntervalSince1970.isFinite else { return "Choose a valid expense date." }
        return calendar.compare(date, to: now, toGranularity: .day) == .orderedDescending
            ? "Expenses must be dated today or earlier. Choose when this expense occurred." : nil
    }
    var validationError: String? {
        if (latitude == nil) != (longitude == nil) { return "Choose a complete map location." }
        if let latitude, let longitude, !latitude.isFinite || !longitude.isFinite || !(-90...90).contains(latitude) || !(-180...180).contains(longitude) { return "Choose a valid map location." }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 { return "Enter a title between 1 and 200 characters." }
        if !amount.isFinite || amount < 0 || amount > 1_000_000_000_000 { return "Enter an amount between 0 and 1 trillion." }
        if category.count > 100 || assignee.count > 254 { return "Category or assignee is too long." }
        if notes.count > 10000 { return "Notes must be 10,000 characters or fewer." }
        if (referenceNumber?.count ?? 0) > 200 { return "Reference number must be 200 characters or fewer." }
        if (location?.count ?? 0) > 500 { return "Location must be 500 characters or fewer." }
        if (contactPhone?.count ?? 0) > 50 || !InputValidation.phone(contactPhone ?? "") { return "Enter a valid contact phone number." }
        if !date.timeIntervalSince1970.isFinite || abs(date.timeIntervalSince1970) > 253_402_214_400 { return "Choose a valid date." }
        if let reminderDate, (!reminderDate.timeIntervalSince1970.isFinite || reminderDate >= date) { return "Choose a reminder time before the activity." }
        if let endDate, !endDate.timeIntervalSince1970.isFinite || endDate < date { return "End time must be after the start time." }
        if let paidAt, (!paidAt.timeIntervalSince1970.isFinite || abs(paidAt.timeIntervalSince1970) > 253_402_214_400) { return "Choose a valid payment date." }
        return nil
    }
}
extension HouseholdProfile {
    var validationError: String? {
        if onboarded && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || household.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberNames.isEmpty) { return "Enter your name, household name, and at least one member." }
        if memberNames.count > 20 || memberNames.contains(where: { $0.count > 100 }) { return "Use up to 20 members, with names of 100 characters or fewer." }
        if name.count > 200 || household.count > 200 || members.count > 2000 { return "Name or household details are too long." }
        if !["LKR", "USD", "GBP", "EUR", "INR"].contains(currency) { return "Select a supported currency." }
        if let details = personalDetails {
            if !details.email.isEmpty && !InputValidation.email(details.email) { return "Enter a valid contact email address." }
            if !InputValidation.mobile(details.phone, countryCode: details.countryCode) { return "Enter a valid mobile number for the selected country code. For +94 use 0771234567 or 771234567." }
            if !InputValidation.phone(details.emergencyPhone) { return "Enter a valid emergency phone number (7–15 digits)." }
            if details.fullName.count > 200 || details.nickname.count > 200 || details.nic.count > 50 || details.emergencyName.count > 200 { return "Personal information is too long." }
        }
        return nil
    }
}

/// Private account data. Device permissions, biometric locks and diagnostic counters stay local.
struct AccountSnapshot: Codable {
    var profile = HouseholdProfile()
    var records: [HouseholdRecord] = []
    var messages: [ChatMessage] = []
    var preferences = HouseholdPreferences()

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    static func same<T: Encodable>(_ a: T, _ b: T) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(a) == encoder.encode(b)
    }
    /// Apply only locally changed fields/items to the latest server snapshot.
    /// Absence relative to the baseline represents a deletion, not an empty-device reset.
    static func merge(local: Self, base: Self, remote: Self) throws -> Self {
        func fields<T: Codable>(_ local: T, _ base: T, _ remote: T) throws -> T {
            let encoder = JSONEncoder()
            let l = try JSONSerialization.jsonObject(with: encoder.encode(local)) as! [String: Any]
            let b = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
            var r = try JSONSerialization.jsonObject(with: encoder.encode(remote)) as! [String: Any]
            for key in Set(l.keys).union(b.keys) {
                let lv = l[key] ?? NSNull(), bv = b[key] ?? NSNull()
                if !NSDictionary(dictionary: ["v": lv]).isEqual(to: ["v": bv]) { r[key] = l[key] }
            }
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: r))
        }
        func items<T: Codable & Identifiable>(_ local: [T], _ base: [T], _ remote: [T]) throws -> [T] where T.ID: Hashable {
            guard Set(local.map(\.id)).count == local.count, Set(base.map(\.id)).count == base.count,
                  Set(remote.map(\.id)).count == remote.count else { throw URLError(.cannotParseResponse) }
            let old = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
            let localIDs = Set(local.map(\.id))
            var result = remote.filter { old[$0.id] == nil || localIDs.contains($0.id) }
            for item in local {
                if let prior = old[item.id], try same(item, prior) { continue }
                if let index = result.firstIndex(where: { $0.id == item.id }) { result[index] = item }
                else { result.append(item) }
            }
            return result
        }
        return try Self(profile: fields(local.profile, base.profile, remote.profile),
                        records: items(local.records, base.records, remote.records),
                        messages: items(local.messages, base.messages, remote.messages),
                        preferences: fields(local.preferences, base.preferences, remote.preferences))
    }
}
