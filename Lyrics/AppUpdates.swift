import SwiftUI
import Sparkle

@MainActor final class AppUpdates: ObservableObject {
    private let controller: SPUStandardUpdaterController
    let available: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        available = Data(base64Encoded: key)?.count == 32
        controller = SPUStandardUpdaterController(startingUpdater: available, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func check() { controller.checkForUpdates(nil) }
}
