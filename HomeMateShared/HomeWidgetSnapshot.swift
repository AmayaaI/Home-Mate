import Foundation

/// Only the small amount of personal data needed by the Home Screen widget.
/// Authentication tokens, notes, attachments and financial amounts never leave the app.
struct HomeWidgetActivity: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case task, bill, maintenance, event

        var symbol: String {
            switch self {
            case .task: return "checkmark.circle"
            case .bill: return "doc.text"
            case .maintenance: return "wrench.and.screwdriver"
            case .event: return "calendar"
            }
        }

        var label: String {
            switch self {
            case .task: return "Task"
            case .bill: return "Bill"
            case .maintenance: return "Maintenance"
            case .event: return "Event"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var title: String
    var date: Date
    var endDate: Date?
    var completed: Bool

    func isPending(at date: Date) -> Bool {
        guard !completed else { return false }
        // Tasks and bills remain visible when overdue. Past events disappear.
        return kind != .event || (endDate ?? self.date.addingTimeInterval(3600)) > date
    }
}

struct HomeWidgetSnapshot: Codable, Equatable {
    var version = 1
    var isActive: Bool
    var householdName: String
    var activities: [HomeWidgetActivity]
    var updatedAt: Date

    static func signedOut(at date: Date = Date()) -> Self {
        Self(isActive: false, householdName: "HomeMate", activities: [], updatedAt: date)
    }

    static func make(householdName: String, activities: [HomeWidgetActivity], at date: Date = Date()) -> Self {
        let name = householdName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            isActive: true,
            householdName: name.isEmpty ? "My Home" : name,
            activities: activities.filter { $0.isPending(at: date) }.sorted {
                if $0.date == $1.date { return $0.id.uuidString < $1.id.uuidString }
                return $0.date < $1.date
            },
            updatedAt: date
        )
    }

    func pendingActivities(at date: Date) -> [HomeWidgetActivity] {
        activities.filter { $0.isPending(at: date) }
    }

    func hasSameContents(as other: Self) -> Bool {
        version == other.version && isActive == other.isActive && householdName == other.householdName && activities == other.activities
    }
}

enum HomeWidgetSnapshotStore {
    static let appGroup = "group.com.homemate.app.shared"
    static let widgetKind = "HomeMateUpcomingWidget"
    private static let filename = "upcoming-home.json"

    static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    @discardableResult
    static func write(_ snapshot: HomeWidgetSnapshot, directory: URL? = sharedDirectory) throws -> Bool {
        guard let directory else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let url = directory.appendingPathComponent(filename)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return true
    }

    static func read(directory: URL? = sharedDirectory) -> HomeWidgetSnapshot {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let snapshot = try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data),
              snapshot.version == 1 else { return .signedOut() }
        return snapshot
    }
}
