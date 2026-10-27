import Foundation
import Combine

@MainActor
final class StartupViewModel: ScreenViewModel {
    @Published var loadingProfile = false
    @Published var profileSyncError: String?
    private var profileTask: Task<Void, Never>?
    private var activatedScope: String?
    private var syncRunning = false
    private var syncAgain = false
    @Published var showingSplash = true
    enum Route { case loading, login, welcome, main }
    var route: Route {
        if store.scope != account.dataScope || loadingProfile { return .loading }
        if !account.signedIn && !store.guestSessionActive { return .login }
        return store.profile.onboarded ? .main : .welcome
    }
    var scope: String { store.scope }
    func continueOffline() { store.guestSessionActive = true }
    func activateAccount() {
        let scope = account.dataScope
        guard activatedScope != scope else { return }
        activatedScope = scope
        profileTask?.cancel()
        store.activate(userID: account.signedIn ? account.userID : nil)
        profileSyncError = nil
        loadingProfile = account.signedIn
        store.onAccountSaved = { [weak self] in
            guard let self else { return }
            Task { await self.syncProfile() }
        }
        profileTask = Task { [weak self] in
            guard let self else { return }
            await self.syncProfile()
            // Retry offline edits and refresh changes made on another device.
            while !Task.isCancelled && self.account.dataScope == scope && self.account.signedIn {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self.syncProfile()
            }
        }
    }
    func syncProfile() async {
        guard account.signedIn, store.scope == account.dataScope else { loadingProfile = false; return }
        if syncRunning { syncAgain = true; return }
        syncRunning = true
        defer {
            syncRunning = false
            if syncAgain {
                syncAgain = false
                Task { await self.syncProfile() }
            }
        }
        let scope = account.dataScope
        let current = { self.account.dataScope == scope && self.store.scope == scope && !Task.isCancelled }
        do {
            try store.migrateVoiceAttachments()
            let local = store.accountSnapshot
            let baseline = store.accountBaseline
            let cloud = try await account.fetchAccountSnapshot()
            guard current() else { return }
            let merged = try AccountSnapshot.merge(local: local, base: baseline, remote: cloud.snapshot)
            if try cloud.updateTime == nil || merged.encoded() != cloud.snapshot.encoded() {
                try await account.uploadAccountSnapshot(merged, updateTime: cloud.updateTime)
                guard current() else { return }
            }
            try store.acceptAccountSnapshot(merged, sent: local, expectedScope: scope)
            if try store.accountSnapshot.encoded() != merged.encoded() { syncAgain = true }
            guard current() else { return }
            profileSyncError = nil
            loadingProfile = false
        } catch {
            guard current() else { return }
            profileSyncError = "Your account data has not synced yet. " + error.localizedDescription
            // Never show fresh onboarding over an existing cloud profile after a failed download.
            loadingProfile = !store.profile.onboarded
        }
    }
    func signedInChanged(from previous: Bool, to current: Bool) {
        if previous && !current { store.guestSessionActive = false }
        activateAccount()
    }
    func start() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") { continueOffline() }
        #endif
        async let pause: Void = Task.sleep(for: .seconds(1.25))
        if !store.guestSessionActive { await account.restoreSession() }
        do { try await pause } catch { return }
        activateAccount()
        showingSplash = false
    }
}
