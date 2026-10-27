import SwiftUI

struct StartupView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var body: some View {
        ViewModelHost(make: StartupViewModel(store: dependencies.store, account: dependencies.account)) { model in
            StartupScreen(viewModel: model)
        }
    }
}

private struct StartupScreen: View {
    @ObservedObject var viewModel: StartupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if viewModel.showingSplash { SplashScreen().transition(.opacity).zIndex(1) }
            else {
                switch viewModel.route {
                case .loading:
                    VStack(spacing: 16) {
                        ProgressView("Opening your household…")
                        if let error = viewModel.profileSyncError {
                            Text(error).font(.callout).multilineTextAlignment(.center)
                            Button("Retry") { Task { await viewModel.syncProfile() } }
                            Button("Sign out") { viewModel.account.signOut() }
                        }
                    }.padding()
                case .login: LoginView(onContinueOffline: viewModel.continueOffline).transition(.opacity)
                case .main: MainView().id(viewModel.scope).transition(.opacity)
                case .welcome: WelcomeView().id(viewModel.scope).transition(.opacity)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if !viewModel.loadingProfile, let error = viewModel.profileSyncError {
                VStack {
                    Text(error).font(.caption)
                    Button("Retry account sync") { Task { await viewModel.syncProfile() } }
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: viewModel.showingSplash)
        .task { await viewModel.start() }
        .onChange(of: viewModel.accountDataScope, initial: true) { _, _ in viewModel.activateAccount() }
        .onChange(of: viewModel.accountSignedIn) { previous, current in viewModel.signedInChanged(from: previous, to: current) }
    }
}

struct SplashScreen: View {
    private let green = DashboardPalette.green
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The CSS overlays 60% #8EDCB5 on top of #F8FAF9.
                HomeMateStyle.background
                Color(red: 142/255, green: 220/255, blue: 181/255).opacity(0.6)

                Ellipse().fill(Color(red: 219/255, green: 228/255, blue: 226/255).opacity(0.18))
                    .frame(width: 223, height: 384).blur(radius: 32)
                    .position(x: geometry.size.width * 0.29, y: geometry.size.height * 0.30)
                Ellipse().fill(DashboardPalette.mint.opacity(0.08))
                    .frame(width: 167, height: 288).blur(radius: 20)
                    .position(x: geometry.size.width * 0.9, y: geometry.size.height * 0.47)

                VStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28).fill(green.opacity(0.1)).frame(width: 112, height: 112).blur(radius: 6)
                        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white)
                            .frame(width: 104, height: 104)
                            .shadow(color: .black.opacity(0.1), radius: 16, x: 0, y: 12)
                        // The pasted export references a PNG without including it.
                        // Keep HomeMate's existing house mark until a logo asset is provided.
                        Image(systemName: "house.lodge.fill").font(.system(size: 49, weight: .medium)).foregroundStyle(green)
                    }.frame(width: 104, height: 104)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "checkmark").font(.caption2 .weight(.bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 21).background(green, in: Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 2).offset(x: 8, y: 8)
                        }
                    VStack(spacing: 4) {
                        Text("HomeMate").font(.title .weight(.bold)).tracking(-0.7).foregroundStyle(DashboardPalette.ink)
                        Text("A little more harmony at home.").font(.body).foregroundStyle(DashboardPalette.muted)
                    }
                }.frame(maxWidth: geometry.size.width - 40)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.365)
                    .accessibilityElement(children: .combine)

                VStack(spacing: 10) {
                    ProgressView().tint(green).controlSize(.regular).accessibilityLabel("Opening HomeMate")
                    Text("WELCOME HOME").font(.caption2 .weight(.semibold)).tracking(1.1).foregroundStyle(DashboardPalette.muted.opacity(0.75))
                }.position(x: geometry.size.width / 2, y: geometry.size.height * 0.78)
            }
        }.ignoresSafeArea()
    }
}

struct SplashScreen_Previews: PreviewProvider {
    static var previews: some View { SplashScreen() }
}
