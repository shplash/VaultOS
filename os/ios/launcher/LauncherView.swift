import Foundation
import SwiftUI
import UniformTypeIdentifiers

// The launcher is a single fixed window: one page at a time, switched from the
// bar at the top. Nothing in it scrolls, because a scroll view inside the
// engine's nested run loop was what kept hanging the launcher.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void

    @State private var page: LauncherPage = .home
    @State private var showControlEditor = false

    private var accent: Color {
        return model.selectedGame.accent
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LauncherBackdrop(accent: accent)

                VStack(spacing: 16) {
                    topBar
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomBar
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showControlEditor) {
            TouchControlEditor(model: model)
        }
        .onAppear {
            model.refreshInstall()
            LauncherMusic.shared.playIfAvailable()
        }
        .onChange(of: model.selectedGame) { game in
            LauncherMusic.shared.crossfade(to: game)
        }
        .onChange(of: model.install.installed) { installed in
            if installed == 1 {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importZip(from: url)
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
                message: Text(model.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(FalloutGame.allCases) { game in
                    gameButton(game)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(LauncherPage.allCases) { item in
                    Button(item.title) {
                        page = item
                    }
                    .buttonStyle(TabButtonStyle(selected: page == item, accent: accent))
                }
            }

            Spacer(minLength: 8)

            statusPill
        }
    }

    private func gameButton(_ game: FalloutGame) -> some View {
        let selected = model.selectedGame == game

        return Button {
            if model.selectedGame != game {
                model.selectedGame = game
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(installed(game) ? game.accent : Theme.faint)
                    .frame(width: 6, height: 6)

                Text(game.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? Theme.text : Theme.dim)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? game.accent.opacity(0.14) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? game.accent.opacity(0.45) : Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        let ready = model.install.installed == 1

        return HStack(spacing: 7) {
            Circle()
                .fill(ready ? accent : Theme.warning)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(ready ? Theme.dim : Theme.warning)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private var statusText: String {
        if model.isInstalling {
            return "INSTALLING"
        }
        return model.install.installed == 1 ? "READY" : "NEEDS FILES"
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .home:
            HStack(alignment: .top, spacing: 18) {
                hero
                installCard
                    .frame(width: 300)
            }
        case .display:
            HStack(alignment: .top, spacing: 18) {
                displayCard
                resolutionCard
                    .frame(width: 330)
            }
        case .audio:
            HStack(alignment: .top, spacing: 18) {
                audioTogglesCard
                volumeCard
            }
        case .game:
            HStack(alignment: .top, spacing: 18) {
                gameplayCard
                savesCard
            }
        case .touch:
            HStack(alignment: .top, spacing: 18) {
                touchCard
                opacityCard
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            VaultRing(accent: accent)
                .frame(width: 220, height: 220)
                .offset(x: -26, y: -34)
                .opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                Spacer(minLength: 0)

                Text(model.selectedGame.title)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(model.selectedGame.tagline)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)

                Text("COMMUNITY EDITION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(2.4)
                    .foregroundColor(accent.opacity(0.85))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var installCard: some View {
        card(title: "INSTALLATION") {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.install.installed == 1 ? "Ready to play" : "Game files required")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(model.install.installed == 1 ? Theme.text : Theme.warning)

                Text(installNote)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.installRows.indices, id: \.self) { index in
                    fileRow(model.installRows[index].0, present: model.installRows[index].1)
                }
            }

            if model.isInstalling {
                ProgressView(value: min(max(model.progress, 0), 1))
                    .accentColor(accent)

                Text(model.statusText)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button {
                model.showImporter = true
            } label: {
                Text(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT GAME ZIP")
            }
            .buttonStyle(SecondaryButtonStyle(accent: accent))
            .disabled(model.isInstalling)
        }
    }

    private var installNote: String {
        if model.install.installed == 1 {
            return model.install.has_saves == 1
                ? "Your data and existing saves are in place."
                : "Your game data is in place."
        }

        switch model.selectedGame {
        case .fallout1:
            return "Import a ZIP with master.dat, critter.dat and the data folder."
        case .fallout2:
            return "Import a ZIP with master.dat, critter.dat, patch000.dat and the data folder."
        }
    }

    private func fileRow(_ name: String, present: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(present ? accent : Theme.faint)

            Text(name)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(present ? Theme.dim : Theme.faint)

            Spacer(minLength: 0)
        }
    }

    private var displayCard: some View {
        card(title: "RESOLUTION") {
            HStack(spacing: 12) {
                ForEach(model.presets) { preset in
                    presetTile(preset)
                }
            }

            Text("FULL renders at two screen pixels per game pixel, HALF at about one and a half, which keeps the interface readable on a phone.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func presetTile(_ preset: DisplayPreset) -> some View {
        let selected = model.selected(preset: preset)

        return Button {
            model.apply(preset: preset)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(preset.id.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.6)
                    .foregroundColor(selected ? accent : Theme.dim)

                Text("\(preset.width) × \(preset.height)")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(selected ? Theme.text : Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(selected ? "IN USE" : "TAP TO USE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? accent.opacity(0.85) : Theme.faint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? accent.opacity(0.12) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? accent.opacity(0.5) : Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var resolutionCard: some View {
        card(title: "CUSTOM") {
            HStack(spacing: 14) {
                DimensionField(title: "WIDTH", value: $model.width, range: 640...4096, accent: accent)
                DimensionField(title: "HEIGHT", value: $model.height, range: 480...4096, accent: accent)
            }

            Text("Written to the game's own resolution file when you press Play.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var audioTogglesCard: some View {
        card(title: "SOUND") {
            toggleRow("SOUND EFFECTS", isOn: $model.sound)
            toggleRow("MUSIC", isOn: $model.music)
            toggleRow("SPEECH", isOn: $model.speech)

            Spacer(minLength: 4)

            Text("THEME: \(LauncherMusic.themeLabel(for: model.selectedGame))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)
        }
    }

    private var volumeCard: some View {
        card(title: "VOLUME") {
            sliderRow("MASTER", value: $model.masterVolume, range: 0...100, unit: "%")
            sliderRow("MUSIC", value: $model.musicVolume, range: 0...100, unit: "%")
            sliderRow("EFFECTS", value: $model.sfxVolume, range: 0...100, unit: "%")
            sliderRow("SPEECH", value: $model.speechVolume, range: 0...100, unit: "%")
            Spacer(minLength: 0)
        }
    }

    private var gameplayCard: some View {
        card(title: "GAMEPLAY") {
            HStack(spacing: 10) {
                Text("LANGUAGE")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)

                Spacer(minLength: 6)

                Menu {
                    ForEach(0..<model.languageNames.count, id: \.self) { index in
                        Button(model.languageNames[index]) {
                            model.language = index
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.languageNames.indices.contains(model.language)
                            ? model.languageNames[model.language]
                            : "ENGLISH")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(minWidth: 110, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    )
                }
            }

            toggleRow("SUBTITLES", isOn: $model.subtitles)
            toggleRow("RUN, DON'T WALK", isOn: $model.alwaysRun)

            Text("Running moves faster and Shift walks instead. Subtitles and running are written to the game's configuration.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var savesCard: some View {
        card(title: "SAVES AND FILES") {
            Text(model.selectedGame == .fallout2
                ? "Fallout 2 keeps its data, configuration and SAVEGAME folder in Documents/Fallout2, apart from the first game."
                : "Fallout keeps its data, configuration and SAVEGAME folder in the app's Documents folder.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Text("Importing a ZIP again replaces the game data and leaves your saves alone. File Sharing is on, so Finder can copy files in and out.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var touchCard: some View {
        card(title: "TOUCH LAYOUT") {
            sliderRow("JOYSTICK SIZE", value: $model.joystickScale, range: 0.75...1.35, unit: "%")
            sliderRow("BUTTON SIZE", value: $model.buttonScale, range: 0.75...1.35, unit: "%")

            toggleRow("WHITE BUTTONS", isOn: $model.whiteButtons)

            Spacer(minLength: 0)

            Button {
                showControlEditor = true
            } label: {
                Text("EDIT CONTROL LAYOUT")
            }
            .buttonStyle(SecondaryButtonStyle(accent: accent))
        }
    }

    private var opacityCard: some View {
        card(title: "CONTROLS OPACITY") {
            sliderRow("OPACITY", value: $model.controlsOpacity, range: 0.15...1, unit: "%")

            HStack(spacing: 10) {
                opacitySample("ACTION", enabled: true, strong: true)
                opacitySample("PIP", enabled: true, strong: false)
                opacitySample("MODE", enabled: false, strong: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Unusable buttons keep their own dimming until this slider goes below it; only then do they fade with the rest.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func opacitySample(_ title: String, enabled: Bool, strong: Bool) -> some View {
        let base = CGFloat(model.controlsOpacity)
        let value = enabled ? base : min(0.35, base)

        return Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(accent)
            .frame(width: strong ? 62 : 46, height: strong ? 44 : 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(accent.opacity(0.45), lineWidth: 1)
            )
            .opacity(Double(value))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.hint)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundColor(Theme.faint)
                    .lineLimit(2)

                Text("SETTINGS ARE STORED FOR EACH GAME")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.faint.opacity(0.7))
            }

            Spacer(minLength: 0)

            Button {
                LauncherMusic.shared.stop()
                model.play(onPlay: onPlay)
            } label: {
                Text("PLAY")
            }
            .buttonStyle(PrimaryButtonStyle(accent: accent))
            .frame(width: 210)
            .disabled(model.install.installed == 0 || model.isInstalling)
            .opacity(model.install.installed == 1 ? 1 : 0.35)
        }
    }

    // MARK: - Shared pieces

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.8)
                .foregroundColor(Theme.faint)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
        }
        .toggleStyle(SwitchToggleStyle())
        .accentColor(accent)
        .padding(.vertical, 2)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 92, alignment: .leading)

            Slider(value: value, in: range)
                .accentColor(accent)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 34)
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

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .home: return "HOME"
        case .display: return "DISPLAY"
        case .audio: return "AUDIO"
        case .game: return "GAME"
        case .touch: return "CONTROLS"
        }
    }

    var hint: String {
        switch self {
        case .home:
            return "Import your game data once, then press Play."
        case .display:
            return "Pick the resolution the game renders at."
        case .audio:
            return "Sound, music and speech can be switched off separately."
        case .game:
            return "Language, subtitles and how the character moves."
        case .touch:
            return "Size and opacity of the on-screen controls."
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
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.6)
                .foregroundColor(Theme.faint)

            TextField("", text: $text)
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundColor(Theme.text)
                .accentColor(accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
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
            return Color(red: 0.93, green: 0.72, blue: 0.42)
        case .fallout2:
            return Color(red: 0.56, green: 0.77, blue: 0.84)
        }
    }
}

private enum Theme {
    static let background = Color(red: 0.047, green: 0.050, blue: 0.058)
    static let surface = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.93, green: 0.925, blue: 0.912)
    static let dim = Color(red: 0.63, green: 0.63, blue: 0.61)
    static let faint = Color(red: 0.43, green: 0.43, blue: 0.42)
    static let warning = Color(red: 0.93, green: 0.70, blue: 0.36)
    static let amber = Color(red: 0.93, green: 0.70, blue: 0.36)
    static let panel = Color.white.opacity(0.05)
}

private struct LauncherBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.086, green: 0.090, blue: 0.101),
                    Theme.background,
                    Color.black.opacity(0.94)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [accent.opacity(0.16), accent.opacity(0)],
                center: UnitPoint(x: 0.16, y: 0.08),
                startRadius: 6,
                endRadius: 640
            )

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.34)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

/// A quiet vault-door motif: three rings and a ring of ticks, drawn from the
/// selected game's accent so no artwork has to be bundled.
private struct VaultRing: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: 1.5)

            Circle()
                .stroke(accent.opacity(0.10), lineWidth: 1)
                .padding(28)

            Circle()
                .fill(accent.opacity(0.05))
                .padding(48)

            ForEach(0..<36) { index in
                Rectangle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 1, height: 8)
                    .offset(y: -100)
                    .rotationEffect(.degrees(Double(index) * 10))
            }
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.82))
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(accent)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(accent)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct TabButtonStyle: ButtonStyle {
    let selected: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(selected ? Theme.text : Theme.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.07) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
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

                VStack(spacing: 0) {
                    editorBar
                    opacityBar
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

    private var editorBar: some View {
        HStack(spacing: 10) {
            Text("TOUCH CONTROLS")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)

            presetButton("FULL LAYOUT", profile: .full)
            presetButton("HALF LAYOUT", profile: .half)

            Button("RESET") {
                ControlLayout.reset(profile: profile, game: game)
                centers = ControlLayout.allCenters(profile: profile, game: game)
                scales = ControlLayout.allScales(profile: profile, game: game)
                dragOrigins.removeAll()
                selected = nil
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.dim)

            Spacer(minLength: 0)

            Text("DRAG TO MOVE, TAP TO SIZE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.faint)

            Button("DONE") {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.82))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.background.opacity(0.94))
    }

    private var opacityBar: some View {
        HStack(spacing: 12) {
            Text("OPACITY")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.faint)

            Slider(value: $model.controlsOpacity, in: 0.15...1)
                .accentColor(accent)
                .frame(maxWidth: 260)

            Text("\(Int((model.controlsOpacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.dim)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.82))
    }

    private func presetButton(_ title: String, profile target: LayoutProfile) -> some View {
        Button(title) {
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
        .foregroundColor(profile == target ? Color.black.opacity(0.82) : Theme.dim)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(profile == target ? accent : Color.white.opacity(0.05))
        )
    }

    private func previewSurface(_ size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.058, blue: 0.066),
                    Color(red: 0.075, green: 0.078, blue: 0.086),
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
                Text("SIZE")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.faint)
            }
            .frame(width: 52, alignment: .leading)

            Slider(value: scaleBinding(for: control), in: 0.55...1.8)
                .accentColor(accent)

            Text("\(Int(((scales[control] ?? 1) * 100).rounded()))%")
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
