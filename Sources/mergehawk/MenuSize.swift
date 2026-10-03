import CoreGraphics

/// The "Menu Size" preference: one fixed scale step for the whole menu panel.
enum MenuSize: String, CaseIterable {
    case small
    case standard
    case large
    case larger

    var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    var factor: CGFloat {
        switch self {
        case .small: 0.85
        case .standard: 1
        case .large: 1.15
        case .larger: 1.3
        }
    }
}
