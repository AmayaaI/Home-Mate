import SwiftUI
import Combine
import WidgetKit

/// Composition root: one repository and authenticated service shared across feature ViewModels.
@MainActor
final class AppDependencies: ObservableObject {
    let store: HouseholdStore
    let account: CloudAccount
    let household: HouseholdContext
    let locations = ErrandLocationService()
    @Published var arrivalRecord: HouseholdRecord?
    @Published var arrivalError: String?
    private var pendingArrival: (scope: String, id: UUID)?
    private var openingArrival = false
    private var observations = Set<AnyCancellable>()
    private var widgetRefreshPending = false
    private var lastWidgetSnapshot: HomeWidgetSnapshot?
    convenience init() { self.init(store: HouseholdStore(), account: CloudAccount()) }
    init(store: HouseholdStore, account: CloudAccount) {
        self.store = store
        self.account = account
        household = HouseholdContext(account: account)
        household.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleWidgetRefresh()
        }.store(in: &observations)
        account.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleWidgetRefresh()
        }.store(in: &observations)
        store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleWidgetRefresh()
        }.store(in: &observations)
        locations.onArrivalTap = { [weak self] scope, id in
            self?.pendingArrival = (scope, id)
            self?.scheduleWidgetRefresh()
        }
        refreshWidget()
    }

    private func openArrival(scope: String, id: UUID) async {
        let accountScope = account.dataScope
        guard scope.hasPrefix(accountScope + ":"), store.scope == accountScope else { return }
        let familyID = String(scope.dropFirst(accountScope.count + 1))
        if familyID == "private" {
            household.select(nil)
            arrivalRecord = store.records.first { $0.id == id }
        } else {
            do {
                let api = FamilyAPI(account: account)
                let families = try await api.families()
                guard account.dataScope == accountScope else { return }
                guard let family = families.first(where: { $0.id == familyID }) else {
                    arrivalError = "This household is no longer available."; return
                }
                guard account.dataScope == accountScope else { return }
                household.select(family)
                await household.refresh()
                guard account.dataScope == accountScope, household.family?.id == familyID else { return }
                arrivalRecord = household.records.first { $0.id == id }
            } catch {
                if account.dataScope == accountScope { arrivalError = "Could not open this errand. " + error.localizedDescription }
                return
            }
        }
        if arrivalRecord == nil { arrivalError = "This errand was removed or is no longer available. Refresh your household and try again." }
    }

    private func scheduleWidgetRefresh() {
        guard !widgetRefreshPending else { return }
        widgetRefreshPending = true
        // @Published sends before assignment. Read the final values on the next actor turn,
        // after a save/rollback or account activation has finished.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.widgetRefreshPending = false
            self.refreshWidget()
        }
    }

    private func refreshWidget() {
        if store.scope == account.dataScope {
            let appearance = store.preferences.appearance ?? "system"
            if ["system", "light", "dark"].contains(appearance), UserDefaults.standard.string(forKey: "appearance") != appearance {
                UserDefaults.standard.set(appearance, forKey: "appearance")
            }
        }
        let active = store.scope == account.dataScope && (account.signedIn || store.guestSessionActive)
        if let pending = pendingArrival, active, !openingArrival {
            pendingArrival = nil
            if pending.scope.hasPrefix(account.dataScope + ":") {
                openingArrival = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.openArrival(scope: pending.scope, id: pending.id)
                    self.openingArrival = false
                    if self.pendingArrival != nil { self.scheduleWidgetRefresh() }
                }
            } else { arrivalError = "Sign in to the account that owns this errand to open it." }
        }
        let visibleRecords = household.family == nil ? store.records : household.records
        var scopes = Dictionary(uniqueKeysWithValues: household.authorisedArrivalRecords.map { (account.dataScope + ":" + $0.key, $0.value) })
        scopes[account.dataScope + ":private"] = store.records
        locations.update(scopes: scopes, identity: household.identity,
                         email: account.email, localName: store.profile.name, enabled: active && store.profile.reminders)
        store.scheduleReminders(for: visibleRecords, identifierPrefix: household.identity)
        #if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains("--preview") else { return }
        #endif
        let snapshot: HomeWidgetSnapshot
        if store.scope == account.dataScope && (account.signedIn || store.guestSessionActive) {
            let activities = visibleRecords.compactMap { record -> HomeWidgetActivity? in
                let kind: HomeWidgetActivity.Kind
                switch record.kind {
                case .task: kind = .task
                case .bill: kind = .bill
                case .maintenance: kind = .maintenance
                case .event: kind = .event
                case .expense: return nil
                }
                return HomeWidgetActivity(id: record.id, kind: kind, title: record.title, date: record.date, endDate: record.endDate, completed: record.completed)
            }
            snapshot = .make(householdName: household.family?.name ?? store.profile.household, activities: activities)
        } else {
            // Never leave the previous account's information on the Home Screen.
            snapshot = .signedOut()
        }
        guard lastWidgetSnapshot.map({ !snapshot.hasSameContents(as: $0) }) ?? true else { return }
        do {
            guard try HomeWidgetSnapshotStore.write(snapshot) else { return }
            lastWidgetSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: HomeWidgetSnapshotStore.widgetKind)
        } catch {
            // A locked or unavailable group container must not prevent personal records saving.
            #if DEBUG
            print("HomeMate widget snapshot could not update: \(error.localizedDescription)")
            #endif
        }
    }
}

/// Keeps a screen's injected ViewModel alive across SwiftUI redraws.
struct ViewModelHost<Model: ObservableObject, Content: View>: View {
    @StateObject private var model: Model
    private let content: (Model) -> Content
    init(make: @autoclosure @escaping () -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        _model = StateObject(wrappedValue: make())
        self.content = content
    }
    var body: some View { content(model) }
}
