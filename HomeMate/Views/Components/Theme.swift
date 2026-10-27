import SwiftUI

// Shared colours from your UIView / CALayer example.
enum HomeMateStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let backgroundUIColor = UIColor.systemGroupedBackground
}


// Shared brand tokens; content surfaces continue to follow the system appearance.
enum DashboardPalette {
    static let brandFill = Color(red: 0.08, green: 0.37, blue: 0.31)
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.48, green: 0.87, blue: 0.73, alpha: 1) : UIColor(red: 0.08, green: 0.37, blue: 0.31, alpha: 1)
    })
    static let ink = Color.primary
    static let muted = Color.secondary
    static let surface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let mint = Color(red: 152/255, green: 243/255, blue: 226/255)
    static let red = Color(uiColor: .systemRed)
}
