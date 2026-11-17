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
    static let green = UIColor(red: 0.55, green: 0.96, blue: 0.45, alpha: 0.95)
    static let amber = UIColor(red: 0.95, green: 0.72, blue: 0.32, alpha: 0.95)
    static let panel = UIColor(red: 0.02, green: 0.05, blue: 0.02, alpha: 0.62)
    static let dim = UIColor(red: 0.45, green: 0.60, blue: 0.45, alpha: 0.9)
}

final class GameControlsOverlay: UIView {
    private static let overlayTag = 0xF0110

    private let joystick = CameraJoystickControl()
    private let rightClickButton = UIButton(type: .custom)

    static func install() {
        let windows = UIApplication.shared.windows
        guard let window = windows.first(where: { $0.isKeyWindow && !$0.isHidden })
            ?? windows.first(where: { !$0.isHidden }) else {
            return
        }

        if window.viewWithTag(overlayTag) != nil {
            return
        }

        let overlay = GameControlsOverlay(frame: window.bounds)
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

        rightClickButton.backgroundColor = ControlTheme.panel
        rightClickButton.layer.cornerRadius = 10
        rightClickButton.layer.borderWidth = 1.5
        rightClickButton.layer.borderColor = ControlTheme.green.withAlphaComponent(0.6).cgColor
        rightClickButton.setTitle("LOOT/RMB", for: .normal)
        rightClickButton.setTitleColor(ControlTheme.green, for: .normal)
        rightClickButton.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        rightClickButton.titleLabel?.adjustsFontSizeToFitWidth = true
        rightClickButton.titleLabel?.minimumScaleFactor = 0.7
        rightClickButton.accessibilityLabel = "Loot or right click"
        rightClickButton.addTarget(self, action: #selector(rightClick), for: .touchUpInside)
        addSubview(rightClickButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let insets = safeAreaInsets
        let baseSize = max(92, min(112, bounds.height * 0.26))
        let margin: CGFloat = 16

        joystick.frame = CGRect(
            x: insets.left + margin,
            y: bounds.height - insets.bottom - baseSize - margin,
            width: baseSize,
            height: baseSize
        )

        let buttonSize: CGFloat = 84
        rightClickButton.frame = CGRect(
            x: bounds.width - insets.right - buttonSize - margin,
            y: bounds.height - insets.bottom - buttonSize - margin,
            width: buttonSize,
            height: buttonSize
        )
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

    @objc private func rightClick() {
        fallout_ios_right_click()
        setRightClickActive(true)
        UISelectionFeedbackGenerator().selectionChanged()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.setRightClickActive(false)
        }
    }

    private func setRightClickActive(_ active: Bool) {
        rightClickButton.backgroundColor = active
            ? ControlTheme.amber.withAlphaComponent(0.22)
            : ControlTheme.panel
        rightClickButton.layer.borderColor = active
            ? ControlTheme.amber.cgColor
            : ControlTheme.green.withAlphaComponent(0.6).cgColor
        rightClickButton.setTitleColor(active ? ControlTheme.amber : ControlTheme.green, for: .normal)
    }
}

private final class CameraJoystickControl: UIControl {
    private let ring = CAShapeLayer()
    private let knob = UIView()
    private let crosshair = CAShapeLayer()
    private let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isExclusiveTouch = true

        ring.fillColor = ControlTheme.panel.withAlphaComponent(0.40).cgColor
        ring.strokeColor = ControlTheme.green.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 1.5
        ring.shadowColor = ControlTheme.green.cgColor
        ring.shadowOpacity = 0.20
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        layer.addSublayer(ring)

        crosshair.fillColor = UIColor.clear.cgColor
        crosshair.strokeColor = ControlTheme.green.withAlphaComponent(0.24).cgColor
        crosshair.lineWidth = 1.2
        crosshair.lineCap = .round
        layer.addSublayer(crosshair)

        knob.isUserInteractionEnabled = false
        knob.backgroundColor = ControlTheme.green.withAlphaComponent(0.14)
        knob.layer.borderWidth = 1.5
        knob.layer.borderColor = ControlTheme.green.withAlphaComponent(0.85).cgColor
        knob.layer.shadowColor = ControlTheme.green.cgColor
        knob.layer.shadowOpacity = 0.35
        knob.layer.shadowRadius = 6
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
            self.knob.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
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

/// Plays `intro music.mp3`, bundled with the app, as soon as the launcher
/// appears. Loading a small MP3 directly avoids the delay of decoding an ACM
/// track from the game data first.
final class LauncherMusic {
    static let shared = LauncherMusic()

    private var player: AVAudioPlayer?

    private init() {}

    func playIfAvailable() {
        if let player = player {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        guard let url = Bundle.main.url(forResource: "intro music", withExtension: "mp3") else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.32
            player.play()
            self.player = player
        } catch {
            // The launcher still works without music.
        }
    }

    func stop() {
        player?.stop()
        player = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
