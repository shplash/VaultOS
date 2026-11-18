import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The launcher is one fixed window: a rail of pages down the left, the selected
// page as a single sheet of rows to its right, and Play always at the bottom of
// the rail. Nothing scrolls, because a scroll view inside the engine's nested
// run loop was what kept hanging the launcher.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void

    @State private var page: LauncherPage = .home
    @State private var showControlEditor = false
    @State private var tipGroup: TipGroup = .touch
    @State private var musicMuted = LauncherMusic.isMuted
    /// What the ZIP picker is being opened for.
    @State private var pendingImport: LauncherImport = .game
    @State private var showSaveImportWarning = false
    @State private var saveImportCountdown = 0

    private var accent: Color {
        return model.selectedGame.accent
    }

    /// The launcher is drawn for the space it is given and never scrolls, so
    /// below this size it would have to clip a page to fit. Scaling the whole
    /// launcher instead keeps every control reachable on a window this small,
    /// and leaves it untouched at the size of a phone or tablet.
    private static let smallestLayout = CGSize(width: 560, height: 320)

    /// What the display keeps for the sensor housing and the home indicator. The
    /// launcher draws edge to edge and keeps its content inside these, so it
    /// fills the screen on every device rather than leaving bands around itself.
    private var screenInsets: EdgeInsets {
        let insets = LauncherHost.safeInsets
        return EdgeInsets(top: insets.top,
                          leading: insets.left,
                          bottom: insets.bottom,
                          trailing: insets.right)
    }

    var body: some View {
        GeometryReader { geometry in
            let fits = geometry.size.width > 1 && geometry.size.height > 1
            let scale = fits
                ? min(1, min(geometry.size.width / LauncherView.smallestLayout.width,
                             geometry.size.height / LauncherView.smallestLayout.height))
                : 1

            ZStack {
                LauncherBackdrop(accent: accent)

                HStack(spacing: 0) {
                    rail(leading: screenInsets.leading, bottom: screenInsets.bottom)
                    content
                }
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale)
            }
        }
        // The launcher is the app's own screen, like the game after it: it covers
        // the whole display and keeps its content inside the edges. Leaving the
        // safe area to SwiftUI instead shrank the launcher into a box with black
        // bands around it on every device with a cut-out.
        .ignoresSafeArea()
        .overlay(
            Group {
                if showSaveImportWarning {
                    saveImportWarning
                }
            }
        )
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showControlEditor) {
            TouchControlEditor(model: model)
        }
        .onAppear {
            model.refreshInstall()
            if !musicMuted {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .onDisappear {
            model.saveSettingsNow()
        }
        .onChange(of: model.install.installed) { installed in
            if installed == 1 {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if showSaveImportWarning && saveImportCountdown > 0 {
                saveImportCountdown -= 1
            }
        }
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            // What the picker was opened for, read after it closes: one picker
            // serves both, because two of them in the same view fight over the
            // presentation.
            let kind = pendingImport

            switch result {
            case .success(let urls):
                // The picker is single-selection, because one file is one
                // archive. Should it ever hand back more than one, only the
                // first is used: two imports must never run over the same
                // folder at once, and the extra file is simply ignored.
                guard let url = urls.first else {
                    return
                }
                switch kind {
                case .game:
                    model.importZip(from: url)
                case .language:
                    model.importLanguagePack(from: url)
                case .saves:
                    model.importSaves(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .alert(
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { shown in
                    if !shown {
                        model.dismissError()
                    }
                }
            )
        ) {
            Alert(
                title: Text(model.selectedGame.title),
                message: Text(L.t(model.errorMessage ?? "")),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Rail

    private func rail(leading: CGFloat, bottom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(FalloutGame.allCases) { game in
                        gameTab(game)
                    }
                }
            }
            .padding(.bottom, 8)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
                .padding(.bottom, 7)

            ForEach(LauncherPage.allCases) { item in
                railItem(item)
            }

            Spacer(minLength: 6)

            playButton
        }
        .padding(.leading, 10 + leading)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 14 + bottom)
        .frame(width: 168 + leading, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private func railItem(_ item: LauncherPage) -> some View {
        let selected = page == item

        return Button {
            page = item
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(selected ? accent : Color.clear)
                    .frame(width: 3, height: 15)

                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15, alignment: .leading)

                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .kerning(0.6)

                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? Theme.text : Theme.faint)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        Button {
            LauncherMusic.shared.stop()
            model.play(onPlay: onPlay)
        } label: {
            VStack(spacing: 3) {
                Text(L.t("PLAY"))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))

                Text(statusText)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundColor(Color.black.opacity(0.55))
            }
        }
        .buttonStyle(PrimaryButtonStyle(accent: accent))
        .disabled(model.install.installed == 0 || model.isInstalling)
        .opacity(model.install.installed == 1 ? 1 : 0.35)
    }

    /// The game switcher used at the top of the rail.
    private func gameTab(_ game: FalloutGame) -> some View {
        let selected = model.selectedGame == game

        return Button {
            if model.selectedGame != game {
                withAnimation(.easeInOut(duration: 0.22)) {
                    model.selectedGame = game
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(installed(game) ? game.accent : Theme.faint)
                        .frame(width: 5, height: 5)

                    Text(game.title)
                        .font(.system(size: 15, weight: selected ? .bold : .medium))
                        .kerning(1.6)
                        .foregroundColor(selected ? Theme.text : Theme.faint)
                }

                Rectangle()
                    .fill(selected ? game.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        if model.isInstalling {
            return L.t("INSTALLING")
        }
        return L.t(model.install.installed == 1 ? "READY" : "NEEDS FILES")
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home:
            homeSheet
        case .display:
            displaySheet
        case .audio:
            audioSheet
        case .game:
            gameSheet
        case .touch:
            controlsSheet
        case .tips:
            tipsSheet
        case .credits:
            creditsSheet
        }
    }

    private var homeSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                row("Game data",
                    detail: model.install.installed == 1 ? "Ready to play" : "Not installed yet") {
                    HStack(spacing: 8) {
                        // A translation pack is the game's own text tree, which
                        // the player supplies: the app ships no game data.
                        Button {
                            pendingImport = .language
                            model.showImporter = true
                        } label: {
                            Text(L.t("LANGUAGE FILES"))
                        }
                        .buttonStyle(SmallButtonStyle(accent: accent))
                        .disabled(model.isInstalling)

                        Button {
                            pendingImport = .game
                            model.showImporter = true
                        } label: {
                            Text(L.t(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT GAME ZIP"))
                        }
                        .buttonStyle(SmallButtonStyle(accent: accent))
                        .disabled(model.isInstalling)
                    }
                }

                HStack(spacing: 16) {
                    ForEach(model.installRows.indices, id: \.self) { index in
                        fileChip(model.installRows[index].0, present: model.installRows[index].1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .overlay(
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1),
                    alignment: .bottom
                )

                if model.isInstalling {
                    ProgressView(value: min(max(model.progress, 0), 1))
                        .accentColor(accent)
                        .padding(.vertical, 10)

                    Text(L.t(model.statusText))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                }

                footnote(model.install.has_saves == 1
                    ? "Your existing saves are kept. Re-importing replaces the game files only."
                    : "Each game keeps its own data, configuration and savegames.")
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.sheet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16 + screenInsets.bottom)
    }

    /// The hero: the selected game's own wasteland still on the right, its
    /// title on the left. The still is masked into the sheet on its left and
    /// bottom edges and tinted warm, so it reads as part of the panel rather
    /// than a photograph pinned to it.
    private var hero: some View {
        GeometryReader { geometry in
            let artWidth = min(min(geometry.size.width * 0.46, 300), geometry.size.height * 4 / 3)
            let artHeight = artWidth * 3 / 4

            ZStack(alignment: .leading) {
                heroArt(width: artWidth, height: artHeight)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .id(model.selectedGame)
                    .transition(.opacity)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedGame.title)
                        .font(.system(size: 38, weight: .heavy))
                        .kerning(1.2)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(model.selectedGame.tagline)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)

                    Text("COMMUNITY EDITION")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(2.2)
                        .foregroundColor(accent.opacity(0.85))
                }
                .padding(.leading, 22)
                .frame(maxWidth: geometry.size.width * 0.60, alignment: .leading)
            }
        }
        .frame(height: 190)
    }

    private func heroArt(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let image = heroImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .saturation(0.82)
                    .brightness(-0.03)
                    .overlay(
                        Color(red: 0.40, green: 0.25, blue: 0.11)
                            .opacity(0.16)
                    )
                    .overlay(
                        LinearGradient(
                            colors: [Color.clear, Theme.sheet.opacity(0.92)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RadialGradient(
                            colors: [Color.clear, Color.black.opacity(0.45)],
                            center: .center,
                            startRadius: width * 0.22,
                            endRadius: width * 0.64
                        )
                    )
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.black.opacity(0), location: 0),
                                .init(color: Color.black.opacity(0.55), location: 0.30),
                                .init(color: Color.black, location: 0.58)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The selected game's still, bundle first. It follows `selectedGame`
    /// directly, so the two can never disagree.
    private var heroImage: UIImage? {
        let isFallout2 = model.selectedGame == .fallout2
        let name = isFallout2 ? "IMG_3579" : "IMG_3570"
        if let image = UIImage(named: name) {
            return image
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: isFallout2 ? "jpeg" : "webp") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    private var tipsSheet: some View {
        sheet(title: "Tips", detail: tipGroup.detail) {
            HStack(spacing: 8) {
                ForEach(TipGroup.allCases) { group in
                    tipPill(group, selected: tipGroup == group)
                }
                Spacer(minLength: 0)

                wikiLink("FALLOUT", address: "https://fallout.fandom.com/wiki/Fallout", primary: model.selectedGame == .fallout1)
                wikiLink("FALLOUT 2", address: "https://fallout.fandom.com/wiki/Fallout_2", primary: model.selectedGame == .fallout2)
            }
            .padding(.vertical, 9)
            .overlay(
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1),
                alignment: .bottom
            )

            ForEach(tipGroup.items.indices, id: \.self) { index in
                tip(tipGroup.items[index].title, tipGroup.items[index].text)
            }
        }
    }

    private func tipPill(_ group: TipGroup, selected: Bool) -> some View {
        Button {
            tipGroup = group
        } label: {
            Text(L.t(group.title))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(0.8)
                .foregroundColor(selected ? Color.black.opacity(0.8) : Theme.faint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Color.clear : Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
    }

    private func wikiLink(_ title: String, address: String, primary: Bool) -> some View {
        Button {
            if let url = URL(string: address) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(0.6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(primary ? Color.black.opacity(0.8) : Theme.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(primary ? accent : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(primary ? Color.clear : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the \(title) wiki")
    }

    private var creditsSheet: some View {
        sheet(title: "Credits", detail: "Who made this, and what it is built on") {
            tip("shplash", "Launcher interface and touch controls.")
            tip("Engines", "Fallout Community Edition and Fallout 2 Community Edition by Alexander Batalov (alexbatalov), under the Sustainable Use License.")
            tip("Libraries", "SDL 2.0 (zlib licence), zlib and fpattern. Their notices apply to this distribution.")
            tip("Notices", "Fallout is a trademark of Bethesda Softworks. Unofficial fan project, not affiliated with Bethesda or Interplay. You must own the games to play.")
            footnote("The app contains no game data; bring your own installation.")
        }
    }

    private enum TipGroup: String, CaseIterable, Identifiable {
        case touch
        case survival
        case launcher

        var id: String {
            return rawValue
        }

        var title: String {
            switch self {
            case .touch: return "TOUCH"
            case .survival: return "SURVIVAL"
            case .launcher: return "LAUNCHER"
            }
        }

        var detail: String {
            switch self {
            case .touch: return "Getting around on a touch screen"
            case .survival: return "A few things worth knowing before you wander"
            case .launcher: return "How the launcher and your data fit together"
            }
        }

        var items: [(title: String, text: String)] {
            switch self {
            case .touch:
                return [
                    ("Cursor", "One finger moves it, a tap clicks. Two-finger tap or ACTION switches move, action and target."),
                    ("Screens", "MAP opens the map, BACK closes a screen, SWAP changes the active hand."),
                    ("Combat", "END ends your turn, SKIP holds it. The attack mode and RELOAD only appear while a weapon is in hand."),
                    ("Layout", "Every control can be moved and resized from Controls, and its opacity set there too."),
                ]
            case .survival:
                return [
                    ("Save often", "There is no autosave. Keep a save before a new area and before a fight you are unsure of."),
                    ("Skills pay", "The skilldex covers Doctor, First Aid and Lockpick. Using them beats guessing at a door or a wound."),
                    ("Talk first", "Many fights can be talked past, and quests tend to pay better than what you can loot."),
                    ("Aim", "An aimed shot costs one more action point and can cripple a limb, which often ends a fight faster than damage."),
                ]
            case .launcher:
                return [
                    ("Import once", "Import a ZIP per game. Importing again replaces the game data and keeps your savegames."),
                    ("HALF or FULL", "HALF keeps the interface readable on a phone; FULL is sharpest on a tablet."),
                    ("Per game", "Resolution, audio, language and controls are stored separately for each game."),
                    ("Own folders", "Fallout keeps its files in Documents, Fallout 2 in Documents/Fallout2, so the two never mix."),
                ]
            }
        }
    }

    private func tip(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.7))
                .frame(width: 3, height: 13)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.t(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.text)

                Text(L.t(text))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var displaySheet: some View {
        sheet(title: "Display", detail: "How large the game world and its interface are drawn", onReset: resetDisplay) {
            HStack(spacing: 12) {
                ForEach(model.presets) { preset in
                    presetTile(preset)
                }
            }
            .padding(.vertical, 12)
            .overlay(
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1),
                alignment: .bottom
            )

            row("Custom size", detail: "Written to the game's resolution file on Play") {
                HStack(spacing: 10) {
                    DimensionField(title: "W", value: $model.width, range: 640...4096, accent: accent)
                    Text("×")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.faint)
                    DimensionField(title: "H", value: $model.height, range: 480...4096, accent: accent)
                }
                .frame(width: 240)
            }

            footnote("FULL draws two screen pixels per game pixel, HALF about one and a half. HALF keeps the interface readable on a phone.")
        }
    }

    private func presetTile(_ preset: DisplayPreset) -> some View {
        let selected = model.selected(preset: preset)

        return Button {
            model.apply(preset: preset)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t(preset.id.uppercased()))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(1.6)
                        .foregroundColor(selected ? accent : Theme.faint)

                    Text(verbatim: "\(preset.width) × \(preset.height)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(selected ? Theme.text : Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Spacer(minLength: 0)

                Text(selected ? L.t("IN USE") : L.t("USE"))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? accent : Theme.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? accent.opacity(0.10) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var audioSheet: some View {
        sheet(title: "Audio", detail: "Volumes, kept per game", onReset: resetAudio) {
            volumeRow("Master", value: $model.masterVolume)
            volumeRow("Music", value: $model.musicVolume)
            volumeRow("Effects", value: $model.sfxVolume)
            volumeRow("Speech", value: $model.speechVolume)

            footnote("0% mutes that channel. The same volumes are in each game's own Options screen.")

            toggleRow("Launcher music",
                      detail: "The track this launcher plays",
                      isOn: Binding(
                        get: { !musicMuted },
                        set: { playing in
                            musicMuted = !playing
                            LauncherMusic.isMuted = musicMuted
                            if musicMuted {
                                LauncherMusic.shared.stop()
                            } else {
                                LauncherMusic.shared.playIfAvailable()
                            }
                        }
                      ))
        }
    }

    // Channel switching is done with the volume sliders; 0% mutes a channel.

    private func volumeRow(_ title: String, value: Binding<Double>) -> some View {
        row(title, detail: nil) {
            HStack(spacing: 12) {
                Slider(value: value, in: 0...100)
                    .accentColor(accent)
                    .frame(width: 220)

                Text(verbatim: "\(Int(value.wrappedValue.rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var gameSheet: some View {
        sheet(title: "Game", detail: "Language, subtitles and how the character moves", onReset: resetGame) {
            row("Language", detail: "Game text, voice, the launcher and the controls") {
                Menu {
                    ForEach(0..<model.languageNames.count, id: \.self) { index in
                        Button(model.languageNames[index]) {
                            model.language = index
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.languageNames.indices.contains(model.language)
                            ? model.languageNames[model.language]
                            : "ENGLISH")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                }
            }

            toggleRow("Subtitles", detail: "Spoken lines appear as text", isOn: $model.subtitles)
            toggleRow("Run, don't walk",
                      detail: "Moves at a run; hold Shift to walk",
                      isOn: $model.alwaysRun)

            savegamesRow

            footnote("Language, subtitles and running are written into the game's configuration on Play. Text your installation does not contain stays English.")
        }
    }

    private var controlsSheet: some View {
        sheet(title: "Controls", detail: "Size and opacity of the on-screen controls", onReset: resetControls) {
            scaleRow("Joystick", detail: "Camera pad in the lower left", value: $model.joystickScale)
            scaleRow("Buttons", detail: "All on-screen buttons", value: $model.buttonScale)
            scaleRow("Opacity", detail: "Unusable buttons hold their dimming until the slider goes below it",
                     value: $model.controlsOpacity)

            toggleRow("White buttons", detail: "Neutral colour instead of the game accent", isOn: $model.whiteButtons)

            HStack {
                Spacer(minLength: 0)

                Button {
                    showControlEditor = true
                } label: {
                    Text(L.t("EDIT CONTROL LAYOUT"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
            }
            .padding(.top, 12)
        }
    }

    /// Backing the saves up is harmless; putting a backup back replaces them, so
    /// that one waits out a countdown with the warning on screen.
    private var savegamesRow: some View {
        row("Savegames", detail: model.savesNotice) {
            HStack(spacing: 8) {
                Button {
                    model.backupSaves()
                } label: {
                    Text(L.t("BACK UP"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
                .disabled(model.isInstalling || model.install.has_saves == 0)

                Button {
                    saveImportCountdown = 5
                    showSaveImportWarning = true
                } label: {
                    Text(L.t("IMPORT"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
                .disabled(model.isInstalling)
            }
        }
    }

    private var saveImportWarning: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(L.t("Replace your savegames?"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.text)

                Text(L.t("Every save in this installation is deleted and the ones in the backup you choose take their place. This cannot be undone."))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(L.t("CANCEL")) {
                        showSaveImportWarning = false
                        saveImportCountdown = 0
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                    Button(saveImportCountdown > 0
                        ? "\(L.t("IMPORT")) \(saveImportCountdown)"
                        : L.t("IMPORT")) {
                        showSaveImportWarning = false
                        pendingImport = .saves
                        model.showImporter = true
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.black.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.opacity(saveImportCountdown > 0 ? 0.4 : 1))
                    )
                    .disabled(saveImportCountdown > 0)
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.sheet)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .padding(24)
        }
    }

    private func scaleRow(_ title: String, detail: String, value: Binding<Double>) -> some View {
        row(title, detail: detail) {
            HStack(spacing: 12) {
                Slider(value: value, in: 0.15...1.35)
                    .accentColor(accent)
                    .frame(width: 200)

                Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                PillToggle(isOn: isOn.wrappedValue, accent: accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        }
    }

    private func fileChip(_ name: String, present: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: present ? "checkmark" : "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(present ? accent : Theme.faint)

            Text(name)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(present ? Theme.dim : Theme.faint)
        }
    }

    // MARK: - Resetting a page

    private func resetDisplay() {
        if let half = model.presets.last {
            model.apply(preset: half)
        }
    }

    private func resetAudio() {
        model.sound = true
        model.music = true
        model.speech = true
        model.masterVolume = 70
        model.musicVolume = 70
        model.sfxVolume = 70
        model.speechVolume = 70
    }

    private func resetGame() {
        model.language = 0
        model.subtitles = false
        model.alwaysRun = true
    }

    private func resetControls() {
        model.joystickScale = 1
        model.buttonScale = 1
        model.controlsOpacity = 1
        model.whiteButtons = false
    }

    // MARK: - Sheet pieces

    private func sheet<C: View>(title: String, detail: String, onReset: (() -> Void)? = nil, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t(title))
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(Theme.text)

                    Text(L.t(detail))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                if let onReset = onReset {
                    Button(action: onReset) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .bold))

                            Text(L.t("RESET"))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .kerning(0.8)
                        }
                        .foregroundColor(Theme.faint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(title) to defaults")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.sheet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16 + screenInsets.bottom)
    }

    private func row<C: View>(_ title: String, detail: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t(title))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)

                if let detail = detail {
                    Text(L.t(detail))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Theme.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.vertical, 10)
        .overlay(
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func footnote(_ text: String) -> some View {
        Text(L.t(text))
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }

    private func installed(_ game: FalloutGame) -> Bool {
        return model.installedGames.contains(game)
    }
}

// MARK: - Pages

private enum LauncherPage: String, CaseIterable, Identifiable {
    case home
    case display
    case audio
    case game
    case touch
    case tips
    case credits

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .home: return L.t("Home")
        case .display: return L.t("Display")
        case .audio: return L.t("Audio")
        case .game: return L.t("Game")
        case .touch: return L.t("Controls")
        case .tips: return L.t("Tips")
        case .credits: return L.t("Credits")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .display: return "display"
        case .audio: return "speaker.wave.2"
        case .game: return "person"
        case .touch: return "hand.tap"
        case .tips: return "lightbulb"
        case .credits: return "info.circle"
        }
    }
}

// MARK: - Resolution field

private struct DimensionField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accent: Color

    @State private var text: String

    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, accent: Color) {
        self.title = title
        self._value = value
        self.range = range
        self.accent = accent
        self._text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.faint)

            TextField("", text: $text)
                .keyboardType(.numberPad)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.text)
                .accentColor(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .onChange(of: text) { newValue in
                    let digits = newValue.filter { $0.isNumber }
                    if digits != newValue {
                        text = digits
                        return
                    }

                    if let parsed = Int(digits), range.contains(parsed) {
                        value = parsed
                    }
                }
                .onChange(of: value) { newValue in
                    if text != String(newValue) {
                        text = String(newValue)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Styling

private extension FalloutGame {
    /// Muted accents: warm amber for the first game, cool steel for the second.
    var accent: Color {
        switch self {
        case .fallout1:
            return Color(red: 0.89, green: 0.64, blue: 0.29)
        case .fallout2:
            return Color(red: 0.42, green: 0.70, blue: 0.62)
        }
    }
}

private enum Theme {
    static let background = Color(red: 0.047, green: 0.043, blue: 0.039)
    static let sheet = Color(red: 0.102, green: 0.094, blue: 0.086)
    static let panel = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color(red: 0.95, green: 0.91, blue: 0.85)
    static let dim = Color(red: 0.71, green: 0.66, blue: 0.58)
    static let faint = Color(red: 0.50, green: 0.46, blue: 0.40)
    static let warning = Color(red: 0.85, green: 0.42, blue: 0.28)
    static let amber = Color(red: 0.89, green: 0.64, blue: 0.29)
}

private struct LauncherBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.093, green: 0.094, blue: 0.103),
                    Theme.background,
                    Color.black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [accent.opacity(0.13), accent.opacity(0)],
                center: UnitPoint(x: 0.30, y: 0.04),
                startRadius: 8,
                endRadius: 700
            )

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.30)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// The home hero uses the game's own still; the drawn vault-door motif was
// replaced by it.

private struct PillToggle: View {
    let isOn: Bool
    let accent: Color

    var body: some View {
        Capsule()
            .fill(isOn ? accent.opacity(0.9) : Color.white.opacity(0.09))
            .frame(width: 46, height: 25)
            .overlay(
                Circle()
                    .fill(isOn ? Color.black.opacity(0.78) : Color.white.opacity(0.55))
                    .frame(width: 19, height: 19)
                    .offset(x: isOn ? 10.5 : -10.5)
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isOn ? 0 : 0.06), lineWidth: 1)
            )
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.09 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Touchscreen control editor

private struct TouchControlEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var model: LauncherModel

    @State private var centers: [TouchControl: CGPoint]
    @State private var scales: [TouchControl: CGFloat]
    @State private var profile: LayoutProfile
    @State private var game: FalloutGame
    @State private var dragOrigins: [TouchControl: CGPoint] = [:]
    @State private var selected: TouchControl?
    @State private var barsHidden = false

    init(model: LauncherModel) {
        self.model = model
        let profile = ControlLayout.profileForCurrentResolution()
        let game = model.selectedGame
        _profile = State(initialValue: profile)
        _game = State(initialValue: game)
        _centers = State(initialValue: ControlLayout.allCenters(profile: profile, game: game))
        _scales = State(initialValue: ControlLayout.allScales(profile: profile, game: game))
    }

    private var accent: Color {
        return game.accent
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.ignoresSafeArea()

                previewSurface(geometry.size)

                ForEach(TouchControl.controls(for: game)) { control in
                    let controlSize = editorSize(for: control, in: geometry.size)
                    editorControl(control, size: controlSize, selected: selected == control)
                        .position(editorCenter(for: control, in: geometry.size))
                        .gesture(dragGesture(for: control, in: geometry.size))
                        .opacity(model.controlsOpacity)
                }

                VStack(alignment: .leading, spacing: 0) {
                    if !barsHidden {
                        editorBar
                        opacityBar
                    }

                    // The toggle sits outside the bars, so it keeps the same
                    // place whether they are shown or hidden, and it is a
                    // labelled capsule rather than a bare chevron, so it can
                    // never be mistaken for one of the game controls.
                    barsToggle

                    Spacer(minLength: 0)
                }

                if let selected = selected {
                    sizeInspector(selected, in: geometry.size)
                }
            }
            .statusBar(hidden: true)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Hides the editor's own bars to give the whole screen to the layout. It is
    /// a filled capsule with a word on it, deliberately unlike the controls it
    /// sits among, and it stays in one place so it can always be found again.
    private var barsToggle: some View {
        Button {
            barsHidden.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: barsHidden ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))

                Text(L.t(barsHidden ? "SHOW BARS" : "HIDE BARS"))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .kerning(1.1)
            }
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(accent))
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t(barsHidden ? "SHOW BARS" : "HIDE BARS"))
        .padding(.leading, 18)
        .padding(.top, 10)
    }

    private var editorBar: some View {
        HStack(spacing: 10) {
            Text(L.t("Touch controls"))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.text)

            presetButton("FULL LAYOUT", profile: .full)
            presetButton("HALF LAYOUT", profile: .half)

            Button(L.t("RESET")) {
                ControlLayout.reset(profile: profile, game: game)
                model.controlsOpacity = 1
                centers = ControlLayout.allCenters(profile: profile, game: game)
                scales = ControlLayout.allScales(profile: profile, game: game)
                dragOrigins.removeAll()
                selected = nil
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.dim)

            Spacer(minLength: 0)

            Text(L.t("DRAG TO MOVE, TAP TO SIZE"))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.faint)

            Button(L.t("DONE")) {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.background.opacity(0.94))
    }

    private var opacityBar: some View {
        HStack(spacing: 12) {
            Text(L.t("OPACITY"))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(Theme.faint)

            Slider(value: $model.controlsOpacity, in: 0.15...1)
                .accentColor(accent)
                .frame(maxWidth: 260)

            Text(verbatim: "\(Int((model.controlsOpacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.dim)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.82))
    }

    private func presetButton(_ title: String, profile target: LayoutProfile) -> some View {
        Button(L.t(title)) {
            profile = target
            if let preset = model.presets.first(where: { $0.id == target.rawValue }) {
                model.apply(preset: preset)
            }
            centers = ControlLayout.allCenters(profile: target, game: game)
            scales = ControlLayout.allScales(profile: target, game: game)
            dragOrigins.removeAll()
            selected = nil
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundColor(profile == target ? Color.black.opacity(0.85) : Theme.dim)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(profile == target ? accent : Color.white.opacity(0.05))
        )
    }

    private func previewSurface(_ size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.056, blue: 0.062),
                    Color(red: 0.075, green: 0.076, blue: 0.083),
                    Theme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // A plain opaque red rectangle for the in-game HUD: the exact
            // footprint the controls have to avoid. No fake interface.
            Rectangle()
                .fill(Color.red.opacity(0.85))
                .frame(width: size.width * 0.484, height: size.height * 0.125)
                .position(x: size.width * 0.492, y: size.height * 0.929)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func editorSize(for control: TouchControl, in size: CGSize) -> CGSize {
        let base = control.defaultSize(in: size, profile: profile)
        let factor = scales[control] ?? 1
        return CGSize(
            width: max(24, base.width * factor),
            height: max(24, base.height * factor)
        )
    }

    private func editorCenter(for control: TouchControl, in size: CGSize) -> CGPoint {
        let point = centers[control] ?? control.defaultCenter(for: profile)
        let controlSize = editorSize(for: control, in: size)
        let halfWidth = controlSize.width / 2
        let halfHeight = controlSize.height / 2
        return CGPoint(
            x: min(max(point.x * size.width, halfWidth), size.width - halfWidth),
            y: min(max(point.y * size.height, halfHeight), size.height - halfHeight)
        )
    }

    private func editorControl(_ control: TouchControl, size: CGSize, selected: Bool) -> some View {
        let shortSide = min(size.width, size.height)
        let tint = model.whiteButtons ? Color.white : accent

        return VStack(spacing: max(1, shortSide * 0.035)) {
            Image(systemName: control.symbol)
                .font(.system(size: max(9, min(28, shortSide * 0.32)), weight: .semibold))

            Text(control.label)
                .font(.system(size: max(7, min(10, shortSide * 0.18)), weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundColor(tint)
        .frame(width: size.width, height: size.height)
        .background(
            Group {
                if control == .joystick {
                    Circle().fill(Theme.panel)
                } else {
                    RoundedRectangle(cornerRadius: min(10, shortSide * 0.16), style: .continuous)
                        .fill(Theme.panel)
                }
            }
        )
        .overlay(
            Group {
                if control == .joystick {
                    Circle().stroke(selected ? Color.white : tint.opacity(0.5),
                                    lineWidth: selected ? 2.2 : 1.2)
                } else {
                    RoundedRectangle(cornerRadius: min(10, shortSide * 0.16), style: .continuous)
                        .stroke(selected ? Color.white : tint.opacity(0.5),
                                lineWidth: selected ? 2.2 : 1.2)
                }
            }
        )
        .contentShape(Rectangle())
    }

    private func sizeInspector(_ control: TouchControl, in size: CGSize) -> some View {
        let width = min(360, max(220, size.width - 24))

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(control.label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(model.whiteButtons ? .white : accent)
                Text(L.t("SIZE"))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.faint)
            }
            .frame(width: 52, alignment: .leading)

            Slider(value: scaleBinding(for: control), in: 0.55...1.8)
                .accentColor(accent)

            Text(verbatim: "\(Int(((scales[control] ?? 1) * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.background.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .position(x: size.width * 0.30, y: 150)
    }

    private func scaleBinding(for control: TouchControl) -> Binding<Double> {
        Binding(
            get: { Double(scales[control] ?? 1) },
            set: { newValue in
                let value = CGFloat(newValue)
                scales[control] = value
                ControlLayout.setScale(value, for: control, profile: profile, game: game)
            }
        )
    }

    private func dragGesture(for control: TouchControl, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                selected = control

                if dragOrigins[control] == nil {
                    dragOrigins[control] = centers[control] ?? control.defaultCenter(for: profile)
                }
                guard let origin = dragOrigins[control] else {
                    return
                }

                let controlSize = editorSize(for: control, in: size)
                let halfWidth = controlSize.width / 2
                let halfHeight = controlSize.height / 2
                let x = min(max((origin.x * size.width + value.translation.width) / max(size.width, 1),
                                (halfWidth + 4) / max(size.width, 1)),
                            (size.width - halfWidth - 4) / max(size.width, 1))
                let y = min(max((origin.y * size.height + value.translation.height) / max(size.height, 1),
                                (halfHeight + 4) / max(size.height, 1)),
                            (size.height - halfHeight - 4) / max(size.height, 1))

                centers[control] = CGPoint(x: x, y: y)
                ControlLayout.setCenter(CGPoint(x: x, y: y), for: control, profile: profile, game: game)
            }
            .onEnded { _ in
                dragOrigins[control] = nil
            }
    }
}
