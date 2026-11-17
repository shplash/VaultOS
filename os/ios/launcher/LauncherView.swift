import Foundation
import SwiftUI
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

    private var accent: Color {
        return model.selectedGame.accent
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LauncherBackdrop(accent: accent)

                HStack(spacing: 0) {
                    rail
                    content
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
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

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(FalloutGame.allCases) { game in
                    gameTab(game)
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

            HStack(spacing: 6) {
                Circle()
                    .fill(model.install.installed == 1 ? accent : Theme.warning)
                    .frame(width: 5, height: 5)

                Text(statusText)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .kerning(1)
                    .foregroundColor(Theme.faint)
            }
            .padding(.leading, 3)
            .padding(.bottom, 7)

            playButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 168, alignment: .leading)
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
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, alignment: .leading)

                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .kerning(0.6)

                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? Theme.text : Theme.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? accent.opacity(0.40) : Color.clear, lineWidth: 1)
            )
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
                Text("PLAY")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))

                Text(model.install.installed == 1 ? "START \(model.selectedGame.title)" : "NEEDS GAME DATA")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.black.opacity(0.5))
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
                model.selectedGame = game
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(installed(game) ? game.accent : Theme.faint)
                        .frame(width: 5, height: 5)

                    Text(game.title)
                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                        .kerning(1.4)
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
            return "INSTALLING"
        }
        return model.install.installed == 1 ? "READY" : "NEEDS FILES"
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
        }
    }

    private var homeSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VaultRing(accent: accent)
                    .frame(width: 230, height: 230)
                    .offset(x: 40, y: -46)
                    .opacity(0.75)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedGame.title)
                        .font(.system(size: 42, weight: .heavy))
                        .kerning(1.5)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(model.selectedGame.tagline)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Theme.dim)

                    Text("COMMUNITY EDITION")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(2.2)
                        .foregroundColor(accent.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .clipped()

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                row("Game data",
                    detail: model.install.installed == 1 ? "Ready to play" : "Not installed yet") {
                    Button {
                        model.showImporter = true
                    } label: {
                        Text(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT GAME ZIP")
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent))
                    .disabled(model.isInstalling)
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

                    Text(model.statusText)
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
        .padding(.vertical, 16)
    }

    private var displaySheet: some View {
        sheet(title: "Display", detail: "How large the game world and its interface are drawn") {
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
                    Text(preset.id.uppercased())
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

                Text(selected ? "IN USE" : "USE")
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
        sheet(title: "Audio", detail: "Sound, music and speech, kept per game") {
            row("Channels", detail: "Tap to switch a channel off") {
                HStack(spacing: 8) {
                    channelPill("SFX", isOn: $model.sound)
                    channelPill("MUSIC", isOn: $model.music)
                    channelPill("SPEECH", isOn: $model.speech)
                }
            }

            volumeRow("Master", value: $model.masterVolume)
            volumeRow("Music", value: $model.musicVolume)
            volumeRow("Effects", value: $model.sfxVolume)
            volumeRow("Speech", value: $model.speechVolume)

            footnote("Launcher theme: \(LauncherMusic.themeLabel(for: model.selectedGame)).")
        }
    }

    private func channelPill(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(0.8)
                .foregroundColor(isOn.wrappedValue ? Color.black.opacity(0.75) : Theme.faint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn.wrappedValue ? accent : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isOn.wrappedValue ? Color.clear : Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

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
        sheet(title: "Game", detail: "Language, subtitles and how the character moves") {
            row("Language", detail: "Text and voice") {
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
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

            footnote("Both are written into the game's own configuration on Play.")
        }
    }

    private var controlsSheet: some View {
        sheet(title: "Controls", detail: "Size and opacity of the on-screen controls") {
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
                    Text("EDIT CONTROL LAYOUT")
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
            }
            .padding(.top, 12)
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

    // MARK: - Sheet pieces

    private func sheet<C: View>(title: String, detail: String, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(Theme.text)

                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Theme.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
        .padding(.vertical, 16)
    }

    private func row<C: View>(_ title: String, detail: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)

                if let detail = detail {
                    Text(detail)
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
        Text(text)
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

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .display: return "Display"
        case .audio: return "Audio"
        case .game: return "Game"
        case .touch: return "Controls"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .display: return "display"
        case .audio: return "speaker.wave.2"
        case .game: return "person"
        case .touch: return "hand.tap"
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

/// A quiet vault-door motif: three rings and a ring of ticks, drawn from the
/// selected game's accent so no artwork has to be bundled.
private struct VaultRing: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.20), lineWidth: 1.5)

            Circle()
                .stroke(accent.opacity(0.11), lineWidth: 1)
                .padding(30)

            Circle()
                .fill(accent.opacity(0.05))
                .padding(52)

            ForEach(0..<36) { index in
                Rectangle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 1, height: 8)
                    .offset(y: -104)
                    .rotationEffect(.degrees(Double(index) * 10))
            }
        }
    }
}

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
            Text("Touch controls")
                .font(.system(size: 17, weight: .bold))
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
            Text("OPACITY")
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
                Text("SIZE")
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
