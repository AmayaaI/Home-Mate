import Foundation
import Combine

@MainActor
final class DashboardViewModel: ScreenViewModel {
    @Published var selected: HouseholdRecord?
    @Published var scanning = false
    @Published var showReminders = false
    @Published var showChat = false
    @Published var editingBulletin = false
    @Published var editingBudget = false
    @Published var budgetDraft = 0.0
    @Published var bulletinTitleDraft = ""
    @Published var bulletinBodyDraft = ""

    func assigneeLabel(_ record: HouseholdRecord) -> String {
        AssignmentDisplay.label(for: record.assignee, accountEmail: accountEmail,
                                localName: profile.name, members: context?.members ?? [],
                                shared: context?.family != nil)
    }

    var pending: [HouseholdRecord] { activeRecords.filter { !$0.completed && $0.kind != .expense }.sorted { $0.priority > $1.priority } }
    var bills: [HouseholdRecord] { pending.filter { $0.kind == .bill }.sorted { $0.date < $1.date } }
    var tasks: [HouseholdRecord] {
        activeRecords.filter { [.task, .maintenance].contains($0.kind) && Calendar.current.isDateInToday($0.date) }
            .sorted { !$0.completed && $1.completed }
    }
    var spending: Double { monthlyExpenses.reduce(0) { $0 + $1.amount } }
    var breakdown: [(String, Double)] {
        let categories = Dictionary(grouping: monthlyExpenses, by: \.category).map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.1 > $1.1 }
        if categories.count <= 3 { return categories }
        return Array(categories.prefix(2)) + [("Other", categories.dropFirst(2).reduce(0) { $0 + $1.1 })]
    }
    var greetingText: String { let hour = Calendar.current.component(.hour, from: Date()); return hour < 12 ? "Good Morning" : hour < 18 ? "Good Afternoon" : "Good Evening" }

    func prepareBulletin() { bulletinTitleDraft = preferences.bulletinTitle; bulletinBodyDraft = preferences.bulletinBody }
    func prepareBudget() { budgetDraft = preferences.monthlyBudget }
    var validBudget: Bool { budgetDraft.isFinite && (0...1_000_000_000_000).contains(budgetDraft) }
    var validBulletin: Bool { bulletinTitleDraft.count <= 200 && bulletinBodyDraft.count <= 10000 }
    func saveBudget() { guard isActive else { return };
        var value = store.preferences; value.monthlyBudget = budgetDraft
        if store.updatePreferences(value) { editingBudget = false }
    }
    func saveBulletin() { guard isActive else { return };
        var value = store.preferences
        var notices = value.resolvedPrivateNotices
        var notice = notices.first ?? FamilyAnnouncement(authorID: accountUserID, authorName: profile.name.isEmpty ? "Me" : profile.name)
        notice.title = bulletinTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        notice.body = bulletinBodyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        notice.revision = "private"
        notices.removeAll { $0.id == notice.id }
        if !notice.title.isEmpty || !notice.body.isEmpty { notices.append(notice) }
        value.setPrivateNotices(notices)
        if store.updatePreferences(value) { editingBulletin = false }
    }
    func toggleLike() { guard isActive else { return }; var value = store.preferences; value.bulletinLiked.toggle(); store.updatePreferences(value) }
    func acknowledge() { guard isActive else { return }; var value = store.preferences; value.bulletinAcknowledged.toggle(); store.updatePreferences(value) }

}
