import AVFoundation
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
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

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

// MARK: - In-game controls

// Native controls shown over SDL's view in the black margins beside the HUD.
// Keeping them as real UIKit views means SDL never sees these touches, while
// the rest of the screen keeps working exactly as before.

private enum ControlTheme {
    static var whiteButtons: Bool {
        UserDefaults.standard.bool(forKey: LauncherModel.optionKey("whiteButtons", for: ControlLayout.activeGame()))
    }

    static var game: FalloutGame {
        ControlLayout.activeGame()
    }

    static var green: UIColor {
        if whiteButtons {
            return .white
        }
        return game == .fallout2
            ? UIColor(red: 0.42, green: 0.75, blue: 1.0, alpha: 0.95)
            : UIColor(red: 0.55, green: 0.96, blue: 0.45, alpha: 0.95)
    }

    static var amber: UIColor {
        whiteButtons ? .white : UIColor(red: 0.95, green: 0.72, blue: 0.32, alpha: 0.95)
    }

    static var panel: UIColor {
        game == .fallout2
            ? UIColor(red: 0.015, green: 0.030, blue: 0.055, alpha: 0.55)
            : UIColor(red: 0.02, green: 0.05, blue: 0.02, alpha: 0.55)
    }

    static let highlight = UIColor.white.withAlphaComponent(0.18)

    static var dim: UIColor {
        if whiteButtons {
            return UIColor.white.withAlphaComponent(0.68)
        }
        return game == .fallout2
            ? UIColor(red: 0.50, green: 0.61, blue: 0.74, alpha: 0.9)
            : UIColor(red: 0.45, green: 0.60, blue: 0.45, alpha: 0.9)
    }
}

enum TouchControl: String, CaseIterable, Identifiable, Hashable {
    case joystick
    case back
    case action
    case skip
    case inv
    case map
    case cha
    case pip
    case skill
    case swap
    case end
    case reload
    case fireMode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .joystick: return "LOOK"
        case .back: return "BACK"
        case .action: return "ACTION"
        case .skip: return "SKIP"
        case .inv: return "INV"
        case .map: return "MAP"
        case .cha: return "CHA"
        case .pip: return "PIP"
        case .skill: return "SKILL"
        case .swap: return "SWAP"
        case .end: return "END"
        case .reload: return "RELOAD"
        case .fireMode: return "MODE"
        }
    }

    var symbol: String {
        switch self {
        case .joystick: return "circle.dashed"
        case .back: return "chevron.backward"
        case .action: return "hand.tap"
        case .skip: return "forward.end"
        case .inv: return "bag"
        case .map: return "map"
        case .cha: return "person"
        case .pip: return "book.closed"
        case .skill: return "star"
        case .swap: return "arrow.left.arrow.right"
        case .end: return "xmark"
        case .reload: return "arrow.clockwise"
        case .fireMode: return "scope"
        }
    }

    /// Fallout 1 and Fallout 2 keep independent control sets and layouts.
    static func controls(for game: FalloutGame) -> [TouchControl] {
        switch game {
        case .fallout1:
            return allCases.filter { $0 != .reload && $0 != .fireMode }
        case .fallout2:
            return allCases
        }
    }

    static func bottomRow(for profile: LayoutProfile) -> [TouchControl] {
        switch profile {
        case .full: return [.map, .cha, .inv, .pip]
        case .half: return [.map, .cha, .inv]
        }
    }

    /// Normalized center of the control on the game view. The editor stores
    /// the same coordinates, so layouts survive resolution and orientation
    /// changes.
    func defaultCenter(for profile: LayoutProfile = .full, in bounds: CGSize = UIScreen.main.bounds.size) -> CGPoint {
        switch profile {
        case .full:
            switch self {
            case .joystick: return CGPoint(x: 0.18125, y: 0.8110)
            case .back: return CGPoint(x: 0.1160, y: 0.5725)
            case .action: return CGPoint(x: 0.9415, y: 0.6900)
            case .skip: return CGPoint(x: 0.9444, y: 0.5320)
            // Four equal cells filling the strip to the right of the HUD.
            case .map: return CGPoint(x: 0.7795, y: 0.9215)
            case .cha: return CGPoint(x: 0.8386, y: 0.9215)
            case .inv: return CGPoint(x: 0.8977, y: 0.9215)
            case .pip: return CGPoint(x: 0.9567, y: 0.9215)
            // Three equal squares in the top-right corner: END, SKILL, SWAP.
            case .skill: return CGPoint(x: 0.9594, y: 0.2000)
            case .swap: return CGPoint(x: 0.9594, y: 0.3250)
            case .end: return CGPoint(x: 0.9594, y: 0.0750)
            // Fallout 2 adds RELOAD next to ACTION and MODE left of END.
            case .reload: return CGPoint(x: 0.8550, y: 0.6900)
            case .fireMode:
                // Same size as END, sitting directly to its left.
                let end = TouchControl.end.defaultCenter(for: profile, in: bounds)
                let side = TouchControl.end.defaultSize(in: bounds, profile: profile).width
                let gap = max(3.0, side * 0.12)
                return CGPoint(x: end.x - (side + gap) / max(bounds.width, 1), y: end.y)
            }
        case .half:
            switch self {
            // Keep the HUD clear at half resolution: PIP moves above BACK,
            // the other three HUD buttons slide together, and LOOK shifts left.
            case .joystick: return CGPoint(x: 0.1170, y: 0.8110)
            case .back: return CGPoint(x: 0.1160, y: 0.5725)
            case .action: return CGPoint(x: 0.9415, y: 0.6900)
            case .skip: return CGPoint(x: 0.9444, y: 0.5320)
            case .map: return CGPoint(x: 0.8347, y: 0.9215)
            case .cha: return CGPoint(x: 0.8953, y: 0.9215)
            case .inv: return CGPoint(x: 0.9559, y: 0.9215)
            case .pip: return CGPoint(x: 0.1080, y: 0.4250)
            case .skill: return CGPoint(x: 0.9594, y: 0.2000)
            case .swap: return CGPoint(x: 0.9594, y: 0.3250)
            case .end: return CGPoint(x: 0.9594, y: 0.0750)
            case .reload: return CGPoint(x: 0.8550, y: 0.6900)
            case .fireMode:
                // Same size as END, sitting directly to its left.
                let end = TouchControl.end.defaultCenter(for: profile, in: bounds)
                let side = TouchControl.end.defaultSize(in: bounds, profile: profile).width
                let gap = max(3.0, side * 0.12)
                return CGPoint(x: end.x - (side + gap) / max(bounds.width, 1), y: end.y)
            }
        }
    }

    /// Base size in points before the global and per-control scale settings.
    /// The HUD-row buttons are intentionally rectangles so they fill the side
    /// strip in the same way as the proposed layout.
    func defaultSize(in bounds: CGSize, profile: LayoutProfile = .full) -> CGSize {
        switch profile {
        case .full:
            switch self {
            case .joystick:
                let side = bounds.height * 0.318
                return CGSize(width: side, height: side)
            case .back:
                let side = min(bounds.width * 0.0670, bounds.height * 0.149)
                return CGSize(width: side, height: side)
            case .action:
                return CGSize(width: bounds.width * 0.0925, height: bounds.height * 0.171)
            case .skip:
                return CGSize(width: bounds.width * 0.0838, height: bounds.height * 0.135)
            case .inv, .map, .cha, .pip:
                return CGSize(width: bounds.width * 0.0591, height: bounds.height * 0.1375)
            case .skill, .swap, .end, .fireMode:
                let side = min(bounds.width * 0.05625, bounds.height * 0.130)
                return CGSize(width: side, height: side)
            case .reload:
                let side = min(bounds.width * 0.055, bounds.height * 0.125)
                return CGSize(width: side, height: side)
            }
        case .half:
            switch self {
            case .joystick:
                let side = bounds.height * 0.318
                return CGSize(width: side, height: side)
            case .back:
                let side = min(bounds.width * 0.0670, bounds.height * 0.149)
                return CGSize(width: side, height: side)
            case .action:
                return CGSize(width: bounds.width * 0.0925, height: bounds.height * 0.171)
            case .skip:
                return CGSize(width: bounds.width * 0.0838, height: bounds.height * 0.135)
            case .map, .cha, .inv:
                return CGSize(width: bounds.width * 0.0606, height: bounds.height * 0.1375)
            case .pip:
                let side = min(bounds.width * 0.0644, bounds.height * 0.143)
                return CGSize(width: side, height: side)
            case .skill, .swap, .end, .fireMode:
                let side = min(bounds.width * 0.05625, bounds.height * 0.130)
                return CGSize(width: side, height: side)
            case .reload:
                let side = min(bounds.width * 0.055, bounds.height * 0.125)
                return CGSize(width: side, height: side)
            }
        }
    }
}

enum LayoutProfile: String {
    case full
    case half
}

enum ControlLayout {
    private static let layoutVersionKey = "launcher.controlLayoutVersion"
    private static let layoutVersion = 12
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
        return CGFloat(min(max(value, 0.15), 1))
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

        // Version 12 moved the attack mode control out from under SWAP to the
        // row with END, so a position saved for its old place no longer fits
        // the square button. Its size is kept.
        for game in FalloutGame.allCases {
            for profile in [LayoutProfile.full, .half] {
                defaults.removeObject(forKey: key(.fireMode, xSuffix, profile: profile, game: game))
                defaults.removeObject(forKey: key(.fireMode, ySuffix, profile: profile, game: game))
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

    static func scale(for control: TouchControl, profile: LayoutProfile, game: FalloutGame) -> CGFloat {
        let value = UserDefaults.standard.object(forKey: key(control, scaleSuffix, profile: profile, game: game)) as? Double ?? 1.0
        return CGFloat(min(max(value, 0.55), 2.0))
    }

    static func setScale(_ scale: CGFloat, for control: TouchControl, profile: LayoutProfile, game: FalloutGame) {
        UserDefaults.standard.set(Double(min(max(scale, 0.55), 2.0)), forKey: key(control, scaleSuffix, profile: profile, game: game))
    }

    static func reset(profile: LayoutProfile, game: FalloutGame) {
        let defaults = UserDefaults.standard
        for control in TouchControl.controls(for: game) {
            defaults.removeObject(forKey: key(control, xSuffix, profile: profile, game: game))
            defaults.removeObject(forKey: key(control, ySuffix, profile: profile, game: game))
            defaults.removeObject(forKey: key(control, scaleSuffix, profile: profile, game: game))
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
    /// Keeps the overlay alive across SDL window changes so its timer can put
    /// it back if the window is recreated.
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
        title: "SKIP",
        symbol: "forward.end",
        iconPointSize: 18,
        accent: true
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
        title: "END",
        symbol: "xmark",
        iconPointSize: 18
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
    private let game = ControlLayout.activeGame()
    private var sideButtons: [LabeledControlButton] = []
    private var cursorModeIcon: String?
    private var cursorModeTitle: String?
    private var cursorModeTimer: Timer?
    private var fireModeValue: Int32 = -2

    static func install() {
        ControlLayout.migrateIfNeeded()

        // The engine calls this once its SDL window exists (Fallout 1's
        // svga_init does), in which case the overlay can attach immediately.
        if let window = sdlWindow() {
            attach(to: window)
            return
        }

        // Fallout 2's engine does not call back after creating its window, so
        // wait for that window to appear instead of covering it with a window
        // of our own.
        observeEngineWindow()
        watchForEngineWindow()
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
        window.addSubview(overlay)
        window.bringSubviewToFront(overlay)
        overlay.setNeedsLayout()
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
            ("PIP", "book.closed", 3),
        ]
        for item in sideActions {
            let button = LabeledControlButton(
                title: item.0,
                symbol: item.1,
                iconPointSize: 14
            )
            button.tag = item.2
            // The four HUD buttons sit edge-to-edge as one strip.
            button.layer.cornerRadius = 3
            button.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
            sideButtons.append(button)
            addSubview(button)
        }

        skillButton.tag = 4
        skillButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(skillButton)

        swapButton.tag = 7
        swapButton.accessibilityLabel = "Swap weapon"
        swapButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(swapButton)

        endButton.tag = 5
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

        refreshControls()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshControls()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorModeTimer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cursorModeTimer?.invalidate()
    }

    override func removeFromSuperview() {
        cursorModeTimer?.invalidate()
        cursorModeTimer = nil
        super.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let defaults = UserDefaults.standard
        let joystickScale = CGFloat(defaults.object(forKey: LauncherModel.optionKey("joystickScale", for: game)) as? Double ?? 1.0)
        let buttonScale = CGFloat(defaults.object(forKey: LauncherModel.optionKey("buttonScale", for: game)) as? Double ?? 1.0)
        let profile = ControlLayout.profileForCurrentResolution()

        place(joystick, at: .joystick, profile: profile, size: scaledSize(for: .joystick, in: bounds.size, globalScale: joystickScale, profile: profile))
        place(backButton, at: .back, profile: profile, size: scaledSize(for: .back, in: bounds.size, globalScale: buttonScale, profile: profile))
        place(actionButton, at: .action, profile: profile, size: scaledSize(for: .action, in: bounds.size, globalScale: buttonScale, profile: profile))
        place(skipButton, at: .skip, profile: profile, size: scaledSize(for: .skip, in: bounds.size, globalScale: buttonScale, profile: profile))

        let row = TouchControl.bottomRow(for: profile)
        for (index, control) in row.enumerated() where index < sideButtons.count {
            place(sideButtons[index], at: control, profile: profile,
                  size: scaledSize(for: control, in: bounds.size, globalScale: buttonScale, profile: profile))
        }
        // At half resolution PIP leaves the row and sits above BACK.
        if row.count < sideButtons.count {
            let pip = sideButtons[row.count]
            place(pip, at: .pip, profile: profile,
                  size: scaledSize(for: .pip, in: bounds.size, globalScale: buttonScale, profile: profile))
        }

        place(skillButton, at: .skill, profile: profile, size: scaledSize(for: .skill, in: bounds.size, globalScale: buttonScale, profile: profile))
        place(swapButton, at: .swap, profile: profile, size: scaledSize(for: .swap, in: bounds.size, globalScale: buttonScale, profile: profile))
        place(endButton, at: .end, profile: profile, size: scaledSize(for: .end, in: bounds.size, globalScale: buttonScale, profile: profile))

        if game == .fallout2 {
            place(reloadButton, at: .reload, profile: profile, size: scaledSize(for: .reload, in: bounds.size, globalScale: buttonScale, profile: profile))
            place(fireModeButton, at: .fireMode, profile: profile, size: scaledSize(for: .fireMode, in: bounds.size, globalScale: buttonScale, profile: profile))
        }
    }

    private func scaledSize(for control: TouchControl, in bounds: CGSize, globalScale: CGFloat, profile: LayoutProfile) -> CGSize {
        let base = control.defaultSize(in: bounds, profile: profile)
        let factor = max(0.55, globalScale) * ControlLayout.scale(for: control, profile: profile, game: game)
        return CGSize(
            width: max(22, min(bounds.width * 0.45, base.width * factor)),
            height: max(22, min(bounds.height * 0.45, base.height * factor))
        )
    }

    private func place(_ view: UIView, at control: TouchControl, profile: LayoutProfile, size: CGSize) {
        let normalized = ControlLayout.center(for: control, profile: profile, game: game)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        // Use the full screen. Subtracting the window's safe-area insets here
        // pulled the right-hand column about 100pt inward on notched phones.
        let x = min(max(normalized.x * bounds.width, halfWidth), bounds.width - halfWidth)
        let y = min(max(normalized.y * bounds.height, halfHeight), bounds.height - halfHeight)
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
        fallout_ios_right_click()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func goBack() {
        fallout_ios_back()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func sideActionPressed(_ sender: LabeledControlButton) {
        fallout_ios_press_action(Int32(sender.tag))
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Pushes the player's opacity setting into every control. Buttons combine
    /// it with their enabled state themselves.
    private func applyControlOpacity(_ value: CGFloat) {
        joystick.controlOpacity = value
        actionButton.controlOpacity = value
        backButton.controlOpacity = value
        skipButton.controlOpacity = value
        skillButton.controlOpacity = value
        swapButton.controlOpacity = value
        endButton.controlOpacity = value
        reloadButton.controlOpacity = value
        fireModeButton.controlOpacity = value
        for button in sideButtons {
            button.controlOpacity = value
        }
    }

    private func refreshControls() {
        // The overlay is attached while SDL is still creating its window, and
        // SDL's own view may be inserted after it. Keep the controls sized to
        // the window, above the game view, and alive if SDL recreates it.
        if tag == Self.overlayTag {
            if let host = superview {
                if frame.size != host.bounds.size {
                    frame = host.bounds
                }
                host.bringSubviewToFront(self)
            } else if let window = Self.sdlWindow() {
                Self.attach(to: window)
            }
        }

        applyControlOpacity(ControlLayout.controlsOpacity())

        let mode = fallout_ios_cursor_mode()
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
        default:
            symbol = "hand.tap"
            title = "ACTIONS"
            accessibilityTitle = "Actions"
        }

        if cursorModeIcon != symbol || cursorModeTitle != title {
            cursorModeIcon = symbol
            cursorModeTitle = title
            actionButton.set(symbol: symbol, title: title)
        }
        actionButton.accessibilityLabel = accessibilityTitle

        for (index, button) in sideButtons.enumerated() {
            button.isEnabled = fallout_ios_action_available(Int32(index)) != 0
        }
        skillButton.isEnabled = fallout_ios_action_available(4) != 0
        swapButton.isEnabled = fallout_ios_action_available(7) != 0
        endButton.isEnabled = fallout_ios_action_available(5) != 0
        skipButton.isHidden = fallout_ios_action_available(6) == 0

        let showFallout2Controls = game == .fallout2
        if showFallout2Controls {
            // Reload needs a firearm; fire mode applies to any held weapon.
            let canReload = fallout_ios_action_available(8) != 0
            let canChangeMode = fallout_ios_action_available(9) != 0
            reloadButton.isHidden = !canReload
            fireModeButton.isHidden = !canChangeMode
            reloadButton.isEnabled = canReload
            fireModeButton.isEnabled = canChangeMode

            if canChangeMode {
                let mode = fallout_ios_fire_mode()
                if mode != fireModeValue {
                    fireModeValue = mode
                    updateFireModeButton(mode)
                }
            }
        } else {
            reloadButton.isHidden = true
            fireModeButton.isHidden = true
        }
    }

    /// The game exposes its selected attack mode through the interface item
    /// action: primary, primary aiming, secondary (burst) and secondary aiming.
    /// The pictogram carries the mode - one dot for the primary attack, two for
    /// the secondary, plus a crosshair when that mode is aimed - and the label
    /// underneath says what the button is, since it applies to melee attacks
    /// as well.
    private func updateFireModeButton(_ mode: Int32) {
        let title = "ATTACK\nMODE"
        switch mode {
        case 1:
            fireModeButton.set(image: fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: single")
        case 2:
            fireModeButton.set(image: fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: aimed")
        case 3:
            fireModeButton.set(image: fireModeImage(mode), title: title,
                               accessibilityLabel: "Attack mode: burst")
        case 4:
            fireModeButton.set(image: fireModeImage(mode), title: title,
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
    private func fireModeImage(_ mode: Int32) -> UIImage {
        let size = CGSize(width: 42, height: 20)
        let color = ControlTheme.green

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
    private let iconView = UIImageView()
    private let label = UILabel()
    private let iconPointSize: CGFloat
    private let accent: Bool
    private let labelLines: Int

    init(title: String, symbol: String, iconPointSize: CGFloat, accent: Bool = false, labelLines: Int = 1) {
        self.iconPointSize = iconPointSize
        self.accent = accent
        self.labelLines = max(1, labelLines)
        super.init(frame: .zero)

        backgroundColor = ControlTheme.panel
        layer.cornerRadius = 10
        layer.borderWidth = 1.5
        layer.borderColor = (accent ? ControlTheme.amber : ControlTheme.green)
            .withAlphaComponent(0.6).cgColor
        tintColor = accent ? ControlTheme.amber : ControlTheme.green

        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = self.labelLines
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.textColor = accent ? ControlTheme.amber : ControlTheme.green
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
        iconView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .semibold)
        )
        label.text = title
        self.accessibilityLabel = accessibilityLabel ?? title
        setNeedsLayout()
    }

    func set(image: UIImage, title: String, accessibilityLabel: String? = nil) {
        iconView.image = image.withRenderingMode(.alwaysOriginal)
        label.text = title
        self.accessibilityLabel = accessibilityLabel ?? title
        setNeedsLayout()
    }

    /// A control that cannot be used right now is dimmed, but never below the
    /// player's own opacity setting: the two only move together once the
    /// slider goes under the dimming, so the unusable ones do not fade first.
    private static let disabledOpacity: CGFloat = 0.35
    private var baseOpacity: CGFloat = 1

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
            let normal = accent ? ControlTheme.amber : ControlTheme.green
            backgroundColor = isHighlighted ? ControlTheme.highlight : ControlTheme.panel
            layer.borderColor = (isHighlighted ? UIColor.white : normal)
                .withAlphaComponent(isHighlighted ? 0.75 : 0.6).cgColor
            tintColor = isHighlighted ? .white : normal
            label.textColor = isHighlighted ? .white : normal
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let hasLabel = !(label.text?.isEmpty ?? true)
        // A two-line label has to share the button with the pictogram, so it
        // gets a smaller font and two line heights instead of one.
        let fontSize = labelLines > 1
            ? max(7, min(9, bounds.height * 0.17))
            : max(8, min(10, bounds.height * 0.19))
        label.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        let lineHeight = ceil(label.font.lineHeight)
        let labelHeight = hasLabel ? lineHeight * CGFloat(labelLines) + (labelLines > 1 ? 1 : 0) : 0

        iconView.frame = CGRect(
            x: 3,
            y: 2,
            width: bounds.width - 6,
            height: max(0, bounds.height - labelHeight - 4)
        )
        label.isHidden = !hasLabel
        label.frame = CGRect(
            x: 1,
            y: bounds.height - labelHeight - 1,
            width: bounds.width - 2,
            height: labelHeight
        )
    }
}

private final class CameraJoystickControl: UIControl {
    private let ring = CAShapeLayer()
    private let knob = UIView()
    private let crosshair = CAShapeLayer()
    private let caption = UILabel()

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

        ring.fillColor = ControlTheme.panel.withAlphaComponent(0.30).cgColor
        ring.strokeColor = ControlTheme.green.withAlphaComponent(0.40).cgColor
        ring.lineWidth = 1.2
        ring.shadowOpacity = 0
        layer.addSublayer(ring)

        crosshair.fillColor = UIColor.clear.cgColor
        crosshair.strokeColor = ControlTheme.green.withAlphaComponent(0.16).cgColor
        crosshair.lineWidth = 1
        crosshair.lineCap = .round
        layer.addSublayer(crosshair)

        knob.isUserInteractionEnabled = false
        knob.backgroundColor = ControlTheme.green.withAlphaComponent(0.10)
        knob.layer.borderWidth = 1.2
        knob.layer.borderColor = ControlTheme.green.withAlphaComponent(0.65).cgColor
        knob.layer.shadowColor = ControlTheme.green.cgColor
        knob.layer.shadowOpacity = 0.10
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = .zero
        addSubview(knob)

        caption.text = "LOOK"
        caption.font = UIFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        caption.textColor = ControlTheme.dim
        caption.textAlignment = .center
        caption.isUserInteractionEnabled = false
        addSubview(caption)

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

        let knobSize = max(38, bounds.width * 0.36)
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        knob.layer.cornerRadius = knobSize / 2
        knob.layer.shadowPath = UIBezierPath(ovalIn: knob.bounds).cgPath

        caption.frame = CGRect(
            x: 0,
            y: bounds.height - 18,
            width: bounds.width,
            height: 12
        )

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

/// Background music for the launcher, reused by the game's main menu.
///
/// Each game can have a track of its own and switching games crossfades between
/// them. A game with no track of its own keeps the bundled one playing rather
/// than restarting it, so the shared app still has music everywhere. Loading a
/// small MP3 directly avoids the delay of decoding an ACM track from the game
/// data first.
final class LauncherMusic {
    static let shared = LauncherMusic()

    private static let volume: Float = 0.32
    private static let fade: TimeInterval = 0.9
    /// The track bundled with the app, used by any game without its own.
    private static let sharedTrack = "intro music"
    private static let trackNames: [FalloutGame: String] = [
        .fallout1: "intro music",
        .fallout2: "fallout2 music",
    ]

    private var player: AVAudioPlayer?
    private var trackName: String?

    private init() {}

    private static func trackName(for game: FalloutGame) -> String? {
        let names = [trackNames[game] ?? sharedTrack, sharedTrack]
        for name in names where !name.isEmpty {
            if Bundle.main.url(forResource: name, withExtension: "mp3") != nil {
                return name
            }
        }
        return nil
    }

    private func play(track: String, crossfade: Bool) {
        guard let url = Bundle.main.url(forResource: track, withExtension: "mp3") else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let next = try AVAudioPlayer(contentsOf: url)
            next.numberOfLoops = -1
            next.volume = crossfade ? 0 : LauncherMusic.volume
            next.play()

            let outgoing = player
            player = next
            trackName = track

            guard let outgoing = outgoing else {
                return
            }

            guard crossfade else {
                outgoing.stop()
                return
            }

            // Both tracks keep playing while they swap volumes, so the change
            // of game is a fade rather than a cut. The old player is released
            // by its own stop, which is all it needs to disappear.
            next.setVolume(LauncherMusic.volume, fadeDuration: LauncherMusic.fade)
            outgoing.setVolume(0, fadeDuration: LauncherMusic.fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + LauncherMusic.fade) {
                outgoing.stop()
            }
        } catch {
            // The launcher still works without music.
        }
    }

    func playIfAvailable() {
        guard let track = LauncherMusic.trackName(for: ControlLayout.activeGame()) else {
            return
        }

        if let player = player, trackName == track {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        play(track: track, crossfade: false)
    }

    /// Called when the player picks the other game in the launcher.
    func crossfade(to game: FalloutGame) {
        guard let track = LauncherMusic.trackName(for: game) else {
            return
        }
        guard track != trackName else {
            return
        }

        play(track: track, crossfade: player != nil)
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
