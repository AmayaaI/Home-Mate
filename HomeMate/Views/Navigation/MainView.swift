import SwiftUI

struct MainView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ViewModelHost(make: NavigationViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            MainViewScreen(viewModel: model)
        }.id(dependencies.household.identity)
            .sheet(item: $dependencies.arrivalRecord) { record in
                RecordDetailView(record: record)
            }
            .alert("Errand unavailable", isPresented: Binding(get: { dependencies.arrivalError != nil }, set: { if !$0 { dependencies.arrivalError = nil } })) {
                Button("OK") { dependencies.arrivalError = nil }
            } message: { Text(dependencies.arrivalError ?? "") }
            .task(id: dependencies.household.identity + String(describing: scenePhase)) {
                await dependencies.household.monitor(active: scenePhase == .active)
            }
    }
}

private struct MainViewScreen: View {

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab = 0
    @State private var showAllTasks = false
    @State private var taskGroup: TaskGroup?
    private let titles = ["Home", "Tasks", "Bills", "Calendar", "More"]
    private let icons = ["house.fill", "checklist", "doc.text", "calendar", "ellipsis"]

    init(viewModel: NavigationViewModel) {
        self.viewModel = viewModel
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview"), let index = arguments.firstIndex(of: "--preview-tab"), arguments.indices.contains(index + 1), let tab = Int(arguments[index + 1]), (0...5).contains(tab) {
            _selectedTab = State(initialValue: tab)
        }
        #endif
    }

    @ObservedObject var viewModel: NavigationViewModel

    var body: some View {
        GeometryReader { geometry in
            if sizeClass == .regular && geometry.size.width >= 700 {
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 10) {
                            Image(systemName: "house.lodge.fill").font(.title)
                            Text("HomeMate").font(.title2 .weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                        }.foregroundStyle(DashboardPalette.green).padding(.horizontal, 22).padding(.top, 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("YOUR HOUSEHOLD").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(DashboardPalette.muted)
                            Text(viewModel.profile.household).font(.body .weight(.semibold))
                        }.padding(.horizontal, 24)
                        VStack(spacing: 8) {
                            ForEach(0..<titles.count, id: \.self) { index in
                                Button { selectedTab = index } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: icons[index]).frame(width: 24)
                                        Text(titles[index]).font(.subheadline .weight(.semibold))
                                        Spacer()
                                        if selectedTab == index { Circle().fill(DashboardPalette.green).frame(width: 6, height: 6) }
                                    }.foregroundStyle(selectedTab == index ? DashboardPalette.green : DashboardPalette.muted)
                                        .padding(15).background(selectedTab == index ? DashboardPalette.mint.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(HomePressStyle()).accessibilityAddTraits(selectedTab == index ? .isSelected : [])
                            }
                        }.padding(.horizontal, 12)
                        Spacer(minLength: 20)
                        Button { selectedTab = 5 } label: {
                            HStack(spacing: 10) {
                                ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData, name: viewModel.profile.name, size: 38)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(viewModel.profile.name.isEmpty ? "Your profile" : viewModel.profile.name).font(.footnote .weight(.semibold)).lineLimit(1)
                                    Text(viewModel.accountSignedIn ? viewModel.accountEmail : "Personal profile").font(.caption2).foregroundStyle(DashboardPalette.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(DashboardPalette.muted)
                            }.padding(12)
                                .foregroundStyle(selectedTab == 5 ? DashboardPalette.green : DashboardPalette.ink)
                                .background(selectedTab == 5 ? DashboardPalette.mint.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(HomePressStyle())
                        .accessibilityLabel("Open profile settings")
                        .accessibilityAddTraits(selectedTab == 5 ? .isSelected : [])
                        .padding(.horizontal, 12).padding(.bottom, 8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(HomeBackdrop()).toolbar(.hidden, for: .navigationBar)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
                } detail: {
                    destination.responsiveHomeWidth()
                }.navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $selectedTab) {
                    DashboardView().responsiveHomeWidth()
                        .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                    RecordsView(kind: .task).responsiveHomeWidth()
                        .tabItem { Label("Tasks", systemImage: "checklist") }.tag(1)
                    RecordsView(kind: .bill).responsiveHomeWidth()
                        .tabItem { Label("Bills", systemImage: "doc.text") }.tag(2)
                    CalendarView().responsiveHomeWidth()
                        .tabItem { Label("Calendar", systemImage: "calendar") }.tag(3)
                    MoreView().responsiveHomeWidth()
                        .tabItem { Label("More", systemImage: "ellipsis") }.tag(4)
                }
            }
        }
        .onChange(of: sizeClass) { _, newSizeClass in
            if newSizeClass == .compact && selectedTab == 5 { selectedTab = 4 }
        }
        .tint(DashboardPalette.green)
    }
    @ViewBuilder private var destination: some View {
        switch selectedTab {
        case 0: DashboardView()
        case 1: RecordsView(kind: .task)
        case 2: RecordsView(kind: .bill)
        case 3: CalendarView()
        case 4: MoreView()
        case 5: NavigationStack { ProfileSettingsView(accountEmail: viewModel.accountSignedIn ? viewModel.accountEmail : "") }
        default: MoreView()
        }
    }

    private var taskDestination: some View {
        NavigationStack {
            Group {
                if let task = viewModel.nextTask {
                    RecordDetailView(record: task, presentsAsSheet: false)
                } else {
                    ContentUnavailableView(
                        "No tasks yet",
                        systemImage: "checklist",
                        description: Text("Open Home and choose Add task to create your first task.")
                    )
                    .navigationTitle("Task Details")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        taskGroupButton(.pending, count: viewModel.pendingTasks.count)
                        taskGroupButton(.overdue, count: viewModel.overdueTasks.count)
                        taskGroupButton(.completed, count: viewModel.completedTasks.count)
                        taskGroupButton(.other, count: viewModel.otherTasks.count)
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                }
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("All Tasks", systemImage: "list.bullet") { showAllTasks = true }
                }
            }
            .sheet(isPresented: $showAllTasks) { RecordsView(kind: .task) }
            .sheet(item: $taskGroup) { group in
                TaskGroupList(title: group.title, records: records(for: group))
            }
        }
    }

    private func taskGroupButton(_ group: TaskGroup, count: Int) -> some View {
        Button { taskGroup = group } label: {
            Label("\(group.title) \(count)", systemImage: group.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(group.color)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(group.color.opacity(0.1), in: Capsule())
        }.buttonStyle(HomePressStyle())
    }

    private func records(for group: TaskGroup) -> [HouseholdRecord] {
        switch group {
        case .pending: viewModel.pendingTasks
        case .overdue: viewModel.overdueTasks
        case .completed: viewModel.completedTasks
        case .other: viewModel.otherTasks
        }
    }
}

private enum TaskGroup: String, Identifiable {
    case pending, overdue, completed, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .pending: "clock.fill"
        case .overdue: "calendar.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .other: "tag.fill"
        }
    }
    var color: Color {
        switch self {
        case .pending: .orange
        case .overdue: DashboardPalette.red
        case .completed: DashboardPalette.green
        case .other: DashboardPalette.muted
        }
    }
}

private struct TaskGroupList: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var records: [HouseholdRecord]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("No \(title.lowercased()) tasks", systemImage: "checklist")
                } else {
                    List(records) { record in
                        NavigationLink {
                            RecordDetailView(record: record, presentsAsSheet: false)
                        } label: {
                            RecordRow(record: record)
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(title) Tasks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
