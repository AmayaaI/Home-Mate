import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: WelcomeViewModel(store: dependencies.store, account: dependencies.account)) { model in
            WelcomeViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct WelcomeViewScreen: View {


    @ObservedObject var viewModel: WelcomeViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 8) { Image(systemName: "house.lodge.fill"); Text("HomeMate").fontWeight(.bold) }.font(.title3).foregroundStyle(DashboardPalette.green)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Image(systemName: "house.lodge.fill").font(.system(size: 72)).foregroundStyle(DashboardPalette.mint); Spacer() }
                        Text("Less to manage.\nMore to enjoy.").font(.largeTitle .weight(.bold)).tracking(-1).foregroundStyle(.white)
                        Text("Bring your household's plans, little tasks and everyday spending together.").font(.subheadline).lineSpacing(4).foregroundStyle(.white.opacity(0.75))
                        HStack(spacing: 14) { Label("Plan", systemImage: "calendar"); Label("Share", systemImage: "person.2"); Label("Relax", systemImage: "leaf") }.font(.caption2 .weight(.semibold)).foregroundStyle(DashboardPalette.mint)
                    }.padding(26).background(LinearGradient(colors: [DashboardPalette.green, Color(red: 0, green: 70/255, blue: 64/255)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30)).shadow(color: DashboardPalette.green.opacity(0.16), radius: 16, y: 8)
                    VStack(alignment: .leading, spacing: 18) {
                        HomeSectionTitle(eyebrow: "Let's make it yours", title: "Welcome home")
                        welcomeField("YOUR NAME", placeholder: "What should we call you?", text: $viewModel.draft.name, icon: "person")
                        welcomeField("HOUSEHOLD NAME", placeholder: "My Home", text: $viewModel.draft.household, icon: "house")
                        Label(viewModel.accountSignedIn ? "Invite people by email from Family & sharing after setting up your profile." : "Sign in for family sharing. Offline mode keeps personal activities on this device.", systemImage: "person.2").font(.footnote).foregroundStyle(.secondary)
                        HomePrimaryButton(title: viewModel.accountSignedIn ? "Set up my profile" : "Create offline household", icon: "arrow.right") { viewModel.save() }.disabled(!viewModel.canSave).opacity(!viewModel.canSave ? 0.55 : 1)
                    }
                    Label("Made for your home. Available offline.", systemImage: "lock.shield").font(.caption2).foregroundStyle(DashboardPalette.muted).frame(maxWidth: .infinity)
                }.padding(22).padding(.vertical, 12).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(HomeBackdrop()).toolbar(.hidden, for: .navigationBar)
        }
    }
    private func welcomeField(_ title: String, placeholder: String, text: Binding<String>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2 .weight(.bold)).tracking(1).foregroundStyle(DashboardPalette.muted)
            HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(DashboardPalette.green).frame(width: 20); TextField(placeholder, text: text).exactTextEntry().font(.body) }.padding(16).homeCard(cornerRadius: 16)
        }
    }
}
