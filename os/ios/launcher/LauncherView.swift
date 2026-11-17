import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void
    @State private var showControlEditor = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LauncherBackdrop(game: model.selectedGame)

                VStack(spacing: 8) {
                    header

                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)

                    gamePicker

                    HStack(alignment: .top, spacing: 12) {
                        installPane
                            .frame(maxHeight: .infinity, alignment: .top)
                            .frame(width: max(220, min(geometry.size.width * 0.31, 318)), alignment: .top)

                        Rectangle()
                            .fill(Theme.line)
                            .frame(width: 1)

                        optionsPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    Text(model.selectedGame.supportsLaunch
                        ? "Preferences are saved when you play."
                        : "Preferences are saved with the game data.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showControlEditor) {
            TouchControlEditor(model: model)
        }
        .onAppear {
            model.refreshInstall()
            LauncherMusic.shared.playIfAvailable()
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(model.selectedGame.title)
                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.accent)
                .lineLimit(1)

            Text("COMMUNITY EDITION")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .kerning(1.4)
                .foregroundColor(Theme.dim)

            Spacer()

            Circle()
                .fill(model.install.installed == 1 ? Theme.accent : Theme.amber)
                .frame(width: 7, height: 7)

            Text(model.isInstalling ? "INSTALLING" : (model.install.installed == 1 ? "DATA READY" : "NEEDS DATA"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(model.install.installed == 1 ? Theme.accent : Theme.amber)
        }
        .padding(.bottom, 1)
    }

    // MARK: - Game picker

    private var gamePicker: some View {
        HStack(spacing: 8) {
            ForEach(FalloutGame.allCases) { game in
                Button {
                    model.selectedGame = game
                } label: {
                    HStack(spacing: 9) {
                        Text(game.shortTitle)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundColor(model.selectedGame == game ? Theme.background : game.tint)
                            .frame(width: 24, height: 24)
                            .background(model.selectedGame == game ? game.tint : Theme.background)
                            .overlay(Rectangle().stroke(game.tint.opacity(0.55), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title)
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundColor(model.selectedGame == game ? Theme.text : Theme.dim)
                                .lineLimit(1)

                            Text(game.tagline)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Theme.dim)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Circle()
                            .fill(installed(for: game) ? game.tint : Theme.amber)
                            .frame(width: 5, height: 5)

                        Text(installed(for: game) ? "READY" : "EMPTY")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(installed(for: game) ? game.tint : Theme.dim)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(model.selectedGame == game ? Theme.panel : Theme.background.opacity(0.45)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(model.selectedGame == game ? game.tint.opacity(0.85) : Theme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func installed(for game: FalloutGame) -> Bool {
        return model.installedGames.contains(game)
    }

    // MARK: - Install

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("INSTALLATION")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.install.installed == 1 ? Theme.accent : Theme.amber)
                        .frame(width: 6, height: 6)

                    Text(model.install.installed == 1 ? "Data ready" : "Game files required")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(model.install.installed == 1 ? Theme.accent : Theme.text)
                }

                Text(installDescription)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.installRows.indices, id: \.self) { index in
                        fileRow(model.installRows[index].0, present: model.installRows[index].1)
                    }
                }

                if model.isInstalling {
                    ProgressView(value: min(max(model.progress, 0), 1))
                        .accentColor(Theme.accent)

                    Text(model.statusText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .lineLimit(2)
                } else if model.install.has_saves == 1 {
                    Text("Existing saves are kept.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.dim)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))

            if !model.selectedGame.supportsLaunch {
                Text("The Fallout 2 engine is not part of this build. Your imported files are kept for the dedicated Fallout 2 app.")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(spacing: 7) {
                Button(action: {
                    model.showImporter = true
                }) {
                    Text(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT GAME ZIP")
                }
                .buttonStyle(LauncherButtonStyle(filled: false))
                .disabled(model.isInstalling)

                Button(action: {
                    LauncherMusic.shared.stop()
                    model.play(onPlay: onPlay)
                }) {
                    Text(model.selectedGame.supportsLaunch ? "PLAY" : "ENGINE NOT INCLUDED")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(LauncherButtonStyle(filled: true))
                .disabled(model.install.installed == 0 || model.isInstalling || !model.selectedGame.supportsLaunch)
                .opacity(model.install.installed == 1 && model.selectedGame.supportsLaunch ? 1 : 0.4)
            }
        }
    }

    private var installDescription: String {
        if model.install.installed == 1 {
            return model.selectedGame.supportsLaunch
                ? "Your installation is ready. Choose Play to launch the game."
                : "Your Fallout 2 data is ready for the dedicated engine build."
        }

        switch model.selectedGame {
        case .fallout1:
            return "Import a ZIP containing master.dat, critter.dat, and the data folder."
        case .fallout2:
            return "Import a ZIP containing master.dat, critter.dat, patch000.dat, and the data folder."
        }
    }

    private func fileRow(_ name: String, present: Bool) -> some View {
        HStack(spacing: 6) {
            Text(present ? "✓" : "✕")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(present ? Theme.green : Theme.amber)
                .frame(width: 12, alignment: .leading)

            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(present ? Theme.text : Theme.dim)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Options

    private var optionsPane: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                displaySection
                audioSection
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: 8) {
                controlsSection
                gameplaySection
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gameplaySection: some View {
        section("GAMEPLAY") {
            HStack(spacing: 8) {
                settingLabel("LANGUAGE")

                Spacer(minLength: 4)

                Menu {
                    ForEach(0..<model.languageNames.count, id: \.self) { index in
                        Button(model.languageNames[index]) {
                            model.language = index
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.languageNames.indices.contains(model.language)
                            ? model.languageNames[model.language]
                            : "ENGLISH")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minWidth: 80, maxWidth: 120, alignment: .leading)
                    .background(Theme.background)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
            }

            Toggle(isOn: $model.alwaysRun) {
                settingLabel("ALWAYS RUN")
            }
            .toggleStyle(SwitchToggleStyle())
            .accentColor(Theme.green)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                sectionLabel("TOUCH LAYOUT")
                Spacer(minLength: 2)
                whiteButtonsToggle
            }

            controlScaleRow("JOYSTICK", value: $model.joystickScale)
            controlScaleRow("BUTTONS", value: $model.buttonScale)

            Button(action: {
                showControlEditor = true
            }) {
                Text("EDIT LAYOUT")
            }
            .buttonStyle(CompactButtonStyle())
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }

    private var whiteButtonsToggle: some View {
        Button {
            model.whiteButtons.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("WHITE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(model.whiteButtons ? Theme.green : Theme.dim)

                Capsule()
                    .fill(model.whiteButtons ? Theme.green : Theme.line)
                    .frame(width: 27, height: 15)
                    .overlay(
                        Circle()
                            .fill(model.whiteButtons ? Theme.background : Theme.dim)
                            .frame(width: 11, height: 11)
                            .padding(2),
                        alignment: model.whiteButtons ? .trailing : .leading
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("White buttons")
        .accessibilityValue(model.whiteButtons ? "On" : "Off")
    }

    private func controlScaleRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            settingLabel(title)
                .frame(width: 54, alignment: .leading)

            Slider(value: value, in: 0.75...1.35)
                .accentColor(Theme.green)
                .frame(height: 18)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.dim)
                .frame(width: 32, alignment: .trailing)
        }
        .frame(height: 22)
    }

    private var displaySection: some View {
        section("DISPLAY") {
            HStack(spacing: 6) {
                ForEach(model.presets) { preset in
                    Button(action: {
                        model.apply(preset: preset)
                    }) {
                        Text(preset.label)
                    }
                    .buttonStyle(ChipButtonStyle(selected: model.selected(preset: preset)))
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                DimensionField(title: "WIDTH", value: $model.width, range: 640...4096)

                Text("×")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .padding(.bottom, 8)

                DimensionField(title: "HEIGHT", value: $model.height, range: 480...4096)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var audioSection: some View {
        section("AUDIO") {
            VStack(spacing: 2) {
                Toggle(isOn: $model.sound) {
                    settingLabel("SOUND")
                }
                .toggleStyle(SwitchToggleStyle())
                .accentColor(Theme.green)

                Toggle(isOn: $model.music) {
                    settingLabel("MUSIC")
                }
                .toggleStyle(SwitchToggleStyle())
                .accentColor(Theme.green)

                Toggle(isOn: $model.speech) {
                    settingLabel("SPEECH")
                }
                .toggleStyle(SwitchToggleStyle())
                .accentColor(Theme.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Shared pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(Theme.amber)
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.dim)
    }
}

// MARK: - Custom resolution field

private struct DimensionField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var text: String

    init(title: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
        self._text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.dim)

            TextField("", text: $text)
                .keyboardType(.numberPad)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(Theme.background)
                .overlay(
                    Rectangle()
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
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Styling

private extension FalloutGame {
    var tint: Color {
        switch self {
        case .fallout1:
            return Color(red: 0.55, green: 0.96, blue: 0.45)
        case .fallout2:
            return Color(red: 0.42, green: 0.75, blue: 1.0)
        }
    }
}

private enum Theme {
    static var game: FalloutGame {
        FalloutGame(rawValue: UserDefaults.standard.string(forKey: "launcher.game") ?? "") ?? .fallout1
    }

    static var background: Color {
        game == .fallout2
            ? Color(red: 0.008, green: 0.016, blue: 0.034)
            : Color(red: 0.012, green: 0.026, blue: 0.012)
    }

    static var panel: Color {
        game == .fallout2
            ? Color(red: 0.022, green: 0.040, blue: 0.070)
            : Color(red: 0.030, green: 0.055, blue: 0.030)
    }

    static var accent: Color { game.tint }
    // Kept as an alias so the control editor and shared styles can use the
    // active game's accent without knowing which game is selected.
    static var green: Color { accent }

    static var dim: Color {
        game == .fallout2
            ? Color(red: 0.50, green: 0.61, blue: 0.74)
            : Color(red: 0.44, green: 0.59, blue: 0.42)
    }

    static var text: Color {
        game == .fallout2
            ? Color(red: 0.80, green: 0.87, blue: 0.96)
            : Color(red: 0.78, green: 0.90, blue: 0.76)
    }

    static let amber = Color(red: 0.95, green: 0.72, blue: 0.32)

    static var line: Color {
        game == .fallout2
            ? Color(red: 0.12, green: 0.23, blue: 0.38)
            : Color(red: 0.16, green: 0.30, blue: 0.16)
    }
}

private struct LauncherBackdrop: View {
    let game: FalloutGame

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.background,
                    game == .fallout2
                        ? Color(red: 0.012, green: 0.024, blue: 0.048)
                        : Color(red: 0.018, green: 0.034, blue: 0.018),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [game.tint.opacity(0.13), .clear],
                center: UnitPoint(x: 0.08, y: 0.02),
                startRadius: 4,
                endRadius: 560
            )

            GeometryReader { geometry in
                GridTexture(spacing: 30)
                    .stroke(game.tint.opacity(0.045), lineWidth: 0.5)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct GridTexture: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x: CGFloat = 0
        while x <= rect.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
            x += spacing
        }

        var y: CGFloat = 0
        while y <= rect.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }

        return path
    }
}

private struct LauncherButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(filled ? Theme.background : Theme.green)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Theme.green : Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(filled ? Theme.green : Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8, weight: selected ? .bold : .medium, design: .monospaced))
            .foregroundColor(selected ? Theme.background : Theme.green)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.green : Theme.background))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Theme.green : Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

private struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.green)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.62 : 1)
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
    @State private var whiteButtons = UserDefaults.standard.bool(forKey: "launcher.whiteButtons")

    init(model: LauncherModel) {
        self.model = model
        let profile = ControlLayout.profileForCurrentResolution()
        let game = model.selectedGame
        _profile = State(initialValue: profile)
        _game = State(initialValue: game)
        _centers = State(initialValue: ControlLayout.allCenters(profile: profile, game: game))
        _scales = State(initialValue: ControlLayout.allScales(profile: profile, game: game))
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
                }

                VStack(spacing: 0) {
                    editorBar
                    Text("Tap a control to select it. Drag to move it, or use the size slider.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
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
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.green)

            presetButton("FULL LAYOUT", profile: .full)
            presetButton("HALF LAYOUT", profile: .half)

            Button("RESET") {
                ControlLayout.reset(profile: profile, game: game)
                centers = ControlLayout.allCenters(profile: profile, game: game)
                scales = ControlLayout.allScales(profile: profile, game: game)
                dragOrigins.removeAll()
                selected = nil
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.amber)

            Button("DONE") {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.background)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel.opacity(0.92))
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .font(.system(size: 9, weight: .heavy, design: .monospaced))
        .foregroundColor(profile == target ? Theme.background : Theme.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(profile == target ? Theme.green : Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private func previewSurface(_ size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.045, blue: 0.035),
                    Color(red: 0.055, green: 0.060, blue: 0.045),
                    Theme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // The reference uses a plain opaque red rectangle for the whole
            // in-game HUD. No fake text, buttons or panel details: only the
            // exact footprint the controls have to avoid.
            Rectangle()
                .fill(Color.red)
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
        let accent = whiteButtons ? Color.white : (control == .skip ? Theme.amber : Theme.green)

        return VStack(spacing: max(1, shortSide * 0.035)) {
            Image(systemName: control.symbol)
                .font(.system(size: max(9, min(28, shortSide * 0.32)), weight: .semibold))

            Text(control.label)
                .font(.system(size: max(7, min(10, shortSide * 0.18)), weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundColor(accent)
        .frame(width: size.width, height: size.height)
        .background(
            Group {
                if control == .joystick {
                    Circle().fill(Theme.panel.opacity(0.82))
                } else {
                    RoundedRectangle(cornerRadius: min(8, shortSide * 0.12))
                        .fill(Theme.panel.opacity(0.82))
                }
            }
        )
        .overlay(
            Group {
                if control == .joystick {
                    Circle().stroke(selected ? Color.white : accent.opacity(0.55),
                                    lineWidth: selected ? 2.2 : 1.3)
                } else {
                    RoundedRectangle(cornerRadius: min(8, shortSide * 0.12))
                        .stroke(selected ? Color.white : accent.opacity(0.55),
                                lineWidth: selected ? 2.2 : 1.3)
                }
            }
        )
        .shadow(color: selected ? Color.white.opacity(0.40) : .clear, radius: 4)
        .contentShape(Rectangle())
    }

    private func sizeInspector(_ control: TouchControl, in size: CGSize) -> some View {
        let width = min(360, max(220, size.width - 24))

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(control.label)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(whiteButtons ? Color.white : Theme.green)
                Text("SIZE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dim)
            }
            .frame(width: 52, alignment: .leading)

            Slider(value: scaleBinding(for: control), in: 0.55...1.8)
                .accentColor(Theme.green)

            Text("\(Int(((scales[control] ?? 1) * 100).rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.text)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width)
        .background(Theme.panel.opacity(0.97))
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .position(x: size.width * 0.30, y: 86)
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
