import Foundation
import UIKit
import Combine
import SwiftUI

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
}

/// What the file picker was opened for.
enum LauncherImport {
    case game
    case language
    case saves
}

/// The colours the on-screen controls can be drawn in. White is the default for
/// both games, so the controls look the same as the interface they sit on.
enum ControlColour: Int, CaseIterable, Identifiable {
    case white
    case orange
    case green
    case blue

    var id: Int {
        return rawValue
    }

    /// English; the launcher translates it when it shows the menu.
    var title: String {
        switch self {
        case .white: return "White"
        case .orange: return "Orange"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .orange: return UIColor(red: 0.89, green: 0.64, blue: 0.29, alpha: 0.95)
        case .green: return UIColor(red: 0.55, green: 0.96, blue: 0.45, alpha: 0.95)
        case .blue: return UIColor(red: 0.42, green: 0.75, blue: 1.0, alpha: 0.95)
        }
    }

    var color: Color {
        return Color(uiColor)
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
    /// A run is the only way to get anywhere at a decent pace on a phone, and
    /// the touch controls have no Shift to walk with, so running is the default.
    @Published var alwaysRun = true { didSet { store(alwaysRun, "alwaysRun") } }
    @Published var targetHighlight = 1 { didSet { store(targetHighlight, "targetHighlight") } }
    @Published var joystickScale: Double = 1 { didSet { store(joystickScale, "joystickScale") } }
    @Published var buttonScale: Double = 1 { didSet { store(buttonScale, "buttonScale") } }
    /// Opacity of the in-game touch controls, 0.10 (barely there) to 1.
    @Published var controlsOpacity: Double = 1 { didSet { store(controlsOpacity, "controlsOpacity") } }
    /// Whether the touch controls are drawn over the game at all. Off leaves the
    /// whole screen to the game, for a session with a controller in hand.
    @Published var touchControls = true { didSet { store(touchControls, "touchControls") } }
    @Published var autoTarget = true { didSet { store(autoTarget, "autoTarget") } }
    @Published var autoSaveMinutes = 5 { didSet { store(autoSaveMinutes, "autoSaveMinutes") } }
    @Published var saveHaptics = true { didSet { store(saveHaptics, "saveHaptics") } }
    @Published var buttonHaptics = false { didSet { store(buttonHaptics, "buttonHaptics") } }
    /// How the game's finished frame is scaled to the display: 0 sharp, 1 smooth,
    /// 2 enhanced. The in-game presenter reads it every frame, so it applies at
    /// once.
    @Published var imageScaling = 2 { didSet { store(imageScaling, "imageScaling") } }
    /// The frame rate the game is capped to in play: 60 or 30.
    @Published var frameRate = 60 { didSet { store(frameRate, "frameRate") } }
    @Published var shaderVibrant = false { didSet { store(shaderVibrant, "shaderVibrant") } }
    /// The colour of the on-screen controls. White unless the player picks one
    /// of the others; stored per game like every other option.
    @Published var buttonColour = ControlColour.white.rawValue {
        didSet { store(buttonColour, "buttonColour") }
    }

    var controlColour: ControlColour {
        return ControlColour(rawValue: buttonColour) ?? .white
    }

    /// Every option is written the moment it changes, so settings survive
    /// closing the app from the launcher, not only pressing Play.
    private func store<T>(_ value: T, _ name: String) {
        guard settingsLoaded else {
            return
        }

        defaults.set(value, forKey: LauncherModel.optionKey(name, for: selectedGame))
    }

    @Published var selectedGame = FalloutGame.fallout1 {
        didSet {
            guard oldValue != selectedGame else {
                return
            }

            defaults.set(selectedGame.rawValue, forKey: "launcher.game")
            savesNotice = nil
            importSummary = nil

            if settingsLoaded {
                saveSettings(for: oldValue)
                refreshInstall()
            }

            loadSettings(for: selectedGame)
        }
    }

    @Published var install = LauncherInstallInfo()
    @Published private(set) var installInfos: [FalloutGame: LauncherInstallInfo] = [:]
    @Published private(set) var installedGames: Set<FalloutGame> = []
    @Published var isInstalling = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var errorMessage: String?
    /// Whether the ZIP picker is open. What it was opened for lives in the
    /// launcher view, so the picker's own dismissal cannot clear the intent
    /// before the chosen file arrives.
    @Published var showImporter = false

    private let documentsDirectory: URL
    private var progressTimer: Timer?
    private let defaults = UserDefaults.standard
    private var settingsLoaded = false

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
        LauncherModel.applyDefaultAutoTarget()
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        LauncherModel.prepareInstallFolders(documents: documentsDirectory)
        selectedGame = FalloutGame(rawValue: UserDefaults.standard.string(forKey: "launcher.game") ?? "") ?? .fallout1
        loadSettings(for: selectedGame)
        settingsLoaded = true
        refreshInstall()
    }

    /// Creates both installation folders and leaves a note in each. iOS only
    /// lists an app in the Files app once its Documents folder holds something,
    /// and a fresh installation holds nothing at all until a game has run - so
    /// the folder that should have been used for copying game files in by hand
    /// was not there to use. The notes say what belongs in each.
    private static func prepareInstallFolders(documents: URL) {
        let manager = FileManager.default
        let folders = [
            documents,
            documents.appendingPathComponent("Fallout2", isDirectory: true),
        ]
        let games = ["Fallout", "Fallout 2"]
        let files = [
            "master.dat, critter.dat and the data folder",
            "master.dat, critter.dat, patch000.dat and the data folder",
        ]

        for (index, folder) in folders.enumerated() {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

            let note = folder.appendingPathComponent("PUT GAME FILES HERE.txt")
            guard !manager.fileExists(atPath: note.path) else {
                continue
            }

            let text = "VaultOS - \(games[index])\n\n"
                + "Copy \(files[index]) into this folder, or import a game ZIP from the launcher's HOME page.\n"
            try? text.write(to: note, atomically: true, encoding: .utf8)
        }
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

    /// The preset the launcher starts on: the one nearer the screen's own
    /// points, its pixels divided by its native scale. The game draws its
    /// 640-wide interface at the game's resolution, so matching points is what
    /// keeps that interface at about iOS's text sizes. On a 3x phone FULL is
    /// already smaller than iOS draws and HALF is nearer, while a 2x tablet
    /// draws FULL at exactly its points and HALF a third larger.
    static func defaultPresetId() -> String {
        let native = LauncherModel.nativeResolution()
        let scale = max(Double(UIScreen.main.nativeScale), 1)
        let pointsHeight = Double(native.1) / scale
        let full = displayResolution(divisor: 2, native: native)
        let half = displayResolution(divisor: 3, native: native)

        return abs(Double(full.1) - pointsHeight) <= abs(Double(half.1) - pointsHeight)
            ? "full"
            : "half"
    }

    /// The size to start on, and the one RESET returns to.
    static func defaultResolution() -> (Int, Int) {
        return displayResolution(divisor: defaultPresetId() == "full" ? 2 : 3)
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

    /// The size stored for a game. The launcher only plays at FULL or HALF, and
    /// anything else - a custom size from an earlier build, or one saved on
    /// another screen - becomes the preset this screen starts on.
    private func storedResolution(for game: FalloutGame) -> (Int, Int) {
        let fallback = LauncherModel.defaultResolution()
        let storedWidth = storedInt("width", for: game, fallback: fallback.0)
        let storedHeight = storedInt("height", for: game, fallback: fallback.1)

        let presets = self.presets
        let preset = presets.first {
            abs($0.width - storedWidth) <= 2 && abs($0.height - storedHeight) <= 2
        } ?? startingPreset

        return (preset.width, preset.height)
    }

    /// The tile the launcher starts on for this screen.
    var startingPreset: DisplayPreset {
        let id = LauncherModel.defaultPresetId()
        return presets.first { $0.id == id } ?? presets[presets.count - 1]
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
        "targetHighlight",
        "joystickScale",
        "buttonScale",
        "controlsOpacity",
        "touchControls",
        "autoTarget",
        "autoSaveMinutes",
        "saveHaptics",
        "buttonHaptics",
        "imageScaling",
        "frameRate",
        "shaderVibrant",
        "buttonColour",
    ]

    /// The defaults key that holds one option of one game. The in-game overlay
    /// reads the same keys, so it always sees the settings of the game it runs.
    static func optionKey(_ name: String, for game: FalloutGame) -> String {
        return "launcher.\(game.rawValue).\(name)"
    }

    private static let displayVersionKey = "launcher.displayVersion"
    private static let displayVersion = 3

    /// Both games start at the preset that matches this screen's points, so a
    /// phone starts at HALF and a tablet at FULL. Earlier builds started every
    /// device at HALF, or at FULL before that, and could have any resolution
    /// stored, so it is reset once here; a preset the player picks afterwards
    /// is kept.
    private static func applyDefaultResolution() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: displayVersionKey) < displayVersion else {
            return
        }

        let start = defaultResolution()
        for game in FalloutGame.allCases {
            defaults.set(start.0, forKey: optionKey("width", for: game))
            defaults.set(start.1, forKey: optionKey("height", for: game))
        }
        defaults.set(displayVersion, forKey: displayVersionKey)
    }

    /// Subtitles ship on. Builds before this stored them off, so they are
    /// switched on once here for both games; the version is raised when an
    /// earlier build left the switch off, which puts an existing install back
    /// on subtitles as well.
    private static let subtitlesVersionKey = "launcher.subtitlesVersion"
    private static let subtitlesVersion = 2

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

    /// Auto target ships on. Builds before this stored it off by default, so it
    /// is switched on once here for both games.
    private static let autoTargetVersionKey = "launcher.autoTargetVersion"
    private static let autoTargetVersion = 1

    private static func applyDefaultAutoTarget() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: autoTargetVersionKey) < autoTargetVersion else {
            return
        }

        for game in FalloutGame.allCases {
            defaults.set(true, forKey: optionKey("autoTarget", for: game))
        }
        defaults.set(autoTargetVersion, forKey: autoTargetVersionKey)
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
        (width, height) = storedResolution(for: game)
        sound = storedBool("sound", for: game, fallback: true)
        music = storedBool("music", for: game, fallback: true)
        speech = storedBool("speech", for: game, fallback: true)
        masterVolume = storedDouble("masterVolume", for: game, fallback: 70)
        musicVolume = storedDouble("musicVolume", for: game, fallback: 70)
        sfxVolume = storedDouble("sfxVolume", for: game, fallback: 70)
        speechVolume = storedDouble("speechVolume", for: game, fallback: 70)
        language = storedInt("language", for: game, fallback: LauncherModel.deviceLanguage)
        subtitles = storedBool("subtitles", for: game, fallback: true)
        alwaysRun = storedBool("alwaysRun", for: game, fallback: true)
        targetHighlight = min(max(storedInt("targetHighlight", for: game, fallback: 1), 0), 2)
        joystickScale = storedDouble("joystickScale", for: game, fallback: 1)
        buttonScale = storedDouble("buttonScale", for: game, fallback: 1)
        controlsOpacity = min(max(storedDouble("controlsOpacity", for: game, fallback: 1), 0.10), 1)
        touchControls = storedBool("touchControls", for: game, fallback: true)
        autoTarget = storedBool("autoTarget", for: game, fallback: true)
        autoSaveMinutes = min(max(storedInt("autoSaveMinutes", for: game, fallback: 5), 0), 10)
        saveHaptics = storedBool("saveHaptics", for: game, fallback: true)
        buttonHaptics = storedBool("buttonHaptics", for: game, fallback: false)
        imageScaling = min(max(storedInt("imageScaling", for: game, fallback: 2), 0), 2)
        frameRate = storedInt("frameRate", for: game, fallback: 60) == 30 ? 30 : 60
        shaderVibrant = storedBool("shaderVibrant", for: game, fallback: false)
        buttonColour = storedInt("buttonColour", for: game, fallback: ControlColour.white.rawValue)
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
        defaults.set(targetHighlight, forKey: LauncherModel.optionKey("targetHighlight", for: game))
        defaults.set(joystickScale, forKey: LauncherModel.optionKey("joystickScale", for: game))
        defaults.set(buttonScale, forKey: LauncherModel.optionKey("buttonScale", for: game))
        defaults.set(controlsOpacity, forKey: LauncherModel.optionKey("controlsOpacity", for: game))
        defaults.set(touchControls, forKey: LauncherModel.optionKey("touchControls", for: game))
        defaults.set(autoTarget, forKey: LauncherModel.optionKey("autoTarget", for: game))
        defaults.set(autoSaveMinutes, forKey: LauncherModel.optionKey("autoSaveMinutes", for: game))
        defaults.set(saveHaptics, forKey: LauncherModel.optionKey("saveHaptics", for: game))
        defaults.set(buttonHaptics, forKey: LauncherModel.optionKey("buttonHaptics", for: game))
        defaults.set(imageScaling, forKey: LauncherModel.optionKey("imageScaling", for: game))
        defaults.set(frameRate, forKey: LauncherModel.optionKey("frameRate", for: game))
        defaults.set(shaderVibrant, forKey: LauncherModel.optionKey("shaderVibrant", for: game))
        defaults.set(buttonColour, forKey: LauncherModel.optionKey("buttonColour", for: game))
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
        var snapshots: [FalloutGame: LauncherInstallInfo] = [:]
        for game in FalloutGame.allCases {
            var gameInfo = LauncherInstallInfo()
            launcher_scan(installDirectory(for: game).path,
                          Int32(game == .fallout2 ? LAUNCHER_GAME_FALLOUT2 : LAUNCHER_GAME_FALLOUT1),
                          &gameInfo)
            snapshots[game] = gameInfo
            if gameInfo.installed == 1 {
                ready.insert(game)
            }
        }
        installInfos = snapshots
        installedGames = ready
    }

    var installRows: [(String, Bool)] {
        return installRows(for: selectedGame, info: install)
    }

    func installRows(for game: FalloutGame, info: LauncherInstallInfo) -> [(String, Bool)] {
        switch game {
        case .fallout1:
            return [
                ("master.dat", info.has_master_dat == 1),
                ("critter.dat", info.has_critter_dat == 1),
                ("data folder", info.has_data_folder == 1),
            ]
        case .fallout2:
            return [
                ("master.dat", info.has_master_dat == 1),
                ("critter.dat", info.has_critter_dat == 1),
                ("patch000.dat", info.has_patch_dat == 1),
                ("data folder", info.has_data_folder == 1),
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
        LauncherLog.write("import game: \(url.path) scope: \(accessed) readable: \(FileManager.default.isReadableFile(atPath: url.path))")

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

            LauncherModel.discardTemporaryCopy(of: url)

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

    /// Adds a translation pack to the selected game's installation: the game's
    /// own text tree, which the engine reads from `data` before the archive.
    func importLanguagePack(from url: URL) {
        guard !isInstalling else {
            return
        }

        let destination = installDirectory.path
        let accessed = url.startAccessingSecurityScopedResource()
        LauncherLog.write("import language: \(url.path) scope: \(accessed) readable: \(FileManager.default.isReadableFile(atPath: url.path))")

        isInstalling = true
        progress = 0
        statusText = "Opening language pack..."
        errorMessage = nil

        startProgressUpdates()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var languages: Int32 = 0
            let result = launcher_install_language_pack(url.path, destination, &languages)
            let failure = String(cString: launcher_last_error())

            if accessed {
                url.stopAccessingSecurityScopedResource()
            }

            LauncherModel.discardTemporaryCopy(of: url)

            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }

                self.stopProgressUpdates()
                self.isInstalling = false
                self.refreshInstall()

                if result == 0 {
                    self.progress = 1
                    self.statusText = "Language files added."
                    self.selectInstalledLanguage(mask: languages)
                    self.importSummary = LauncherModel.languagePackSummary(language: self.language)
                } else {
                    self.errorMessage = failure.isEmpty ? "Installation failed." : failure
                    self.statusText = ""
                }
            }
        }
    }

    /// Picks the language the pack carried: the one already selected when it is
    /// in the pack, otherwise the only language the pack has, otherwise the
    /// device's own when the pack has that too. A pack holding several leaves
    /// the choice alone.
    private func selectInstalledLanguage(mask: Int32) {
        guard mask != 0 else {
            return
        }

        func has(_ index: Int) -> Bool {
            let bit = Int32(1) << Int32(index)
            return mask & bit != 0
        }

        if has(language) {
            return
        }

        let carried = [0, 1, 2, 3, 4].filter { has($0) }
        if carried.count == 1 {
            language = carried[0]
        } else if has(LauncherModel.deviceLanguage) {
            language = LauncherModel.deviceLanguage
        }
    }

    /// A confirmation that takes the Savegames subtitle's place while it lasts,
    /// kept until the page or the game changes.
    @Published var savesNotice: String?

    @Published var importSummary: String?

    /// The backup just written, offered to the share sheet so a copy can be
    /// dropped into Files, iCloud or anywhere else that takes a file.
    @Published var shareFile: URL?

    /// Zips this game's SAVEGAME folder into a file beside the game data, so it
    /// can be copied out of the app, kept, or brought back later.
    func backupSaves() {
        guard !isInstalling, install.has_saves == 1 else {
            return
        }

        let destination = installDirectory.path
        // The archive is named after the game, so a Fallout and a Fallout 2
        // backup are told apart at a glance in the Files app.
        let game = Int32(selectedGame == .fallout2 ? LAUNCHER_GAME_FALLOUT2 : LAUNCHER_GAME_FALLOUT1)

        isInstalling = true
        errorMessage = nil
        savesNotice = nil
        statusText = "Backing up saves..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var path = [CChar](repeating: 0, count: 1024)
            let result = launcher_backup_saves(destination, game, &path, Int32(path.count))
            let failure = String(cString: launcher_last_error())

            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }

                self.isInstalling = false
                self.statusText = ""

                if result == 0 {
                    self.notice("Saves backed up.")

                    let created = String(cString: path)
                    if !created.isEmpty {
                        self.shareFile = URL(fileURLWithPath: created)
                    }
                } else {
                    self.errorMessage = failure.isEmpty ? "Installation failed." : failure
                }
            }
        }
    }

    /// Replaces this game's savegames with the ones in a backup the player picks.
    func importSaves(from url: URL) {
        guard !isInstalling else {
            return
        }

        let destination = installDirectory.path
        let accessed = url.startAccessingSecurityScopedResource()
        LauncherLog.write("import saves: \(url.path) scope: \(accessed) readable: \(FileManager.default.isReadableFile(atPath: url.path))")

        isInstalling = true
        errorMessage = nil
        savesNotice = nil
        statusText = "Restoring saves..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = launcher_import_saves(url.path, destination)
            let failure = String(cString: launcher_last_error())

            if accessed {
                url.stopAccessingSecurityScopedResource()
            }

            LauncherModel.discardTemporaryCopy(of: url)

            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }

                self.isInstalling = false
                self.statusText = ""
                self.refreshInstall()

                if result == 0 {
                    self.notice("Saves restored.")
                } else {
                    self.errorMessage = failure.isEmpty ? "Installation failed." : failure
                }
            }
        }
    }

    private static func discardTemporaryCopy(of url: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        guard path != temporary, path.hasPrefix(temporary + "/") else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            LauncherLog.write("removed the picker's copy of \(url.lastPathComponent)")
        } catch {
            LauncherLog.write("could not remove the picker's copy of \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func notice(_ text: String) {
        savesNotice = text
    }

    private static func languagePackSummary(language: Int) -> String {
        let names = LauncherModel.languageNames
        let name = names.indices.contains(language) ? names[language] : "ENGLISH"
        let bytes = launcher_language_pack_bytes(Int32(language))
        let largest = max(launcher_language_pack_largest(), bytes)

        let actual = String(format: "%.1f", Double(bytes) / 1_000_000)
        let full = String(format: "%.1f", Double(largest) / 1_000_000)

        var line = L.t("Text in the pack: {size} MB. A full language is about {full} MB.")
        line = line.replacingOccurrences(of: "{size}", with: actual)
        line = line.replacingOccurrences(of: "{full}", with: full)

        let share = largest > 0 ? Double(bytes) / Double(largest) : 0
        let verdict: String
        if share >= 0.75 {
            verdict = "Looks like a complete language pack."
        } else if share >= 0.35 {
            verdict = "Only part of a language pack: some text will stay English."
        } else {
            verdict = "Very little text in this pack: most of it will stay English."
        }

        return name + " — " + line + "\n" + L.t(verdict)
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
        raw.target_highlight = Int32(targetHighlight)
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

    /// A save on disk, as the launcher shows it.
    struct LauncherSave: Identifiable {
        let id: Int
        let slot: Int
        let name: String
        let detail: String
        let saved: String
        let played: String
        let level: Int
        let preview: URL?
        let modified: Date
    }

    @Published var saves: [LauncherSave] = []

    /// The folder the saves were looked in, shown while the list bedded in.
    @Published var savesFolder = ""

    /// The save the launcher asked the engine to load, once Play is pressed.
    var launchSlot: Int?

    func refreshSaves() {
        saves = LauncherModel.readSaves(installDirectory: installDirectory, game: selectedGame)

        let folder = LauncherModel.saveFolder(installDirectory: installDirectory, game: selectedGame)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        savesFolder = "\(folder?.path.replacingOccurrences(of: documents, with: "") ?? "no SAVEGAME") · \(saves.count)"
    }

    func delete(save: LauncherSave) {
        if let root = LauncherModel.saveFolder(installDirectory: installDirectory, game: selectedGame) {
            let folder = root.appendingPathComponent(String(format: "SLOT%02d", save.slot), isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
        }
        refreshSaves()
    }

    /// The folder the game writes its saves into. The game can leave an empty
    /// SAVEGAME folder behind - it creates one where its data folder points
    /// and can write the slots into another - so the folder actually holding
    /// slots is the one to read, and a folder the short list does not spell is
    /// found by its name instead.
    private static func saveFolder(installDirectory: URL, game: FalloutGame) -> URL? {
        let known = ["data/SAVEGAME", "SAVEGAME", "data/savegame", "savegame"]
            .map { installDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if let folder = known.first(where: { hasSlots(in: $0) }) {
            return folder
        }

        if let folder = known.first {
            return folder
        }

        return folders(in: installDirectory, depth: 2).first {
            $0.lastPathComponent.caseInsensitiveCompare("SAVEGAME") == .orderedSame
                && hasSlots(in: $0)
        }
    }

    private static func hasSlots(in folder: URL) -> Bool {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])

        return (entries ?? []).contains { $0.lastPathComponent.uppercased().hasPrefix("SLOT") }
    }

    /// The folders inside one, down to a depth and no further: the game's data
    /// folder holds hundreds of files, and nothing below this holds saves.
    private static func folders(in directory: URL, depth: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            result.append(url)

            if enumerator.level >= depth {
                enumerator.skipDescendants()
            }
        }

        return result
    }

    private static func readSaves(installDirectory: URL, game: FalloutGame) -> [LauncherSave] {
        guard let root = saveFolder(installDirectory: installDirectory, game: game),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return []
        }

        var result: [LauncherSave] = []
        for entry in entries {
            let folder = entry.lastPathComponent.uppercased()
            guard folder.hasPrefix("SLOT"), let slot = Int(folder.dropFirst(4)) else {
                continue
            }

            let file = (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?.first {
                $0.lastPathComponent.uppercased() == "SAVE.DAT"
            }
            let data = file.flatMap { try? Data(contentsOf: $0) } ?? Data()

            let name = readString(data, at: 29, length: 32)
            let description = readString(data, at: 61, length: 30)
            let gameMonth = readShort(data, at: 101)
            let gameDay = readShort(data, at: 103)
            let gameYear = readShort(data, at: 105)
            let gameTime = readInt(data, at: 107)
            let minutes = (gameTime / 600) % 60
            let hours = (gameTime / 600) / 60 % 24
            let saved = String(format: "%02d.%02d.%04d  %02d:%02d", gameDay, gameMonth, gameYear, hours, minutes)
            let sidecar = readSidecar(entry)
            let played = sidecar.played
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

            let previewFile = entry.appendingPathComponent("preview.bmp")
            let preview = FileManager.default.fileExists(atPath: previewFile.path) ? previewFile : nil

            result.append(LauncherSave(id: slot,
                                       slot: slot,
                                       name: name,
                                       detail: description.isEmpty ? L.t("Saved game") : description,
                                       saved: saved,
                                       played: played,
                                       level: sidecar.level,
                                       preview: preview,
                                       modified: modified))
        }

        return result.sorted { $0.modified > $1.modified }
    }

    private static func readString(_ data: Data, at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= data.count else {
            return ""
        }

        let bytes = [UInt8](data[offset ..< offset + length])
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readShort(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else {
            return 0
        }

        let low = UInt16(data[offset])
        let high = UInt16(data[offset + 1]) << 8
        return Int(low | high)
    }

    private static func readInt(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else {
            return 0
        }

        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Int(value)
    }

    private static func readSidecar(_ folder: URL) -> (played: String, level: Int) {
        let file = folder.appendingPathComponent("VaultOS.json")
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            return ("0:00", 0)
        }

        let seconds = number(in: text, key: "playSeconds")
        return (String(format: "%d:%02d", seconds / 3600, seconds / 60 % 60), number(in: text, key: "level"))
    }

    private static func number(in text: String, key: String) -> Int {
        guard let anchor = text.range(of: "\"\(key)\"") else {
            return 0
        }

        var seenColon = false
        var digits = ""
        for character in text[anchor.upperBound...] {
            if !seenColon {
                if character == ":" {
                    seenColon = true
                } else if !character.isWhitespace {
                    return 0
                }
                continue
            }

            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }

        return Int(digits) ?? 0
    }

    func play(onPlay: () -> Void) {
        play(onPlay: onPlay, loadSlot: nil)
    }

    func play(onPlay: () -> Void, loadSlot: Int?) {
        guard install.installed == 1, !isInstalling else {
            return
        }
        launchSlot = loadSlot
        importSummary = nil
        if applyOptions() {
            stopProgressUpdates()
            onPlay()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func resetEverything() {
        for game in FalloutGame.allCases {
            for name in LauncherModel.optionNames {
                defaults.removeObject(forKey: LauncherModel.optionKey(name, for: game))
            }
        }

        loadSettings(for: selectedGame)
        saveSettings(for: selectedGame)
    }

    /// Writes the launcher's own settings without touching the game's config,
    /// so a change survives quitting the app without pressing Play.
    func saveSettingsNow() {
        saveSettings(for: selectedGame)
        defaults.set(selectedGame.rawValue, forKey: "launcher.game")
    }
}
