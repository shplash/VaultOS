import Foundation
import SwiftUI
import UIKit

/// Entry point called from the engine's `main` on iOS. Presents the launcher in
/// its own window and blocks until the user taps Play; the engine boots right
/// after this returns.
@_cdecl("fallout_ios_present_launcher")
public func fallout_ios_present_launcher() {
    LauncherHost.shared.present()
}

final class LauncherHost {
    static let shared = LauncherHost()

    private var window: UIWindow?
    private var finished = false

    func present() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                self.present()
            }
            return
        }

        guard !finished else {
            return
        }

        let model = LauncherModel()
        let root = LauncherView(model: model, onPlay: { [weak self] in
            self?.finish(launchGame: true)
        })

        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = UIColor.black

        let window = UIWindow(frame: UIScreen.main.bounds)
        // Above SDL's launch screen window (UIWindowLevelNormal + 1).
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        // main() has to keep control until the game is ready to boot, so run a
        // nested run loop. finish(launchGame:) stops it.
        fallout_ios_run_launcher_loop()
    }

    private func finish(launchGame: Bool) {
        guard !finished else {
            return
        }
        finished = true

        window?.isHidden = true
        let closingWindow = window
        window = nil

        // Let the tap finish dispatching before the window and its SwiftUI
        // hierarchy go away, then hand control back to the engine.
        DispatchQueue.main.async {
            closingWindow?.rootViewController = nil
            fallout_launcher_finish(Int32(launchGame ? 1 : 0))
        }
    }
}
