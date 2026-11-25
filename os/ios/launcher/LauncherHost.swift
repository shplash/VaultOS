import AVFoundation
import Foundation
import QuartzCore
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
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var sizeObservers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        resignObserver = center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.appWillResignActive()
        }
        activeObserver = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.appDidBecomeActive()
        }
    }

    /// What the display keeps for the sensor housing and the home indicator.
    /// The launcher covers the whole screen and keeps its own content inside
    /// these, so it fills a phone or a tablet instead of sitting in a box.
    static var safeInsets: UIEdgeInsets {
        return shared.window?.safeAreaInsets ?? .zero
    }

    private func appWillResignActive() {
        if finished {
            // The game is running; pause both its SDL stream and the launcher
            // track if the main menu is using it.
            fallout_ios_pause_game_audio()
            LauncherMusic.shared.pause()
        } else {
            // Leaving the launcher in the background should silence its music.
            LauncherMusic.shared.stop()
        }
    }

    private func appDidBecomeActive() {
        if finished {
            fallout_ios_resume_game_audio()
            LauncherMusic.shared.resume()
        } else if window != nil {
            // Launching the app rotates the interface to landscape, which lands
            // after the launcher's window exists.
            fitToAvailableSpace()
            LauncherMusic.shared.playIfAvailable()
        }
    }

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
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // The window takes the space the app is actually given, never a shape
        // guessed from the screen. main() runs this during launch, before the
        // landscape-only rotation has landed, so the screen can still report the
        // portrait metrics; and on an iPad the app can be given a window smaller
        // than the screen. A window built from the wrong bounds leaves the
        // launcher laid out for a shape it is never shown in, which reads as a
        // squeezed rail with the rest of the page off screen.
        let window = launcherWindow()
        // Above SDL's launch screen window (UIWindowLevelNormal + 1).
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        fitToAvailableSpace()
        followAvailableSpace()

        // main() has to keep control until the game is ready to boot, so run a
        // nested run loop. finish(launchGame:) stops it.
        fallout_ios_run_launcher_loop()
    }

    /// A window owned by the app's scene when it has one, so UIKit keeps it the
    /// size of the space the app was given; a landscape window otherwise.
    private func launcherWindow() -> UIWindow {
        if let windowScene = scene() {
            return UIWindow(windowScene: windowScene)
        }
        return UIWindow(frame: availableBounds())
    }

    /// The scene the launcher belongs to, preferring the one in front.
    private func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    /// The space the launcher may use: its own scene when UIKit gave it one,
    /// the screen otherwise, always in the shape the app is shown in. During
    /// launch the scene still reports the portrait metrics until the interface
    /// rotation to landscape lands, and a launcher laid out for those only puts
    /// itself right once the device is turned.
    private func availableBounds() -> CGRect {
        let bounds: CGRect
        if let windowScene = window?.windowScene {
            bounds = windowScene.coordinateSpace.bounds
        } else if let windowScene = scene() {
            bounds = windowScene.coordinateSpace.bounds
        } else {
            bounds = UIScreen.main.bounds
        }

        guard bounds.height > bounds.width else {
            return bounds
        }

        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.height, height: bounds.width)
    }

    private func fitToAvailableSpace() {
        guard let window = window else {
            return
        }

        let bounds = availableBounds()
        guard bounds.width > 0 && bounds.height > 0 else {
            return
        }

        if window.frame != bounds {
            window.frame = bounds
        }
        if let view = window.rootViewController?.view, view.bounds.size != bounds.size {
            view.frame = CGRect(origin: .zero, size: bounds.size)
        }
    }

    /// The interface rotation that follows launch is not a device rotation, and
    /// a resized window on an iPad can change at any time, so the launcher's
    /// window is fitted again on every change and once more once UIKit has
    /// settled the launch-time rotation.
    private func followAvailableSpace() {
        sizeObservers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.fitToAvailableSpace()
        })
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    private func finish(launchGame: Bool) {
        guard !finished else {
            return
        }
        finished = true

        for observer in sizeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sizeObservers.removeAll()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

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

// MARK: - In-game controls

// Native controls shown over SDL's view in the black margins beside the HUD.
// Keeping them as real UIKit views means SDL never sees these touches, while
// the rest of the screen keeps working exactly as before.

private enum ControlTheme {
    /// The colour the player picked for the controls. It tints the glyphs, the
    /// labels and the wash of a held or selected button; the plates, their
    /// outlines and their shadows stay neutral, so nothing here tints the game
    /// underneath them.
    static var control: UIColor {
        let key = LauncherModel.optionKey("buttonColour", for: ControlLayout.activeGame())
        let index = UserDefaults.standard.integer(forKey: key)
        return ControlColour(rawValue: index)?.uiColor ?? .white
    }

    static var panel: UIColor {
        return VaultUI.controlFill.withAlphaComponent(0.78)
    }

    static var solidPanel: UIColor {
        return VaultUI.controlFill
    }

    static var border: UIColor {
        return VaultUI.controlBorder
    }

    static var content: UIColor {
        return VaultUI.controlContent
    }

    static var pressed: UIColor {
        return VaultUI.controlPressed
    }

    static var pressedEdge: UIColor {
        return UIColor(white: 0.55, alpha: 1)
    }

    static var innerEdge: UIColor {
        return UIColor(white: 1, alpha: 0.10)
    }

    static var wash: UIColor {
        return control.withAlphaComponent(0.20)
    }
}

enum TouchControl: String, CaseIterable, Identifiable, Hashable {
    case joystick
    case back
    case pip
    case action
    case skip
    case inv
    case map
    case cha
    case skill
    case swap
    case end
    case reload
    case fireMode
    case load
    case saves
    case quickSave
    case tray

    var id: String { rawValue }

    var label: String {
        let english: String
        switch self {
        case .joystick: english = "CAMERA"
        case .back: english = "BACK"
        case .pip: english = "PIP"
        case .action: english = "MOVE"
        case .skip: english = "END TURN"
        case .inv: english = "INV"
        case .map: english = "MAP"
        case .cha: english = "CHA"
        case .skill: english = "SKILL"
        case .swap: english = "SWAP"
        case .end: english = "END\nCOMBAT"
        case .reload: english = "RELOAD"
        case .fireMode: english = "ATTACK MODE"
        case .load: english = "LOAD"
        case .saves: english = "SAVE"
        case .quickSave: english = "QUICK SAVE"
        case .tray: english = "TRAY"
        }
        return L.t(english)
    }

    var symbol: String {
        switch self {
        case .joystick: return "circle.dashed"
        case .back: return "chevron.backward"
        case .pip: return "book.closed"
        case .action: return "arrow.up.and.down.and.arrow.left.and.right"
        case .skip: return "forward.end"
        case .inv: return "bag"
        case .map: return "map"
        case .cha: return "person"
        case .skill: return "star"
        case .swap: return "arrow.left.arrow.right"
        case .end: return "xmark"
        case .reload: return "arrow.clockwise"
        case .fireMode: return "scope"
        case .load: return "tray.and.arrow.down"
        case .saves: return "tray.full"
        case .quickSave: return "bolt.fill"
        case .tray: return "chevron.right"
        }
    }

    /// Both games keep independent control sets and layouts. The reload and
    /// attack-mode buttons show themselves only when the running engine reports
    /// the action as available.
    static func controls(for game: FalloutGame) -> [TouchControl] {
        return allCases
    }

    /// MAP, CHA and INV, in that order, along the bottom right corner.
    static func bottomRow(for profile: LayoutProfile) -> [TouchControl] {
        return [.map, .cha, .inv]
    }

    /// The space between two neighbouring controls at their own size.
    static func gap(in bounds: CGSize) -> CGFloat {
        return max(2, min(bounds.width * 0.05625, bounds.height * 0.130) * 0.08)
    }

    /// Normalized center of the control on the game view. The editor stores the
    /// same coordinates, so layouts survive resolution and orientation changes.
    func defaultCenter(for profile: LayoutProfile = .full, in bounds: CGSize = UIScreen.main.bounds.size) -> CGPoint {
        if profile == .half {
            return presetCenter(in: bounds)
        }

        switch self {
        case .quickSave:
            return CGPoint(x: 0.9550, y: 0.1054)
        case .tray:
            let save = TouchControl.quickSave.defaultCenter(for: profile, in: bounds)
            let size = TouchControl.quickSave.defaultSize(in: bounds, profile: profile)
            let side = TouchControl.tray.defaultSize(in: bounds, profile: profile).width
            let step = size.width / 2 + side / 2
            let direction: CGFloat = ControlLayout.traySide(profile: profile, game: ControlLayout.activeGame()) == .left ? -1 : 1
            return CGPoint(x: save.x + direction * step / max(bounds.width, 1), y: save.y)
        case .load:
            return CGPoint(x: 0.8493, y: 0.1029)
        case .saves:
            return CGPoint(x: 0.7800, y: 0.1020)
        case .pip:
            return CGPoint(x: 0.1565, y: 0.6063)
        case .back:
            return CGPoint(x: 0.2209, y: 0.7154)
        case .joystick:
            return CGPoint(x: 0.1165, y: 0.8308)
        case .end:
            return CGPoint(x: 0.8646, y: 0.2547)
        case .fireMode:
            return CGPoint(x: 0.9517, y: 0.2565)
        case .skill:
            return CGPoint(x: 0.8389, y: 0.7934)
        case .swap:
            return CGPoint(x: 0.9655, y: 0.4026)
        case .skip:
            return CGPoint(x: 0.9454, y: 0.6270)
        case .action:
            return CGPoint(x: 0.9327, y: 0.8385)
        case .reload:
            return CGPoint(x: 0.8389, y: 0.9260)
        case .map:
            return CGPoint(x: 0.0937, y: 0.2195)
        case .cha:
            return CGPoint(x: 0.0931, y: 0.3892)
        case .inv:
            return CGPoint(x: 0.0931, y: 0.5585)
        }
    }

    func presetCenter(in bounds: CGSize) -> CGPoint {
        switch self {
        case .quickSave:
            let width = TouchControl.quickSave.defaultSize(in: bounds).width
            let side = min(bounds.width * 0.05625, bounds.height * 0.130)
            let left = (1 - 0.9594) * bounds.width - side / 2
            return CGPoint(x: (left + width / 2) / max(bounds.width, 1), y: 0.0750)
        case .tray:
            let save = TouchControl.quickSave.presetCenter(in: bounds)
            let size = TouchControl.quickSave.defaultSize(in: bounds)
            let side = TouchControl.tray.defaultSize(in: bounds).width
            let step = size.width / 2 + side / 2
            return CGPoint(x: save.x + step / max(bounds.width, 1), y: save.y)
        case .load:
            let tray = TouchControl.tray.presetCenter(in: bounds)
            let side = TouchControl.tray.defaultSize(in: bounds).width
            let width = TouchControl.load.defaultSize(in: bounds).width
            let step = side / 2 + TouchControl.gap(in: bounds) + width / 2
            return CGPoint(x: tray.x + step / max(bounds.width, 1), y: tray.y)
        case .saves:
            let load = TouchControl.load.presetCenter(in: bounds)
            let width = TouchControl.load.defaultSize(in: bounds).width
            let step = width + TouchControl.gap(in: bounds)
            return CGPoint(x: load.x + step / max(bounds.width, 1), y: load.y)
        case .pip:
            return CGPoint(x: 0.1080, y: 0.4250)
        case .back:
            return CGPoint(x: 0.1160, y: 0.5725)
        case .joystick:
            return CGPoint(x: 0.1170, y: 0.8110)
        case .end:
            let width = TouchControl.end.defaultSize(in: bounds).width
            let square = min(bounds.width * 0.05625, bounds.height * 0.130)
            return CGPoint(x: 0.9594 - (width - square) / 2 / max(bounds.width, 1), y: 0.0750)
        case .fireMode:
            let end = TouchControl.end.presetCenter(in: bounds)
            let side = TouchControl.end.defaultSize(in: bounds).width
            let step = side + TouchControl.gap(in: bounds)
            return CGPoint(x: end.x - step / max(bounds.width, 1), y: end.y)
        case .skill:
            return CGPoint(x: 0.9594, y: 0.2000)
        case .swap:
            return CGPoint(x: 0.9594, y: 0.3250)
        case .skip:
            return CGPoint(x: 0.9444, y: 0.5320)
        case .action:
            return CGPoint(x: 0.9415, y: 0.6900)
        case .reload:
            return CGPoint(x: 0.8550, y: 0.6900)
        case .map:
            return CGPoint(x: 0.8347, y: 0.9071)
        case .cha:
            return CGPoint(x: 0.8953, y: 0.9071)
        case .inv:
            return CGPoint(x: 0.9559, y: 0.9071)
        }
    }

    /// The phone the control layout was designed on, in points.
    static let designScreen = CGSize(width: 852, height: 393)

    /// How much bigger this screen is than that phone, for every size below.
    /// One factor for both sides keeps each control's shape: a width taken from
    /// the screen's width and a height from its height changes shape with the
    /// aspect, so SKIP, ACTION, MAP, CHA and INV came out as tall blocks on a
    /// 4:3 tablet and flat bars on a 2:1 phone.
    static func sizeUnit(in bounds: CGSize) -> CGFloat {
        return max(0.75, min(bounds.width / designScreen.width,
                             bounds.height / designScreen.height))
    }

    /// Base size in points before the global and per-control scale settings.
    /// The HUD-row buttons are intentionally rectangles so they fill the side
    /// strip in the same way as the proposed layout.
    func defaultSize(in bounds: CGSize, profile: LayoutProfile = .full) -> CGSize {
        let size = designSize()
        let unit = TouchControl.sizeUnit(in: bounds)
        return CGSize(width: size.width * unit, height: size.height * unit)
    }

    /// This control's size on the phone the layout was designed on, in points.
    private func designSize() -> CGSize {
        let bounds = TouchControl.designScreen
        let square = min(bounds.width * 0.05625, bounds.height * 0.130)
        switch self {
        case .quickSave:
            return CGSize(width: square * 1.51, height: square)
        case .tray:
            return CGSize(width: square * 0.56, height: square)
        case .load, .saves:
            return CGSize(width: square * 1.25, height: square)
        case .pip:
            let side = min(bounds.width * 0.0644, bounds.height * 0.143)
            return CGSize(width: side, height: side)
        case .back:
            let side = min(bounds.width * 0.0670, bounds.height * 0.149)
            return CGSize(width: side, height: side)
        case .joystick:
            let side = bounds.height * 0.318
            return CGSize(width: side, height: side)
        case .end, .fireMode:
            return CGSize(width: square * 1.28, height: square)
        case .skill, .swap:
            return CGSize(width: square, height: square)
        case .skip:
            return CGSize(width: bounds.width * 0.0838, height: bounds.height * 0.135)
        case .action:
            return CGSize(width: bounds.width * 0.0925, height: bounds.height * 0.171)
        case .reload:
            let side = min(bounds.width * 0.055, bounds.height * 0.125)
            return CGSize(width: side, height: side)
        case .map, .cha, .inv:
            return CGSize(width: bounds.width * 0.0606, height: bounds.height * 0.1665)
        }
    }
}

enum LayoutProfile: String {
    case full
    case half
}

enum ControlLayout {
    private static let layoutVersionKey = "launcher.controlLayoutVersion"
    private static let layoutVersion = 23
    private static let sideSuffix = ".side"
    private static let xSuffix = ".x"
    private static let ySuffix = ".y"
    private static let scaleSuffix = ".scale"

    static func activeGame() -> FalloutGame {
        FalloutGame(rawValue: UserDefaults.standard.string(forKey: "launcher.game") ?? "") ?? .fallout1
    }

    private static func key(_ control: TouchControl, _ suffix: String, profile: LayoutProfile, game: FalloutGame) -> String {
        return "launcher.control.\(game.rawValue).\(profile.rawValue).\(control.rawValue)\(suffix)"
    }

    private static func previousKey(_ control: TouchControl, _ suffix: String, profile: LayoutProfile) -> String {
        return "launcher.control.\(profile.rawValue).\(control.rawValue)\(suffix)"
    }

    private static func legacyKey(_ control: TouchControl, _ suffix: String) -> String {
        return "launcher.control.\(control.rawValue)\(suffix)"
    }

    /// Which layout the current resolution setting uses. The launcher saves
    /// width/height before handing control to the engine, so the overlay can
    /// pick the matching layout without a separate switch.
    static func profileForCurrentResolution() -> LayoutProfile {
        let defaults = UserDefaults.standard
        let game = activeGame()
        let native = LauncherModel.nativeResolution()
        let half = LauncherModel.displayResolution(divisor: 3, native: native)
        let width = defaults.object(forKey: LauncherModel.optionKey("width", for: game)) as? Int ?? 0
        let height = defaults.object(forKey: LauncherModel.optionKey("height", for: game)) as? Int ?? 0
        return (width == half.0 && height == half.1) ? .half : .full
    }

    /// The player's opacity setting for the in-game controls.
    static func controlsOpacity() -> CGFloat {
        let value = UserDefaults.standard.object(
            forKey: LauncherModel.optionKey("controlsOpacity", for: activeGame())) as? Double ?? 1
        return CGFloat(min(max(value, 0.10), 1))
    }

    /// Whether the in-game touch controls are drawn at all. On unless the player
    /// has switched them off for this game.
    static func touchControls() -> Bool {
        let value = UserDefaults.standard.object(
            forKey: LauncherModel.optionKey("touchControls", for: activeGame())) as? Bool
        return value ?? true
    }

    static func autoTarget() -> Bool {
        let value = UserDefaults.standard.object(
            forKey: LauncherModel.optionKey("autoTarget", for: activeGame())) as? Bool
        return value ?? true
    }

    /// The first build with the reference layout used saved drag positions
    /// from the older oversized layout. This migration copies the existing
    /// single layout into the FULL profile, then starts a separate HALF
    /// profile from its own defaults.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: layoutVersionKey) < layoutVersion else {
            return
        }

        for control in TouchControl.allCases {
            for (legacy, target) in [
                (legacyKey(control, xSuffix), key(control, xSuffix, profile: .full, game: .fallout1)),
                (legacyKey(control, ySuffix), key(control, ySuffix, profile: .full, game: .fallout1)),
                (legacyKey(control, scaleSuffix), key(control, scaleSuffix, profile: .full, game: .fallout1)),
            ] {
                if let value = defaults.object(forKey: legacy) {
                    defaults.set(value, forKey: target)
                }
                defaults.removeObject(forKey: legacy)
            }

            // Version 10 stored one layout per display profile for Fallout 1.
            // Move it to the game-qualified key so Fallout 2 can own its own.
            for (suffix, target) in [
                (xSuffix, key(control, xSuffix, profile: .full, game: .fallout1)),
                (ySuffix, key(control, ySuffix, profile: .full, game: .fallout1)),
                (scaleSuffix, key(control, scaleSuffix, profile: .full, game: .fallout1)),
            ] {
                if let value = defaults.object(forKey: previousKey(control, suffix, profile: .full)) {
                    defaults.set(value, forKey: target)
                }
            }
            for (suffix, target) in [
                (xSuffix, key(control, xSuffix, profile: .half, game: .fallout1)),
                (ySuffix, key(control, ySuffix, profile: .half, game: .fallout1)),
                (scaleSuffix, key(control, scaleSuffix, profile: .half, game: .fallout1)),
            ] {
                if let value = defaults.object(forKey: previousKey(control, suffix, profile: .half)) {
                    defaults.set(value, forKey: target)
                }
            }
        }

        let previous = defaults.integer(forKey: layoutVersionKey)

        // Version 17 put every control back on the original layout with the
        // neutral faces, so the stored positions are cleared and each one comes
        // back where the layout puts it. The player's own sizes are kept, since
        // those still mean what they meant.
        if previous < 17 {
            for game in FalloutGame.allCases {
                for profile in [LayoutProfile.full, .half] {
                    for control in TouchControl.allCases {
                        defaults.removeObject(forKey: key(control, xSuffix, profile: profile, game: game))
                        defaults.removeObject(forKey: key(control, ySuffix, profile: profile, game: game))
                    }
                }
            }
        }

        // Version 18 joins QUICK SAVE and its chevron into one assembly, which
        // only reads as one control when the two sit flush. Their stored
        // positions are cleared so they come back joined; the other controls,
        // and every size, keep what the player set.
        if previous < 18 {
            for game in FalloutGame.allCases {
                for profile in [LayoutProfile.full, .half] {
                    for control in [TouchControl.quickSave, .tray] {
                        defaults.removeObject(forKey: key(control, xSuffix, profile: profile, game: game))
                        defaults.removeObject(forKey: key(control, ySuffix, profile: profile, game: game))
                    }
                }
            }
        }

        if previous < 19 {
            for game in FalloutGame.allCases {
                for control in TouchControl.allCases {
                    defaults.removeObject(forKey: key(control, xSuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, ySuffix, profile: .full, game: game))
                }
            }
        }

        if previous < 20 {
            for game in FalloutGame.allCases {
                for control in TouchControl.allCases {
                    defaults.removeObject(forKey: key(control, xSuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, ySuffix, profile: .full, game: game))
                }
                defaults.removeObject(forKey: key(.tray, sideSuffix, profile: .full, game: game))
            }
        }

        if previous < 21 {
            for game in FalloutGame.allCases {
                for control in TouchControl.allCases {
                    defaults.removeObject(forKey: key(control, xSuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, ySuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, scaleSuffix, profile: .full, game: game))
                }
                defaults.removeObject(forKey: key(.tray, sideSuffix, profile: .full, game: game))
            }
        }

        if previous < 22 {
            for game in FalloutGame.allCases {
                for control in TouchControl.allCases {
                    defaults.removeObject(forKey: key(control, xSuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, ySuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, scaleSuffix, profile: .full, game: game))
                }
                defaults.removeObject(forKey: key(.tray, sideSuffix, profile: .full, game: game))
            }
        }

        if previous < 23 {
            for game in FalloutGame.allCases {
                for control in TouchControl.allCases {
                    defaults.removeObject(forKey: key(control, xSuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, ySuffix, profile: .full, game: game))
                    defaults.removeObject(forKey: key(control, scaleSuffix, profile: .full, game: game))
                }
                defaults.removeObject(forKey: key(.tray, sideSuffix, profile: .full, game: game))
            }
        }

        defaults.set(layoutVersion, forKey: layoutVersionKey)
    }

    static func center(for control: TouchControl, profile: LayoutProfile, game: FalloutGame) -> CGPoint {
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: key(control, xSuffix, profile: profile, game: game)) as? Double,
              let y = defaults.object(forKey: key(control, ySuffix, profile: profile, game: game)) as? Double else {
            return control.defaultCenter(for: profile)
        }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    static func setCenter(_ point: CGPoint, for control: TouchControl, profile: LayoutProfile, game: FalloutGame) {
        let defaults = UserDefaults.standard
        defaults.set(Double(min(max(point.x, 0), 1)), forKey: key(control, xSuffix, profile: profile, game: game))
        defaults.set(Double(min(max(point.y, 0), 1)), forKey: key(control, ySuffix, profile: profile, game: game))
    }

    static func defaultScale(for control: TouchControl, profile: LayoutProfile) -> CGFloat {
        guard profile == .full else {
            return 1.0
        }

        switch control {
        case .action:
            return 1.35
        case .skip:
            return 1.19
        case .end, .fireMode:
            return 1.21
        case .skill, .swap:
            return 1.06
        case .reload:
            return 1.07
        case .quickSave, .load, .saves:
            return 0.95
        default:
            return 1.0
        }
    }

    static func scale(for control: TouchControl, profile: LayoutProfile, game: FalloutGame) -> CGFloat {
        if let value = UserDefaults.standard.object(forKey: key(control, scaleSuffix, profile: profile, game: game)) as? Double {
            return CGFloat(min(max(value, 0.55), 2.0))
        }
        return defaultScale(for: control, profile: profile)
    }

    static func setScale(_ scale: CGFloat, for control: TouchControl, profile: LayoutProfile, game: FalloutGame) {
        UserDefaults.standard.set(Double(min(max(scale, 0.55), 2.0)), forKey: key(control, scaleSuffix, profile: profile, game: game))
    }

    static func displaySize(for control: TouchControl, in bounds: CGSize, profile: LayoutProfile, game: FalloutGame) -> CGSize {
        let defaults = UserDefaults.standard
        let name = control == .joystick ? "joystickScale" : "buttonScale"
        let global = CGFloat(defaults.object(forKey: LauncherModel.optionKey(name, for: game)) as? Double ?? 1.0)
        let base = control.defaultSize(in: bounds, profile: profile)
        let factor = max(0.55, global) * scale(for: control, profile: profile, game: game)
        return CGSize(
            width: max(22, min(bounds.width * 0.45, base.width * factor)),
            height: max(22, min(bounds.height * 0.45, base.height * factor))
        )
    }

    enum TraySide: Int {
        case right = 0
        case left = 1
    }

    static func traySide(profile: LayoutProfile, game: FalloutGame) -> TraySide {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: key(.tray, sideSuffix, profile: profile, game: game)) as? Int {
            return TraySide(rawValue: raw) ?? .right
        }
        return profile == .full ? .left : .right
    }

    static func setTraySide(_ side: TraySide, profile: LayoutProfile, game: FalloutGame) {
        UserDefaults.standard.set(side.rawValue, forKey: key(.tray, sideSuffix, profile: profile, game: game))
    }

    static func quickSaveFrame(profile: LayoutProfile, game: FalloutGame, in bounds: CGSize) -> CGRect {
        let stored = center(for: .quickSave, profile: profile, game: game)
        let size = displaySize(for: .quickSave, in: bounds, profile: profile, game: game)
        return CGRect(x: stored.x * bounds.width - size.width / 2,
                      y: stored.y * bounds.height - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    static func centerPoint(for control: TouchControl, profile: LayoutProfile, game: FalloutGame, in bounds: CGSize) -> CGPoint {
        if control == .tray {
            let quick = quickSaveFrame(profile: profile, game: game, in: bounds)
            let traySize = displaySize(for: .tray, in: bounds, profile: profile, game: game)
            let trayX = traySide(profile: profile, game: game) == .left
                ? quick.minX - traySize.width / 2
                : quick.maxX + traySize.width / 2
            return CGPoint(x: trayX, y: quick.midY)
        }

        let stored = center(for: control, profile: profile, game: game)
        return CGPoint(x: stored.x * bounds.width, y: stored.y * bounds.height)
    }

    static func reset(profile: LayoutProfile, game: FalloutGame) {
        let defaults = UserDefaults.standard
        for control in TouchControl.controls(for: game) {
            defaults.removeObject(forKey: key(control, xSuffix, profile: profile, game: game))
            defaults.removeObject(forKey: key(control, ySuffix, profile: profile, game: game))
            defaults.removeObject(forKey: key(control, scaleSuffix, profile: profile, game: game))
            defaults.removeObject(forKey: key(control, sideSuffix, profile: profile, game: game))
        }
    }

    static func allCenters(profile: LayoutProfile, game: FalloutGame) -> [TouchControl: CGPoint] {
        var centers: [TouchControl: CGPoint] = [:]
        for control in TouchControl.controls(for: game) {
            centers[control] = center(for: control, profile: profile, game: game)
        }
        return centers
    }

    static func allScales(profile: LayoutProfile, game: FalloutGame) -> [TouchControl: CGFloat] {
        var scales: [TouchControl: CGFloat] = [:]
        for control in TouchControl.controls(for: game) {
            scales[control] = scale(for: control, profile: profile, game: game)
        }
        return scales
    }
}

enum ScreenMode: Int {
    case game = 0
    case inventory = 1
    case loot = 2
    case barter = 3
    case dialogue = 4
    case character = 5
    case pipboy = 6
    case skilldex = 7
    case automap = 8
    case worldmap = 9
    case options = 10
    case saves = 11

    /// The panel that picks the item to use something on: drawn like the
    /// inventory, but the touch layer keeps the trackpad there.
    case useOn = 12

    case pickAmount = 13

    /// The called shot panel drawn over the game view; it is a menu for the
    /// overlay's purposes, so the HUD steps aside and only BACK stays.
    case calledShot = 14

    case death = 15

    case menu = 16

    var isMenu: Bool {
        return self != .game
    }

    var listsItems: Bool {
        switch self {
        case .inventory, .loot, .barter:
            return true
        default:
            return false
        }
    }
}

final class GameControlsOverlay: UIView {
    /// The overlay is a subview of the engine's own window, exactly like the
    /// original single-engine build. A separate window above SDL looks the same
    /// but stops the engine from receiving touches in the empty area, which
    /// kills the trackpad cursor: Fallout 1 turns SDL finger events into mouse
    /// movement in touch.cc/mouse.cc. Being a sibling above SDL's view keeps
    /// the buttons working while touches outside them fall through to the game.
    private static let overlayTag = 0xF0110
    private static var windowObserver: NSObjectProtocol?
    private static var windowRetryTimer: Timer?
    private static var overlayClock: Timer?
    /// Keeps the overlay alive across SDL window changes.
    private static var installedOverlay: GameControlsOverlay?

    private let joystick = CameraJoystickControl()
    private let actionButton = LabeledControlButton(
        title: "ACTION",
        symbol: "hand.tap",
        iconPointSize: 18
    )
    private let backButton = LabeledControlButton(
        title: "BACK",
        symbol: "chevron.backward",
        iconPointSize: 18
    )
    private let skipButton = LabeledControlButton(
        title: "END\nTURN",
        symbol: "forward.end",
        iconPointSize: 18,
        accent: true,
        labelLines: 2
    )
    private let skillButton = LabeledControlButton(
        title: "SKILL",
        symbol: "star",
        iconPointSize: 18
    )
    private let swapButton = LabeledControlButton(
        title: "SWAP",
        symbol: "arrow.left.arrow.right",
        iconPointSize: 18
    )
    private let endButton = LabeledControlButton(
        title: "END\nCOMBAT",
        symbol: "xmark",
        iconPointSize: 18,
        labelLines: 2
    )
    private let reloadButton = LabeledControlButton(
        title: "RELOAD",
        symbol: "arrow.clockwise",
        iconPointSize: 16
    )
    private let fireModeButton = LabeledControlButton(
        title: "ATTACK\nMODE",
        symbol: "scope",
        iconPointSize: 16,
        labelLines: 2
    )
    private let savesButton = LabeledControlButton(
        title: "SAVE",
        symbol: "tray.full",
        iconPointSize: 16
    )
    private let loadButton = LabeledControlButton(
        title: "LOAD",
        symbol: "tray.and.arrow.down",
        iconPointSize: 16
    )
    private let quickSaveButton = LabeledControlButton(
        title: "QUICK\nSAVE",
        symbol: "bolt.fill",
        iconPointSize: 17,
        labelLines: 2,
        layout: .horizontal
    )
    private let trayButton = LabeledControlButton(
        title: "",
        symbol: "chevron.right",
        iconPointSize: 15
    )
    private let saveAssembly = VaultPanelView()
    private let saveDivider = UIView()
    private let pipButton = LabeledControlButton(
        title: "PIP",
        symbol: "book.closed",
        iconPointSize: 14
    )
    private let movieShield = UIView()
    private let skipMovieButton = MovieSkipButton()
    private let lookButton = LabeledControlButton(
        title: "INSPECT",
        symbol: "eye",
        iconPointSize: 16
    )
    private let helpButton = LabeledControlButton(
        title: "",
        symbol: "info",
        iconPointSize: 22
    )
    private let barterButton = LabeledControlButton(
        title: "",
        symbol: "dollarsign.circle",
        iconPointSize: 18
    )
    private let tellAboutButton = LabeledControlButton(
        title: "",
        symbol: "bubble.left",
        iconPointSize: 18
    )
    private let offerButton = LabeledControlButton(
        title: "HOLD OFFER",
        symbol: "arrow.left.arrow.right.circle",
        iconPointSize: 16,
        labelLines: 2
    )
    private let talkButton = LabeledControlButton(
        title: "TALK",
        symbol: "bubble.right",
        iconPointSize: 16
    )
    private var menuRectCache: CGRect?
    private var menuRectScreen: ScreenMode = .game
    private let quickSaveNotice = UIView()
    private let quickSaveNoticeLabel = UILabel()
    private var quickSaveNoticeTimer: Timer?
    private var keyboardIsUp = false
    private var pushedUp: CGFloat = 0
    private var keyboardTap: UITapGestureRecognizer?
    private var keyboardSwipe: UISwipeGestureRecognizer?
    private let helpBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let helpCard = InventoryHelpCard()
    private var currentScreen: ScreenMode = .game
    private let game = ControlLayout.activeGame()
    private var sideButtons: [LabeledControlButton] = []
    private var cursorModeIcon: String?
    private var cursorModeTitle: String?
    private var fireModeValue: Int32 = -2
    private var wasInCombat = false
    private var startCombatShown = false
    private var skipPressedAt: Date?
    private var inspectOn = false
    private var movieWasPlaying = false
    private var lastCursorMode: Int32 = -1
    private var lastModeRequests: Int32 = 0
    private var keepTargeting = false
    private var quickSaveSerial: Int32 = -1
    private var trayOpen = false

    /// Refreshes the overlay that is on screen, if there is one. The engine
    /// calls this from its own input loop, on the main thread between frames,
    /// which is why nothing here may change the view hierarchy: it only asks
    /// the game what the controls can do and updates them.
    static func refreshInstalled() {
        installedOverlay?.refreshControls()
    }

    static func autoSaveFailed() {
        installedOverlay?.showAutoSaveNotice()
    }

    static func install() {
        ControlLayout.migrateIfNeeded()

        // The engine calls this once its SDL window exists (Fallout 1's
        // svga_init does), in which case the overlay can attach immediately.
        if let window = sdlWindow() {
            attach(to: window)
        } else {
            // Fallout 2's engine does not call back after creating its window,
            // so wait for that window to appear instead of covering it with a
            // window of our own.
            observeEngineWindow()
            watchForEngineWindow()
        }

        startOverlayClock()
    }

    /// Second way of noticing SDL's window, for the case where the visibility
    /// notification is not posted or arrives before the window is usable. The
    /// run loop the engine keeps spinning is the only clock available here.
    private static func watchForEngineWindow() {
        guard windowRetryTimer == nil else {
            return
        }

        var remaining = 100
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            if let window = sdlWindow() {
                timer.invalidate()
                windowRetryTimer = nil
                attach(to: window)
                return
            }

            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                windowRetryTimer = nil
            }
        }
        windowRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// SDL's window is the only visible window at the normal level once the
    /// engine starts: the launcher sits above it and is hidden, and SDL's
    /// launch-screen window is one level above normal.
    private static func sdlWindow() -> UIWindow? {
        return UIApplication.shared.windows.first {
            !$0.isHidden && $0.windowLevel == .normal
        }
    }

    private static func observeEngineWindow() {
        guard windowObserver == nil else {
            return
        }

        // queue: nil delivers synchronously on the thread that posts the
        // notification, which is the main thread during SDL window creation.
        // A main-queue observer would only run when the run loop next spins,
        // and the engine blocks that loop for the whole session.
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let window = notification.object as? UIWindow else {
                return
            }
            guard !window.isHidden, window.windowLevel == .normal else {
                return
            }
            attach(to: window)
        }
    }

    private static func attach(to window: UIWindow) {
        windowRetryTimer?.invalidate()
        windowRetryTimer = nil

        guard window.viewWithTag(overlayTag) == nil else {
            return
        }

        let overlay = installedOverlay ?? GameControlsOverlay(frame: window.bounds)
        installedOverlay = overlay
        overlay.tag = overlayTag
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if overlay.frame != window.bounds {
            overlay.frame = window.bounds
        }
        window.addSubview(overlay)
        window.bringSubviewToFront(overlay)
        overlay.setNeedsLayout()
    }

    private static func ensureFrontmost() {
        guard let overlay = installedOverlay else {
            return
        }

        guard let window = overlay.window ?? sdlWindow() else {
            return
        }

        if overlay.superview !== window {
            attach(to: window)
        } else if window.subviews.last !== overlay {
            window.bringSubviewToFront(overlay)
        }
    }

    private static func startOverlayClock() {
        guard overlayClock == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            ensureFrontmost()
        }
        overlayClock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true

        addSubview(joystick)

        actionButton.accessibilityLabel = "Action"
        actionButton.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        addSubview(actionButton)

        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        addSubview(backButton)

        let sideActions = [
            ("MAP", "map", 1),
            ("CHA", "person", 2),
            ("INV", "bag", 0),
        ]
        for item in sideActions {
            let button = LabeledControlButton(
                title: item.0,
                symbol: item.1,
                iconPointSize: 14
            )
            button.tag = item.2
            button.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
            sideButtons.append(button)
            addSubview(button)
        }

        pipButton.tag = 3
        pipButton.accessibilityLabel = "Pip boy"
        pipButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(pipButton)

        skillButton.tag = 4
        skillButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(skillButton)

        swapButton.tag = 7
        swapButton.accessibilityLabel = "Swap weapon"
        swapButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(swapButton)

        endButton.tag = 5
        endButton.accessibilityLabel = "End combat"
        endButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(endButton)

        skipButton.tag = 6
        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(skipButton)

        reloadButton.tag = 8
        reloadButton.accessibilityLabel = "Reload weapon"
        reloadButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(reloadButton)

        fireModeButton.tag = 9
        fireModeButton.accessibilityLabel = "Change fire mode"
        fireModeButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(fireModeButton)

        savesButton.tag = 10
        savesButton.accessibilityLabel = "Saves"
        savesButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(savesButton)

        loadButton.tag = 11
        loadButton.accessibilityLabel = "Load"
        loadButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(loadButton)

        // The engine's own quick save, with a tick for confirmation when it has
        // been asked for. QUICK SAVE and the chevron share one plate, drawn
        // under both, so the pair reads as one control with a divider.
        saveAssembly.isHidden = true
        saveAssembly.fill = ControlTheme.panel
        saveAssembly.edge = ControlTheme.border
        saveAssembly.lineWidth = 1.25
        saveAssembly.innerEdge = ControlTheme.innerEdge
        saveAssembly.innerInset = 2
        saveAssembly.shadowOpacity = 0.25
        saveAssembly.corner = 10
        addSubview(saveAssembly)

        saveDivider.isHidden = true
        saveDivider.isUserInteractionEnabled = false
        saveDivider.backgroundColor = ControlTheme.border.withAlphaComponent(0.7)
        addSubview(saveDivider)

        quickSaveButton.tag = 19
        quickSaveButton.accessibilityLabel = "Quick save"
        quickSaveButton.addTarget(self, action: #selector(quickSavePressed), for: .touchUpInside)
        quickSaveButton.drawsOwnPlate = false
        addSubview(quickSaveButton)

        // The chevron beside QUICK SAVE opens the tray that holds LOAD and
        // SAVE, which stay out of the way until they are asked for.
        trayButton.accessibilityLabel = "Save options"
        trayButton.addTarget(self, action: #selector(trayPressed), for: .touchUpInside)
        trayButton.drawsOwnPlate = false
        addSubview(trayButton)

        quickSaveNotice.isHidden = true
        quickSaveNotice.backgroundColor = VaultUI.controlFill.withAlphaComponent(0.92)
        quickSaveNotice.layer.cornerRadius = 9
        quickSaveNotice.layer.borderWidth = 1.5
        quickSaveNotice.layer.borderColor = ControlTheme.border.cgColor
        quickSaveNotice.isUserInteractionEnabled = false
        addSubview(quickSaveNotice)

        quickSaveNoticeLabel.font = VaultUI.label(10, weight: .semibold)
        quickSaveNoticeLabel.textColor = VaultUI.controlContent
        quickSaveNoticeLabel.numberOfLines = 2
        quickSaveNoticeLabel.textAlignment = .center
        quickSaveNoticeLabel.adjustsFontSizeToFitWidth = true
        quickSaveNoticeLabel.minimumScaleFactor = 0.7
        quickSaveNoticeLabel.isUserInteractionEnabled = false
        quickSaveNotice.addSubview(quickSaveNoticeLabel)

        movieShield.isHidden = true
        addSubview(movieShield)

        lookButton.isHidden = true
        lookButton.accessibilityLabel = "Inspect"
        lookButton.addTarget(self, action: #selector(lookPressed), for: .touchUpInside)
        addSubview(lookButton)

        barterButton.isHidden = true
        barterButton.tag = 20
        barterButton.accessibilityLabel = "Barter"
        barterButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(barterButton)

        tellAboutButton.isHidden = true
        tellAboutButton.tag = 22
        tellAboutButton.accessibilityLabel = "Tell me about"
        tellAboutButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(tellAboutButton)

        offerButton.isHidden = true
        offerButton.accessibilityLabel = "Offer"
        offerButton.backgroundOpacity = 0.9
        offerButton.onHold = { [weak self] in
            fallout_ios_press_action(23)
            self?.refreshControls()
            self?.successFeedback()
        }
        addSubview(offerButton)

        talkButton.isHidden = true
        talkButton.tag = 24
        talkButton.accessibilityLabel = "Talk"
        talkButton.backgroundOpacity = 0.9
        talkButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(talkButton)

        keyboardIsUp = false

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillShow),
                                               name: UIResponder.keyboardWillShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)

        // The help button is the same square as INSPECT, in the same panel, so
        // the two read as one column against the menu's edge.
        helpButton.isHidden = true
        helpButton.accessibilityLabel = "Inventory help"
        helpButton.addTarget(self, action: #selector(helpPressed), for: .touchUpInside)
        addSubview(helpButton)

        helpBackdrop.isHidden = true
        helpBackdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissHelp)))
        addSubview(helpBackdrop)

        helpCard.isHidden = true
        updateHelpText(for: .inventory)
        helpCard.onClose = { [weak self] in
            self?.setHelp(visible: false)
        }
        addSubview(helpCard)

        skipMovieButton.isHidden = true
        skipMovieButton.onTrigger = { [weak self] in
            // Asked again here and not trusted: the overlay is not refreshed
            // while the engine is busy, so this button can still be on screen
            // after the movie ended - and ESC in the main menu is the key that
            // closes the game.
            if fallout_ios_movie_state() != 0 {
                fallout_ios_back()
            }
            self?.hideMovieControls()
        }
        addSubview(skipMovieButton)

        refreshControls()
        // No timer. The overlay used to poll the engine every half second to
        // learn what it could do (cursor mode, attack mode, reload, skip), from
        // an NSTimer running inside the engine's own loop - and a crash report
        // shows exactly that: __NSFireTimer on the main thread, a few frames of
        // ours, then a read through a null pointer. The engine is asked only
        // when the player actually presses something now.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let profile = ControlLayout.profileForCurrentResolution()

        place(joystick, at: .joystick, profile: profile, size: scaledSize(for: .joystick, in: bounds.size, profile: profile))
        place(backButton, at: .back, profile: profile, size: scaledSize(for: .back, in: bounds.size, profile: profile))
        place(pipButton, at: .pip, profile: profile, size: scaledSize(for: .pip, in: bounds.size, profile: profile))
        place(actionButton, at: .action, profile: profile, size: scaledSize(for: .action, in: bounds.size, profile: profile))
        place(skipButton, at: .skip, profile: profile, size: scaledSize(for: .skip, in: bounds.size, profile: profile))

        let row = TouchControl.bottomRow(for: profile)
        for (index, control) in row.enumerated() where index < sideButtons.count {
            place(sideButtons[index], at: control, profile: profile,
                  size: scaledSize(for: control, in: bounds.size, profile: profile))
        }

        place(skillButton, at: .skill, profile: profile, size: scaledSize(for: .skill, in: bounds.size, profile: profile))
        place(swapButton, at: .swap, profile: profile, size: scaledSize(for: .swap, in: bounds.size, profile: profile))
        place(endButton, at: .end, profile: profile, size: scaledSize(for: .end, in: bounds.size, profile: profile))

        place(reloadButton, at: .reload, profile: profile, size: scaledSize(for: .reload, in: bounds.size, profile: profile))
        place(fireModeButton, at: .fireMode, profile: profile, size: scaledSize(for: .fireMode, in: bounds.size, profile: profile))

        place(savesButton, at: .saves, profile: profile, size: scaledSize(for: .saves, in: bounds.size, profile: profile))
        place(loadButton, at: .load, profile: profile, size: scaledSize(for: .load, in: bounds.size, profile: profile))
        place(quickSaveButton, at: .quickSave, profile: profile, size: scaledSize(for: .quickSave, in: bounds.size, profile: profile))
        place(trayButton, at: .tray, profile: profile, size: scaledSize(for: .tray, in: bounds.size, profile: profile))
        placeSaveAssembly()

        if trayButton.glyphName != traySymbol {
            trayButton.set(symbol: traySymbol, title: "",
                           accessibilityLabel: trayOpen ? "Close the save tray" : "Open the save tray")
        }

        let unit = TouchControl.sizeUnit(in: bounds.size)

        if !quickSaveNotice.isHidden {
            let noticeWidth = min(220 * unit, bounds.width * 0.32)
            quickSaveNotice.frame = CGRect(x: quickSaveButton.frame.minX,
                                           y: quickSaveButton.frame.maxY + 6 * unit,
                                           width: max(120 * unit, noticeWidth),
                                           height: 42 * unit)
            quickSaveNoticeLabel.frame = quickSaveNotice.bounds.insetBy(dx: 8 * unit, dy: 4 * unit)
        }

        movieShield.frame = bounds
        helpBackdrop.frame = bounds

        if currentScreen.isMenu {
            layoutMenuControls()
        }

        if !helpCard.isHidden {
            layoutHelpCard()
        }

        let skipWidth = 120 * unit
        let skipHeight = 40 * unit
        skipMovieButton.frame = CGRect(x: bounds.width - skipWidth - 44 * unit,
                                       y: bounds.height - skipHeight - 58 * unit,
                                       width: skipWidth,
                                       height: skipHeight)
    }

    private func layoutMenuControls() {
        let panel = menuRectCache ?? engineMenuRect()
        let surface = gameSurface()
        let box = panel.map(gameRect) ?? menuBox(for: currentScreen)

        let gap: CGFloat = 6
        let side = min(max(48, surface.height * 0.17), 84)

        if currentScreen == .skilldex, let panel = panel {
            // The skill panel's own CANCEL button sits at 48,338 in the panel's
            // own pixels. BACK is centred on the panel's bottom strip, dark
            // enough to hide it, so the panel does not offer the same way out
            // twice.
            let width = min(152, panel.width - 30)
            backButton.solidBackground = true
            backButton.frame = gameRect(CGRect(x: panel.midX - width / 2 + 2, y: panel.minY + 332,
                                               width: max(96, width), height: 34))
            return
        }
        backButton.solidBackground = false

        let clampLeft = max(10, safeAreaInsets.left + 6)
        let clampRight = bounds.width - max(10, safeAreaInsets.right + 6) - side
        let clampTop = max(10, safeAreaInsets.top + 6)
        let clampBottom = bounds.height - max(10, safeAreaInsets.bottom + 6)

        if currentScreen == .dialogue {
            placeDialogueButtons(in: box)
            return
        }

        if currentScreen == .barter {
            placeBarterControls(in: menuBox(for: .barter), gap: gap, side: side)
            return
        }

        let middle = min(max(box.midY, side / 2 + clampTop), clampBottom - side / 2)

        var leftColumn: [UIView] = [backButton]
        if !offerButton.isHidden {
            leftColumn.append(offerButton)
        }
        let leftHeight = CGFloat(leftColumn.count) * side + CGFloat(leftColumn.count - 1) * gap
        var leftY = min(max(clampTop, middle - leftHeight / 2), max(clampTop, clampBottom - leftHeight))
        let leftX = min(max(box.minX - gap - side, clampLeft), clampRight)
        for view in leftColumn {
            view.frame = CGRect(x: leftX, y: leftY, width: side, height: side)
            leftY += side + gap
        }

        let rightX = max(min(box.maxX + gap, clampRight), clampLeft)
        var column: [UIView] = []
        if !lookButton.isHidden {
            column.append(lookButton)
        }
        if !talkButton.isHidden {
            column.append(talkButton)
        }
        let stackHeight = CGFloat(column.count) * side + CGFloat(max(0, column.count - 1)) * gap
        var y = max(clampTop, middle - stackHeight / 2)
        for view in column {
            view.frame = CGRect(x: rightX, y: y, width: side, height: side)
            y += side + gap
        }

        let helpSide = max(26, min(38, side * 0.5))
        helpButton.frame = clampFrame(CGRect(x: rightX, y: max(clampTop, box.minY + 4),
                                             width: helpSide, height: helpSide))
        helpButton.layer.cornerRadius = max(6, helpSide * 0.20)
    }

    private func placeSaveAssembly() {
        let quick = quickSaveButton.frame
        let tray = trayButton.frame
        let height = max(quick.height, tray.height)
        let top = min(quick.minY, tray.minY)
        let left = min(quick.minX, tray.minX)
        let right = max(quick.maxX, tray.maxX)
        saveAssembly.frame = CGRect(x: left, y: top, width: right - left, height: height)
        saveAssembly.corner = max(6, min(min(18, height * 0.20), (right - left) * 0.28))

        let dividerX = tray.midX > quick.midX ? tray.minX - 0.5 : tray.maxX - 0.5
        let dividerHeight = height * 0.62
        saveDivider.frame = CGRect(x: dividerX,
                                   y: saveAssembly.frame.midY - dividerHeight / 2,
                                   width: 1,
                                   height: dividerHeight)
    }

    private func placeBarterControls(in table: CGRect, gap: CGFloat, side: CGFloat) {
        let small = max(34, side * 0.72)
        let middle = table.midY + 6
        let bottom = bounds.height - small - 7

        let offerX = table.minX - gap - small
        let backX = offerX - gap - side
        let innerX = table.maxX + gap
        let outerX = innerX + small + gap

        backButton.frame = clampFrame(CGRect(x: backX, y: middle - side / 2, width: side, height: side))
        offerButton.frame = clampFrame(CGRect(x: offerX + 2, y: bottom + 2, width: small, height: small))
        talkButton.frame = clampFrame(CGRect(x: innerX - 2, y: bottom + 2, width: small, height: small))
        lookButton.frame = clampFrame(CGRect(x: outerX, y: middle - side / 2, width: side, height: side))

        let helpSide = max(26, min(38, side * 0.5))
        helpButton.frame = clampFrame(CGRect(x: outerX, y: max(8, table.minY + 4),
                                             width: helpSide, height: helpSide))
        helpButton.layer.cornerRadius = max(6, helpSide * 0.20)
    }

    private func clampFrame(_ frame: CGRect) -> CGRect {
        let x = min(max(frame.minX, 8), max(8, bounds.width - frame.width - 8))
        let y = min(max(frame.minY, 8), max(8, bounds.height - frame.height - 8))
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func placeDialogueButtons(in box: CGRect) {
        let unit = gameRect(CGRect(x: 0, y: 0, width: 1, height: 1)).width
        let barterSlot = actionButtonRect(20) ?? CGRect(x: box.minX + 593 * unit,
                                                       y: box.minY + 41 * unit,
                                                       width: 14 * unit,
                                                       height: 14 * unit)
        let aboutSlot = actionButtonRect(22) ?? CGRect(x: box.minX + 593 * unit,
                                                       y: box.minY + 116 * unit,
                                                       width: 14 * unit,
                                                       height: 14 * unit)

        var side = max(30, barterSlot.height + 20)
        let span = abs(aboutSlot.midY - barterSlot.midY)
        if span > 1 {
            side = min(side, span - 6)
        }
        side = max(24, min(side, 44))

        barterButton.solidBackground = true
        tellAboutButton.solidBackground = true
        place(barterButton, on: barterSlot, side: side, extraWidth: 6)
        place(tellAboutButton, on: aboutSlot, side: side, extraWidth: 6)
    }

    private func place(_ button: UIView, on slot: CGRect, side: CGFloat, extraWidth: CGFloat = 0) {
        let width = side + extraWidth
        let x = min(max(slot.midX - width / 2, 8), bounds.width - width - 8)
        let y = min(max(slot.midY - side / 2, 8), bounds.height - side - 8)
        button.frame = CGRect(x: x, y: y, width: width, height: side)
    }

    private func actionButtonRect(_ action: Int32) -> CGRect? {
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0

        guard fallout_ios_action_button_rect(action, &x, &y, &width, &height) != 0,
              width > 1, height > 1 else {
            return nil
        }

        return gameRect(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
    }

    private func updateHelpText(for screen: ScreenMode) {
        if screen == .barter {
            helpCard.text = L.t("Drag an item onto the table to offer it.")
                + "\n\n"
                + L.t("Hold OFFER to make the trade.")
                + "\n\n"
                + L.t("TALK goes back to the conversation.")
                + "\n\n"
                + L.t("Drag your finger to scroll the inventory.")
            return
        }

        helpCard.text = L.t("Hold and drag an item to equip or move it.")
            + "\n\n"
            + L.t("Tap an item while INSPECT is toggled on to see its characteristics.")
            + "\n\n"
            + L.t("Hold an item with INSPECT on to open its extra actions: use, look, unload and drop.")
            + "\n\n"
            + L.t("Drag your finger to scroll the inventory.")
    }

    private func layoutHelpCard() {
        let width = min(bounds.width - 60, 520)
        let size = helpCard.preferredSize(maxWidth: width)
        helpCard.frame = CGRect(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2,
                                width: size.width,
                                height: size.height)
    }

    /// The panel the engine says is on screen, in game pixels.
    private func engineMenuRect() -> CGRect? {
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0

        guard fallout_ios_menu_rect(&x, &y, &width, &height) != 0, width > 1, height > 1 else {
            return nil
        }

        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    /// A rectangle in game pixels, drawn where the engine draws its screen on
    /// this display.
    private func gameRect(_ rect: CGRect) -> CGRect {
        let surface = gameSurface()
        let defaults = UserDefaults.standard
        let width = CGFloat(defaults.object(forKey: LauncherModel.optionKey("width", for: game)) as? Int ?? 640)
        let height = CGFloat(defaults.object(forKey: LauncherModel.optionKey("height", for: game)) as? Int ?? 480)
        guard width > 1, height > 1 else {
            return surface
        }

        let scale = surface.width / width
        return CGRect(x: surface.minX + rect.minX * scale,
                      y: surface.minY + rect.minY * scale,
                      width: rect.width * scale,
                      height: rect.height * scale)
    }

    private func menuBox(for screen: ScreenMode) -> CGRect {
        let surface = gameSurface()
        let defaults = UserDefaults.standard
        let width = CGFloat(defaults.object(forKey: LauncherModel.optionKey("width", for: game)) as? Int ?? 0)
        let height = CGFloat(defaults.object(forKey: LauncherModel.optionKey("height", for: game)) as? Int ?? 0)
        guard width > 1, height > 1 else {
            return surface
        }

        let design = menuDesignBox(for: screen)
        let scale = surface.width / width
        let originX = surface.minX + (width - 640) / 2 * scale
        let originY = surface.minY + (height - 480) / 2 * scale
        return CGRect(x: originX + design.minX * scale,
                      y: originY + design.minY * scale,
                      width: design.width * scale,
                      height: design.height * scale)
    }

    private func menuDesignBox(for screen: ScreenMode) -> CGRect {
        switch screen {
        case .inventory:
            return CGRect(x: 80, y: 0, width: 499, height: 377)
        case .loot:
            return CGRect(x: 80, y: 0, width: 537, height: 376)
        case .barter:
            return CGRect(x: 80, y: 290, width: 480, height: 180)
        case .automap:
            return CGRect(x: 60, y: 0, width: 519, height: 480)
        case .dialogue:
            return CGRect(x: 127, y: 225, width: 393, height: 227)
        default:
            return CGRect(x: 0, y: 0, width: 640, height: 480)
        }
    }

    /// A rectangle in the game's own 640x480 design space, drawn where the
    /// engine draws that space on this display.
    private func designRect(_ design: CGRect) -> CGRect {
        let surface = gameSurface()
        let scale = surface.width / 640
        return CGRect(x: surface.minX + design.minX * scale,
                      y: surface.minY + design.minY * scale,
                      width: design.width * scale,
                      height: design.height * scale)
    }

    private func gameSurface() -> CGRect {
        let defaults = UserDefaults.standard
        let width = CGFloat(defaults.object(forKey: LauncherModel.optionKey("width", for: game)) as? Int ?? 0)
        let height = CGFloat(defaults.object(forKey: LauncherModel.optionKey("height", for: game)) as? Int ?? 0)
        guard width > 1, height > 1 else {
            return bounds
        }

        let scale = min(bounds.width / width, bounds.height / height)
        let shown = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (bounds.width - shown.width) / 2,
                      y: (bounds.height - shown.height) / 2,
                      width: shown.width,
                      height: shown.height)
    }

    private func scaledSize(for control: TouchControl, in bounds: CGSize, profile: LayoutProfile) -> CGSize {
        return ControlLayout.displaySize(for: control, in: bounds, profile: profile, game: game)
    }

    private func place(_ view: UIView, at control: TouchControl, profile: LayoutProfile, size: CGSize) {
        let point = ControlLayout.centerPoint(for: control, profile: profile, game: game, in: bounds.size)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        // The whole screen, sensor housing included: the controls belong on its
        // edges, and pulling them inside the safe-area insets squeezed the side
        // columns into each other on a notched phone.
        let x: CGFloat
        let y: CGFloat
        if control == .tray {
            x = point.x
            y = point.y
        } else {
            x = min(max(point.x, halfWidth), bounds.width - halfWidth)
            y = min(max(point.y, halfHeight), bounds.height - halfHeight)
        }
        view.frame = CGRect(x: x - halfWidth, y: y - halfHeight, width: size.width, height: size.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Empty parts of the overlay must not eat touches intended for SDL.
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.frame.contains(point) {
                return true
            }
        }
        return false
    }

    @objc private func primaryAction() {
        // USE SKILL is a mode of its own that the game's own cycle does not
        // leave, so the button puts the game back into movement, or into combat
        // targeting while a fight is on.
        if currentScreen == .game && fallout_ios_cursor_mode() == 3 {
            fallout_ios_press_action(fallout_ios_action_available(5) != 0 ? 12 : 13)
        } else {
            fallout_ios_right_click()
        }
        refreshControls()
        selectionFeedback()
    }

    @objc private func goBack() {
        fallout_ios_back()
        refreshControls()
        impactFeedback()
    }

    @objc private func sideActionPressed(_ sender: LabeledControlButton) {
        fallout_ios_press_action(Int32(sender.tag))
        if sender.tag == 6 {
            skipPressedAt = Date()
        }
        if sender === loadButton || sender === savesButton {
            setTray(open: false)
        }
        refreshControls()
        selectionFeedback()
    }

    /// The chevron beside QUICK SAVE. Tapping it slides LOAD and SAVE out of the
    /// tray, and tapping it again puts them away; the button keeps QUICK SAVE
    /// as its neighbour and never moves.
    @objc private func trayPressed() {
        setTray(open: !trayOpen)
        selectionFeedback()
    }

    private func setTray(open: Bool) {
        let wasOpen = trayOpen
        trayOpen = open
        trayButton.set(symbol: traySymbol,
                       title: "",
                       accessibilityLabel: open ? "Close the save tray" : "Open the save tray")

        let views: [UIView] = [loadButton, savesButton]
        for view in views {
            view.layer.removeAllAnimations()
            view.alpha = 1
            view.transform = .identity
            view.isHidden = !open
        }

        guard open, !wasOpen, !UIAccessibility.isReduceMotionEnabled else {
            return
        }

        for view in views {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: -12, y: 0)
                .scaledBy(x: 0.9, y: 0.9)
        }
        UIView.animate(withDuration: 0.20,
                       delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut]) {
            for view in views {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    @objc private func quickSavePressed() {
        let result = fallout_ios_quick_save()

        if result == -2 {
            // The engine cannot report a result: ask it the old way and claim
            // nothing.
            fallout_ios_press_action(19)
            selectionFeedback()
            return
        }

        // The count has moved because of this press, so the refresh must not
        // show the same save twice.
        quickSaveSerial = fallout_ios_quick_save_serial()
        showQuickSaveResult(saved: result == 1)
    }

    // The tick means the game was really written, the cross means it was not.
    // Nothing in between, whether a finger or the launcher's own clock asked.
    private func showQuickSaveResult(saved: Bool) {
        quickSaveNotice.isHidden = true
        quickSaveButton.set(symbol: saved ? "checkmark" : "xmark",
                            title: "QUICK\nSAVE",
                            accessibilityLabel: saved ? "Saved" : "Save failed")
        if saveHaptics {
            UINotificationFeedbackGenerator().notificationOccurred(saved ? .success : .error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.quickSaveButton.set(symbol: "bolt.fill", title: "QUICK\nSAVE",
                                      accessibilityLabel: "Quick save")
        }
    }

    private var saveHaptics: Bool {
        let key = LauncherModel.optionKey("saveHaptics", for: game)
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private var buttonHaptics: Bool {
        let key = LauncherModel.optionKey("buttonHaptics", for: game)
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func selectionFeedback() {
        if buttonHaptics {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func impactFeedback() {
        if buttonHaptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func successFeedback() {
        if buttonHaptics {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private var traySymbol: String {
        let onLeft = ControlLayout.traySide(profile: ControlLayout.profileForCurrentResolution(), game: game) == .left
        if trayOpen {
            return onLeft ? "chevron.right" : "chevron.left"
        }
        return onLeft ? "chevron.left" : "chevron.right"
    }

    private func showAutoSaveNotice() {
        quickSaveNoticeLabel.text = L.t("Auto save found no free slot.")
            + "\n"
            + L.t("Clear one in SAVES.")
        quickSaveNotice.isHidden = false
        setNeedsLayout()
        quickSaveNoticeTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            self?.quickSaveNotice.isHidden = true
        }
        quickSaveNoticeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func lookPressed() {
        fallout_ios_press_action(16)
        // The game keeps this mode to itself, so the button carries it, and a
        // wash shows when the inventory is in look mode. The engine is told as
        // well: in look mode a touch clicks an item instead of dragging it, and
        // that click is what shows the item's description.
        inspectOn.toggle()
        fallout_ios_press_action(inspectOn ? 17 : 18)
        lookButton.showsSelection = inspectOn
        selectionFeedback()
    }

    @objc private func helpPressed() {
        setHelp(visible: helpCard.isHidden)
        selectionFeedback()
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        keyboardIsUp = true

        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let height = frame?.height ?? 0

        if keyboardTap == nil, let window = self.window ?? GameControlsOverlay.sdlWindow() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(keyboardDismissRequested))
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap)
            keyboardTap = tap

            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(keyboardDismissRequested))
            swipe.direction = .down
            swipe.cancelsTouchesInView = false
            window.addGestureRecognizer(swipe)
            keyboardSwipe = swipe
        }

        if currentScreen == .dialogue {
            pushGameUp(by: height)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardIsUp = false

        if let tap = keyboardTap {
            tap.view?.removeGestureRecognizer(tap)
            keyboardTap = nil
        }
        if let swipe = keyboardSwipe {
            swipe.view?.removeGestureRecognizer(swipe)
            keyboardSwipe = nil
        }

        pushGameUp(by: 0)
    }

    @objc private func keyboardDismissRequested() {
        fallout_ios_hide_keyboard()
    }

    private func pushGameUp(by keyboardHeight: CGFloat) {
        let surface = gameSurface()
        let keyboardTop = bounds.height - keyboardHeight
        let needed = keyboardHeight > 0 ? max(0, surface.maxY - keyboardTop + 12) : 0
        let shift = needed
        guard abs(shift - pushedUp) > 0.5 else {
            return
        }

        pushedUp = shift
        fallout_ios_present_shift(Double(shift))
        refreshControls()
        setNeedsLayout()
    }

    @objc private func dismissHelp() {
        setHelp(visible: false)
    }

    private func setHelp(visible: Bool) {
        helpCard.isHidden = !visible
        helpBackdrop.isHidden = !visible
        if visible {
            setNeedsLayout()
        }
    }

    /// Laying a finger on the screen is the other moment the controls are
    /// refreshed: the player is about to act, so what is on offer is looked up
    /// then, and never from a clock running inside the engine's loop.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        refreshControls()
        super.touchesBegan(touches, with: event)
    }

    /// Pushes the player's opacity setting into every control. Buttons combine
    /// it with their enabled state themselves.
    private func applyControlOpacity(_ value: CGFloat) {
        joystick.controlOpacity = value
        actionButton.controlOpacity = value
        backButton.controlOpacity = value
        pipButton.controlOpacity = value
        skipButton.controlOpacity = value
        skillButton.controlOpacity = value
        swapButton.controlOpacity = value
        endButton.controlOpacity = value
        reloadButton.controlOpacity = value
        fireModeButton.controlOpacity = value
        savesButton.controlOpacity = value
        loadButton.controlOpacity = value
        quickSaveButton.controlOpacity = value
        trayButton.controlOpacity = value
        lookButton.controlOpacity = value
        barterButton.controlOpacity = value
        tellAboutButton.controlOpacity = value
        offerButton.controlOpacity = value
        talkButton.controlOpacity = value
        for button in sideButtons {
            button.controlOpacity = value
        }
    }

    private func refreshControls() {
        // No view hierarchy work here, deliberately. This runs from the engine's
        // own loop; attaching, resizing or reordering views there is what used
        // to end in a crash. Attaching is the engine window watcher's job.
        applyControlOpacity(ControlLayout.controlsOpacity())

        var controls: [UIView] = [joystick, actionButton, backButton, pipButton, skipButton, skillButton, swapButton, endButton, reloadButton, fireModeButton, savesButton, loadButton, quickSaveButton, trayButton, saveAssembly, saveDivider]
        controls.append(contentsOf: sideButtons as [UIView])

        if keyboardIsUp {
            for control in controls {
                control.isHidden = true
            }
            helpCard.isHidden = true
            helpBackdrop.isHidden = true
            CATransaction.flush()
            return
        }

        let movie = fallout_ios_movie_state()
        skipMovieButton.isHidden = movie == 0
        skipMovieButton.requiresHold = movie != 1
        skipMovieButton.holdSeconds = movie == 3 ? 1 : 2
        movieShield.isHidden = movie == 0
        if movie != 0 {
            movieWasPlaying = true
            for control in controls {
                control.isHidden = true
            }
            lookButton.isHidden = true
            helpButton.isHidden = true
            barterButton.isHidden = true
            tellAboutButton.isHidden = true
            offerButton.isHidden = true
            talkButton.isHidden = true
            helpCard.isHidden = true
            helpBackdrop.isHidden = true
            quickSaveNotice.isHidden = true
            if isHidden {
                isHidden = false
            }
            // The engine usually blocks on the loading screen that follows a
            // movie, and UIKit would only commit these hides once it gets the
            // run loop back - long after that screen is drawn. Flushing sends
            // them to the screen now.
            CATransaction.flush()
            return
        }

        if movieWasPlaying {
            movieWasPlaying = false
            // What follows a movie is usually a loading screen the engine draws
            // without handing the run loop back for a while, so the controls
            // that just went away are sent to the screen now.
            CATransaction.flush()
        }

        for control in controls {
            control.isHidden = false
        }

        // LOAD and SAVE only exist while the tray beside QUICK SAVE is open.
        loadButton.isHidden = !trayOpen
        savesButton.isHidden = !trayOpen

        let screen = ScreenMode(rawValue: Int(fallout_ios_screen())) ?? .game
        if screen != currentScreen {
            currentScreen = screen
            setTray(open: false)
            if inspectOn {
                inspectOn = false
                fallout_ios_press_action(18)
            }
            lookButton.showsSelection = false
            updateHelpText(for: screen)
            setNeedsLayout()
        }

        if screen == .death || screen == .menu {
            for control in controls {
                control.isHidden = true
            }
            lookButton.isHidden = true
            helpButton.isHidden = true
            barterButton.isHidden = true
            tellAboutButton.isHidden = true
            offerButton.isHidden = true
            talkButton.isHidden = true
            helpCard.isHidden = true
            helpBackdrop.isHidden = true
            CATransaction.flush()
            return
        }

        let itemScreen = screen.listsItems
        lookButton.isHidden = !itemScreen
        helpButton.isHidden = !itemScreen
        if !itemScreen {
            helpCard.isHidden = true
            helpBackdrop.isHidden = true
        }

        let dialogueBarter = screen == .dialogue && fallout_ios_action_available(20) != 0
        barterButton.isHidden = !dialogueBarter
        tellAboutButton.isHidden = !(screen == .dialogue && fallout_ios_action_available(22) != 0)
        let barterScreen = screen == .barter
        offerButton.isHidden = !(barterScreen && fallout_ios_action_available(23) != 0)
        talkButton.isHidden = !(barterScreen && fallout_ios_action_available(24) != 0)

        if screen.isMenu {
            if menuRectScreen != screen {
                menuRectScreen = screen
                menuRectCache = nil
            }

            if menuRectCache == nil {
                menuRectCache = engineMenuRect()
                if menuRectCache != nil {
                    setNeedsLayout()
                }
            }

            if screen == .dialogue {
                setNeedsLayout()
            }

            if !ControlLayout.touchControls() {
                helpButton.isHidden = true
                helpCard.isHidden = true
                helpBackdrop.isHidden = true
                isHidden = true
                return
            }

            // A menu already carries the game's own buttons, so the only
            // control worth keeping is the way out of it. The item screens
            // also keep INSPECT and its help beside them.
            for control in controls where control !== backButton {
                control.isHidden = true
            }
            lookButton.isHidden = !itemScreen
            helpButton.isHidden = !itemScreen

            if fallout_ios_action_available(21) == 0 {
                backButton.isHidden = true
            }

            if isHidden {
                isHidden = false
            }
            return
        }

        // With the touch controls switched off the overlay leaves the screen
        // entirely, so the game gets every touch, not only the ones that miss a
        // control.
        let shown = ControlLayout.touchControls() && fallout_ios_in_game() != 0
        if isHidden == shown {
            isHidden = !shown
        }

        let inCombat = fallout_ios_action_available(25) != 0
        if inCombat && !wasInCombat && ControlLayout.autoTarget() && fallout_ios_cursor_mode() != 2 {
            fallout_ios_press_action(12)
            keepTargeting = true
        } else if !inCombat && wasInCombat {
            fallout_ios_press_action(13)
            keepTargeting = false
        }
        wasInCombat = inCombat

        let mode = fallout_ios_cursor_mode()
        if mode != lastCursorMode {
            let requests = fallout_ios_cursor_mode_requests()
            let requested = requests != lastModeRequests
            lastModeRequests = requests
            if requested {
                keepTargeting = mode == 2
                lastCursorMode = mode
            } else if inCombat && keepTargeting && mode == 0 {
                fallout_ios_press_action(12)
                lastCursorMode = mode
            } else {
                if inCombat && mode == 2 {
                    keepTargeting = true
                }
                lastCursorMode = mode
            }
        }

        let savedSerial = fallout_ios_quick_save_serial()
        if quickSaveSerial < 0 {
            quickSaveSerial = savedSerial
        } else if savedSerial > quickSaveSerial {
            quickSaveSerial = savedSerial
            showQuickSaveResult(saved: true)
        }

        let symbol: String
        let title: String
        let accessibilityTitle: String
        switch mode {
        case 0:
            symbol = "arrow.up.and.down.and.arrow.left.and.right"
            title = "MOVE"
            accessibilityTitle = "Move cursor"
        case 2:
            symbol = "scope"
            title = "TARGET"
            accessibilityTitle = "Target"
        case 3:
            symbol = "hand.point.up.left.fill"
            title = "USE SKILL"
            accessibilityTitle = "Use skill"
        default:
            symbol = "hand.tap"
            title = "ACTION"
            accessibilityTitle = "Action"
        }

        if cursorModeIcon != symbol || cursorModeTitle != title {
            cursorModeIcon = symbol
            cursorModeTitle = title
            actionButton.set(symbol: symbol, title: title)
        }
        actionButton.accessibilityLabel = accessibilityTitle

        for button in sideButtons {
            button.isEnabled = fallout_ios_action_available(Int32(button.tag)) != 0
        }
        pipButton.isEnabled = fallout_ios_action_available(3) != 0
        skillButton.isEnabled = fallout_ios_action_available(4) != 0
        swapButton.isEnabled = fallout_ios_action_available(7) != 0
        endButton.isEnabled = fallout_ios_action_available(5) != 0

        let startsCombat = !inCombat
        skipButton.tag = startsCombat ? 27 : 6
        var skipReady = true
        if let pressed = skipPressedAt {
            if Date().timeIntervalSince(pressed) < 0.45 {
                skipReady = false
            } else {
                skipPressedAt = nil
            }
        }
        skipButton.isEnabled = skipReady && fallout_ios_action_available(startsCombat ? 27 : 6) != 0
        if startsCombat != startCombatShown {
            startCombatShown = startsCombat
            skipButton.set(symbol: startsCombat ? "burst" : "forward.end",
                           title: startsCombat ? "START\nCOMBAT" : "SKIP\nTURN",
                           accessibilityLabel: startsCombat ? "Start combat" : "Skip turn")
        }

        // Reload stays on screen for anything that takes ammunition and dims
        // when it would do nothing; a melee weapon or empty hands keep it away.
        // The attack mode is always there and dims without a usable weapon.
        let carriesFirearm = fallout_ios_action_available(26) != 0
        let canReload = fallout_ios_action_available(8) != 0
        let canChangeMode = fallout_ios_action_available(9) != 0
        reloadButton.isHidden = !carriesFirearm
        reloadButton.isEnabled = canReload
        fireModeButton.isEnabled = canChangeMode

        if canChangeMode {
            let mode = fallout_ios_fire_mode()
            if mode != fireModeValue {
                fireModeValue = mode
                updateFireModeButton(mode)
            }
        }
    }

    /// Takes the movie controls off the screen at once, including the pending
    /// layer commit: the engine blocks its own thread as soon as a movie ends.
    private func hideMovieControls() {
        skipMovieButton.isHidden = true
        movieShield.isHidden = true
        CATransaction.flush()
    }

    /// The game exposes its selected attack mode through the interface item
    /// action: primary, primary aiming, secondary (burst) and secondary aiming.
    /// The pictogram carries the mode - one dot for the primary attack, two for
    /// the secondary, plus a crosshair when that mode is aimed - and the label
    /// underneath says what the button is, since it applies to melee attacks
    /// as well.
    private func updateFireModeButton(_ mode: Int32) {
        // Aimed steps of the attack mode are the game's VATS: they show the
        // chance to hit and cost an extra action point, so the label says so
        // while one of them is selected.
        let aimed = mode == 2 || mode == 4
        let title = aimed ? "VATS\nMODE" : "ATTACK\nMODE"
        switch mode {
        case 1:
            fireModeButton.set(image: Self.fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: single")
        case 2:
            fireModeButton.set(image: Self.fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: aimed")
        case 3:
            fireModeButton.set(image: Self.fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: burst")
        case 4:
            fireModeButton.set(image: Self.fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: aimed secondary")
        default:
            // No readable mode: a hollow bullet and the same label.
            fireModeButton.set(symbol: "circle", title: title,
                               accessibilityLabel: "Attack mode")
        }
    }

    /// One 42x20 pictogram: one dot for the primary attack, two for the
    /// secondary (burst), and a crosshair when the mode is aimed. The whole
    /// group is centred in the canvas so all four modes line up in the button.
    static func fireModeImage(_ mode: Int32) -> UIImage {
        let size = CGSize(width: 42, height: 20)
        let color = ControlTheme.control

        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setFillColor(color.cgColor)
            cg.setStrokeColor(color.cgColor)

            let aimed = mode == 2 || mode == 4
            let dotCount = (mode == 3 || mode == 4) ? 2 : 1
            let dotRadius: CGFloat = 2.6
            let dotSpacing: CGFloat = 8
            let crosshairRadius: CGFloat = 6
            let gap: CGFloat = 3

            let dotsWidth = dotRadius * 2 + CGFloat(dotCount - 1) * dotSpacing
            let totalWidth = dotsWidth + (aimed ? gap + crosshairRadius * 2 : 0)
            let startX = (size.width - totalWidth) / 2
            let centerY = size.height / 2

            for index in 0..<dotCount {
                let x = startX + dotRadius + CGFloat(index) * dotSpacing
                cg.fillEllipse(in: CGRect(
                    x: x - dotRadius,
                    y: centerY - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }

            guard aimed else {
                return
            }

            let centerX = startX + dotsWidth + gap + crosshairRadius
            cg.setLineWidth(1.2)
            cg.strokeEllipse(in: CGRect(
                x: centerX - crosshairRadius,
                y: centerY - crosshairRadius,
                width: crosshairRadius * 2,
                height: crosshairRadius * 2
            ))

            let tick: CGFloat = 2.2
            cg.move(to: CGPoint(x: centerX, y: centerY - crosshairRadius - tick))
            cg.addLine(to: CGPoint(x: centerX, y: centerY - crosshairRadius + 1.2))
            cg.move(to: CGPoint(x: centerX, y: centerY + crosshairRadius - 1.2))
            cg.addLine(to: CGPoint(x: centerX, y: centerY + crosshairRadius + tick))
            cg.move(to: CGPoint(x: centerX - crosshairRadius - tick, y: centerY))
            cg.addLine(to: CGPoint(x: centerX - crosshairRadius + 1.2, y: centerY))
            cg.move(to: CGPoint(x: centerX + crosshairRadius - 1.2, y: centerY))
            cg.addLine(to: CGPoint(x: centerX + crosshairRadius + tick, y: centerY))
            cg.strokePath()
        }
    }
}

private final class LabeledControlButton: UIControl {
    /// A stacked control carries its glyph above its label. The horizontal one,
    /// used by QUICK SAVE, puts the glyph beside the label instead.
    enum Layout {
        case stacked
        case horizontal
    }

    private let plate = VaultPanelView()
    private let pressWash = UIView()
    private let selectionView = UIView()
    private let holdFill = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()

    /// A control that has to hide what is under it, such as the skill panel's
    /// own CANCEL button, paints its panel solid instead of translucent.
    var solidBackground = false {
        didSet {
            plate.fill = normalBackground
        }
    }

    /// Set for an action that must not happen on a stray tap: the button fills
    /// while it is held and fires only once the hold is long enough. It stays
    /// the same button as its neighbours otherwise.
    var onHold: (() -> Void)?
    var holdSeconds: TimeInterval = 2

    private var holdStarted: Date?
    private var holdTimer: Timer?

    private var normalBackground: UIColor {
        return solidBackground ? ControlTheme.solidPanel : ControlTheme.panel.withAlphaComponent(backgroundOpacity)
    }

    /// A control that is one half of a joined assembly draws no plate of its
    /// own: the assembly behind it supplies the outline and the fill, while the
    /// glyph, label, press state and touch area stay its own.
    var drawsOwnPlate = true {
        didSet {
            plate.isHidden = !drawsOwnPlate
        }
    }

    var backgroundOpacity: CGFloat = 0.80 {
        didSet {
            plate.fill = normalBackground
        }
    }
    private let iconPointSize: CGFloat
    private let accent: Bool
    private let labelLines: Int
    private let layout: Layout

    init(title: String, symbol: String, iconPointSize: CGFloat, accent: Bool = false, labelLines: Int = 1, layout: Layout = .stacked) {
        self.iconPointSize = iconPointSize
        self.accent = accent
        self.labelLines = max(1, labelLines)
        self.layout = layout
        super.init(frame: .zero)

        backgroundColor = .clear
        plate.fill = normalBackground
        plate.edge = ControlTheme.border
        plate.lineWidth = 1.25
        plate.innerEdge = ControlTheme.innerEdge
        plate.innerInset = 2
        plate.shadowOpacity = 0.25
        plate.corner = 10
        insertSubview(plate, at: 0)
        tintColor = ControlTheme.control

        // A translucent wash over the panel, for a control that is switched on
        // rather than pressed. The player's colour shows here and in the labels;
        // the plate and its outline stay neutral.
        selectionView.backgroundColor = ControlTheme.wash
        selectionView.isUserInteractionEnabled = false
        selectionView.isHidden = true
        addSubview(selectionView)

        // The sweep of a held control, under the wash and under the label.
        holdFill.backgroundColor = ControlTheme.wash
        holdFill.isUserInteractionEnabled = false
        holdFill.isHidden = true
        insertSubview(holdFill, at: 1)

        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        pressWash.backgroundColor = ControlTheme.pressed
        pressWash.isUserInteractionEnabled = false
        pressWash.isHidden = true
        insertSubview(pressWash, aboveSubview: plate)

        label.font = VaultUI.label(11, weight: .bold)
        label.textAlignment = layout == .horizontal ? .left : .center
        label.numberOfLines = self.labelLines
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.textColor = ControlTheme.control
        label.isUserInteractionEnabled = false
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .button
        set(symbol: symbol, title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(symbol: String, title: String, accessibilityLabel: String? = nil) {
        setGlyph(symbol)
        label.text = L.t(title)
        self.accessibilityLabel = accessibilityLabel ?? title
        setNeedsLayout()
    }

    func set(image: UIImage, title: String, accessibilityLabel: String? = nil) {
        symbolName = nil
        iconView.image = image.withRenderingMode(.alwaysOriginal)
        label.text = L.t(title)
        self.accessibilityLabel = accessibilityLabel ?? title
        setNeedsLayout()
    }

    private var symbolName: String?
    private var symbolPoint: CGFloat = 0

    var glyphName: String? {
        return symbolName
    }

    private func setGlyph(_ name: String) {
        symbolName = name
        symbolPoint = 0
        applyGlyph(iconPointSize)
    }

    private func applyGlyph(_ point: CGFloat) {
        guard let name = symbolName else {
            return
        }
        if iconView.image != nil && abs(point - symbolPoint) < 0.5 {
            return
        }
        symbolPoint = point
        iconView.image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: point, weight: .semibold)
        )
    }

    /// A control that cannot be used right now is dimmed, but never below the
    /// player's own opacity setting: the two only move together once the
    /// slider goes under the dimming, so the unusable ones do not fade first.
    private static let disabledOpacity: CGFloat = 0.35
    private var baseOpacity: CGFloat = 1

    var showsSelection: Bool = false {
        didSet {
            selectionView.isHidden = !showsSelection
        }
    }

    var controlOpacity: CGFloat {
        get {
            return baseOpacity
        }
        set {
            baseOpacity = min(max(newValue, 0.1), 1)
            updateAlpha()
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateAlpha()
        }
    }

    private func updateAlpha() {
        alpha = isEnabled ? baseOpacity : min(Self.disabledOpacity, baseOpacity)
    }

    override var isHighlighted: Bool {
        didSet {
            plate.fill = isHighlighted ? ControlTheme.pressed : normalBackground
            plate.edge = isHighlighted ? ControlTheme.pressedEdge : ControlTheme.border
            tintColor = ControlTheme.control
            label.textColor = ControlTheme.control
            if !drawsOwnPlate {
                pressWash.isHidden = !isHighlighted
            }
        }
    }

    // A held control fills while the finger is down, as an interpolation rather
    // than a timer redrawing it: the engine keeps the main run loop to itself
    // and a timer only gets a slot now and then.
    private var holdFraction: CGFloat {
        guard let holdStarted = holdStarted else {
            return 0
        }
        return min(1, max(0, CGFloat(Date().timeIntervalSince(holdStarted) / holdSeconds)))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if onHold == nil {
            return true
        }

        holdTimer?.invalidate()
        holdStarted = Date()
        holdFill.isHidden = false
        holdFill.layer.removeAllAnimations()
        holdFill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        UIView.animate(withDuration: holdSeconds,
                       delay: 0,
                       options: [.curveLinear, .beginFromCurrentState]) {
            self.holdFill.frame = CGRect(x: 0, y: 0, width: self.bounds.width, height: self.bounds.height)
        }
        CATransaction.flush()

        let timer = Timer(timeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.fireHold()
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if holdFraction >= 1 {
            fireHold()
        } else {
            cancelHold()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelHold()
    }

    private func fireHold() {
        guard let onHold = onHold else {
            return
        }

        cancelHold()
        onHold()
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStarted = nil
        holdFill.layer.removeAllAnimations()
        holdFill.isHidden = true
        holdFill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let radius = max(6, min(min(18, bounds.height * 0.20), bounds.width * 0.28))
        plate.frame = bounds
        plate.corner = radius

        pressWash.frame = bounds
        pressWash.layer.cornerRadius = radius

        selectionView.frame = bounds
        selectionView.layer.cornerRadius = radius

        holdFill.layer.cornerRadius = radius
        if holdStarted == nil {
            holdFill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        }

        let hasLabel = !(label.text?.isEmpty ?? true)
        label.isHidden = !hasLabel

        switch layout {
        case .stacked:
            // A two-line label has to share the button with the pictogram, so
            // it gets a smaller font and two line heights instead of one.
            let fontSize = labelLines > 1
                ? max(9, min(15, min(bounds.width * 0.30, bounds.height * 0.235)))
                : max(10, min(16, min(bounds.width * 0.26, bounds.height * 0.24)))
            label.font = VaultUI.label(fontSize, weight: .bold)

            let lineHeight = ceil(label.font.lineHeight)
            let labelHeight = hasLabel ? lineHeight * CGFloat(labelLines) + (labelLines > 1 ? 1 : 0) : 0

            iconView.frame = CGRect(
                x: 3,
                y: 2,
                width: bounds.width - 6,
                height: max(0, bounds.height - labelHeight - 4)
            )
            label.frame = CGRect(
                x: 1,
                y: bounds.height - labelHeight - 1,
                width: bounds.width - 2,
                height: labelHeight
            )
            let widthCap = hasLabel ? bounds.width * 0.60 : bounds.width * 0.95
            let heightCap = hasLabel ? bounds.height * 0.55 : bounds.height * 0.70
            applyGlyph(max(11, min(min(iconView.frame.height * 0.92, widthCap), heightCap)))
        case .horizontal:
            let fontSize = labelLines > 1
                ? max(10, min(16, bounds.height * 0.26))
                : max(10, min(16, bounds.height * 0.30))
            label.font = VaultUI.label(fontSize, weight: .bold)

            let iconSide = min(bounds.height * 0.52, bounds.width * 0.34)
            let space = max(4, bounds.height * 0.14)
            let textRoom = max(0, bounds.width - iconSide - space - 6)
            let textWidth = hasLabel
                ? min(textRoom, ceil(label.sizeThatFits(CGSize(width: textRoom, height: bounds.height)).width))
                : 0
            let groupWidth = hasLabel ? iconSide + space + textWidth : iconSide
            let originX = max(2, (bounds.width - groupWidth) / 2)

            iconView.frame = CGRect(x: originX,
                                    y: (bounds.height - iconSide) / 2,
                                    width: iconSide,
                                    height: iconSide)
            label.frame = CGRect(x: originX + iconSide + space,
                                 y: 0,
                                 width: textWidth,
                                 height: bounds.height)
            applyGlyph(max(11, min(iconSide * 0.92, bounds.height * 0.52)))
        }
    }
}

private final class CameraJoystickControl: UIControl {
    private let ring = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let knob = UIView()
    private let shade = CAGradientLayer()
    private let crosshair = CAShapeLayer()

    var controlOpacity: CGFloat = 1 {
        didSet {
            alpha = min(max(controlOpacity, 0.1), 1)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isExclusiveTouch = true

        ring.fillColor = VaultUI.controlFill.withAlphaComponent(0.72).cgColor
        ring.strokeColor = ControlTheme.border.cgColor
        ring.lineWidth = 1.6
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.4
        ring.shadowRadius = 7
        ring.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(ring)

        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = ControlTheme.innerEdge.cgColor
        rim.lineWidth = 1
        layer.addSublayer(rim)

        crosshair.fillColor = UIColor.clear.cgColor
        crosshair.strokeColor = ControlTheme.content.withAlphaComponent(0.22).cgColor
        crosshair.lineWidth = 1
        crosshair.lineCap = .round
        layer.addSublayer(crosshair)

        knob.isUserInteractionEnabled = false
        knob.backgroundColor = VaultUI.controlKnob.withAlphaComponent(0.95)
        knob.layer.borderWidth = 1.6
        knob.layer.borderColor = ControlTheme.border.withAlphaComponent(0.9).cgColor
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.25
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(knob)

        shade.colors = [UIColor(white: 1, alpha: 0.12).cgColor,
                        UIColor(white: 0, alpha: 0.20).cgColor]
        shade.locations = [0, 1]
        shade.masksToBounds = true
        knob.layer.insertSublayer(shade, at: 0)

        accessibilityLabel = "Camera joystick"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        ring.frame = bounds
        let ringInset: CGFloat = 1.5
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: ringInset, dy: ringInset)).cgPath
        ring.shadowPath = ring.path

        rim.frame = bounds
        rim.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3.5, dy: 3.5)).cgPath

        let knobSize = max(38, bounds.width * 0.36)
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        knob.layer.cornerRadius = knobSize / 2
        knob.layer.shadowPath = UIBezierPath(ovalIn: knob.bounds).cgPath

        shade.frame = knob.bounds
        shade.cornerRadius = knobSize / 2

        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.28))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.16))
        path.move(to: CGPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.16))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.28))
        path.move(to: CGPoint(x: bounds.midX - bounds.width * 0.28, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.midX - bounds.width * 0.16, y: bounds.midY))
        path.move(to: CGPoint(x: bounds.midX + bounds.width * 0.16, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.midX + bounds.width * 0.28, y: bounds.midY))
        crosshair.path = path.cgPath
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(with: touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(with: touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        reset()
    }

    override func cancelTracking(with event: UIEvent?) {
        reset()
    }

    private func update(with touch: UITouch) {
        let point = touch.location(in: self)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = max(1, bounds.width / 2 - knob.bounds.width / 2 - 8)

        var dx = point.x - center.x
        var dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > maxRadius {
            dx = dx / distance * maxRadius
            dy = dy / distance * maxRadius
        }

        let target = CGPoint(x: center.x + dx, y: center.y + dy)
        UIView.animate(withDuration: 0.07,
                       delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.knob.center = target
            self.knob.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
        }
        fallout_ios_camera_pan(Double(dx / maxRadius), Double(dy / maxRadius))
    }

    private func reset() {
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.knob.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            self.knob.transform = .identity
        }
        fallout_ios_camera_stop()
    }
}

@_cdecl("fallout_ios_install_game_controls")
public func falloutIOSInstallGameControls() {
    if Thread.isMainThread {
        GameControlsOverlay.install()
    } else {
        DispatchQueue.main.async {
            GameControlsOverlay.install()
        }
    }
}

// MARK: - Launcher music

/// Background music for the launcher, reused by the game's main menu. Loading a
/// small MP3 directly avoids the delay of decoding an ACM track from the game
/// data first.
final class LauncherMusic {
    static let shared = LauncherMusic()

    private static let volume: Float = 0.32
    /// The track bundled with the app, used by any game that has no theme of
    /// its own. It stops being used once both games have theirs.
    private static let sharedTrack = "intro music"
    /// Per-game themes, in the order they are looked for in the bundle.
    private static let themeNames: [FalloutGame: [String]] = [
        .fallout1: ["maybe", "fallout1 music"],
        .fallout2: ["blue moon", "fallout2 music"],
    ]

    private var player: AVAudioPlayer?
    private var trackName: String?

    private init() {}

    private static let mutedKey = "launcher.musicMuted"

    /// Kept across launches, so muting the launcher track sticks.
    static var isMuted: Bool {
        get {
            return UserDefaults.standard.bool(forKey: mutedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: mutedKey)
            LauncherMusic.shared.player?.volume = newValue ? 0 : LauncherMusic.volume
        }
    }

    /// The track a game plays, or nil when the app carries no music at all.
    /// A game's own theme wins; otherwise the shared track covers it, which is
    /// how one generic file keeps both games scored until the real songs land.
    static func themeName(for game: FalloutGame) -> String? {
        let names = (themeNames[game] ?? []) + [sharedTrack]
        for name in names where !name.isEmpty {
            if Bundle.main.url(forResource: name, withExtension: "mp3") != nil {
                return name
            }
        }
        return nil
    }

    private func play(track: String) {
        guard let url = Bundle.main.url(forResource: track, withExtension: "mp3") else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let next = try AVAudioPlayer(contentsOf: url)
            next.numberOfLoops = -1
            next.volume = LauncherMusic.isMuted ? 0 : LauncherMusic.volume
            // Loading the buffers now is what keeps the first second of the
            // track from being late; the game's ACMs take seconds to decode,
            // an MP3 prepared this way starts at once.
            next.prepareToPlay()
            next.play()

            player?.stop()
            player = next
            trackName = track
        } catch {
            // The launcher still works without music.
        }
    }

    func playIfAvailable() {
        guard let track = LauncherMusic.themeName(for: ControlLayout.activeGame()) else {
            return
        }

        if let player = player, trackName == track {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        play(track: track)
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
        trackName = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// The game's own main menu asks for 07desert.acm. On iOS the launcher MP3 is
// used there too, so the bundled track replaces the game-data ACM cleanly.
@_cdecl("fallout_ios_menu_music_start")
public func fallout_ios_menu_music_start() {
    LauncherMusic.shared.playIfAvailable()
}

@_cdecl("fallout_ios_menu_music_stop")
public func fallout_ios_menu_music_stop() {
    LauncherMusic.shared.stop()
}

// The engine asks for this from its own input loop, a few times a second, on
// the main thread and between frames. It is how the on-screen controls know
// what the game can do right now without a timer of ours interrupting it.
@_cdecl("fallout_ios_refresh_game_controls")
public func fallout_ios_refresh_game_controls() {
    GameControlsOverlay.refreshInstalled()
}

@_cdecl("fallout_ios_auto_save_failed")
public func falloutIOSAutoSaveFailed() {
    GameControlsOverlay.autoSaveFailed()
}

final class MovieSkipButton: UIControl {
    var onTrigger: (() -> Void)?
    var requiresHold = false {
        didSet {
            caption.text = L.t(requiresHold ? "HOLD TO SKIP" : "TAP TO SKIP")
        }
    }
    var holdSeconds: TimeInterval = 2

    private let fill = UIView()
    private let caption = UILabel()
    private var progressTimer: Timer?
    private var startedAt: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = VaultUI.controlFill.withAlphaComponent(0.78)
        layer.cornerRadius = 9
        layer.masksToBounds = true
        layer.borderWidth = 1.5
        layer.borderColor = ControlTheme.border.cgColor

        fill.backgroundColor = ControlTheme.wash
        fill.isUserInteractionEnabled = false
        addSubview(fill)

        caption.text = L.t("TAP TO SKIP")
        caption.font = VaultUI.label(11, weight: .bold)
        caption.textColor = VaultUI.controlContent
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.6
        caption.isUserInteractionEnabled = false
        addSubview(caption)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        caption.frame = bounds
        if startedAt == nil {
            fill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if requiresHold {
            startedAt = Date()
            startProgress()
        } else {
            trigger()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        holdReached()
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelProgress()
    }

    private var fraction: CGFloat {
        guard let startedAt = startedAt else {
            return 0
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        return min(1, max(0, CGFloat(elapsed / holdSeconds)))
    }

    private func startProgress() {
        progressTimer?.invalidate()

        // The fill is a Core Animation interpolation, not a timer redrawing it
        // thirty times a second. The engine keeps the main run loop blocked
        // while it runs, so a timer only gets a slot now and then and the bar
        // crawls; an animation is drawn by the render server and stays smooth.
        // Flushing hands it over now instead of waiting for a run loop turn.
        fill.layer.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        UIView.animate(withDuration: holdSeconds,
                       delay: 0,
                       options: [.curveLinear, .beginFromCurrentState]) {
            self.fill.frame = CGRect(x: 0, y: 0, width: self.bounds.width, height: self.bounds.height)
        }
        CATransaction.flush()

        // Only the moment the hold is long enough is timed.
        let timer = Timer(timeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.trigger()
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A hold counts as done the moment the finger comes up, whatever the timer
    /// managed to do while the run loop was busy.
    private func holdReached() {
        if fraction >= 1 {
            trigger()
        } else {
            cancelProgress()
        }
    }

    private func cancelProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        startedAt = nil
        fill.layer.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
    }

    private func trigger() {
        cancelProgress()
        onTrigger?()
    }
}


final class InventoryHelpCard: UIView {
    static let green = UIColor(red: 0.30, green: 1.0, blue: 0.40, alpha: 1)

    private let plate = VaultPanelView()
    private let label = UILabel()
    private let closeButton = UIButton(type: .system)

    /// Called by the small cross in the corner.
    var onClose: (() -> Void)?

    private let inset: CGFloat = 18
    private let header: CGFloat = 18

    var text: String {
        get {
            return label.text ?? ""
        }
        set {
            label.text = newValue
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        plate.fill = VaultUI.controlFill.withAlphaComponent(0.92)
        plate.edge = VaultUI.controlBorder
        plate.corner = 14
        addSubview(plate)

        label.font = VaultUI.label(14, weight: .medium)
        label.textColor = VaultUI.controlContent
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        addSubview(label)

        closeButton.setImage(UIImage(systemName: "xmark",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)),
                             for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - inset * 2,
                                                 height: .greatestFiniteMagnitude))
        return CGSize(width: maxWidth, height: textSize.height + inset * 2 + header)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        plate.frame = bounds

        label.frame = CGRect(x: inset,
                             y: inset + header,
                             width: max(0, bounds.width - inset * 2),
                             height: max(0, bounds.height - inset * 2 - header))

        let side: CGFloat = 30
        closeButton.frame = CGRect(x: bounds.width - side - 6, y: 4, width: side, height: side)
    }

    @objc private func close() {
        onClose?()
    }
}
