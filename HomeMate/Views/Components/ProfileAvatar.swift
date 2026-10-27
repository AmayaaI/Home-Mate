import SwiftUI

struct ProfileAvatar: View {
    var data: Data?
    var name: String
    var size: CGFloat
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(DashboardPalette.surface)
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .foregroundStyle(DashboardPalette.green)
            .overlay(Circle().stroke(.white, lineWidth: 4))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .accessibilityLabel("Profile photo")
    }
}
