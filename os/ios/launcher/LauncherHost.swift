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
    private let backButton = UIButton(type: .custom)
    private let speedSlider = UISlider()
    private let speedIcon = UIImageView()
    private var cursorModeTimer: Timer?
    private var cursorModeIcon: String?

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

        configureControlButton(rightClickButton)
        rightClickButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 27, weight: .semibold),
            forImageIn: .normal
        )
        rightClickButton.accessibilityLabel = "Switch cursor mode"
        rightClickButton.addTarget(self, action: #selector(rightClick), for: .touchUpInside)
        addSubview(rightClickButton)

        configureControlButton(backButton)
        backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        backButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold),
            forImageIn: .normal
        )
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        addSubview(backButton)

        let savedSpeed = UserDefaults.standard.object(forKey: "FalloutCursorSpeed") as? Double ?? 1.0
        speedSlider.minimumValue = 0.4
        speedSlider.maximumValue = 2.0
        speedSlider.value = Float(savedSpeed)
        speedSlider.minimumTrackTintColor = ControlTheme.green.withAlphaComponent(0.75)
        speedSlider.maximumTrackTintColor = ControlTheme.dim.withAlphaComponent(0.22)
        speedSlider.thumbTintColor = ControlTheme.green
        speedSlider.isContinuous = true
        speedSlider.addTarget(self, action: #selector(cursorSpeedChanged), for: .valueChanged)
        addSubview(speedSlider)

        speedIcon.image = UIImage(systemName: "speedometer")
        speedIcon.tintColor = ControlTheme.dim
        speedIcon.contentMode = .scaleAspectFit
        speedIcon.isUserInteractionEnabled = false
        addSubview(speedIcon)

        fallout_ios_set_cursor_speed(savedSpeed)
        refreshCursorMode()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshCursorMode()
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
        let joystickScale = CGFloat(defaults.object(forKey: "launcher.joystickScale") as? Double ?? 1.0)
        let buttonScale = CGFloat(defaults.object(forKey: "launcher.buttonScale") as? Double ?? 1.0)
        let leftHanded = defaults.bool(forKey: "launcher.leftHanded")

        let insets = safeAreaInsets
        let baseSize = max(80, min(132, max(92, min(112, bounds.height * 0.26)) * joystickScale))
        let margin: CGFloat = 16
        let bottomY = bounds.height - insets.bottom - margin

        joystick.frame = CGRect(
            x: leftHanded ? bounds.width - insets.right - baseSize - margin : insets.left + margin,
            y: bottomY - baseSize,
            width: baseSize,
            height: baseSize
        )

        let buttonSize = max(60, min(110, 76 * buttonScale))
        rightClickButton.frame = CGRect(
            x: leftHanded ? insets.left + margin : bounds.width - insets.right - buttonSize - margin,
            y: bottomY - buttonSize,
            width: buttonSize,
            height: buttonSize
        )

        let backSize: CGFloat = 44
        backButton.frame = CGRect(
            x: leftHanded ? rightClickButton.frame.maxX + 8 : rightClickButton.frame.minX - 8 - backSize,
            y: bottomY - backSize,
            width: backSize,
            height: backSize
        )

        let sliderWidth: CGFloat = 100
        let sliderHeight: CGFloat = 28
        speedSlider.frame = CGRect(
            x: bounds.width - insets.right - sliderWidth - margin,
            y: bottomY - max(baseSize, buttonSize) - sliderHeight - 10,
            width: sliderWidth,
            height: sliderHeight
        )
        speedIcon.frame = CGRect(
            x: speedSlider.frame.minX - 20,
            y: speedSlider.frame.midY - 8,
            width: 16,
            height: 16
        )
    }

    private func configureControlButton(_ button: UIButton) {
        button.backgroundColor = ControlTheme.panel
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1.5
        button.layer.borderColor = ControlTheme.green.withAlphaComponent(0.6).cgColor
        button.tintColor = ControlTheme.green
        button.imageView?.contentMode = .scaleAspectFit
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

    @objc private func goBack() {
        fallout_ios_back()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func cursorSpeedChanged() {
        let value = Double(speedSlider.value)
        fallout_ios_set_cursor_speed(value)
        UserDefaults.standard.set(value, forKey: "FalloutCursorSpeed")
    }

    private func refreshCursorMode() {
        let mode = fallout_ios_cursor_mode()
        let symbol: String
        let label: String
        switch mode {
        case 0:
            symbol = "arrow.up.and.down.and.arrow.left.and.right"
            label = "Move cursor"
        case 2:
            symbol = "scope"
            label = "Target"
        default:
            symbol = "hand.tap"
            label = "Actions"
        }

        if cursorModeIcon != symbol {
            cursorModeIcon = symbol
            rightClickButton.setImage(UIImage(systemName: symbol), for: .normal)
        }
        rightClickButton.accessibilityLabel = label
    }

    private func setRightClickActive(_ active: Bool) {
        rightClickButton.backgroundColor = active
            ? ControlTheme.amber.withAlphaComponent(0.22)
            : ControlTheme.panel
        rightClickButton.layer.borderColor = active
            ? ControlTheme.amber.cgColor
            : ControlTheme.green.withAlphaComponent(0.6).cgColor
        rightClickButton.tintColor = active ? ControlTheme.amber : ControlTheme.green
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
