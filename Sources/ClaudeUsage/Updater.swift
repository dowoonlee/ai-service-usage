import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController

    override init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }
}
