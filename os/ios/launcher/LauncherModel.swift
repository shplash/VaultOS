import Foundation
import UIKit
import Combine

struct DisplayPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
}

/// Owns the launcher state and talks to the C++ install core.
final class LauncherModel: ObservableObject {
    @Published var width: Int
    @Published var height: Int
    @Published var sound: Bool
    @Published var music: Bool
    @Published var speech: Bool
    @Published var masterVolume: Double
    @Published var musicVolume: Double
    @Published var sfxVolume: Double
    @Published var speechVolume: Double
    @Published var language: Int
    @Published var subtitles: Bool
    @Published var alwaysRun: Bool
    @Published var joystickScale: Double
    @Published var buttonScale: Double
    @Published var leftHanded: Bool
    @Published var whiteButtons: Bool {
        didSet {
            UserDefaults.standard.set(whiteButtons, forKey: "launcher.whiteButtons")
        }
    }

    @Published var install = LauncherInstallInfo()
    @Published var isInstalling = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var showImporter = false
    @Published var savedNotice = false

    let installDirectory: URL
    private var progressTimer: Timer?
    private let defaults = UserDefaults.standard

    private static let languageNames = ["ENGLISH", "FRENCH", "GERMAN", "ITALIAN", "SPANISH"]

    init() {
        ControlLayout.migrateIfNeeded()
        installDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let native = LauncherModel.nativeResolution()
        // Version 4 defaults to HALF, which scales the interface up. Version 3
        // and earlier defaulted to FULL; migrate those once so the new default
        // is visible without requiring a fresh install.
        let selected: (Int, Int)
        if defaults.integer(forKey: "launcher.resolutionVersion") < 4 {
            selected = LauncherModel.displayResolution(divisor: 3, native: native)
            defaults.set(4, forKey: "launcher.resolutionVersion")
        } else {
            let fallback = LauncherModel.displayResolution(divisor: 3, native: native)
            selected = (
                defaults.object(forKey: "launcher.width") as? Int ?? fallback.0,
                defaults.object(forKey: "launcher.height") as? Int ?? fallback.1
            )
        }
        width = selected.0
        height = selected.1
        defaults.set(selected.0, forKey: "launcher.width")
        defaults.set(selected.1, forKey: "launcher.height")

        sound = defaults.object(forKey: "launcher.sound") as? Bool ?? true
        music = defaults.object(forKey: "launcher.music") as? Bool ?? true
        speech = defaults.object(forKey: "launcher.speech") as? Bool ?? true
        masterVolume = defaults.object(forKey: "launcher.masterVolume") as? Double ?? 70
        musicVolume = defaults.object(forKey: "launcher.musicVolume") as? Double ?? 70
        sfxVolume = defaults.object(forKey: "launcher.sfxVolume") as? Double ?? 70
        speechVolume = defaults.object(forKey: "launcher.speechVolume") as? Double ?? 70
        language = defaults.object(forKey: "launcher.language") as? Int ?? 0
        subtitles = defaults.bool(forKey: "launcher.subtitles")
        alwaysRun = defaults.bool(forKey: "launcher.alwaysRun")
        joystickScale = defaults.object(forKey: "launcher.joystickScale") as? Double ?? 1.0
        buttonScale = defaults.object(forKey: "launcher.buttonScale") as? Double ?? 1.0
        leftHanded = defaults.bool(forKey: "launcher.leftHanded")
        whiteButtons = defaults.bool(forKey: "launcher.whiteButtons")

        refreshInstall()
    }

    // MARK: - Screen size

    /// The screen's real pixel size in landscape. It is the basis for the
    /// FULL/HALF logical sizes, not a game resolution by itself.
    static func nativeResolution() -> (Int, Int) {
        let nativeBounds = UIScreen.main.nativeBounds
        let scale = max(UIScreen.main.nativeScale, 1)
        let pixelWidth = nativeBounds.width > 0 ? nativeBounds.width : UIScreen.main.bounds.width * scale
        let pixelHeight = nativeBounds.height > 0 ? nativeBounds.height : UIScreen.main.bounds.height * scale
        let longSide = Int(max(pixelWidth, pixelHeight).rounded())
        let shortSide = Int(min(pixelWidth, pixelHeight).rounded())

        return (max(640, longSide), max(480, shortSide))
    }

    var nativeResolutionLabel: String {
        let native = LauncherModel.nativeResolution()
        return "\(native.0)x\(native.1)"
    }

    /// Logical game sizes, matched to the screen's aspect ratio. Rendering at
    /// every physical pixel made the world tiny; two pixels per game pixel
    /// keeps the HUD readable and is still sharp on a Retina panel.
    static func displayResolution(divisor: Int, native: (Int, Int)? = nil) -> (Int, Int) {
        let screen = native ?? LauncherModel.nativeResolution()
        let aspect = Double(screen.0) / Double(max(screen.1, 1))

        // Keep FULL and HALF distinct even on shorter screens, where both
        // would otherwise be clamped to the engine's 480 pixel minimum.
        let minimumHeight = divisor == 2 ? 540 : 480
        let height = max(minimumHeight, (screen.1 / divisor) & ~1)
        let width = max(640, min(4096, Int((Double(height) * aspect).rounded()) & ~1))
        return (width, height)
    }

    var presets: [DisplayPreset] {
        let native = LauncherModel.nativeResolution()
        let full = LauncherModel.displayResolution(divisor: 2, native: native)
        let half = LauncherModel.displayResolution(divisor: 3, native: native)

        return [
            DisplayPreset(id: "full", label: "FULL  \(full.0)x\(full.1)", width: full.0, height: full.1),
            DisplayPreset(id: "half", label: "HALF  \(half.0)x\(half.1)", width: half.0, height: half.1),
        ]
    }

    func selected(preset: DisplayPreset) -> Bool {
        return width == preset.width && height == preset.height
    }

    func apply(preset: DisplayPreset) {
        width = preset.width
        height = preset.height
        // Persist immediately so the control overlay can choose the matching
        // FULL/HALF layout even if the editor is closed without tapping Play.
        defaults.set(width, forKey: "launcher.width")
        defaults.set(height, forKey: "launcher.height")
    }

    var languageNames: [String] {
        return LauncherModel.languageNames
    }

    // MARK: - Installation

    func refreshInstall() {
        var info = LauncherInstallInfo()
        launcher_scan(installDirectory.path, &info)
        install = info
    }

    func importZip(from url: URL) {
        guard !isInstalling else {
            return
        }

        let options = makeRawOptions()
        let destination = installDirectory.path
        let accessed = url.startAccessingSecurityScopedResource()

        isInstalling = true
        progress = 0
        statusText = "Opening game archive..."
        errorMessage = nil

        startProgressUpdates()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var raw = options
            let result = launcher_install_zip(url.path, destination, &raw)
            let failure = String(cString: launcher_last_error())

            if accessed {
                url.stopAccessingSecurityScopedResource()
            }

            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }

                self.stopProgressUpdates()
                self.isInstalling = false
                self.refreshInstall()

                if result == 0 {
                    self.progress = 1
                    self.statusText = "Game data installed."
                } else {
                    self.errorMessage = failure.isEmpty ? "Installation failed." : failure
                    self.statusText = ""
                }
            }
        }
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.progress = launcher_progress()
            let status = String(cString: launcher_status())
            if !status.isEmpty {
                self.statusText = status
            }
        }
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Settings

    func makeRawOptions() -> LauncherOptions {
        var raw = LauncherOptions()
        raw.width = Int32(width)
        raw.height = Int32(height)
        raw.scale_2x = 0
        raw.sound = sound ? 1 : 0
        raw.music = music ? 1 : 0
        raw.speech = speech ? 1 : 0
        raw.master_volume = Int32(masterVolume.rounded())
        raw.music_volume = Int32(musicVolume.rounded())
        raw.sfx_volume = Int32(sfxVolume.rounded())
        raw.speech_volume = Int32(speechVolume.rounded())
        raw.subtitles = subtitles ? 1 : 0
        raw.always_run = alwaysRun ? 1 : 0
        raw.language = Int32(language)
        return raw
    }

    private func persist() {
        defaults.set(width, forKey: "launcher.width")
        defaults.set(height, forKey: "launcher.height")
        defaults.set(3, forKey: "launcher.resolutionVersion")
        defaults.set(sound, forKey: "launcher.sound")
        defaults.set(music, forKey: "launcher.music")
        defaults.set(speech, forKey: "launcher.speech")
        defaults.set(masterVolume, forKey: "launcher.masterVolume")
        defaults.set(musicVolume, forKey: "launcher.musicVolume")
        defaults.set(sfxVolume, forKey: "launcher.sfxVolume")
        defaults.set(speechVolume, forKey: "launcher.speechVolume")
        defaults.set(language, forKey: "launcher.language")
        defaults.set(subtitles, forKey: "launcher.subtitles")
        defaults.set(alwaysRun, forKey: "launcher.alwaysRun")
        defaults.set(joystickScale, forKey: "launcher.joystickScale")
        defaults.set(buttonScale, forKey: "launcher.buttonScale")
        defaults.set(leftHanded, forKey: "launcher.leftHanded")
        defaults.set(whiteButtons, forKey: "launcher.whiteButtons")
    }

    @discardableResult
    private func applyOptions() -> Bool {
        var raw = makeRawOptions()
        let result = launcher_write_options(installDirectory.path, &raw)

        if result == 0 {
            persist()
            refreshInstall()
            return true
        }

        let failure = String(cString: launcher_last_error())
        if !failure.isEmpty {
            errorMessage = failure
        }
        return false
    }

    func saveOptions() {
        if applyOptions() {
            statusText = "Settings saved."
            savedNotice = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.savedNotice = false
            }
        }
    }

    func play(onPlay: () -> Void) {
        guard install.installed == 1, !isInstalling else {
            return
        }
        if applyOptions() {
            stopProgressUpdates()
            onPlay()
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}
