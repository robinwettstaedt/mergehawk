import Combine
import Foundation
import Sparkle

enum SoftwareUpdateDistribution: String {
    case development
    case github

    static let infoDictionaryKey = "MergeHawkDistributionChannel"

    init(bundle: Bundle) {
        let rawValue = bundle.object(forInfoDictionaryKey: Self.infoDictionaryKey) as? String
        self = SoftwareUpdateDistribution(rawValue: rawValue ?? "") ?? .development
    }
}

@MainActor
protocol SoftwareUpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    func checkForUpdates()
}

@MainActor
final class SoftwareUpdateController: ObservableObject {
    private var backend: (any SoftwareUpdateBackend)?

    init(backend: (any SoftwareUpdateBackend)? = nil) {
        self.backend = backend
    }

    var isAvailable: Bool { backend != nil }

    var canCheckForUpdates: Bool { backend?.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { backend?.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            backend?.automaticallyChecksForUpdates = newValue
        }
    }

    static func disabled() -> SoftwareUpdateController {
        SoftwareUpdateController()
    }

    static func testing(
        automaticallyChecksForUpdates: Bool = true,
        canCheckForUpdates: Bool = true,
        onCheckForUpdates: @escaping @MainActor () -> Void = {}
    ) -> SoftwareUpdateController {
        SoftwareUpdateController(
            backend: TestingSoftwareUpdateBackend(
                automaticallyChecksForUpdates: automaticallyChecksForUpdates,
                canCheckForUpdates: canCheckForUpdates,
                onCheckForUpdates: onCheckForUpdates
            )
        )
    }

    func enableSparkleIfConfigured(bundle: Bundle = .main) {
        guard backend == nil, let sparkleBackend = SparkleSoftwareUpdateBackend(bundle: bundle) else {
            return
        }
        objectWillChange.send()
        backend = sparkleBackend
    }

    func checkForUpdates() {
        objectWillChange.send()
        backend?.checkForUpdates()
    }
}

@MainActor
private final class SparkleSoftwareUpdateBackend: SoftwareUpdateBackend {
    private let updaterController: SPUStandardUpdaterController

    init?(bundle: Bundle) {
        guard
            SoftwareUpdateDistribution(bundle: bundle) == .github,
            bundle.nonEmptyInfoString(forKey: "SUFeedURL") != nil,
            bundle.nonEmptyInfoString(forKey: "SUPublicEDKey") != nil
        else {
            return nil
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

@MainActor
private final class TestingSoftwareUpdateBackend: SoftwareUpdateBackend {
    var automaticallyChecksForUpdates: Bool
    let canCheckForUpdates: Bool
    private let onCheckForUpdates: @MainActor () -> Void

    init(
        automaticallyChecksForUpdates: Bool,
        canCheckForUpdates: Bool,
        onCheckForUpdates: @escaping @MainActor () -> Void
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
    }

    func checkForUpdates() {
        onCheckForUpdates()
    }
}

private extension Bundle {
    func nonEmptyInfoString(forKey key: String) -> String? {
        guard let value = object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
