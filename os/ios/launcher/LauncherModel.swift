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
    @Published var scale2x: Bool
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
        installDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let native = LauncherModel.nativeResolution()
        width = defaults.object(forKey: "launcher.width") as? Int ?? native.0
        height = defaults.object(forKey: "launcher.height") as? Int ?? native.1

        scale2x = defaults.bool(forKey: "launcher.scale2x")
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

        refreshInstall()
    }

    // MARK: - Screen size

    /// Logical screen size in points. Tall screens get a 480 pixel high,
    /// aspect-correct resolution, as recommended by the engine's README.
    static func nativeResolution() -> (Int, Int) {
        let bounds = UIScreen.main.bounds
        let longSide = Int(max(bounds.width, bounds.height).rounded())
        let shortSide = Int(min(bounds.width, bounds.height).rounded())
        let aspect = Double(longSide) / Double(max(shortSide, 1))

        if shortSide >= 480 {
            return (max(640, longSide), shortSide)
        }

        let height = 480
        let width = max(640, Int((Double(height) * aspect).rounded()))
        return (width, height)
    }

    var presets: [DisplayPreset] {
        let native = LauncherModel.nativeResolution()
        var list = [
            DisplayPreset(id: "device", label: "DEVICE \(native.0)x\(native.1)", width: native.0, height: native.1),
            DisplayPreset(id: "640", label: "640x480", width: 640, height: 480),
            DisplayPreset(id: "800", label: "800x600", width: 800, height: 600),
            DisplayPreset(id: "1024", label: "1024x768", width: 1024, height: 768),
            DisplayPreset(id: "1280", label: "1280x720", width: 1280, height: 720),
            DisplayPreset(id: "1600", label: "1600x900", width: 1600, height: 900),
            DisplayPreset(id: "1920", label: "1920x1080", width: 1920, height: 1080),
        ]

        var seen = Set<String>()
        list = list.filter { preset in
            let key = "\(preset.width)x\(preset.height)"
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }

        return list
    }

    func selected(preset: DisplayPreset) -> Bool {
        return width == preset.width && height == preset.height
    }

    func apply(preset: DisplayPreset) {
        width = preset.width
        height = preset.height
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
        raw.scale_2x = scale2x ? 1 : 0
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
        defaults.set(scale2x, forKey: "launcher.scale2x")
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
