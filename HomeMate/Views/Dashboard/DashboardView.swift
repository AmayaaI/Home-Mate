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
    @ObservedObject var viewModel: DashboardViewModel

    private var firstName: String {
        viewModel.profile.name.split(separator: " ").first.map(String.init) ?? viewModel.profile.name
    }
    private var urgent: HouseholdRecord? {
        viewModel.pending.filter { $0.date < Date() || $0.important }
            .min { $0.date < $1.date }
    }
    private var nextActivity: HouseholdRecord? {
        viewModel.pending.filter { $0.id != urgent?.id }.min { $0.date < $1.date }
    }
    private var budgetUsage: Double {
        guard viewModel.preferences.monthlyBudget > 0 else { return 0 }
        return min(viewModel.spending / viewModel.preferences.monthlyBudget, 9.99)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    welcome
                    householdHero
                    quickActions
                    nextUp
                    spendingSection
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
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
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
            .navigationDestination(isPresented: $showingProfile) {
                ProfileSettingsView(accountEmail: viewModel.accountSignedIn ? viewModel.accountEmail : "")
            }
        }
    }

    private var welcome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.greetingText.uppercased())
                    .font(.caption2.weight(.bold)).tracking(1.8)
                    .foregroundStyle(DashboardPalette.green)
                Text(firstName.isEmpty ? "Welcome home." : "Hello, \(firstName).")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .lineLimit(2)
                Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { viewModel.showReminders = true } label: {
                Image(systemName: viewModel.pending.isEmpty ? "bell" : "bell.badge")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activity reminders")
            Button { showingProfile = true } label: {
                ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData,
                              name: viewModel.profile.name, size: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile settings")
        }
    }

    private var householdHero: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(dependencies.household.family == nil ? "YOUR PRIVATE SPACE" : "YOUR SHARED HOME",
                          systemImage: "house.fill")
                        .font(.caption2.weight(.bold)).tracking(1.3)
                        .foregroundStyle(DashboardPalette.mint)
                    Text(viewModel.profile.household)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A little more harmony, every day.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 4)
                Button { viewModel.showChat = true } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.headline).frame(width: 44, height: 44)
                        .background(.white.opacity(0.14), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open family hub")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heroMetrics }
                VStack(alignment: .leading, spacing: 12) { heroMetrics }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(red: 0.05, green: 0.23, blue: 0.21),
                                        DashboardPalette.brandFill],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(.white.opacity(0.07), lineWidth: 36)
                    .frame(width: 230, height: 230).offset(x: 105, y: -110)
                Circle().fill(DashboardPalette.mint.opacity(0.07))
                    .frame(width: 180, height: 180).offset(x: 95, y: 100)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: DashboardPalette.brandFill.opacity(0.18), radius: 18, x: 0, y: 10)
    }

    @ViewBuilder private var heroMetrics: some View {
        heroMetric("Open activities", value: viewModel.pending.count, icon: "clock")
        heroMetric("Tasks today", value: viewModel.tasks.count, icon: "checklist")
        heroMetric("Unpaid bills", value: viewModel.bills.count, icon: "doc.text")
    }

    private func heroMetric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(DashboardPalette.mint)
            Text(value.formatted()).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Make room for easy").font(.headline)
                Spacer()
                Text("QUICK ADD").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                quickAction("New task", icon: "plus", tint: DashboardPalette.green) {
                    creatingRecord = HouseholdRecord(kind: .task, title: "", assignee: viewModel.recommendedMember)
                }
                quickAction("Add bill", icon: "doc.badge.plus", tint: Color(uiColor: .systemOrange)) {
                    creatingRecord = HouseholdRecord(kind: .bill, title: "", assignee: viewModel.recommendedMember)
                }
                quickAction("Scan receipt", icon: "viewfinder", tint: Color(uiColor: .systemIndigo)) {
                    viewModel.scanning = true
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
                Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.pending.count) open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.pending.isEmpty ? DashboardPalette.green : DashboardPalette.red)
            }
            if let urgent {
                HStack {
                    Label(urgent.date < Date() ? "OVERDUE" : "IMPORTANT",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DashboardPalette.red)
                    Spacer()
                    Text(urgent.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(DashboardPalette.red)
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: urgent.kind.icon)
                        .font(.title3)
                        .foregroundStyle(DashboardPalette.green)
                        .frame(width: 42, height: 42)
                        .background(DashboardPalette.green.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(urgent.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(viewModel.assigneeLabel(urgent)) · \(urgent.kind.rawValue)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if urgent.amount > 0 {
                        Text(viewModel.money(urgent.amount))
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                HStack(spacing: 10) {
                    Button { viewModel.selected = urgent } label: {
                        Text("View details").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Button { viewModel.toggle(urgent) } label: {
                        Label(urgent.kind == .bill ? "Mark paid" : "Complete",
                              systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let nextActivity {
                    Button { viewModel.selected = nextActivity } label: {
                        HStack(spacing: 10) {
                            Image(systemName: nextActivity.kind.icon)
                                .foregroundStyle(DashboardPalette.green)
                            Text(nextActivity.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            } else if let nextActivity {
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
                Label("Monthly spending", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Button { viewModel.scanning = true } label: {
                    Image(systemName: "doc.viewfinder").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Scan receipt")
            }
            HStack {
                Text(Date().formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.preferences.monthlyBudget > 0 {
                    Text("\(Int(budgetUsage * 100))% spent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(budgetUsage > 1 ? DashboardPalette.red : DashboardPalette.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DashboardPalette.green.opacity(0.10), in: Capsule())
                }
            }
            Text(viewModel.money(viewModel.spending))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text("Spent this month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if viewModel.preferences.monthlyBudget > 0 {
                ProgressView(value: min(budgetUsage, 1))
                    .tint(budgetUsage > 1 ? DashboardPalette.red : DashboardPalette.green)
                    .scaleEffect(x: 1, y: 1.6, anchor: .center)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Monthly budget used")
                HStack {
                    Text("of \(viewModel.money(viewModel.preferences.monthlyBudget)) budget")
                    Spacer()
                    Text("\(viewModel.money(max(0, viewModel.preferences.monthlyBudget - viewModel.spending))) remaining")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Set a budget to follow your monthly spending.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ExpenseAnalysisSummary()
            if !viewModel.breakdown.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.breakdown.enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(DashboardPalette.green.opacity(index == 0 ? 1 : 0.55))
                                        .frame(width: 7, height: 7)
                                    Text(item.0)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(viewModel.money(item.1))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            }
            HStack {
                Button(viewModel.preferences.monthlyBudget > 0 ? "Edit budget" : "Set a budget") {
                    viewModel.editingBudget = true
                }.disabled(dependencies.household.family != nil)
                Spacer()
                NavigationLink("View expenses") { RecordsView(kind: .expense) }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
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

private struct DashboardSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.04)))
            .shadow(color: .black.opacity(0.025), radius: 14, x: 0, y: 6)
    }
}
