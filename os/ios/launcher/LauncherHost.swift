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
    private let actionButton = LabeledControlButton(
        title: "MOVE",
        symbol: "arrow.up.and.down.and.arrow.left.and.right",
        iconPointSize: 27
    )
    private let backButton = LabeledControlButton(
        title: "BACK",
        symbol: "chevron.backward",
        iconPointSize: 18
    )
    private let skipButton = LabeledControlButton(
        title: "SKIP",
        symbol: "forward.end",
        iconPointSize: 20,
        accent: true
    )
    private var sideButtons: [LabeledControlButton] = []
    private var cursorModeIcon: String?
    private var cursorModeTitle: String?
    private var cursorModeTimer: Timer?

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

        actionButton.accessibilityLabel = "Move cursor"
        actionButton.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        addSubview(actionButton)

        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        addSubview(backButton)

        let sideActions = [
            ("INV", "bag"),
            ("MAP", "map"),
            ("CHA", "person"),
            ("PIP", "book.closed"),
            ("SKILL", "star"),
            ("END", "xmark"),
        ]
        for (index, item) in sideActions.enumerated() {
            let button = LabeledControlButton(
                title: item.0,
                symbol: item.1,
                iconPointSize: 15
            )
            button.tag = index
            button.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
            sideButtons.append(button)
            addSubview(button)
        }

        skipButton.tag = 6
        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(sideActionPressed(_:)), for: .touchUpInside)
        addSubview(skipButton)

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
        let joystickScale = CGFloat(defaults.object(forKey: "launcher.joystickScale") as? Double ?? 1.0)
        let buttonScale = CGFloat(defaults.object(forKey: "launcher.buttonScale") as? Double ?? 1.0)
        let leftHanded = defaults.bool(forKey: "launcher.leftHanded")

        var gameWidthValue: Int32 = 0
        var gameHeightValue: Int32 = 0
        fallout_ios_screen_size(&gameWidthValue, &gameHeightValue)
        let gameWidth = CGFloat(max(Int(gameWidthValue), 640))
        let gameHeight = CGFloat(max(Int(gameHeightValue), 480))
        let hudWidth = min(bounds.width, bounds.width * 640.0 / gameWidth)
        let hudHeight = min(bounds.height, bounds.height * 100.0 / gameHeight)
        let hudLeft = (bounds.width - hudWidth) / 2
        let hudRight = hudLeft + hudWidth
        let hudTop = bounds.height - hudHeight

        let insets = safeAreaInsets
        let margin: CGFloat = 14
        let bottomY = bounds.height - insets.bottom - margin
        let joystickSize = max(80, min(132, max(92, min(112, bounds.height * 0.26)) * joystickScale))
        joystick.frame = CGRect(
            x: leftHanded ? bounds.width - insets.right - joystickSize - margin : insets.left + margin,
            y: bottomY - joystickSize,
            width: joystickSize,
            height: joystickSize
        )

        let backSize = max(44, min(56, joystickSize * 0.48))
        backButton.frame = CGRect(
            x: leftHanded ? joystick.frame.minX - 8 - backSize : joystick.frame.maxX + 8,
            y: joystick.frame.midY - backSize / 2,
            width: backSize,
            height: backSize
        )

        let actionSize = max(66, min(92, 76 * buttonScale))
        let actionX = leftHanded ? hudLeft + 10 : hudRight - actionSize - 10
        actionButton.frame = CGRect(
            x: actionX,
            y: max(insets.top + 8, hudTop - actionSize - 10),
            width: actionSize,
            height: actionSize
        )

        let skipSize = max(54, min(72, 62 * buttonScale))
        skipButton.frame = CGRect(
            x: leftHanded ? actionButton.frame.maxX + 8 : actionButton.frame.minX - 8 - skipSize,
            y: actionButton.frame.midY - skipSize / 2,
            width: skipSize,
            height: skipSize
        )

        let gap: CGFloat = 3
        let sideSpace = leftHanded ? hudLeft - insets.left - 8 : bounds.width - insets.right - hudRight - 8
        let sideSize = max(24, min(44,
            (sideSpace - gap * 5) / 6,
            hudHeight - 6
        ))
        let rowWidth = sideSize * 6 + gap * 5
        let rowX = leftHanded ? insets.left + 4 : bounds.width - insets.right - 4 - rowWidth
        let rowY = min(
            hudTop + max(2, (hudHeight - sideSize) / 2),
            bounds.height - insets.bottom - sideSize - 2
        )

        for (index, button) in sideButtons.enumerated() {
            button.frame = CGRect(
                x: rowX + CGFloat(index) * (sideSize + gap),
                y: rowY,
                width: sideSize,
                height: sideSize
            )
        }
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
        actionButton.setActive(true)
        UISelectionFeedbackGenerator().selectionChanged()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.actionButton.setActive(false)
        }
    }

    @objc private func goBack() {
        fallout_ios_back()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func sideActionPressed(_ sender: LabeledControlButton) {
        fallout_ios_press_action(Int32(sender.tag))
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func refreshControls() {
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
        skipButton.isHidden = fallout_ios_action_available(6) == 0
    }
}

private final class LabeledControlButton: UIControl {
    private let iconView = UIImageView()
    private let label = UILabel()
    private let iconPointSize: CGFloat
    private let accent: Bool

    init(title: String, symbol: String, iconPointSize: CGFloat, accent: Bool = false) {
        self.iconPointSize = iconPointSize
        self.accent = accent
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

    func set(symbol: String, title: String) {
        iconView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .semibold)
        )
        label.text = title
        accessibilityLabel = title
    }

    func setActive(_ active: Bool) {
        let color = active ? ControlTheme.amber : (accent ? ControlTheme.amber : ControlTheme.green)
        backgroundColor = active
            ? ControlTheme.amber.withAlphaComponent(0.22)
            : ControlTheme.panel
        layer.borderColor = color.withAlphaComponent(active ? 1.0 : 0.6).cgColor
        tintColor = color
        label.textColor = color
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.35
        }
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? (accent ? ControlTheme.amber : ControlTheme.green).withAlphaComponent(0.16)
                : ControlTheme.panel
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let labelHeight = max(9, min(11, bounds.height * 0.22))
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
        label.font = UIFont.monospacedSystemFont(
            ofSize: max(8, min(10, bounds.height * 0.19)),
            weight: .bold
        )
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
