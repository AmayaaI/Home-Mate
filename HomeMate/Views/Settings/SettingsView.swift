import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var onBack: (() -> Void)? = nil
    var body: some View {
        ViewModelHost(make: SettingsViewModel(store: dependencies.store, account: dependencies.account)) { model in
            SettingsViewScreen(onBack: onBack, viewModel: model)
        }.id(dependencies.account.dataScope)
            .homeAppearance()
    }
}

private struct SettingsViewScreen: View {
    @EnvironmentObject private var appLock: AppLockViewModel



    private var appearance: String {
        get { viewModel.appearance }
        nonmutating set { viewModel.appearance = newValue }
    }
    @State private var page: SettingsPage?

    @State private var confirmRestore = false
    @State private var showFamilyChat = false
    var onBack: (() -> Void)?
    private let green = DashboardPalette.green
    private let border = Color(red: 190/255, green: 201/255, blue: 198/255)
    private enum SettingsPage: String, Identifiable {
        case profile, household, members, currency, appearance, sync, help, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: "My profile"
            case .household: "Household"
            case .members: "Family & sharing"
            case .currency: "Currency"
            case .appearance: "Appearance"
            case .sync: "Sync status"
            case .help: "Help & support"
            case .about: "About HomeMate"
            }
        }
    }
    @ObservedObject var viewModel: SettingsViewModel
    private var draftProfile: HouseholdProfile { get { viewModel.draftProfile } nonmutating set { viewModel.draftProfile = newValue } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { page = .profile } label: {
                        HStack(spacing: 16) {
                            ProfileAvatar(data: viewModel.profile.personalDetails?.avatarData, name: viewModel.profile.name, size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.profile.name).font(.headline).foregroundStyle(.primary)
                                Text(viewModel.accountSignedIn ? viewModel.accountEmail : viewModel.profile.household).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                }
                Section("Household") {
                    settingsLink("My private space", symbol: "house", page: .household)
                    settingsLink("Family & sharing", symbol: "person.2", page: .members)
                    Button { showFamilyChat = true } label: { Label(viewModel.accountSignedIn ? "Shared families & chat" : "Offline notes", systemImage: "bubble.left.and.bubble.right") }
                }
                Section {
                    Toggle(isOn: Binding(get: { appLock.enabled }, set: { value in Task { await appLock.setEnabled(value) } })) {
                        Label("Require Face ID", systemImage: "faceid")
                    }.disabled(appLock.busy)
                    if let message = appLock.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Privacy & security") } footer: {
                    Text("Lock HomeMate when you leave the app. Use Face ID or Touch ID to unlock. Device passcode alone cannot unlock HomeMate.")
                }
                Section("Preferences") {
                    Toggle("Notifications", systemImage: "bell.badge", isOn: $viewModel.notifications)
                    settingsLink("Currency", symbol: "banknote", page: .currency)
                    Picker(selection: Binding(get: { appearance }, set: { appearance = $0 })) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                }
                Section("Data & storage") {
                    settingsLink("Sync status", symbol: "arrow.triangle.2.circlepath", page: .sync)
                    NavigationLink { AnalyticsView() } label: { Label("Insights", systemImage: "chart.bar") }
                }
                Section("Support") {
                    settingsLink("Help & support", symbol: "questionmark.circle", page: .help)
                    settingsLink("About HomeMate", symbol: "info.circle", page: .about)
                }
                Section {
                    Button(role: viewModel.accountSignedIn ? .destructive : nil) {
                        if viewModel.accountSignedIn { viewModel.signOut() } else { page = .sync }
                    } label: {
                        Label(viewModel.accountSignedIn ? "Sign out" : "Sign in",
                              systemImage: viewModel.accountSignedIn ? "rectangle.portrait.and.arrow.right" : "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.listStyle(.insetGrouped)
                .navigationTitle("Settings")
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--preview"), ProcessInfo.processInfo.arguments.contains("--preview-profile") { page = .profile }
                    #endif
                }
                .fullScreenCover(isPresented: $showFamilyChat) { NavigationStack { if viewModel.accountSignedIn { FamilySharingView() } else { FamilyChatView().responsiveHomeWidth() } } }
                .sheet(item: $page) { selected in
                    NavigationStack {
                        if selected == .profile {
                            ProfileSettingsView(accountEmail: viewModel.accountSignedIn ? viewModel.accountEmail : "")
                        } else if selected == .members {
                            FamilySharingView()
                        } else {
                        detail(selected).navigationTitle(selected.title).navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") {
                                if [.household, .members, .currency].contains(selected) {
                                    if viewModel.saveDraft() { page = nil }
                                } else { page = nil }
                            } }
                            .confirmationDialog("Replace local records with your cloud backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
                                Button("Replace local records", role: .destructive) { Task { await viewModel.restore() } }
                            }
                        }
                    }.onAppear { viewModel.prepareDraft() }
                }
        }
    }
    private func settingsLink(_ title: String, symbol: String, page target: SettingsPage) -> some View {
        Button { page = target } label: {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
    @ViewBuilder private func detail(_ selected: SettingsPage) -> some View {
        Form {
            switch selected {
            case .profile:
                Section("Personal information") { TextField("Your name", text: $viewModel.draftProfile.name).exactTextEntry(); Text(viewModel.accountSignedIn ? viewModel.accountEmail : "Local profile • no account connected") }
            case .household:
                Section("Your home") { TextField("Household name", text: $viewModel.draftProfile.household).exactTextEntry() }
            case .members:
                Section { Text("Open Family & sharing to invite real accounts by email.") }
            case .currency:
                Picker("Currency", selection: $viewModel.draftProfile.currency) { ForEach(["LKR", "USD", "GBP", "EUR", "INR"], id: \.self) { Text($0) } }.pickerStyle(.inline)
                Text("Changes display formatting. Existing amounts are not converted.")
            case .appearance:
                Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0 })) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            case .sync:
                cloudControls
            case .help:
                Section("Getting started") { Text("Use Tasks or Bills to create, edit or delete household records. Swipe a record to complete or delete it."); Text("Scan receipts from Manage, then check the extracted text and amount before saving."); Text("Enable Notifications in Settings and allow permission to receive local reminders.") }
                Section("Explore") { NavigationLink("Expense analytics") { AnalyticsView() }; Button("Add example records") { viewModel.loadExamples() }.disabled(!viewModel.personalRecords.isEmpty) }
            case .about:
                Section("HomeMate 1.0") { Text("A simple household organiser built with SwiftUI, Core Data, Vision and local notifications.") }
                Section("Privacy") { Text("Signed-in account data is saved locally and automatically synced to Firebase, including your profile, activities, budget, notices, private notes, photos and voice notes. Receipt text recognition runs on your device. Face ID and device permissions stay on each device."); Text("Local data is separated by your Firebase account. Signing out hides that account’s household and notifications. Offline data is kept separately on this device.") }
                Section("Technologies") { Text("Apple system frameworks; no third-party packages. Bundled Core ML category, forecast and unusual-transaction models trained on demonstration data. Categories are editable; forecasts need three completed months. Unusual-transaction scores use earlier household payments and are experimental. Trends and statistical fallbacks are labelled separately.") }
            }
        }.scrollContentBackground(.hidden).background(HomeBackdrop())
    }
    @ViewBuilder private var cloudControls: some View {
        Section("Firebase account") {
            if !viewModel.accountConfigured { Text("Local storage is ready. Add FirebaseAPIKey and FirebaseProjectID in Info.plist to enable online accounts. See README.md.") }
            if viewModel.accountSignedIn {
                Text(viewModel.accountEmail)
                NavigationLink("Cloud records") { CloudRecordsView() }
                Button("Back up records") { Task { await viewModel.backup() } }
                Button("Restore cloud records") { confirmRestore = true }
                Button("Sign out") { viewModel.signOut() }
            } else {
                NavigationLink("Sign in or create account") { LoginView() }
            }
            if viewModel.accountBusy { ProgressView() }
            if !viewModel.accountMessage.isEmpty { Text(viewModel.accountMessage).font(.caption) }
        }.disabled(viewModel.accountBusy)
        Section { Text("Your account data syncs automatically after saving and refreshes every 30 seconds while the app is active. Sign in with the same account on another device to restore it. The buttons above manage an additional records-only backup. Offline mode has a separate household.") }
    }
}

