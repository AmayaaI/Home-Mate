import Foundation

@main
struct VerifyHomeWidget {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = HomeWidgetActivity(id: UUID(), kind: .bill, title: "Electricity", date: now.addingTimeInterval(-86400), completed: false)
        let future = HomeWidgetActivity(id: UUID(), kind: .task, title: "Shopping", date: now.addingTimeInterval(86400), completed: false)
        let complete = HomeWidgetActivity(id: UUID(), kind: .task, title: "Finished", date: now, completed: true)
        let pastEvent = HomeWidgetActivity(id: UUID(), kind: .event, title: "Yesterday", date: now.addingTimeInterval(-7200), completed: false)
        let ongoing = HomeWidgetActivity(id: UUID(), kind: .event, title: "Dinner", date: now.addingTimeInterval(-600), endDate: now.addingTimeInterval(600), completed: false)
        let snapshot = HomeWidgetSnapshot.make(householdName: "  My family  ", activities: [future, complete, pastEvent, ongoing, overdue], at: now)
        precondition(snapshot.householdName == "My family")
        precondition(snapshot.activities.map(\.id) == [overdue.id, ongoing.id, future.id], "Keep overdue work, skip completed work and expired events, and sort by date.")
        precondition(snapshot.pendingActivities(at: now.addingTimeInterval(601)).map(\.id) == [overdue.id, future.id], "Events disappear from future timeline entries.")
        precondition(HomeWidgetSnapshot.make(householdName: " ", activities: [], at: now).householdName == "My Home")
        let later = HomeWidgetSnapshot.make(householdName: "My family", activities: snapshot.activities, at: now.addingTimeInterval(1))
        precondition(snapshot.hasSameContents(as: later), "No redundant timeline reload for timestamps alone.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeMateWidgetCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try HomeWidgetSnapshotStore.write(snapshot, directory: directory)
        precondition(saved)
        precondition(HomeWidgetSnapshotStore.read(directory: directory) == snapshot, "The extension reads the same Codable data the app wrote.")
        let cleared = HomeWidgetSnapshot.signedOut(at: now)
        let clearedSaved = try HomeWidgetSnapshotStore.write(cleared, directory: directory)
        precondition(clearedSaved)
        precondition(HomeWidgetSnapshotStore.read(directory: directory).activities.isEmpty, "Signing out replaces all previous personal widget data.")
        precondition(!HomeWidgetSnapshotStore.read(directory: directory).isActive)
        precondition(!HomeWidgetSnapshotStore.read(directory: directory.appendingPathComponent("missing")).isActive, "Missing data has an honest sign-in state.")
        let unavailableSaved = try HomeWidgetSnapshotStore.write(snapshot, directory: nil)
        precondition(!unavailableSaved, "Missing App Groups capability does not write to an unrelated location.")
        print("Widget snapshot checks passed: filtering, ordering, expiration, persistence, logout clearing and unavailable container.")
    }
}
