import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void
    @State private var showControlEditor = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                header

                HStack(alignment: .top, spacing: 12) {
                    installPane
                        .frame(width: max(240, min(geometry.size.width * 0.34, 320)), alignment: .top)

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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("GAME DATA")

            if model.install.installed == 1 {
                Text("Ready to play")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.green)
            } else {
                Text("Import your own Fallout files")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.text)

                Text("Choose a ZIP containing master.dat, critter.dat and the data folder.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
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

            Spacer(minLength: 4)

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                displaySection
                audioSection
            }

            HStack(alignment: .top, spacing: 6) {
                controlsSection
                gameplaySection
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var gameplaySection: some View {
        section("GAMEPLAY") {
            HStack(spacing: 8) {
                Text("LANGUAGE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dim)

                Spacer(minLength: 4)

                Picker(selection: $model.language, label: EmptyView()) {
                    ForEach(0..<model.languageNames.count, id: \.self) { index in
                        Text(model.languageNames[index]).tag(index)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .accentColor(Theme.green)
            }

            Toggle(isOn: $model.alwaysRun) {
                Text("ALWAYS RUN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dim)
            }
            .toggleStyle(SwitchToggleStyle())
            .accentColor(Theme.green)
        }
    }

    private var controlsSection: some View {
        section("CONTROL LAYOUT") {
            controlScaleRow("JOYSTICK", value: $model.joystickScale)
            controlScaleRow("BUTTONS", value: $model.buttonScale)

            Button(action: {
                showControlEditor = true
            }) {
                Text("EDIT TOUCH CONTROLS")
            }
            .buttonStyle(LauncherButtonStyle(filled: false))
        }
    }

    private func controlScaleRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            settingLabel(title)
                .frame(width: 62, alignment: .leading)

            Slider(value: value, in: 0.75...1.35)
                .accentColor(Theme.green)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.dim)
                .frame(width: 34, alignment: .trailing)
        }
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
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var audioSection: some View {
        section("AUDIO") {
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
        .frame(width: 180, alignment: .top)
    }

    // MARK: - Shared pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(title)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Touchscreen control editor

private struct TouchControlEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var centers = ControlLayout.allCenters()
    @State private var dragOrigins: [TouchControl: CGPoint] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.ignoresSafeArea()

                mockPlayfield(geometry.size)

                ForEach(TouchControl.allCases) { control in
                    let controlSize = editorSize(for: control, in: geometry.size)
                    editorControl(control, size: controlSize)
                        .position(editorCenter(for: control, in: geometry.size))
                        .gesture(dragGesture(for: control, in: geometry.size))
                }

                VStack(spacing: 0) {
                    editorBar
                    Text("Drag any control to move it. Changes apply the next time you play.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
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
                dragOrigins.removeAll()
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

    private func mockPlayfield(_ size: CGSize) -> some View {
        ZStack {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: min(size.width * 0.56, 520), height: min(58, size.height * 0.16))
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    Spacer()
                }
                .padding(.bottom, 6)
            }

            // The camera cutout, so the editor shows the same left-edge
            // obstacle as the phone.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .frame(width: 16, height: min(90, size.height * 0.24))
                .position(x: 16, y: size.height * 0.45)
        }
    }

    private func editorSize(for control: TouchControl, in size: CGSize) -> CGFloat {
        switch control {
        case .joystick:
            return max(58, min(110, size.height * 0.28))
        case .action:
            return max(52, min(92, size.height * 0.20))
        case .skip:
            return max(42, min(76, size.height * 0.16))
        case .back:
            return max(38, min(66, size.height * 0.14))
        case .skill, .end:
            return max(38, min(78, size.height * 0.19))
        default:
            return max(38, min(78, size.height * 0.19))
        }
    }

    private func editorCenter(for control: TouchControl, in size: CGSize) -> CGPoint {
        let point = centers[control] ?? control.defaultCenter
        let half = editorSize(for: control, in: size) / 2
        return CGPoint(
            x: min(max(point.x * size.width, half + 8), size.width - half - 8),
            y: min(max(point.y * size.height, half + 8), size.height - half - 8)
        )
    }

    private func editorControl(_ control: TouchControl, size: CGFloat) -> some View {
        VStack(spacing: max(1, size * 0.045)) {
            Image(systemName: control.symbol)
                .font(.system(size: size * 0.34, weight: .semibold))

            Text(control.label)
                .font(.system(size: max(7, size * 0.18), weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundColor(control == .skip ? Theme.amber : Theme.green)
        .frame(width: size, height: size)
        .background(
            Group {
                if control == .joystick {
                    Circle().fill(Theme.panel.opacity(0.85))
                } else {
                    Rectangle().fill(Theme.panel.opacity(0.85))
                }
            }
        )
        .overlay(
            Group {
                if control == .joystick {
                    Circle().stroke(Theme.green.opacity(0.45), lineWidth: 1.5)
                } else {
                    Rectangle().stroke((control == .skip ? Theme.amber : Theme.green).opacity(0.55), lineWidth: 1.5)
                }
            }
        )
        .contentShape(Rectangle())
    }

    private func dragGesture(for control: TouchControl, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigins[control] == nil {
                    dragOrigins[control] = centers[control] ?? control.defaultCenter
                }
                guard let origin = dragOrigins[control] else {
                    return
                }

                let half = editorSize(for: control, in: size) / 2
                let x = min(max((origin.x * size.width + value.translation.width) / max(size.width, 1), (half + 8) / max(size.width, 1)), (size.width - half - 8) / max(size.width, 1))
                let y = min(max((origin.y * size.height + value.translation.height) / max(size.height, 1), (half + 8) / max(size.height, 1)), (size.height - half - 8) / max(size.height, 1))

                centers[control] = CGPoint(x: x, y: y)
                ControlLayout.setCenter(CGPoint(x: x, y: y), for: control)
            }
            .onEnded { _ in
                dragOrigins[control] = nil
            }
    }
}
