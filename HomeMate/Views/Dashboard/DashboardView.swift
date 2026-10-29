import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: DashboardViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            DashboardViewScreen(viewModel: model)
        }
        .id(dependencies.household.identity)
    }
}

private struct DashboardViewScreen: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.colorScheme) private var colorScheme
    @State private var creatingRecord: HouseholdRecord?
    @State private var showingProfile = false
    @State private var showingErrandsMap = false
    @ObservedObject var viewModel: DashboardViewModel

    private var firstName: String {
        viewModel.profile.name.split(separator: " ").first.map(String.init) ?? viewModel.profile.name
    }
    private var urgentRecords: [HouseholdRecord] {
        viewModel.pending.filter { $0.date < Date() || $0.important }
            .sorted { $0.priority > $1.priority }
    }
    private var nextActivity: HouseholdRecord? {
        viewModel.pending.first { record in !urgentRecords.contains { $0.id == record.id } }
    }
    private var budgetUsage: Double {
        guard viewModel.preferences.monthlyBudget > 0 else { return 0 }
        return min(viewModel.spending / viewModel.preferences.monthlyBudget, 9.99)
    }
    private var previousMonthSpending: Double {
        let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return ExpenseIntelligence.spendingRecords(viewModel.activeRecords, inMonthOf: previousMonth)
            .reduce(0) { $0 + $1.amount }
    }
    private var spendingHistory: [(date: Date, total: Double)] {
        let calendar = Calendar.current
        return (0..<5).reversed().compactMap { monthsBack in
            guard let date = calendar.date(byAdding: .month, value: -monthsBack, to: Date()) else { return nil }
            let total = ExpenseIntelligence.spendingRecords(viewModel.activeRecords, inMonthOf: date)
                .reduce(0) { $0 + $1.amount }
            return (date, total)
        }
    }
    private var upcomingErrand: HouseholdRecord? {
        let today = Calendar.current.startOfDay(for: Date())
        return viewModel.activeRecords
            .filter { record in
                !record.completed && [.task, .maintenance, .event].contains(record.kind)
                    && record.date >= today
                    && (!(record.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ErrandMapPolicy.hasPin(record))
            }
            .min { $0.date < $1.date }
    }
    private var dashboardCategories: [(name: String, total: Double)] {
        Array(ExpenseIntelligence.categories.prefix(4)).map { category in
            (category, viewModel.spending(in: category))
        }
    }
    private var recentExpenses: [HouseholdRecord] {
        viewModel.activeRecords.filter { $0.kind == .expense }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    welcome
                    householdHero
                    activityMetrics
                    quickActions
                    spendingSection
                    categorySection
                    errandSection
                    budgetAndInsightsSection
                    nextUp
                    recentExpensesSection
                    tasksSection
                    billsSection
                    if dependencies.household.family != nil {
                        NavigationLink {
                            HouseholdAnnouncementsView(context: dependencies.household, userID: viewModel.accountUserID, authorName: viewModel.profile.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Household announcements", systemImage: "megaphone.fill").font(.headline)
                                if let latest = dependencies.household.announcements.first {
                                    Text(latest.title).font(.subheadline.weight(.semibold))
                                    Text(latest.body).lineLimit(3)
                                    Text(latest.authorName).font(.caption).foregroundStyle(.secondary)
                                } else { Text("Share the first update with your household.") }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding().homeCard()
                        }.buttonStyle(.plain)
                    } else { familySection }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 42)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .tint(DashboardPalette.green)
            .sheet(item: $viewModel.selected) { RecordDetailView(record: $0) }
            .sheet(item: $creatingRecord) { RecordEditor(record: $0) }
            .sheet(isPresented: $viewModel.scanning) { ScanReviewView() }
            .fullScreenCover(isPresented: $viewModel.showChat) {
                NavigationStack { FamilySharingView() }
            }
            .sheet(isPresented: $viewModel.showReminders) { remindersSheet }
            .sheet(isPresented: $viewModel.editingBudget) { budgetSheet }
            .sheet(isPresented: $viewModel.editingBulletin) { bulletinSheet }
            .sheet(isPresented: $showingErrandsMap) { ErrandsMapView() }
            .navigationDestination(isPresented: $showingProfile) {
                ProfileSettingsView(accountEmail: viewModel.accountSignedIn ? viewModel.accountEmail : "")
            }
        }
    }

    private var welcome: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 380
            ZStack(alignment: .topLeading) {
                Image("DashboardWelcome")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: Color(uiColor: .systemGroupedBackground).opacity(colorScheme == .dark ? 0.78 : 0.24), location: 0),
                            .init(color: Color(uiColor: .systemGroupedBackground).opacity(colorScheme == .dark ? 0.40 : 0.08), location: 0.34),
                            .init(color: .clear, location: 0.72)
                        ], startPoint: .leading, endPoint: .trailing)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(uiColor: .systemGroupedBackground).opacity(0.66)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                    }
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.24 : 0))

                VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button { viewModel.showReminders = true } label: {
                            Image(systemName: viewModel.pending.isEmpty ? "bell" : "bell.badge")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(DashboardPalette.green)
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Activity reminders")
                        Button { showingProfile = true } label: {
                            ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData,
                                          name: viewModel.profile.name, size: 42)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open profile settings")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.greetingText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? .white.opacity(0.88) : Color(red: 0.13, green: 0.23, blue: 0.21))
                        Text(firstName.isEmpty ? "Welcome home" : firstName)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .foregroundStyle(colorScheme == .dark ? .white : Color(red: 0.07, green: 0.16, blue: 0.14))
                        Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DashboardPalette.green)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: geometry.size.width * (compact ? 0.62 : 0.56), alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .contain)
        }
        .frame(height: 238)
    }

    private var householdHero: some View {
        DashboardSurface {
            HStack {
                Text("Family Hub").font(.headline.weight(.bold))
                Spacer(minLength: 4)
                Button { viewModel.showChat = true } label: {
                    Label("Manage", systemImage: "person.2")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(DashboardPalette.green.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open family hub")
            }
        }
    }

    private var activityMetrics: some View {
        HStack(alignment: .top, spacing: 9) {
            heroMetric("Open activities", value: viewModel.pending.count, icon: "clock")
            heroMetric("Tasks today", value: viewModel.tasks.count, icon: "checklist")
            heroMetric("Unpaid bills", value: viewModel.bills.count, icon: "doc.text")
        }
    }

    private func heroMetric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                Text(value.formatted()).font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
            }
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(9)
        .background(DashboardPalette.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Make room for easy").font(.headline)
                Spacer()
                Text("QUICK ADD").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                quickAction("New task", icon: "plus", tint: DashboardPalette.green) {
                    creatingRecord = HouseholdRecord(kind: .task, title: "", assignee: viewModel.recommendedMember)
                }
                quickAction("Add bill", icon: "doc.badge.plus", tint: Color(uiColor: .systemOrange)) {
                    creatingRecord = HouseholdRecord(kind: .bill, title: "", assignee: viewModel.recommendedMember)
                }
                quickAction("Add event", icon: "calendar.badge.plus", tint: Color(uiColor: .systemPurple)) {
                    creatingRecord = HouseholdRecord(kind: .event, title: "", assignee: viewModel.recommendedMember)
                }
            }
        }
    }

    private func quickAction(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint).frame(width: 48, height: 48)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 98)
            .padding(8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }

    private var nextUp: some View {
        DashboardSurface {
            HStack {
                Label("Needs Attention", systemImage: "exclamationmark.circle.fill").font(.headline)
                Spacer()
                Text("\(viewModel.pending.count) open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.pending.isEmpty ? DashboardPalette.green : DashboardPalette.red)
            }
            if urgentRecords.isEmpty, let nextActivity {
                Button { viewModel.selected = nextActivity } label: {
                    HStack(spacing: 12) {
                        Image(systemName: nextActivity.kind.icon)
                            .foregroundStyle(DashboardPalette.green)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nextActivity.title).font(.subheadline.weight(.semibold))
                            Text(nextActivity.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 48)
                }
                .buttonStyle(.plain)
            } else if !urgentRecords.isEmpty {
                ForEach(Array(urgentRecords.enumerated()), id: \.offset) { index, record in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            Image(systemName: record.date < Date() ? "exclamationmark.triangle.fill" : "star.fill")
                                .font(.caption2.weight(.bold))
                            Text(record.date < Date() ? "OVERDUE" : "IMPORTANT")
                                .font(.caption2.weight(.bold)).tracking(0.6)
                            Spacer()
                            Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(DashboardPalette.red)
                        HStack(spacing: 10) {
                            Image(systemName: record.kind.icon)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DashboardPalette.green)
                                .frame(width: 38, height: 38)
                                .background(DashboardPalette.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            Button { viewModel.selected = record } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text("\(viewModel.assigneeLabel(record)) · \(record.kind.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if record.amount > 0 {
                                Text(viewModel.money(record.amount))
                                    .font(.subheadline.weight(.bold)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        HStack(spacing: 10) {
                            Button { viewModel.selected = record } label: {
                                Label("View Details", systemImage: "arrow.up.right")
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(.bordered)
                            Button { viewModel.toggle(record) } label: {
                                Label(record.kind == .bill ? "Mark paid" : "Complete", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    if index < urgentRecords.count - 1 { Divider() }
                }
                if let nextActivity {
                    Button { viewModel.selected = nextActivity } label: {
                        HStack(spacing: 10) {
                            Image(systemName: nextActivity.kind.icon).foregroundStyle(DashboardPalette.green)
                            Text(nextActivity.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(nextActivity.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Label("Everything is up to date", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(DashboardPalette.green)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
    }

    private var tasksSection: some View {
        DashboardSurface {
            HStack {
                Text("Today's tasks").font(.headline)
                Text("\(viewModel.tasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DashboardPalette.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DashboardPalette.green.opacity(0.10), in: Capsule())
                Spacer()
                Button {
                    creatingRecord = HouseholdRecord(kind: .task, title: "",
                                                      assignee: viewModel.recommendedMember)
                } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Add task")
            }
            if viewModel.tasks.isEmpty {
                emptyRow("No tasks scheduled for today.", icon: "checkmark.circle")
            } else {
                ForEach(viewModel.tasks.prefix(3)) { task in
                    HStack(spacing: 8) {
                        Button { viewModel.toggle(task) } label: {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(DashboardPalette.green)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.completed ? "Reopen \(task.title)" : "Complete \(task.title)")
                        Button { viewModel.selected = task } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .strikethrough(task.completed)
                                        .lineLimit(2)
                                    Text(viewModel.assigneeLabel(task))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                Text(task.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(task.title)")
                    }
                    if task.id != viewModel.tasks.prefix(3).last?.id { Divider() }
                }
            }
            NavigationLink("View all tasks") {
                RecordsView(kind: .task)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    private var spendingSection: some View {
        DashboardSurface {
            HStack {
                Image(systemName: "wallet.bifold.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [DashboardPalette.green, DashboardPalette.green.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly spending").font(.headline)
                    Text(Date().formatted(.dateTime.month(.wide).year()))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { viewModel.scanning = true } label: {
                    Image(systemName: "doc.viewfinder").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Scan receipt")
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.money(viewModel.spending))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Label("Spent this month", systemImage: "arrow.down.right")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    if previousMonthSpending > 0 {
                        let change = (viewModel.spending - previousMonthSpending) / previousMonthSpending
                        let changePercent = Int((abs(change) * 100).rounded())
                        Label("\(changePercent)% \(change <= 0 ? "lower" : "higher") than last month",
                              systemImage: change <= 0 ? "arrow.down" : "arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(change <= 0 ? DashboardPalette.green : DashboardPalette.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Your recorded household spending")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                spendingHistoryChart
                    .frame(width: 150, height: 92)
                    .accessibilityLabel("Monthly spending for the last five months")
            }
        }
    }

    private var categorySection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
            ForEach(dashboardCategories, id: \.name) { category in
                let style = categoryStyle(category.name)
                VStack(spacing: 9) {
                    Image(systemName: style.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(style.color)
                        .frame(width: 52, height: 52)
                        .background(style.color.opacity(0.12), in: Circle())
                    Text(category.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(viewModel.money(category.total))
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.55)
                    ProgressView(value: viewModel.spending > 0 ? category.total / viewModel.spending : 0)
                        .tint(style.color)
                        .accessibilityLabel("\(category.name) share of monthly spending")
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: 142)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(style.color.opacity(0.08)))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var errandSection: some View {
        Group {
            if let upcomingErrand {
                errandCard(upcomingErrand)
            } else {
                HStack(spacing: 15) {
                    DashboardErrandIllustration().frame(width: 92, height: 82).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UPCOMING ERRAND").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(DashboardPalette.green)
                        Text("No saved errands yet").font(.headline)
                        Text("Add a location to a task to see it here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Errands Map", systemImage: "map") { showingErrandsMap = true }
                            .font(.caption.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DashboardPalette.green.opacity(colorScheme == .dark ? 0.16 : 0.075), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            }
        }
    }

    private var budgetAndInsightsSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)], spacing: 12) {
            budgetAlertCard
            coreMLInsightCard
        }
    }

    private var budgetAlertCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(budgetUsage >= 0.8 ? DashboardPalette.red : DashboardPalette.green)
                    .frame(width: 42, height: 42)
                    .background((budgetUsage >= 0.8 ? DashboardPalette.red : DashboardPalette.green).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Budget Alert").font(.headline.weight(.bold))
                    Text(viewModel.preferences.monthlyBudget > 0 ? "Monthly budget" : "Set a monthly budget")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { viewModel.editingBudget = true } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.preferences.monthlyBudget > 0 ? "Edit monthly budget" : "Set monthly budget")
                .disabled(dependencies.household.family != nil)
            }
            if viewModel.preferences.monthlyBudget > 0 {
                Text("You've used \(Int(budgetUsage * 100))% of your monthly budget.")
                    .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: min(budgetUsage, 1))
                    .tint(budgetUsage >= 1 ? DashboardPalette.red : DashboardPalette.green)
                    .scaleEffect(x: 1, y: 2, anchor: .center)
                    .accessibilityLabel("Monthly budget used")
                HStack {
                    Text("\(viewModel.money(max(0, viewModel.preferences.monthlyBudget - viewModel.spending))) remaining")
                    Spacer(minLength: 5)
                    Text("\(Int(budgetUsage * 100))%")
                        .fontWeight(.bold).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Set a budget to track your household spending.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Set budget") { viewModel.editingBudget = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(dependencies.household.family != nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .background(Color(red: 1, green: 0.94, blue: 0.95).opacity(colorScheme == .dark ? 0.16 : 1), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(DashboardPalette.red.opacity(0.10)))
    }

    private var coreMLInsightCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Spending Insight", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color(red: 0.10, green: 0.32, blue: 0.56))
            ExpenseAnalysisSummary()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .background(Color(red: 0.92, green: 0.96, blue: 1).opacity(colorScheme == .dark ? 0.18 : 1), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(Color.blue.opacity(0.10)))
    }

    private var recentExpensesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Expenses").font(.title3.weight(.bold))
                Spacer()
                NavigationLink { RecordsView(kind: .expense) } label: {
                    HStack(spacing: 6) {
                        Text("See All").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                }
            }
            DashboardSurface {
                if recentExpenses.isEmpty {
                    emptyRow("No expenses recorded yet.", icon: "creditcard")
                } else {
                    ForEach(Array(recentExpenses.prefix(4).enumerated()), id: \.offset) { index, record in
                        let style = categoryStyle(record.category)
                        Button { viewModel.selected = record } label: {
                            HStack(spacing: 12) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(style.color)
                                    .frame(width: 42, height: 42)
                                    .background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("\(record.category) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(viewModel.money(record.amount))
                                    .font(.subheadline.weight(.bold)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(record.title), \(record.category), \(viewModel.money(record.amount))")
                        if index < min(3, recentExpenses.count - 1) { Divider().padding(.leading, 54) }
                    }
                }
            }
        }
    }

    private var spendingHistoryChart: some View {
        let maximum = max(spendingHistory.map(\.total).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(spendingHistory.enumerated()), id: \.offset) { index, month in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(index == spendingHistory.count - 1
                              ? DashboardPalette.green
                              : DashboardPalette.green.opacity(colorScheme == .dark ? 0.36 : 0.20))
                        .frame(maxWidth: .infinity)
                        .frame(height: month.total > 0 ? max(8, 54 * month.total / maximum) : 5)
                    Text(month.date.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption2.weight(index == spendingHistory.count - 1 ? .bold : .medium))
                        .foregroundStyle(index == spendingHistory.count - 1 ? DashboardPalette.green : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(month.date.formatted(.dateTime.month(.wide))): \(viewModel.money(month.total))")
            }
        }
    }

    @ViewBuilder private func errandCard(_ record: HouseholdRecord) -> some View {
        HStack(spacing: 16) {
            DashboardErrandIllustration()
                .frame(width: 112, height: 96)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("UPCOMING ERRAND")
                    .font(.caption2.weight(.bold)).tracking(1.0)
                    .foregroundStyle(DashboardPalette.green.opacity(0.8))
                Button { viewModel.selected = record } label: {
                    Text(record.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Label(record.location ?? "Saved map location",
                      systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(2)
                Label(record.date.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Button { showingErrandsMap = true } label: {
                    Label("View on Map", systemImage: "map.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(DashboardPalette.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [DashboardPalette.green.opacity(colorScheme == .dark ? 0.18 : 0.09),
                                    DashboardPalette.green.opacity(colorScheme == .dark ? 0.09 : 0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(DashboardPalette.green.opacity(0.10)))
    }

    private func categoryStyle(_ category: String) -> (icon: String, color: Color) {
        switch category.lowercased() {
        case let name where name.contains("grocer") || name.contains("food"):
            ("basket.fill", Color(uiColor: .systemGreen))
        case let name where name.contains("util") || name.contains("electric"):
            ("bolt.fill", Color(uiColor: .systemIndigo))
        case let name where name.contains("transport") || name.contains("fuel"):
            ("car.fill", Color(uiColor: .systemOrange))
        case let name where name.contains("home") || name.contains("house"):
            ("house.fill", Color(uiColor: .systemPink))
        case let name where name.contains("health"):
            ("cross.case.fill", Color(uiColor: .systemRed))
        default:
            ("square.grid.2x2.fill", DashboardPalette.green)
        }
    }

    private var billsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Upcoming bills").font(.headline)
                Spacer()
                Button {
                    creatingRecord = HouseholdRecord(kind: .bill, title: "",
                                                      assignee: viewModel.recommendedMember)
                } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Add bill")
                NavigationLink("See all") { RecordsView(kind: .bill) }
                    .font(.subheadline.weight(.semibold))
            }
            if viewModel.bills.isEmpty {
                DashboardSurface {
                    emptyRow("No unpaid bills.", icon: "checkmark.circle")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(viewModel.bills.prefix(8)) { bill in
                            Button { viewModel.selected = bill } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text.fill")
                                            .foregroundStyle(DashboardPalette.green)
                                        Text(bill.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    Text(bill.date < Date() ? "Overdue" : "Due \(bill.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(bill.date < Date() ? DashboardPalette.red : .secondary)
                                    Text(viewModel.money(bill.amount))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                    HStack {
                                        Text(viewModel.assigneeLabel(bill))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(DashboardPalette.green)
                                    }
                                }
                                .padding(16)
                                .frame(width: 250, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View bill \(bill.title)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var familySection: some View {
        DashboardSurface {
            HStack {
                Text("Latest announcement").font(.headline)
                Spacer()
                Button { viewModel.editingBulletin = true } label: {
                    Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Edit announcement")
            }
            if viewModel.preferences.bulletinTitle.isEmpty && viewModel.preferences.bulletinBody.isEmpty {
                Text("No household announcement yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 9) {
                    ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData,
                                  name: viewModel.profile.name, size: 32)
                    Text(viewModel.profile.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Household update")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !viewModel.preferences.bulletinTitle.isEmpty {
                        Text(viewModel.preferences.bulletinTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(viewModel.preferences.bulletinBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Button { viewModel.toggleLike() } label: {
                        Label(viewModel.preferences.bulletinLiked ? "Liked" : "Like",
                              systemImage: viewModel.preferences.bulletinLiked ? "heart.fill" : "heart")
                    }
                    Button { viewModel.acknowledge() } label: {
                        Label(viewModel.preferences.bulletinAcknowledged ? "Seen" : "Mark seen",
                              systemImage: "checkmark.circle")
                    }
                    Spacer(minLength: 0)
                    Button("Open family") { viewModel.showChat = true }
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }
            if viewModel.preferences.bulletinTitle.isEmpty && viewModel.preferences.bulletinBody.isEmpty {
                Button("Write an update", systemImage: "plus") {
                    viewModel.editingBulletin = true
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private func emptyRow(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private var remindersSheet: some View {
        NavigationStack {
            List {
                if viewModel.pending.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle")
                } else {
                    ForEach(viewModel.pending) { record in
                        RecordRow(record: record)
                    }
                }
            }
            .navigationTitle("Needs attention")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewModel.showReminders = false }
                }
            }
        }
    }

    private var budgetSheet: some View {
        NavigationStack {
            Form {
                TextField("Monthly budget", value: $viewModel.budgetDraft, format: .number)
                    .keyboardType(.decimalPad)
                Text("Budget is shown in \(viewModel.profile.currency). Use 0 if you haven’t set a budget.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !viewModel.validBudget {
                    Text("Enter a budget between 0 and 1 trillion.").foregroundStyle(.red)
                }
            }
            .navigationTitle("Monthly budget")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.editingBudget = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewModel.saveBudget() }.disabled(!viewModel.validBudget)
                }
            }
            .onAppear { viewModel.prepareBudget() }
        }
    }

    private var bulletinSheet: some View {
        NavigationStack {
            Form {
                TextField("Announcement title", text: $viewModel.bulletinTitleDraft)
                TextField("Message to your household", text: $viewModel.bulletinBodyDraft, axis: .vertical)
                if !viewModel.validBulletin {
                    Text("Use at most 200 characters for the title and 10,000 for the message.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Family update")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.editingBulletin = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewModel.saveBulletin() }.disabled(!viewModel.validBulletin)
                }
            }
            .onAppear { viewModel.prepareBulletin() }
        }
    }
}

private struct DashboardErrandIllustration: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 120, size.height / 100)
            context.translateBy(x: (size.width - 120 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(ellipseIn: CGRect(x: 5, y: 8, width: 108, height: 84)), with: .color(DashboardPalette.green.opacity(0.10)))
            var map = Path()
            map.move(to: CGPoint(x: 15, y: 28)); map.addLine(to: CGPoint(x: 47, y: 17)); map.addLine(to: CGPoint(x: 75, y: 28)); map.addLine(to: CGPoint(x: 105, y: 17)); map.addLine(to: CGPoint(x: 105, y: 72)); map.addLine(to: CGPoint(x: 76, y: 84)); map.addLine(to: CGPoint(x: 45, y: 73)); map.addLine(to: CGPoint(x: 15, y: 84)); map.closeSubpath()
            context.fill(map, with: .color(Color(red: 0.87, green: 0.94, blue: 0.82)))
            var road = Path()
            road.move(to: CGPoint(x: 20, y: 59)); road.addCurve(to: CGPoint(x: 94, y: 34), control1: CGPoint(x: 43, y: 36), control2: CGPoint(x: 69, y: 65))
            context.stroke(road, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            context.stroke(road, with: .color(DashboardPalette.green.opacity(0.62)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
            var route = Path()
            route.move(to: CGPoint(x: 25, y: 65)); route.addCurve(to: CGPoint(x: 80, y: 31), control1: CGPoint(x: 42, y: 72), control2: CGPoint(x: 60, y: 25))
            context.stroke(route, with: .color(DashboardPalette.green), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 4]))
            var pin = Path()
            pin.addArc(center: CGPoint(x: 82, y: 35), radius: 13, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            pin.move(to: CGPoint(x: 70, y: 40)); pin.addLine(to: CGPoint(x: 82, y: 59)); pin.addLine(to: CGPoint(x: 94, y: 40)); pin.closeSubpath()
            context.fill(pin, with: .color(Color(red: 0.91, green: 0.31, blue: 0.29)))
            context.fill(Path(ellipseIn: CGRect(x: 77, y: 30, width: 10, height: 10)), with: .color(.white))
        }
        .drawingGroup()
    }
}

private struct DashboardSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [Color(uiColor: .secondarySystemGroupedBackground),
                                        DashboardPalette.green.opacity(colorScheme == .dark ? 0.055 : 0.025)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DashboardPalette.green.opacity(colorScheme == .dark ? 0.12 : 0.07)))
            .shadow(color: DashboardPalette.green.opacity(colorScheme == .dark ? 0.06 : 0.035), radius: 14, x: 0, y: 6)
    }
}
