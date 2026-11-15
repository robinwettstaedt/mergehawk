import AppKit

/// The "Appearance" preference: follow the macOS appearance, or force light or dark for the whole app.
enum AppAppearance: String, CaseIterable {
    case auto
    case light
    case dark

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The application appearance for this option. `nil` clears it so windows follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
