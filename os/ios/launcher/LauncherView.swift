import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void
    @State private var showControlEditor = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                header

                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 12) {
                    installPane
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(width: max(220, min(geometry.size.width * 0.30, 300)), alignment: .top)

                    Rectangle()
                        .fill(Theme.line)
                        .frame(width: 1)

                    optionsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Text("Settings apply when you tap Play.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showControlEditor) {
            TouchControlEditor()
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
                title: Text("FALLOUT"),
                message: Text(model.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("FALLOUT")
                .font(.system(size: 27, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.green)

            Text("Community Edition")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)

            Spacer()

            Circle()
                .fill(model.install.installed == 1 ? Theme.green : Theme.amber)
                .frame(width: 7, height: 7)

            Text(model.isInstalling ? "INSTALLING" : (model.install.installed == 1 ? "READY" : "NO GAME DATA"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(model.install.installed == 1 ? Theme.green : Theme.amber)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Install

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("GAME DATA")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.install.installed == 1 ? Theme.green : Theme.amber)
                        .frame(width: 6, height: 6)

                    Text(model.install.installed == 1 ? "Ready to play" : "Game files required")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(model.install.installed == 1 ? Theme.green : Theme.text)
                }

                Text(model.install.installed == 1
                    ? "Your installation is ready. Choose Play to launch the game."
                    : "Import a ZIP containing master.dat, critter.dat and the data folder.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 5) {
                    fileRow("master.dat", present: model.install.has_master_dat == 1)
                    fileRow("critter.dat", present: model.install.has_critter_dat == 1)
                    fileRow("data folder", present: model.install.has_data_folder == 1)
                }

                if model.isInstalling {
                    ProgressView(value: min(max(model.progress, 0), 1))
                        .accentColor(Theme.green)

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
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                Button(action: {
                    model.showImporter = true
                }) {
                    Text(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT ZIP")
                }
                .buttonStyle(LauncherButtonStyle(filled: false))
                .disabled(model.isInstalling)

                Button(action: {
                    LauncherMusic.shared.stop()
                    model.play(onPlay: onPlay)
                }) {
                    Text("PLAY")
                }
                .buttonStyle(LauncherButtonStyle(filled: true))
                .disabled(model.install.installed == 0 || model.isInstalling)
                .opacity(model.install.installed == 1 ? 1 : 0.4)
            }
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
                sectionLabel("CONTROL LAYOUT")
                Spacer(minLength: 2)
                whiteButtonsToggle
            }

            controlScaleRow("JOYSTICK", value: $model.joystickScale)
            controlScaleRow("BUTTONS", value: $model.buttonScale)

            Button(action: {
                showControlEditor = true
            }) {
                Text("EDIT TOUCH CONTROLS")
            }
            .buttonStyle(CompactButtonStyle())
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
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
        .background(Theme.panel)
        .overlay(
            Rectangle()
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

private enum Theme {
    static let background = Color(red: 0.012, green: 0.026, blue: 0.012)
    static let panel = Color(red: 0.030, green: 0.055, blue: 0.030)
    static let green = Color(red: 0.55, green: 0.96, blue: 0.45)
    static let dim = Color(red: 0.44, green: 0.59, blue: 0.42)
    static let text = Color(red: 0.78, green: 0.90, blue: 0.76)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.32)
    static let line = Color(red: 0.16, green: 0.30, blue: 0.16)
}

private struct LauncherButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(filled ? Theme.background : Theme.green)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(filled ? Theme.green : Theme.panel)
            .overlay(
                Rectangle()
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
            .background(selected ? Theme.green : Theme.background)
            .overlay(
                Rectangle()
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
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

// MARK: - Touchscreen control editor

private struct TouchControlEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var centers = ControlLayout.allCenters()
    @State private var scales = ControlLayout.allScales()
    @State private var dragOrigins: [TouchControl: CGPoint] = [:]
    @State private var selected: TouchControl?
    @State private var whiteButtons = UserDefaults.standard.bool(forKey: "launcher.whiteButtons")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.ignoresSafeArea()

                previewSurface(geometry.size)

                ForEach(TouchControl.allCases) { control in
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
        .preferredColorScheme(.dark)
    }

    private var editorBar: some View {
        HStack(spacing: 10) {
            Text("TOUCH CONTROLS")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.green)

            Button("RESET") {
                ControlLayout.reset()
                centers = ControlLayout.allCenters()
                scales = ControlLayout.allScales()
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

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    mockHUD(in: size)
                    Spacer(minLength: 0)
                }
            }

            // The camera cutout, drawn at the same left edge position as the
            // real device so controls are not placed underneath it.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .frame(width: max(12, size.width * 0.02), height: size.height * 0.25)
                .position(x: max(12, size.width * 0.02), y: size.height * 0.45)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func mockHUD(in size: CGSize) -> some View {
        let hudWidth = size.width * 0.60
        let hudHeight = max(44, size.height * 0.17)

        return ZStack {
            Rectangle()
                .fill(Color(red: 0.14, green: 0.12, blue: 0.085).opacity(0.94))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("INV")
                    Text("AP 5")
                }
                .frame(width: hudWidth * 0.16, alignment: .leading)

                Rectangle()
                    .fill(Theme.line.opacity(0.8))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("You see a dark cave.")
                    Text("The air is cold.")
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Theme.line.opacity(0.8))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("HP 039")
                    Text("AC 007")
                }
                .frame(width: hudWidth * 0.18, alignment: .leading)
                .padding(.leading, 8)
            }
            .font(.system(size: max(6, min(9, hudHeight * 0.15)), weight: .bold, design: .monospaced))
            .foregroundColor(Theme.green.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Circle()
                .fill(Color(red: 0.55, green: 0.08, blue: 0.05))
                .frame(width: hudHeight * 0.17, height: hudHeight * 0.17)
                .overlay(Circle().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
                .position(x: hudWidth * 0.18, y: hudHeight * 0.17)

            Circle()
                .fill(Color(red: 0.55, green: 0.08, blue: 0.05))
                .frame(width: hudHeight * 0.17, height: hudHeight * 0.17)
                .overlay(Circle().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
                .position(x: hudWidth * 0.82, y: hudHeight * 0.17)
        }
        .frame(width: hudWidth, height: hudHeight)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private func editorSize(for control: TouchControl, in size: CGSize) -> CGSize {
        let base = control.defaultSize(in: size)
        let factor = scales[control] ?? 1
        return CGSize(
            width: max(24, base.width * factor),
            height: max(24, base.height * factor)
        )
    }

    private func editorCenter(for control: TouchControl, in size: CGSize) -> CGPoint {
        let point = centers[control] ?? control.defaultCenter
        let controlSize = editorSize(for: control, in: size)
        let halfWidth = controlSize.width / 2
        let halfHeight = controlSize.height / 2
        return CGPoint(
            x: min(max(point.x * size.width, halfWidth + 4), size.width - halfWidth - 4),
            y: min(max(point.y * size.height, halfHeight + 4), size.height - halfHeight - 4)
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
                ControlLayout.setScale(value, for: control)
            }
        )
    }

    private func dragGesture(for control: TouchControl, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                selected = control

                if dragOrigins[control] == nil {
                    dragOrigins[control] = centers[control] ?? control.defaultCenter
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
                ControlLayout.setCenter(CGPoint(x: x, y: y), for: control)
            }
            .onEnded { _ in
                dragOrigins[control] = nil
            }
    }
}
