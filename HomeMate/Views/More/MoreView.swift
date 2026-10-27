import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: MoreViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            MoreViewScreen(viewModel: model)
        }
        .id(dependencies.household.identity)
    }
}

private struct MoreViewScreen: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.homeContentWidth) private var contentWidth
    @ScaledMetric(relativeTo: .headline) private var householdTitleSize = 18
    @ScaledMetric(relativeTo: .subheadline) private var moduleTitleSize = 16
    @ObservedObject var viewModel: MoreViewModel
    @State private var destination: MoreDestination?

    private var pageBackground: Color {
        colorScheme == .dark ? HomeMateStyle.background : Color(red: 248/255, green: 250/255, blue: 249/255)
    }
    private var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var insetBackground: Color {
        colorScheme == .dark ? Color(uiColor: .tertiarySystemGroupedBackground) : Color(red: 242/255, green: 244/255, blue: 243/255)
    }
    private var columnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return contentWidth > 650 ? 2 : 1 }
        if contentWidth >= 850 { return 4 }
        if contentWidth >= 620 { return 3 }
        return 2
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                householdCard

                HouseholdContextView(context: dependencies.household)
                    .padding(16)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionLabel("Household modules")
                        Spacer(minLength: 8)
                        if viewModel.familyLoading {
                            ProgressView().controlSize(.mini).accessibilityLabel("Loading household members")
                        }
                    }
                    .padding(.horizontal, 4)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount), spacing: 12) {
                        module(.expenses, title: "Expenses", subtitle: "Receipts & daily spending", icon: "creditcard", badge: "\(viewModel.expensesCount) this month")
                        module(.insights, title: "Insights", subtitle: "Recommendations", icon: "chart.line.uptrend.xyaxis", badge: "On device")
                        module(.communication, title: "Communication", subtitle: viewModel.accountSignedIn ? "Family chat & shared activities" : "Private notes & attachments", icon: "bubble.left.and.bubble.right", badge: viewModel.accountSignedIn ? "Family" : "Private")
                        module(.maintenance, title: "Maintenance", subtitle: "Repairs & home upkeep", icon: "wrench.and.screwdriver", badge: "\(viewModel.pendingMaintenanceCount) open")
                        module(.members, title: "Members", subtitle: "Invitations & family sharing", icon: "person.2", badge: viewModel.familyBadge)
                        module(.errands, title: "Errands Map", subtitle: "Saved places & directions", icon: "map", badge: viewModel.locatedRecords.count == 1 ? "1 place" : "\(viewModel.locatedRecords.count) places")
                        module(.notifications, title: "Notifications", subtitle: "Activity reminders & alerts", icon: "bell", badge: viewModel.notificationsEnabled ? "On" : "Off")
                        module(.settings, title: "Settings", subtitle: "Appearance, privacy & data", icon: "slider.horizontal.3", badge: "App")
                    }
                }

                Button {
                    if viewModel.accountSignedIn { viewModel.signOut() }
                    else { destination = .signIn }
                } label: {
                    Label(viewModel.accountSignedIn ? "Sign Out" : "Sign In", systemImage: viewModel.accountSignedIn ? "rectangle.portrait.and.arrow.right" : "person.crop.circle")
                        .font(.system(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(viewModel.accountSignedIn ? DashboardPalette.red : DashboardPalette.green)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(HomePressStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(pageBackground.ignoresSafeArea())
        .foregroundStyle(DashboardPalette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.refreshFamily()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview"), ProcessInfo.processInfo.arguments.contains("--preview-errands") { destination = .errands }
            if ProcessInfo.processInfo.arguments.contains("--preview"), ProcessInfo.processInfo.arguments.contains("--preview-insights") { destination = .insights }
            #endif
        }
        .refreshable { await viewModel.refreshFamily() }
        .sheet(item: $destination, onDismiss: { Task { await viewModel.refreshFamily() } }) { selected in
            destinationView(selected)
                .presentationDragIndicator(.visible)
        }
    }

    private var householdCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                MoreAvatar(name: viewModel.displayName, data: viewModel.profile.personalDetails?.avatarData, size: 56)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(DashboardPalette.brandFill, in: Circle())
                            .overlay(Circle().stroke(cardBackground, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.householdTitle)
                        .font(.system(size: householdTitleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(viewModel.householdSubtitle)
                        .font(.system(.footnote))
                        .foregroundStyle(DashboardPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    memberRow.padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { destination = .profile } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DashboardPalette.green)
                        .frame(width: 44, height: 44)
                        .background(insetBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(HomePressStyle())
                .accessibilityLabel("Edit profile")
            }

            Button { destination = .members } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(DashboardPalette.green)
                    Text(viewModel.ownerSummary)
                        .font(.system(.footnote))
                        .foregroundStyle(DashboardPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Manage")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(DashboardPalette.green)
                }
                .padding(12)
                .frame(minHeight: 58)
                .background(insetBackground, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(HomePressStyle())

            if let message = viewModel.familyMessage {
                Text(message).font(.caption).foregroundStyle(DashboardPalette.muted)
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 2, y: 1)
    }

    private var memberRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                memberAvatars
                Text(viewModel.memberSummary).font(.system(.caption, weight: .medium)).foregroundStyle(DashboardPalette.muted)
            }
            Text(viewModel.memberSummary).font(.system(.caption, weight: .medium)).foregroundStyle(DashboardPalette.muted)
        }
    }

    private var memberAvatars: some View {
        HStack(spacing: -7) {
            ForEach(Array(viewModel.memberNames.prefix(3).enumerated()), id: \.offset) { index, name in
                MoreAvatar(name: name, size: 24)
                    .overlay(Circle().stroke(cardBackground, lineWidth: 2))
                    .zIndex(Double(3 - index))
            }
            if viewModel.memberNames.count > 3 {
                Text("+\(viewModel.memberNames.count - 3)")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(insetBackground, in: Circle())
                    .overlay(Circle().stroke(cardBackground, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(DashboardPalette.muted)
    }

    private func module(_ target: MoreDestination, title: String, subtitle: String, icon: String, badge: String) -> some View {
        Button { destination = target } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(DashboardPalette.green)
                        .frame(width: 40, height: 40)
                        .background(DashboardPalette.green.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 12))
                    Spacer(minLength: 0)
                    Text(badge)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(target == .insights ? Color.white : DashboardPalette.green)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(target == .insights ? DashboardPalette.brandFill : insetBackground, in: Capsule())
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: moduleTitleSize, weight: .semibold))
                        .foregroundStyle(DashboardPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(DashboardPalette.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func destinationView(_ selected: MoreDestination) -> some View {
        switch selected {
        case .expenses: RecordsView(kind: .expense, onClose: { destination = nil }).responsiveHomeWidth()
        case .insights:
            NavigationStack {
                AnalyticsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
            }
        case .maintenance: RecordsView(kind: .maintenance, onClose: { destination = nil }).responsiveHomeWidth()
        case .communication:
            NavigationStack {
                FamilyCommunicationView(family: dependencies.household.family)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { destination = nil } } }
            }
        case .members:
            NavigationStack {
                if let family = viewModel.family {
                    FamilyMembersView(family: family)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { destination = nil } } }
                }
                else {
                    HouseholdMembersSetupView(viewModel: viewModel, dismiss: { destination = nil })
                }
            }
        case .settings: dismissible { SettingsView() }
        case .signIn: dismissible { NavigationStack { LoginView() } }
        case .profile:
            NavigationStack { ProfileSettingsView(accountEmail: viewModel.accountSignedIn ? viewModel.accountEmail : "") }
        case .notifications:
            NavigationStack {
                Form {
                    Section {
                        Toggle("Activity reminders", isOn: $viewModel.notificationsEnabled)
                    } footer: {
                        Text("HomeMate schedules local reminders for your pending activities. Allow notifications when iOS asks. You can also change permission in the device’s Settings app.")
                    }
                }
                .navigationTitle("Notifications")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { destination = nil } } }
            }
        case .errands:
            ErrandsMapView()
        }
    }

    private func dismissible<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { destination = nil }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .background(cardBackground)
        }
    }

    private func mapsURL(_ location: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }
}

private struct HouseholdMembersSetupView: View {
    @ObservedObject var viewModel: MoreViewModel
    var dismiss: () -> Void
    @State private var showSharingSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 7) {
                    Image(systemName: "house.fill").foregroundStyle(DashboardPalette.green)
                    Text("HomeMate").font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DashboardPalette.muted)
                    Text(viewModel.householdTitle).font(.caption).lineLimit(1)
                    Spacer()
                    Text("PRIVATE").font(.caption2.weight(.bold)).tracking(1)
                        .foregroundStyle(DashboardPalette.green)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(DashboardPalette.green.opacity(0.1), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR HOUSEHOLD").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(DashboardPalette.muted)
                            Text(viewModel.householdTitle).font(.title3.weight(.bold))
                        }
                        Spacer()
                        Text("1 member").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Label("Family sharing has not been set up yet", systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(DashboardPalette.muted)
                }
                .padding(16).homeCard(cornerRadius: 12)

                memberSectionTitle("Household owner", trailing: "Private profile")
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData, name: viewModel.displayName, size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Text(viewModel.displayName).font(.headline)
                                Text("You").font(.caption2.weight(.bold)).foregroundStyle(DashboardPalette.green)
                            }
                            Text(viewModel.accountSignedIn ? viewModel.accountEmail : "Local profile")
                                .font(.subheadline).foregroundStyle(DashboardPalette.muted)
                            Label("Owner · private household", systemImage: "key.fill")
                                .font(.caption).foregroundStyle(DashboardPalette.green)
                        }
                    }
                    Label("Your personal activities and profile remain private", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(DashboardPalette.muted)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(16).homeCard(cornerRadius: 12)

                memberSectionTitle("Household members (0)", trailing: "Shared access")
                VStack(spacing: 10) {
                    Image(systemName: "person.2.badge.plus").font(.title2).foregroundStyle(DashboardPalette.green)
                    Text("No shared members yet").font(.headline)
                    Text("Set up family sharing when you want to invite another HomeMate account.")
                        .font(.footnote).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(24).homeCard(cornerRadius: 12)

                HomePrimaryButton(
                    title: viewModel.accountSignedIn ? "Set up family sharing" : "Sign in to invite members",
                    icon: viewModel.accountSignedIn ? "person.badge.plus" : "person.crop.circle"
                ) { showSharingSetup = true }

                Text("Email verification is requested only when you choose to create or join a shared household. Opening Members keeps you on this page.")
                    .font(.caption).foregroundStyle(DashboardPalette.muted).padding(.horizontal, 6)
            }
            .padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Household Members").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: dismiss) } }
        .sheet(isPresented: $showSharingSetup, onDismiss: { Task { await viewModel.refreshFamily() } }) {
            NavigationStack {
                if viewModel.accountSignedIn { FamilySharingView() }
                else { LoginView() }
            }
        }
    }

    private func memberSectionTitle(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(1.25)
            Spacer()
            Text(trailing).font(.caption).foregroundStyle(DashboardPalette.muted)
        }.padding(.horizontal, 2)
    }
}

struct FamilyCommunicationView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var family: SharedFamily?

    var body: some View {
        ViewModelHost(make: CommunicationViewModel(store: dependencies.store, account: dependencies.account, family: family, context: dependencies.household)) { model in
            FamilyCommunicationScreen(viewModel: model)
        }
        .id(dependencies.account.dataScope + (family?.id ?? "-private"))
    }
}

private struct FamilyCommunicationScreen: View {
    private enum SectionTab: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case notices = "Notices"
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: CommunicationViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab: SectionTab = .chats
    @State private var showSearch = false
    @State private var announcementDraft: FamilyAnnouncement?
    @State private var deletingAnnouncement: FamilyAnnouncement?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                communicationHeader
                communicationTabs

                if let error = viewModel.error {
                    Label("Shared updates could not load. \(error)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(DashboardPalette.red)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).homeCard(cornerRadius: 12)
                }

                if selectedTab == .chats && viewModel.family == nil && viewModel.hasAnnouncement {
                    announcementCard
                }

                if selectedTab == .chats { chats }
                else { notices }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Family Communication").navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(isPresented: $showSearch) { CommunicationSearchView(viewModel: viewModel) }
        .sheet(item: $announcementDraft) { draft in
            AnnouncementComposer(draft: draft, isPrivate: viewModel.family == nil) { saved in
                try await viewModel.saveAnnouncement(saved)
            }
        }
        .confirmationDialog("Delete notice?", isPresented: Binding(get: { deletingAnnouncement != nil }, set: { if !$0 { deletingAnnouncement = nil } })) {
            Button("Delete notice", role: .destructive) {
                if let deletingAnnouncement { Task { await viewModel.deleteAnnouncement(deletingAnnouncement) } }
                deletingAnnouncement = nil
            }
        } message: {
            Text(viewModel.family == nil ? "This removes your private notice." : "This removes the notice for every accepted member of this household.")
        }
    }

    private var communicationTabs: some View {
        HStack(spacing: 4) {
            communicationTab(.chats, icon: "bubble.left.and.bubble.right.fill", count: viewModel.chatCount)
            communicationTab(.notices, icon: "megaphone.fill", count: viewModel.noticeCount)
        }
        .padding(4).background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func communicationTab(_ tab: SectionTab, icon: String, count: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { selectedTab = tab } } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(tab.rawValue)
                Text("\(count)").font(.caption2.bold()).foregroundStyle(selectedTab == tab ? .white : DashboardPalette.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(selectedTab == tab ? DashboardPalette.brandFill : DashboardPalette.green.opacity(0.1), in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selectedTab == tab ? DashboardPalette.green : DashboardPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selectedTab == tab ? Color(uiColor: .secondarySystemGroupedBackground) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(HomePressStyle()).accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    private var communicationHeader: some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.householdTitle).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text(viewModel.contextSubtitle).font(.caption).foregroundStyle(DashboardPalette.muted)
            }
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .background(DashboardPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }.accessibilityLabel("Search messages")
            NavigationLink {
                if let family = viewModel.family { FamilyMembersView(family: family) }
                else { FamilySharingView() }
            } label: {
                Image(systemName: "person.2").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .background(DashboardPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }.accessibilityLabel("Household members and sharing")
        }
    }

    private var announcementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("PINNED HOUSEHOLD ANNOUNCEMENT", systemImage: "pin.fill")
                .font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(DashboardPalette.green)
            if !viewModel.preferences.bulletinTitle.isEmpty {
                Text(viewModel.preferences.bulletinTitle).font(.headline)
            }
            if !viewModel.preferences.bulletinBody.isEmpty {
                Text(viewModel.preferences.bulletinBody).font(.subheadline).foregroundStyle(DashboardPalette.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DashboardPalette.green.opacity(0.16)))
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Household channels", trailing: viewModel.family == nil ? "Private" : "Shared")
            if let family = viewModel.family {
                NavigationLink { SharedFamilyChatView(family: family) } label: {
                    channelCard(
                        title: "Family chat",
                        subtitle: viewModel.latestFamilyMessage.map { "\($0.authorName): \($0.text)" } ?? "Start the household conversation",
                        icon: "bubble.left.and.bubble.right.fill",
                        badge: "\(viewModel.familyMessages.count)"
                    )
                }.buttonStyle(.plain)
            }

            NavigationLink { FamilyChatView().responsiveHomeWidth() } label: {
                channelCard(
                    title: "Private notes",
                    subtitle: viewModel.personalMessages.last.map { $0.text.isEmpty ? "Saved attachment" : $0.text } ?? "Notes, photos, voice and linked records",
                    icon: "note.text",
                    badge: "\(viewModel.personalMessages.count)"
                )
            }.buttonStyle(.plain)

            if viewModel.family == nil {
                ForEach(viewModel.context?.families ?? []) { family in
                    NavigationLink { SharedFamilyChatView(family: family) } label: {
                        channelCard(
                            title: "Family chat",
                            subtitle: family.name,
                            icon: "bubble.left.and.bubble.right.fill",
                            badge: "Shared"
                        )
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(viewModel.family == nil ? "Private bulletin & reminders" : "Household notices", trailing: "\(viewModel.noticeCount) active")
            Button {
                announcementDraft = FamilyAnnouncement(authorID: viewModel.accountUserID, authorName: viewModel.profile.name.isEmpty ? "Me" : viewModel.profile.name)
            } label: {
                Label("Add Notice", systemImage: "plus")
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(DashboardPalette.brandFill)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            ForEach(viewModel.orderedAnnouncements) { announcement in announcementCard(announcement) }
            if viewModel.noticeRecords.isEmpty && !viewModel.hasAnnouncement {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.title2).foregroundStyle(DashboardPalette.green)
                    Text("No notices right now").font(.headline)
                    Text(viewModel.family == nil ? "Your private bulletin and important reminders appear here." : "Post the first household update, such as a water cut or Sunday day out.")
                        .font(.footnote).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity).homeCard(cornerRadius: 14)
            }
            ForEach(viewModel.noticeRecords) { record in noticeCard(record) }
        }
    }

    private func announcementCard(_ announcement: FamilyAnnouncement) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: announcement.important ? "pin.fill" : "megaphone.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(announcement.important ? DashboardPalette.red : DashboardPalette.green)
                    .frame(width: 44, height: 44)
                    .background((announcement.important ? DashboardPalette.red : DashboardPalette.green).opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(announcement.important ? "Important notice" : "Household announcement")
                        .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                    Text(announcement.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.canManage(announcement) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { announcementDraft = announcement }
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingAnnouncement = announcement }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel("Actions for \(announcement.title)")
                }
            }
            Text(announcement.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(announcement.body).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Label("Posted by \(announcement.authorName)", systemImage: "person.crop.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .homeCard(cornerRadius: 20)
    }

    private func noticeCard(_ record: HouseholdRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.date < Date() ? "calendar.badge.exclamationmark" : "exclamationmark.circle.fill")
                .foregroundStyle(record.date < Date() ? DashboardPalette.red : .orange)
                .frame(width: 42, height: 42)
                .background((record.date < Date() ? DashboardPalette.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.subheadline.weight(.semibold))
                Text("\(record.kind.rawValue) · \(viewModel.assigneeLabel(record))").font(.caption).foregroundStyle(DashboardPalette.muted)
                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(record.date < Date() ? DashboardPalette.red : DashboardPalette.muted)
            }
            Spacer()
            Text(record.date < Date() ? "Overdue" : "Important").font(.caption2.weight(.bold))
                .foregroundStyle(record.date < Date() ? DashboardPalette.red : .orange)
        }
        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Spacer()
            if viewModel.loading { ProgressView().controlSize(.small) }
            else { Text(trailing).font(.caption).foregroundStyle(DashboardPalette.muted) }
        }.padding(.horizontal, 2)
    }

    private func channelCard(title: String, subtitle: String, icon: String, badge: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.headline).foregroundStyle(DashboardPalette.green)
                .frame(width: 46, height: 46).background(DashboardPalette.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DashboardPalette.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                .padding(.horizontal, 8).padding(.vertical, 5).background(DashboardPalette.surface, in: Capsule())
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(DashboardPalette.muted)
        }
        .padding(16).homeCard(cornerRadius: 18)
    }
}

private struct AnnouncementComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FamilyAnnouncement
    var isPrivate = false
    @State private var saving = false
    @State private var error: String?
    let save: (FamilyAnnouncement) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(isPrivate ? "Private notice" : "Household announcement") {
                    TextField("Title", text: $draft.title)
                    TextField("Message", text: $draft.body, axis: .vertical).lineLimit(4...10)
                    Toggle("Mark as important", isOn: $draft.important)
                }
                Section {
                    Text(isPrivate ? "Only you can see this notice. Important notices appear first; the first notice also appears on your private Home dashboard." : "Every accepted member of this shared household can see this announcement.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(DashboardPalette.red) }
            }
            .navigationTitle(draft.revision == nil ? "New notice" : "Edit notice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : draft.revision == nil ? "Post" : "Save") {
                        saving = true; error = nil
                        Task {
                            defer { saving = false }
                            do { try await save(draft); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(saving || draft.validationError != nil)
                }
            }
        }
    }
}

private struct CommunicationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CommunicationViewModel
    @State private var query = ""

    private var familyResults: [FamilyMessage] {
        viewModel.familyMessages.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.authorName.localizedCaseInsensitiveContains(query) }
    }
    private var privateResults: [ChatMessage] {
        viewModel.personalMessages.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !familyResults.isEmpty {
                    Section("Family messages") {
                        ForEach(familyResults) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.authorName).font(.caption.bold()).foregroundStyle(DashboardPalette.green)
                                Text(message.text)
                                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if !privateResults.isEmpty {
                    Section("Private notes") {
                        ForEach(privateResults) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.author).font(.caption.bold()).foregroundStyle(DashboardPalette.green)
                                Text(message.text.isEmpty ? "Attachment" : message.text)
                                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if familyResults.isEmpty && privateResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search messages")
            .navigationTitle("Search Messages").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private enum MoreDestination: String, Identifiable {
    case expenses, insights, communication, maintenance, members, errands, notifications, settings, profile, signIn
    var id: String { rawValue }
}

private struct MoreAvatar: View {
    var name: String
    var data: Data? = nil
    var size: CGFloat

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials.isEmpty ? "H" : initials)
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(DashboardPalette.green)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DashboardPalette.green.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
