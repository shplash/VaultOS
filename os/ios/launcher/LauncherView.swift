import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                installPane
                    .frame(width: max(300, geometry.size.width * 0.40))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 1)

                optionsPane
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshInstall()
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
                title: Text("Fallout Launcher"),
                message: Text(model.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Install pane

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FALLOUT")
                            .font(.system(size: 28, weight: .black, design: .monospaced))
                            .foregroundColor(Theme.green)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)

                        Text("COMMUNITY EDITION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .kerning(2.5)
                            .foregroundColor(Theme.dim)
                            .lineLimit(1)
                    }

                    Text("LAUNCHER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .kerning(2)
                        .foregroundColor(Theme.amber)

                    VStack(alignment: .leading, spacing: 5) {
                        fileRow("master.dat", present: model.install.has_master_dat == 1)
                        fileRow("critter.dat", present: model.install.has_critter_dat == 1)
                        fileRow("data folder", present: model.install.has_data_folder == 1)
                    }

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
                        Text("Savegames found. They are kept when you re-import.")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.dim)
                            .lineLimit(2)
                    }

                    Text("Use a ZIP of your own Fallout installation. master.dat, critter.dat and the data folder are required.")
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
            Image(systemName: present ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(present ? Theme.green : Theme.amber)

            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(present ? Theme.text : Theme.dim)

            Spacer(minLength: 2)

            Text(present ? "OK" : "MISSING")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(present ? Theme.green : Theme.amber)
        }
    }

    // MARK: - Options pane

    private var optionsPane: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                section("DISPLAY") {
                    VStack(alignment: .leading, spacing: 8) {
                        caption("INTERNAL RESOLUTION")

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

                        HStack(spacing: 12) {
                            Stepper(value: $model.width, in: 640...4096, step: 16) {
                                Text("W \(model.width)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.text)
                            }

                            Stepper(value: $model.height, in: 480...4096, step: 16) {
                                Text("H \(model.height)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.text)
                            }
                        }

                        Toggle(isOn: $model.scale2x) {
                            caption("PIXEL DOUBLING")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)

                        caption("Lower resolutions run smoother. Pixel doubling renders at half size for the original chunky look.")
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

                        volumeRow("MASTER", value: $model.masterVolume)
                        volumeRow("MUSIC", value: $model.musicVolume)
                        volumeRow("SOUND FX", value: $model.sfxVolume)
                        volumeRow("SPEECH", value: $model.speechVolume)
                    }
                }

                section("GAMEPLAY") {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker(selection: $model.language, label: caption("LANGUAGE")) {
                            ForEach(0..<model.languageNames.count, id: \.self) { index in
                                Text(model.languageNames[index]).tag(index)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())

                        Toggle(isOn: $model.subtitles) {
                            caption("SUBTITLES")
                        }
                        .toggleStyle(SwitchToggleStyle())
                        .accentColor(Theme.green)

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
                    Text("SETTINGS SAVED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.green)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .kerning(2)
                .foregroundColor(Theme.amber)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(
            Rectangle()
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.dim)
    }

    private func volumeRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                caption(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.text)
            }

            Slider(value: value, in: 0...100, step: 5)
                .accentColor(Theme.green)
        }
    }
}

// MARK: - Styling

private enum Theme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.035)
    static let panel = Color(red: 0.065, green: 0.095, blue: 0.065)
    static let green = Color(red: 0.55, green: 0.96, blue: 0.45)
    static let dim = Color(red: 0.45, green: 0.60, blue: 0.45)
    static let text = Color(red: 0.78, green: 0.90, blue: 0.76)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.32)
    static let line = Color(red: 0.18, green: 0.32, blue: 0.18)
}

private struct LauncherButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(filled ? Theme.background : Theme.green)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(filled ? Theme.green : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(Theme.green, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: selected ? .bold : .regular, design: .monospaced))
            .foregroundColor(selected ? Theme.background : Theme.green)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.green : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(selected ? Theme.green : Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
