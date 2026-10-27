import SwiftUI

@main
struct HomeMateApp: App {
    @StateObject private var dependencies = AppDependencies()
    private var store: HouseholdStore { dependencies.store }
    @StateObject private var appLock = AppLockViewModel()


    var body: some Scene {
        WindowGroup {
            AppLockContainer { StartupView() }.environmentObject(appLock).environmentObject(dependencies).tint(DashboardPalette.green)
                .scrollContentBackground(.hidden)
                .background(HomeBackdrop())
                .homeAppearance()
                .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("OK") { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
    }
}
