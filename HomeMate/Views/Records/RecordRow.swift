import SwiftUI

struct RecordRow: View {
    @EnvironmentObject private var dependencies: AppDependencies
    let record: HouseholdRecord
    var body: some View {
        ViewModelHost(make: RecordRowViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            RecordRowScreen(record: record, viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct RecordRowScreen: View {

    let record: HouseholdRecord
    @ObservedObject var viewModel: RecordRowViewModel

    private var assigneeLabel: String {
        AssignmentDisplay.label(for: record.assignee, accountEmail: viewModel.account.email, localName: viewModel.profile.name, members: viewModel.context?.members ?? [], shared: viewModel.context?.family != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: record.kind.icon).font(.title3.weight(.semibold)).foregroundStyle(DashboardPalette.green).frame(width: 48, height: 48).background(DashboardPalette.mint.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true).foregroundStyle(DashboardPalette.ink)
                    .strikethrough(record.completed && record.kind != .bill)
                Text("\(assigneeLabel) · \((ExpenseIntelligence.spendingDate(for: record) ?? record.date).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                if record.kind != .expense { RecordStatusBadge(record: record) }
            }
            Spacer()
            if record.amount > 0 { Text(viewModel.money(record.amount)).font(.body .weight(.bold)).foregroundStyle(DashboardPalette.green) }
        }.padding(.vertical, 9)
    }
}

/// State is shown separately from the button that changes it.
struct RecordStatusBadge: View {
    let record: HouseholdRecord
    private var title: String {
        if record.kind == .bill {
            if record.completed { return "Paid" }
            return record.date < Date() ? "Overdue" : "Unpaid"
        }
        return record.completed ? "Completed" : "Pending"
    }
    var body: some View {
        Label(title, systemImage: record.completed ? "checkmark.circle.fill" : title == "Overdue" ? "calendar.badge.exclamationmark" : "circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(record.completed ? DashboardPalette.green : title == "Overdue" ? DashboardPalette.red : DashboardPalette.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((record.completed ? DashboardPalette.green : title == "Overdue" ? DashboardPalette.red : Color.secondary).opacity(0.09), in: Capsule())
            .accessibilityLabel("Status: \(title)")
    }
}
