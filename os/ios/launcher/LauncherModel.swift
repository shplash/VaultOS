import Foundation
import UIKit
import Combine

enum FalloutGame: String, CaseIterable, Identifiable {
    case fallout1
    case fallout2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fallout1: return "FALLOUT"
        case .fallout2: return "FALLOUT 2"
        }
    }

    var shortTitle: String {
        switch self {
        case .fallout1: return "F1"
        case .fallout2: return "F2"
        }
    }

    var tagline: String {
        switch self {
        case .fallout1: return "A post-nuclear classic"
        case .fallout2: return "The wasteland continues"
        }
    }

    var installFolder: String {
        switch self {
        case .fallout1: return ""
        case .fallout2: return "Fallout2"
        }
    }

    /// Both engines ship inside this application. Kept so the interface can
    /// describe a game whose data is missing without special cases.
    var supportsLaunch: Bool {
        return true
    }
}

struct DisplayPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
}

/// Owns the launcher state and talks to the C++ install core.
///
/// Both games keep their own installation and configuration, so every option
/// is stored per game as well. The published properties always describe the
/// selected game: switching games saves the outgoing values and loads the
/// incoming ones, which lets Fallout 1 and Fallout 2 run at different
/// resolutions with their own audio, gameplay and touch settings.
final class LauncherModel: ObservableObject {
    @Published var width = 1280 { didSet { store(width, "width") } }
    @Published var height = 720 { didSet { store(height, "height") } }
    @Published var sound = true { didSet { store(sound, "sound") } }
    @Published var music = true { didSet { store(music, "music") } }
    @Published var speech = true { didSet { store(speech, "speech") } }
    @Published var masterVolume: Double = 70 { didSet { store(masterVolume, "masterVolume") } }
    @Published var musicVolume: Double = 70 { didSet { store(musicVolume, "musicVolume") } }
    @Published var sfxVolume: Double = 70 { didSet { store(sfxVolume, "sfxVolume") } }
    @Published var speechVolume: Double = 70 { didSet { store(speechVolume, "speechVolume") } }
    @Published var language = 0 { didSet { store(language, "language") } }
    @Published var subtitles = true { didSet { store(subtitles, "subtitles") } }
    @Published var alwaysRun = false { didSet { store(alwaysRun, "alwaysRun") } }
    @Published var joystickScale: Double = 1 { didSet { store(joystickScale, "joystickScale") } }
    @Published var buttonScale: Double = 1 { didSet { store(buttonScale, "buttonScale") } }
    /// Opacity of the in-game touch controls, 0.15 (barely there) to 1.
    @Published var controlsOpacity: Double = 1 { didSet { store(controlsOpacity, "controlsOpacity") } }
    @Published var leftHanded = false { didSet { store(leftHanded, "leftHanded") } }
    @Published var whiteButtons = false { didSet { store(whiteButtons, "whiteButtons") } }

    /// Every option is written the moment it changes, so settings survive
    /// closing the app from the launcher, not only pressing Play.
    private func store<T>(_ value: T, _ name: String) {
        defaults.set(value, forKey: LauncherModel.optionKey(name, for: selectedGame))
    }

    @Published var selectedGame = FalloutGame.fallout1 {
        didSet {
            guard oldValue != selectedGame else {
                return
            }

            defaults.set(selectedGame.rawValue, forKey: "launcher.game")
            saveSettings(for: oldValue)
            loadSettings(for: selectedGame)
            refreshInstall()
        }
    }

    @Published var install = LauncherInstallInfo()
    @Published private(set) var installedGames: Set<FalloutGame> = []
    @Published var isInstalling = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var showImporter = false
    @Published var savedNotice = false

    private let documentsDirectory: URL
    private var progressTimer: Timer?
    private let defaults = UserDefaults.standard

    var installDirectory: URL {
        return installDirectory(for: selectedGame)
    }

    func installDirectory(for game: FalloutGame) -> URL {
        if game.installFolder.isEmpty {
            return documentsDirectory
        }
        return documentsDirectory.appendingPathComponent(game.installFolder, isDirectory: true)
    }

    /// Shown in each language's own words, so the list can be read whatever the
    /// launcher is currently set to.
    private static let languageNames = ["ENGLISH", "FRANÇAIS", "DEUTSCH", "ITALIANO", "ESPAÑOL"]

    /// A fresh installation starts in the device's language when the launcher
    /// speaks it; the GAME page's own choice overrides it from then on.
    private static let deviceLanguage: Int = {
        for tag in Locale.preferredLanguages {
            switch String(tag.prefix(2)).lowercased() {
            case "fr": return 1
            case "de": return 2
            case "it": return 3
            case "es": return 4
            default: continue
            }
        }
        return 0
    }()

    init() {
        ControlLayout.migrateIfNeeded()
        LauncherModel.migrateSettings()
        LauncherModel.applyDefaultResolution()
        LauncherModel.applyDefaultSubtitles()
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        selectedGame = FalloutGame(rawValue: UserDefaults.standard.string(forKey: "launcher.game") ?? "") ?? .fallout1
        loadSettings(for: selectedGame)
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
        // A pixel or two of slack: a size saved on another screen is still
        // meant to be that preset, so the tile has to read as in use.
        return abs(width - preset.width) <= 2 && abs(height - preset.height) <= 2
    }

    func apply(preset: DisplayPreset) {
        width = preset.width
        height = preset.height
        // Persist immediately so the control overlay can choose the matching
        // FULL/HALF layout even if the editor is closed without tapping Play.
        defaults.set(width, forKey: LauncherModel.optionKey("width", for: selectedGame))
        defaults.set(height, forKey: LauncherModel.optionKey("height", for: selectedGame))
    }

    var languageNames: [String] {
        return LauncherModel.languageNames
    }

    // MARK: - Per-game settings

    private static let settingsVersionKey = "launcher.settingsVersion"
    private static let settingsVersion = 1

    /// Every option the launcher stores for one game.
    private static let optionNames = [
        "width",
        "height",
        "sound",
        "music",
        "speech",
        "masterVolume",
        "musicVolume",
        "sfxVolume",
        "speechVolume",
        "language",
        "subtitles",
        "alwaysRun",
        "joystickScale",
        "buttonScale",
        "controlsOpacity",
        "leftHanded",
        "whiteButtons",
    ]

    /// The defaults key that holds one option of one game. The in-game overlay
    /// reads the same keys, so it always sees the settings of the game it runs.
    static func optionKey(_ name: String, for game: FalloutGame) -> String {
        return "launcher.\(game.rawValue).\(name)"
    }

    private static let displayVersionKey = "launcher.displayVersion"
    private static let displayVersion = 2

    /// Both games start at HALF. Earlier builds defaulted to FULL and could
    /// have any resolution stored, so it is reset once here; a resolution the
    /// player picks afterwards is kept.
    private static func applyDefaultResolution() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: displayVersionKey) < displayVersion else {
            return
        }

        let half = displayResolution(divisor: 3)
        for game in FalloutGame.allCases {
            defaults.set(half.0, forKey: optionKey("width", for: game))
            defaults.set(half.1, forKey: optionKey("height", for: game))
        }
        defaults.set(displayVersion, forKey: displayVersionKey)
    }

    /// Subtitles ship on. Builds before this stored them off, so they are
    /// switched on once here for both games.
    private static let subtitlesVersionKey = "launcher.subtitlesVersion"
    private static let subtitlesVersion = 1

    private static func applyDefaultSubtitles() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: subtitlesVersionKey) < subtitlesVersion else {
            return
        }

        for game in FalloutGame.allCases {
            defaults.set(true, forKey: optionKey("subtitles", for: game))
        }
        defaults.set(subtitlesVersion, forKey: subtitlesVersionKey)
    }

    /// Earlier builds stored a single set of options for the only game the app
    /// had. Those values belong to Fallout 1; Fallout 2 starts from defaults.
    private static func migrateSettings() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: settingsVersionKey) < settingsVersion else {
            return
        }

        for name in optionNames {
            let legacyKey = "launcher.\(name)"
            guard let value = defaults.object(forKey: legacyKey) else {
                continue
            }

            let target = optionKey(name, for: .fallout1)
            if defaults.object(forKey: target) == nil {
                defaults.set(value, forKey: target)
            }
            defaults.removeObject(forKey: legacyKey)
        }

        defaults.removeObject(forKey: "launcher.resolutionVersion")
        defaults.set(settingsVersion, forKey: settingsVersionKey)
    }

    private func loadSettings(for game: FalloutGame) {
        let resolution = LauncherModel.displayResolution(divisor: 3)
        width = storedInt("width", for: game, fallback: resolution.0)
        height = storedInt("height", for: game, fallback: resolution.1)
        sound = storedBool("sound", for: game, fallback: true)
        music = storedBool("music", for: game, fallback: true)
        speech = storedBool("speech", for: game, fallback: true)
        masterVolume = storedDouble("masterVolume", for: game, fallback: 70)
        musicVolume = storedDouble("musicVolume", for: game, fallback: 70)
        sfxVolume = storedDouble("sfxVolume", for: game, fallback: 70)
        speechVolume = storedDouble("speechVolume", for: game, fallback: 70)
        language = storedInt("language", for: game, fallback: LauncherModel.deviceLanguage)
        subtitles = storedBool("subtitles", for: game, fallback: true)
        alwaysRun = storedBool("alwaysRun", for: game, fallback: false)
        joystickScale = storedDouble("joystickScale", for: game, fallback: 1)
        buttonScale = storedDouble("buttonScale", for: game, fallback: 1)
        controlsOpacity = min(max(storedDouble("controlsOpacity", for: game, fallback: 1), 0.15), 1)
        leftHanded = storedBool("leftHanded", for: game, fallback: false)
        whiteButtons = storedBool("whiteButtons", for: game, fallback: false)
    }

    private func saveSettings(for game: FalloutGame) {
        defaults.set(width, forKey: LauncherModel.optionKey("width", for: game))
        defaults.set(height, forKey: LauncherModel.optionKey("height", for: game))
        defaults.set(sound, forKey: LauncherModel.optionKey("sound", for: game))
        defaults.set(music, forKey: LauncherModel.optionKey("music", for: game))
        defaults.set(speech, forKey: LauncherModel.optionKey("speech", for: game))
        defaults.set(masterVolume, forKey: LauncherModel.optionKey("masterVolume", for: game))
        defaults.set(musicVolume, forKey: LauncherModel.optionKey("musicVolume", for: game))
        defaults.set(sfxVolume, forKey: LauncherModel.optionKey("sfxVolume", for: game))
        defaults.set(speechVolume, forKey: LauncherModel.optionKey("speechVolume", for: game))
        defaults.set(language, forKey: LauncherModel.optionKey("language", for: game))
        defaults.set(subtitles, forKey: LauncherModel.optionKey("subtitles", for: game))
        defaults.set(alwaysRun, forKey: LauncherModel.optionKey("alwaysRun", for: game))
        defaults.set(joystickScale, forKey: LauncherModel.optionKey("joystickScale", for: game))
        defaults.set(buttonScale, forKey: LauncherModel.optionKey("buttonScale", for: game))
        defaults.set(controlsOpacity, forKey: LauncherModel.optionKey("controlsOpacity", for: game))
        defaults.set(leftHanded, forKey: LauncherModel.optionKey("leftHanded", for: game))
        defaults.set(whiteButtons, forKey: LauncherModel.optionKey("whiteButtons", for: game))
    }

    private func storedInt(_ name: String, for game: FalloutGame, fallback: Int) -> Int {
        return defaults.object(forKey: LauncherModel.optionKey(name, for: game)) as? Int ?? fallback
    }

    private func storedBool(_ name: String, for game: FalloutGame, fallback: Bool) -> Bool {
        return defaults.object(forKey: LauncherModel.optionKey(name, for: game)) as? Bool ?? fallback
    }

    private func storedDouble(_ name: String, for game: FalloutGame, fallback: Double) -> Double {
        return defaults.object(forKey: LauncherModel.optionKey(name, for: game)) as? Double ?? fallback
    }

    // MARK: - Installation

    func refreshInstall() {
        var info = LauncherInstallInfo()
        launcher_scan(installDirectory.path, Int32(selectedGame == .fallout2 ? LAUNCHER_GAME_FALLOUT2 : LAUNCHER_GAME_FALLOUT1), &info)
        install = info

        var ready: Set<FalloutGame> = []
        for game in FalloutGame.allCases {
            var gameInfo = LauncherInstallInfo()
            launcher_scan(installDirectory(for: game).path,
                          Int32(game == .fallout2 ? LAUNCHER_GAME_FALLOUT2 : LAUNCHER_GAME_FALLOUT1),
                          &gameInfo)
            if gameInfo.installed == 1 {
                ready.insert(game)
            }
        }
        installedGames = ready
    }

    var installRows: [(String, Bool)] {
        switch selectedGame {
        case .fallout1:
            return [
                ("master.dat", install.has_master_dat == 1),
                ("critter.dat", install.has_critter_dat == 1),
                ("data folder", install.has_data_folder == 1),
            ]
        case .fallout2:
            return [
                ("master.dat", install.has_master_dat == 1),
                ("critter.dat", install.has_critter_dat == 1),
                ("patch000.dat", install.has_patch_dat == 1),
                ("data folder", install.has_data_folder == 1),
            ]
        }
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
        raw.game = Int32(selectedGame == .fallout2 ? LAUNCHER_GAME_FALLOUT2 : LAUNCHER_GAME_FALLOUT1)
        return raw
    }

    private func persist() {
        saveSettings(for: selectedGame)
        defaults.set(selectedGame.rawValue, forKey: "launcher.game")
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

    /// Writes the launcher's own settings without touching the game's config,
    /// so a change survives quitting the app without pressing Play.
    func saveSettingsNow() {
        saveSettings(for: selectedGame)
        defaults.set(selectedGame.rawValue, forKey: "launcher.game")
    }
}
