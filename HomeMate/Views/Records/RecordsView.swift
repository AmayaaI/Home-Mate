import SwiftUI

/// A viewing projection only: shared records never enter the private store.
struct AccessibleRecordsList: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var kind: RecordKind?
    var date: Date? = nil
    var onRecords: (([HouseholdRecord]) -> Void)? = nil
    var body: some View {
        ViewModelHost(make: AccessibleRecordsViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            AccessibleRecordsListContent(model: model, kind: kind, date: date, onRecords: onRecords)
        }.id(dependencies.household.identity)
    }
}

private struct AccessibleRecordsListContent: View {
    @ObservedObject var model: AccessibleRecordsViewModel
    @Environment(\.scenePhase) private var phase
    @State private var editing: AccessibleRecord?
    var kind: RecordKind?
    var date: Date?
    var onRecords: (([HouseholdRecord]) -> Void)?
    private func accent(for kind: RecordKind) -> Color {
        switch kind {
        case .task: DashboardPalette.green
        case .bill: DashboardPalette.green
        case .maintenance: Color(uiColor: .systemBlue)
        case .expense: DashboardPalette.green
        case .event: Color(uiColor: .systemPurple)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Assignment", selection: $model.mineOnly) {
                Text(kind == .task ? "All Accessible Tasks" : "All Accessible Records").tag(false)
                Text("Assigned to Me").tag(true)
            }
            Toggle(kind == .bill ? "Unpaid only" : "Pending only", isOn: $model.pendingOnly)
            if model.loading { ProgressView("Loading households…") }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading)
            if !model.loading && model.filtered(kind: kind, date: date).isEmpty {
                ContentUnavailableView("No matching records", systemImage: "tray", description: Text("Try another date or filter."))
            }
            ForEach(model.filtered(kind: kind, date: date)) { entry in
                let cardAccent = accent(for: entry.record.kind)
                VStack(alignment: .leading, spacing: 10) {
                    Label(entry.householdName, systemImage: entry.family == nil ? "lock" : "person.2")
                        .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(entry.record.title, systemImage: entry.record.kind.icon).font(.headline).foregroundStyle(cardAccent)
                            Text(AssignmentDisplay.label(for: entry.record.assignee, accountEmail: model.accountEmail, localName: model.profile.name, members: entry.members, shared: entry.family != nil)).font(.subheadline)
                            Text(entry.record.kind == .expense ? "Recorded" : entry.record.completed ? (entry.record.kind == .bill ? "Paid" : "Completed") : entry.record.date < Date() ? "Overdue" : "Pending").font(.caption.weight(.semibold)).foregroundStyle(cardAccent)
                            Text(entry.record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if entry.record.amount > 0 { Text(entry.record.amount.formatted(.currency(code: entry.family?.currency ?? model.store.profile.currency))) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Open record editor")
                    Button("View in \(entry.householdName)", systemImage: "arrow.up.right") {
                        model.context?.select(entry.family)
                        Task { await model.context?.refresh() }
                    }.font(.caption.weight(.semibold)).foregroundStyle(cardAccent)
                }
                .padding(16)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(cardAccent.opacity(0.055))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardAccent.opacity(0.12)))
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                onRecords?(model.entries.map(\.record))
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .sheet(item: $editing) { entry in
            RecordEditor(record: entry.record, sharedMembers: entry.family == nil ? nil : entry.members, sourceFamily: entry.family, onSave: { updated in
                try await model.save(updated, source: entry)
            })
        }
    }
}

struct RecordsView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var kind: RecordKind = .task
    var onClose: (() -> Void)? = nil
    var body: some View {
        ViewModelHost(make: RecordsViewModel(store: dependencies.store, account: dependencies.account, kind: kind, context: dependencies.household)) { model in
            RecordsViewScreen(viewModel: model, onClose: onClose)
        }.id(dependencies.household.identity)
    }
}

private struct RecordsViewScreen: View {

    @Environment(\.homeContentWidth) private var contentWidth
    @Environment(\.colorScheme) private var colorScheme








    @ObservedObject var viewModel: RecordsViewModel
    @State private var allHouseholds = false
    var onClose: (() -> Void)?
    private var kind: RecordKind { viewModel.kind }
    private var search: String { get { viewModel.search } nonmutating set { viewModel.search = newValue } }
    private var selected: HouseholdRecord? { get { viewModel.selected } nonmutating set { viewModel.selected = newValue } }
    private var creating: Bool { get { viewModel.creating } nonmutating set { viewModel.creating = newValue } }
    private var scanning: Bool { get { viewModel.scanning } nonmutating set { viewModel.scanning = newValue } }
    private var showCompleted: Bool { get { viewModel.showCompleted } nonmutating set { viewModel.showCompleted = newValue } }
    private func accent(for kind: RecordKind) -> Color {
        switch kind {
        case .task: DashboardPalette.green
        case .bill: DashboardPalette.green
        case .maintenance: Color(uiColor: .systemBlue)
        case .expense: DashboardPalette.green
        case .event: Color(uiColor: .systemPurple)
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Viewing", selection: $allHouseholds) {
                        Text(viewModel.context?.family?.name ?? "Private").tag(false)
                        Text("All Households").tag(true)
                    }.pickerStyle(.segmented)
                    if allHouseholds {
                        AccessibleRecordsList(kind: kind)
                    } else {
                    if kind == .expense {
                        expenseOverview
                    } else if kind == .bill { billOverview }
                    if kind == .task { taskOverview }
                    if kind == .expense { ExpenseAnalysisSummary().padding(18).homeCard(cornerRadius: 18) }
                    if kind == .task {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TaskFilter.allCases) { filter in
                                    Button { withAnimation(.easeInOut(duration: 0.15)) { viewModel.taskFilter = filter } } label: {
                                        Text(filter.rawValue)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 13).padding(.vertical, 9)
                                            .foregroundStyle(viewModel.taskFilter == filter ? .white : accent(for: kind))
                                            .background(viewModel.taskFilter == filter ? accent(for: kind) : accent(for: kind).opacity(0.09), in: Capsule())
                                    }
                                    .buttonStyle(HomePressStyle())
                                    .accessibilityAddTraits(viewModel.taskFilter == filter ? .isSelected : [])
                                }
                            }
                        }
                        .accessibilityLabel("Task filters")
                    }
                    if kind == .bill {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(BillFilter.allCases) { filter in
                                    Button { withAnimation(.easeInOut(duration: 0.15)) { viewModel.billFilter = filter } } label: {
                                        Text(filter.rawValue)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 13).padding(.vertical, 9)
                                            .foregroundStyle(viewModel.billFilter == filter ? .white : accent(for: kind))
                                            .background(viewModel.billFilter == filter ? accent(for: kind) : accent(for: kind).opacity(0.09), in: Capsule())
                                    }
                                    .buttonStyle(HomePressStyle())
                                    .accessibilityAddTraits(viewModel.billFilter == filter ? .isSelected : [])
                                }
                            }
                        }
                        .accessibilityLabel("Bill filters")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(DashboardPalette.muted.opacity(0.6))
                        TextField("Search \(kind.rawValue.lowercased())", text: $viewModel.search).font(.subheadline)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DashboardPalette.muted.opacity(0.5)) }.accessibilityLabel("Clear search") }
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack {
                        Text(kind == .expense ? "YOUR SPENDING" : kind == .task ? "\(viewModel.taskFilter.rawValue.uppercased())" : "YOUR \(kind.rawValue.uppercased())").font(.caption2 .weight(.bold)).tracking(1.5).foregroundStyle(DashboardPalette.muted)
                        Spacer()
                        if kind != .expense && kind != .bill {
                            Menu {
                                Toggle("Include completed", isOn: $viewModel.showCompleted)
                            } label: {
                                Label(showCompleted ? "All statuses" : "Pending only", systemImage: "line.3.horizontal.decrease")
                                    .font(.caption2.weight(.semibold))
                            }.accessibilityLabel("Filter by status")
                        }
                    }
                    if viewModel.filtered.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: search.isEmpty ? kind.icon : "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(DashboardPalette.green).frame(width: 76, height: 76).background(DashboardPalette.mint.opacity(0.2), in: RoundedRectangle(cornerRadius: 26))
                            Text(search.isEmpty ? "A fresh start" : "No matches yet").font(.title3 .weight(.bold))
                            Text(search.isEmpty ? (kind == .bill ? "Add a bill you need to pay." : kind == .expense ? "Add a paid receipt to track spending." : "Add your first activity and give it a home.") : "Try a different name or clear the search.").font(.footnote).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center)
                        }.padding(30).frame(maxWidth: .infinity).homeCard()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: contentWidth >= 1120 ? 3 : contentWidth >= 760 ? 2 : 1), alignment: .leading, spacing: 14) {
                        ForEach(viewModel.filtered) { record in
                            let cardAccent = accent(for: record.kind)
                            VStack(alignment: .leading, spacing: 14) {
                                Label(viewModel.context?.family?.name ?? "Private", systemImage: viewModel.context?.family == nil ? "lock" : "person.2")
                                    .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                                Button { selected = record } label: { RecordRow(record: record, accent: cardAccent) }.buttonStyle(.plain)
                                HStack {
                                    Text(record.category.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(cardAccent).padding(.horizontal, 9).padding(.vertical, 5).background(cardAccent.opacity(0.10), in: Capsule())
                                    Spacer()
                                    if kind != .expense {
                                        Button { viewModel.toggle(record) } label: { Label(record.completed ? "Reopen" : kind == .bill ? "Mark paid" : "Mark complete", systemImage: record.completed ? "arrow.uturn.backward" : "checkmark").font(.caption .weight(.semibold)) }
                                            .buttonStyle(.bordered)
                                    }
                                    Menu { Button("View details", systemImage: "doc.text.magnifyingglass") { selected = record }; Button("Delete", systemImage: "trash", role: .destructive) { viewModel.delete(record) } } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }.accessibilityLabel("Record actions")
                                }
                            }
                            .padding(16)
                            .background {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(cardAccent.opacity(colorScheme == .dark ? 0.10 : 0.055))
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardAccent.opacity(0.12)))
                            .tint(cardAccent)
                        }
                    }
                    }
                }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
            .background(HomeBackdrop())
            .navigationTitle(kind == .task ? "Tasks" : kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(selected == nil ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                pageHeader
            }
                .sheet(isPresented: $viewModel.creating) { RecordEditor(record: HouseholdRecord(kind: kind, title: "", assignee: viewModel.recommendedMember)) }
                .sheet(isPresented: $viewModel.scanning) { ScanReviewView(initialKind: kind == .expense ? .expense : .bill) }
                .navigationDestination(isPresented: Binding(
                    get: { selected != nil },
                    set: { if !$0 { selected = nil } }
                )) {
                    if let selected { RecordDetailView(record: selected, presentsAsSheet: false) }
                }
        }
    }

    private var expenseOverview: some View {
        let accent = DashboardPalette.green
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("MONTHLY SPENDING", systemImage: "sparkle")
                        .font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.8))
                    Text(viewModel.money(viewModel.spendingThisMonth))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text(Date.now.formatted(.dateTime.month(.wide).year()))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                }
                Spacer(minLength: 8)
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "receipt")
                Text("\(viewModel.monthlyExpenses.count) transactions this month")
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background { premiumCardBackground }
        .shadow(color: accent.opacity(0.2), radius: 16, x: 0, y: 8)
    }

    private var taskOverview: some View {
        let green = DashboardPalette.green
        let tasks = viewModel.activeRecords.filter { $0.kind == .task }
        let completed = tasks.filter(\.completed).count
        let pending = tasks.count - completed
        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("HOUSEHOLD TASKS", systemImage: "checklist")
                        .font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.8))
                    Text("Your home,\nin good hands")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 25, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(pending)").font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("tasks to do").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                Spacer()
                Label("\(completed) done", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background { premiumCardBackground }
        .shadow(color: green.opacity(0.2), radius: 16, x: 0, y: 8)
    }

    private var billOverview: some View {
        let accent = DashboardPalette.green
        let unpaidCount = viewModel.activeRecords.filter { $0.kind == .bill && !$0.completed }.count
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("BILLS & PAYMENTS", systemImage: "creditcard.fill")
                        .font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.8))
                    Text(viewModel.money(viewModel.unpaidBills))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText()).foregroundStyle(.white)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text("Outstanding balance")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                }
                Spacer(minLength: 8)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
            HStack(spacing: 8) {
                Label("\(unpaidCount) unpaid", systemImage: "exclamationmark.circle")
                Spacer()
                Text("Paid this month")
                Text(viewModel.money(viewModel.paidBillsThisMonth)).fontWeight(.bold)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background { premiumCardBackground }
        .shadow(color: accent.opacity(0.2), radius: 16, x: 0, y: 8)
    }

    private var premiumCardBackground: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [DashboardPalette.brandFill, DashboardPalette.green, DashboardPalette.brandFill], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(.white.opacity(0.09))
                .frame(width: 170, height: 170)
                .blur(radius: 1)
                .offset(x: 55, y: -86)
            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 1)
                .frame(width: 112, height: 112)
                .offset(x: 19, y: -57)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onClose {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: onClose).font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text(kind == .task ? "Tasks" : kind.rawValue)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    headerAction(kind == .task ? "Add task" : kind == .bill ? "Add bill" : kind == .expense ? "Add expense" : kind == .event ? "Add event" : "Add maintenance", icon: "plus", primary: true) { creating = true }
                    if kind == .bill || kind == .expense {
                        headerAction(kind == .bill ? "Scan bill" : "Scan receipt", icon: "doc.viewfinder", primary: false) { scanning = true }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: 1200).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func headerAction(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(primary ? .white : DashboardPalette.green)
                .frame(width: 44, height: 44)
                .background(primary ? DashboardPalette.brandFill : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(title)
    }
}
