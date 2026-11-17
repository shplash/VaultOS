import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void

    @State private var cursorOn = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TerminalBackground()

                VStack(spacing: 8) {
                    header

                    HStack(alignment: .top, spacing: 10) {
                        installPane
                            .frame(width: max(300, min(geometry.size.width * 0.41, 390)))

                        Rectangle()
                            .fill(Theme.line)
                            .frame(width: 1)

                        optionsPane
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    footer
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshInstall()
            LauncherMusic.shared.playIfAvailable(installDirectory: model.installDirectory)
            withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                cursorOn = false
            }
        }
        .onChange(of: model.install.installed) { installed in
            if installed == 1 {
                LauncherMusic.shared.playIfAvailable(installDirectory: model.installDirectory)
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
                title: Text("FALLOUT LAUNCHER"),
                message: Text(model.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("☢")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.amber)

            VStack(alignment: .leading, spacing: 1) {
                Text("VAULT-TEC INDUSTRIES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(2)
                    .foregroundColor(Theme.amber)

                Text("ROBCO TERMLINK // PERSONAL COMPUTER")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundColor(Theme.dim)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(model.install.installed == 1 ? Theme.green : Theme.amber)
                    .frame(width: 6, height: 6)

                Text(model.install.installed == 1 ? "DATA LINK ONLINE" : "AWAITING GAME DATA")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(model.install.installed == 1 ? Theme.green : Theme.amber)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.panel.opacity(0.92))
        .overlay(
            Rectangle()
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    // MARK: - Install pane

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 3) {
                            Text("FALLOUT")
                                .font(.system(size: 38, weight: .black, design: .monospaced))
                                .kerning(1)
                                .foregroundColor(Theme.green)
                                .shadow(color: Theme.green.opacity(0.45), radius: 9)
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)

                            Text("█")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.green)
                                .opacity(cursorOn ? 1 : 0.1)
                        }

                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(Theme.amber)
                                .frame(width: 22, height: 1)

                            Text("COMMUNITY EDITION // iOS")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .kerning(1.4)
                                .foregroundColor(Theme.dim)

                            Spacer(minLength: 0)
                        }
                    }

                    Text("OVERSEER TERMINAL // INSTALLATION CONTROL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .kerning(0.8)
                        .foregroundColor(Theme.amber)

                    VStack(alignment: .leading, spacing: 5) {
                        fileRow("master.dat", present: model.install.has_master_dat == 1)
                        fileRow("critter.dat", present: model.install.has_critter_dat == 1)
                        fileRow("data folder", present: model.install.has_data_folder == 1)
                        fileRow("music archive", present: model.install.has_music == 1)
                    }
                    .padding(7)
                    .background(Theme.panel.opacity(0.75))
                    .overlay(
                        Rectangle()
                            .stroke(Theme.line, lineWidth: 1)
                    )

                    if model.isInstalling {
                        VStack(alignment: .leading, spacing: 5) {
                            ProgressView(value: min(max(model.progress, 0), 1))
                                .accentColor(Theme.green)

                            Text(model.statusText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.dim)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    } else if !model.statusText.isEmpty {
                        Text(model.statusText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.dim)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if model.install.has_saves == 1 {
                        Text("SAVEGAMES DETECTED // preserved on re-import")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.dim)
                            .lineLimit(2)
                    }

                    Text("Import a ZIP of your own Fallout installation. master.dat, critter.dat and the data folder are required.")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: {
                model.showImporter = true
            }) {
                Text(model.install.installed == 1 ? "REPLACE GAME FILES" : "IMPORT GAME ZIP")
            }
            .buttonStyle(LauncherButtonStyle(filled: false))
            .disabled(model.isInstalling)

            Button(action: {
                LauncherMusic.shared.stop()
                model.play(onPlay: onPlay)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("PLAY")
                }
            }
            .buttonStyle(LauncherButtonStyle(filled: true))
            .disabled(model.install.installed == 0 || model.isInstalling)
            .opacity(model.install.installed == 1 ? 1 : 0.4)
        }
    }

    private func fileRow(_ name: String, present: Bool) -> some View {
        HStack(spacing: 6) {
            Text(present ? "[ OK ]" : "[ -- ]")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(present ? Theme.green : Theme.amber)

            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(present ? Theme.text : Theme.dim)

            Spacer(minLength: 2)

            Text(present ? "LINKED" : "MISSING")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(present ? Theme.green : Theme.amber)
        }
    }

    // MARK: - Options pane

    private var optionsPane: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                section("DISPLAY // \(model.nativeResolutionLabel) NATIVE") {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6),
                            ],
                            spacing: 6
                        ) {
                            ForEach(model.presets) { preset in
                                Button(action: {
                                    model.apply(preset: preset)
                                }) {
                                    Text(preset.label)
                                }
                                .buttonStyle(ChipButtonStyle(selected: model.selected(preset: preset)))
                            }
                        }

                        HStack(alignment: .bottom, spacing: 8) {
                            DimensionField(title: "WIDTH", value: $model.width, range: 640...4096)

                            Text("x")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.dim)
                                .padding(.bottom, 7)

                            DimensionField(title: "HEIGHT", value: $model.height, range: 480...4096)
                        }

                        caption("FULL uses the panel's native pixel grid. HALF is the optional lighter mode. Type a custom value in the fields - no steppers.")
                    }
                }

                section("AUDIO") {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(isOn: $model.sound) {
                            caption("SOUND")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)

                        Toggle(isOn: $model.music) {
                            caption("MUSIC")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)

                        Toggle(isOn: $model.speech) {
                            caption("SPEECH")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)

                        caption("Volume and subtitles are set in the game's own options menu.")
                    }
                }

                section("GAMEPLAY") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            caption("LANGUAGE")

                            Spacer()

                            Picker(selection: $model.language, label: EmptyView()) {
                                ForEach(0..<model.languageNames.count, id: \.self) { index in
                                    Text(model.languageNames[index]).tag(index)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .accentColor(Theme.green)
                        }

                        Toggle(isOn: $model.alwaysRun) {
                            caption("ALWAYS RUN")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)
                    }
                }

                Button(action: {
                    model.saveOptions()
                }) {
                    Text("SAVE OPTIONS")
                }
                .buttonStyle(LauncherButtonStyle(filled: false))
                .disabled(model.install.installed == 0 || model.isInstalling)

                if model.savedNotice {
                    Text(">> SETTINGS WRITTEN TO fallout.cfg")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.green)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("VAULT-TEC(R) PERSONAL COMPUTER // MODEL 3000")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)

            Spacer()

            Text("READY")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.green)

            Text("//")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.line)

            Text(model.install.installed == 1 ? "GAME DATA OK" : "NO DATA")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(model.install.installed == 1 ? Theme.green : Theme.amber)
        }
        .padding(.horizontal, 2)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(">>")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.green)

                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .kerning(1.4)
                    .foregroundColor(Theme.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(
            Rectangle()
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
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

private struct TerminalBackground: View {
    var body: some View {
        ZStack {
            Theme.background

            LinearGradient(
                gradient: Gradient(stops: (0..<150).map { index in
                    Gradient.Stop(
                        color: Theme.green.opacity(index % 2 == 0 ? 0.028 : 0.0),
                        location: Double(index) / 150.0
                    )
                }),
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.58)]),
                center: .center,
                startRadius: 40,
                endRadius: 680
            )
        }
        .ignoresSafeArea()
    }
}

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
            .font(.system(size: 9, weight: selected ? .bold : .medium, design: .monospaced))
            .foregroundColor(selected ? Theme.background : Theme.green)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.green : Theme.background)
            .overlay(
                Rectangle()
                    .stroke(selected ? Theme.green : Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}
