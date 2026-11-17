import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void
    @State private var showControlEditor = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 0) {
                    installPane
                        .frame(width: min(300, max(230, geometry.size.width * 0.33)), alignment: .topLeading)
                        .padding(24)

                    Rectangle()
                        .fill(Theme.line)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)

                    ScrollView {
                        optionsPane
                            .padding(24)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(LauncherBackdrop().ignoresSafeArea())
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedGame.title)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .kerning(3)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("COMMUNITY EDITION")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .kerning(2.4)
                    .foregroundColor(Theme.dim)
            }

            Spacer(minLength: 12)

            gamePicker
        }
    }

    // MARK: - Game picker

    private var gamePicker: some View {
        HStack(spacing: 20) {
            ForEach(FalloutGame.allCases) { game in
                Button {
                    model.selectedGame = game
                } label: {
                    VStack(spacing: 4) {
                        Text(game.title)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .kerning(1.4)

                        Rectangle()
                            .fill(model.selectedGame == game ? Theme.accent : Color.clear)
                            .frame(height: 1)
                    }
                    .foregroundColor(model.selectedGame == game ? Theme.accent : Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Install

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("INSTALLATION")

            Text(model.isInstalling
                ? "Installing"
                : (model.install.installed == 1 ? "Data ready" : "Game files required"))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(model.install.installed == 1 ? Theme.text : Theme.accent)
                .padding(.top, 10)

            Text(installDescription)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 14)

            VStack(spacing: 7) {
                ForEach(model.installRows.indices, id: \.self) { index in
                    fileRow(model.installRows[index].0, present: model.installRows[index].1)
                }
            }

            if model.isInstalling {
                ProgressView(value: min(max(model.progress, 0), 1))
                    .accentColor(Theme.accent)
                    .padding(.top, 14)

                Text(model.statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .lineLimit(2)
                    .padding(.top, 4)
            } else if model.install.has_saves == 1 {
                Text("Existing saves are kept.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .padding(.top, 14)
            }

            Spacer(minLength: 16)

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
                Text("PLAY")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(LauncherButtonStyle(filled: true))
            .disabled(model.install.installed == 0 || model.isInstalling)
            .opacity(model.install.installed == 1 ? 1 : 0.35)
            .padding(.top, 8)

            Button(action: {
                model.saveOptions()
            }) {
                Text("SAVE SETTINGS")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundColor(model.savedNotice ? Theme.accent : Theme.dim)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var installDescription: String {
        if model.install.installed == 1 {
            return "The installation is ready."
        }

        switch model.selectedGame {
        case .fallout1:
            return "Import master.dat, critter.dat and the data folder."
        case .fallout2:
            return "Import master.dat, critter.dat, patch000.dat and the data folder."
        }
    }

    private func fileRow(_ name: String, present: Bool) -> some View {
        HStack(spacing: 8) {
            Text(present ? "✓" : "—")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(present ? Theme.accent : Theme.dim)
                .frame(width: 12, alignment: .leading)

            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(present ? Theme.text : Theme.dim)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Options

    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            displaySection
            audioSection
            gameplaySection
            controlsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gameplaySection: some View {
        section("GAMEPLAY") {
            VStack(spacing: 0) {
                HStack {
                    settingLabel("LANGUAGE")
                    Spacer(minLength: 12)

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

                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.text)
                    }
                }
                .padding(.vertical, 9)

                rowDivider

                minimalToggle("ALWAYS RUN", isOn: $model.alwaysRun)
            }
        }
    }

    private var controlsSection: some View {
        section("CONTROLS") {
            VStack(spacing: 0) {
                controlScaleRow("JOYSTICK", value: $model.joystickScale)
                rowDivider
                controlScaleRow("BUTTONS", value: $model.buttonScale)
                rowDivider
                minimalToggle("WHITE BUTTONS", isOn: $model.whiteButtons)
                rowDivider

                Button(action: {
                    showControlEditor = true
                }) {
                    Text("EDIT TOUCH LAYOUT")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(1.2)
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func controlScaleRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            settingLabel(title)
                .frame(width: 62, alignment: .leading)

            Slider(value: value, in: 0.75...1.35)
                .accentColor(Theme.accent)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private var displaySection: some View {
        section("DISPLAY") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    ForEach(model.presets) { preset in
                        Button(action: {
                            model.apply(preset: preset)
                        }) {
                            Text(preset.label)
                        }
                        .buttonStyle(ChipButtonStyle(selected: model.selected(preset: preset)))
                    }
                }

                HStack(spacing: 20) {
                    DimensionField(title: "WIDTH", value: $model.width, range: 640...4096)
                    DimensionField(title: "HEIGHT", value: $model.height, range: 480...4096)
                }
            }
        }
    }

    private var audioSection: some View {
        section("AUDIO") {
            VStack(spacing: 0) {
                minimalToggle("SOUND", isOn: $model.sound)
                rowDivider
                minimalToggle("MUSIC", isOn: $model.music)
                rowDivider
                minimalToggle("SPEECH", isOn: $model.speech)
            }
        }
    }

    // MARK: - Shared pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .kerning(2)
            .foregroundColor(Theme.accent)
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.dim)
    }

    private func minimalToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            settingLabel(title)
            Spacer(minLength: 12)

            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Text(isOn.wrappedValue ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundColor(isOn.wrappedValue ? Theme.background : Theme.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isOn.wrappedValue ? Theme.accent : Color.clear)
                    .overlay(Rectangle().stroke(isOn.wrappedValue ? Theme.accent : Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
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
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(Theme.dim)

            VStack(spacing: 2) {
                TextField("", text: $text)
                    .keyboardType(.numberPad)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.text)
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

                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)
            }
            .frame(width: 68)
        }
    }
}

// MARK: - Styling

private enum Theme {
    static let background = Color(red: 0.065, green: 0.060, blue: 0.050)
    static let panel = Color(red: 0.090, green: 0.083, blue: 0.070)
    static let text = Color(red: 0.88, green: 0.85, blue: 0.78)
    static let dim = Color(red: 0.52, green: 0.49, blue: 0.42)
    static let accent = Color(red: 0.82, green: 0.64, blue: 0.34)
    static let line = Color(red: 0.19, green: 0.18, blue: 0.15)

    // Aliases used by the control editor and the shared styles.
    static var green: Color { accent }
    static var amber: Color { accent }
}

private struct LauncherBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.105, green: 0.095, blue: 0.078),
                Theme.background,
                Color.black
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct LauncherButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .kerning(1.6)
            .foregroundColor(filled ? Theme.background : Theme.text)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(filled ? Theme.accent : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(filled ? Theme.accent : Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.label
                .font(.system(size: 9, weight: selected ? .semibold : .regular, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(selected ? Theme.accent : Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Rectangle()
                .fill(selected ? Theme.accent : Color.clear)
                .frame(height: 1)
        }
        .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(Theme.accent)
            .opacity(configuration.isPressed ? 0.65 : 1)
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
