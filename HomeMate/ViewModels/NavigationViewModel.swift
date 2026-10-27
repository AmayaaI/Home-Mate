import Foundation
import Combine

@MainActor
final class NavigationViewModel: ScreenViewModel {
    var taskRecords: [HouseholdRecord] {
        activeRecords.filter { $0.kind == .task || $0.kind == .maintenance }
    }
    var pendingTasks: [HouseholdRecord] {
        taskRecords.filter { !$0.completed && $0.date >= Date() }.sorted { $0.date < $1.date }
    }
    var overdueTasks: [HouseholdRecord] {
        taskRecords.filter { !$0.completed && $0.date < Date() }.sorted { $0.date < $1.date }
    }
    var completedTasks: [HouseholdRecord] {
        taskRecords.filter(\.completed).sorted { $0.date > $1.date }
    }
    var otherTasks: [HouseholdRecord] {
        taskRecords.filter { $0.category.caseInsensitiveCompare("Other") == .orderedSame }
            .sorted { $0.completed != $1.completed ? !$0.completed : $0.date < $1.date }
    }
    var nextTask: HouseholdRecord? {
        overdueTasks.first ?? pendingTasks.first ?? completedTasks.first
    }
}
