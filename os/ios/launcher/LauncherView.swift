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
    @State private var showResetAllWarning = false
    /// The update check runs only while the player waits for it, and its answer
    /// is shown once in a note over the About page.
    @State private var isCheckingForUpdates = false
    @State private var updateOutcome: UpdateOutcome?

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
                if showResetAllWarning {
                    resetAllWarning
                }
            }
        )
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showControlEditor) {
            TouchControlEditor(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.shareFile != nil },
            set: { shown in
                if !shown {
                    model.shareFile = nil
                }
            }
        )) {
            if let url = model.shareFile {
                ShareSheet(items: [url])
            }
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
        .onChange(of: page) { _ in
            model.savesNotice = nil
            model.importSummary = nil
        }
        .onChange(of: model.install.installed) { installed in
            if installed == 1 {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // The app's Documents folder is in the Files app now, so game files
            // can be dropped in while the launcher is in the background. Look
            // at the installation again when it comes back to the front.
            model.refreshInstall()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Only the save-import countdown needs a tick. Without it this ran a
            // full redraw of the launcher every second for as long as it was open.
            guard showSaveImportWarning && saveImportCountdown > 0 else {
                return
            }
            saveImportCountdown -= 1
        }
        .onChange(of: model.showImporter) { shown in
            guard shown else {
                return
            }

            // One picker serves all three imports, and what it was opened for
            // has to be read now: its answer arrives later.
            model.showImporter = false
            presentImporter(for: pendingImport)
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
                message: Text(L.message(model.errorMessage ?? "")),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: updateOutcomeAlert) { () -> Alert in
            let outcome = updateOutcome ?? UpdateOutcome(message: "", address: nil)
            if let address = outcome.address, let url = URL(string: address) {
                return Alert(
                    title: Text(L.t("UPDATES")),
                    message: Text(outcome.message),
                    primaryButton: .default(Text(L.t("GET"))) {
                        UIApplication.shared.open(url)
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            }
            return Alert(
                title: Text(L.t("UPDATES")),
                message: Text(outcome.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Importing

    /// Opens the document picker in copy mode for whichever import asked for
    /// it, and hands what comes back to the model. LauncherDocumentPicker
    /// explains why the copy matters.
    private func presentImporter(for kind: LauncherImport) {
        LauncherLog.write("picker opened for \(kind)")

        LauncherDocumentPicker.shared.present { url in
            guard let url = url else {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 11)

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
        .padding(.top, 11)
        .padding(.bottom, 14 + bottom)
        .frame(width: 152 + leading, alignment: .leading)
        .background(Theme.rail)
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
                    .frame(width: 16, alignment: .leading)

                Text(item.title)
                    .font(Vault.label(10, weight: selected ? .bold : .regular))
                    .kerning(1.1)

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
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        Button {
            LauncherMusic.shared.stop()
            model.play(onPlay: onPlay)
        } label: {
            VStack(spacing: 4) {
                Text(L.t("PLAY"))
                    .font(Vault.display(21))
                    .kerning(1.6)

                Text(statusText)
                    .font(Vault.label(8, weight: .bold))
                    .kerning(1.3)
                    .foregroundColor(Vault.ink.opacity(0.62))
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(game.accent)
                        .frame(width: 6, height: 6)

                    Text(game.title.uppercased())
                        .font(Vault.display(32))
                        .kerning(0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
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
        case .about:
            aboutSheet
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
                        .disabled(model.isInstalling || model.install.installed == 0)

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
                .padding(.vertical, 9)
                .overlay(
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1),
                    alignment: .bottom
                )

                savegamesRow

                if model.isInstalling {
                    ProgressView(value: min(max(model.progress, 0), 1))
                        .accentColor(accent)
                        .padding(.vertical, 10)

                    Text(L.message(model.statusText))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                } else if let summary = model.importSummary {
                    Text(summary)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Theme.faint)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }

                if model.importSummary == nil {
                    footnote(model.install.has_saves == 1
                        ? "Your existing saves are kept. Re-importing replaces the game files only."
                        : "Each game keeps its own data, configuration and savegames.")

                    footnote("LANGUAGE FILES adds a translation pack to this game. The game files themselves are left alone.")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaultPlate(corner: 20, fill: Theme.rail)
        .padding(.horizontal, 18)
        .padding(.top, 12)
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

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        aboutLink("GITHUB", address: "https://github.com/shplash/fallout1-ce-iosimproved", primary: true)
                        aboutLink(L.t("SUPPORT ME"), address: "https://ko-fi.com/shplash", primary: true)
                    }

                    Text(model.selectedGame.title.uppercased())
                        .font(Vault.display(54))
                        .kerning(1.4)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(L.t(model.selectedGame.tagline))
                        .font(Vault.body(12))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)

                    Text(L.t("COMMUNITY EDITION"))
                        .font(Vault.label(9, weight: .bold))
                        .kerning(2.4)
                        .foregroundColor(accent)
                }
                .padding(.leading, 22)
                .frame(maxWidth: geometry.size.width * 0.60, alignment: .leading)
            }
        }
        .frame(height: 172)
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
                            colors: [Color.clear, Theme.rail.opacity(0.92)],
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
        let name = isFallout2 ? "fallout2" : "fallout1"
        if let image = UIImage(named: name) {
            return image
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: isFallout2 ? "jpeg" : "webp") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    private var tipsSheet: some View {
        sheet(title: "MANUAL", detail: tipGroup.detail) {
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

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
        .accessibilityLabel("Open \(title)")
    }

    /// Where to report things, and who to credit for the rest.
    ///
    /// The links sit in the header, outside the scroll view: the way to a bug
    /// report can never scroll out of reach, and only the credits - text nobody
    /// taps, in a fixed order - move. This is the launcher's only scroll view,
    /// and it holds static rows only.
    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("INFO"))
                        .font(Vault.display(27))
                        .kerning(1.2)
                        .foregroundColor(Theme.text)

                    Text(L.t("Who made this, and what it is built on"))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: "v\(appVersionShort)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.dim)

                    Text(verbatim: "build \(appBuild)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.faint)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                aboutLink(L.t("REQUEST"), address: "https://github.com/shplash/fallout1-ce-iosimproved/issues/new?template=feature_request.yml", primary: true)
                aboutLink(L.t("BUG"), address: "https://github.com/shplash/fallout1-ce-iosimproved/issues/new?template=bug_report.yml", primary: true)
                checkForUpdatesButton

                Spacer(minLength: 0)

                resetAllButton
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    tip("shplash", "Launcher interface and touch controls.")
                    tip("Engines", "Fallout Community Edition and Fallout 2 Community Edition by Alexander Batalov (alexbatalov), under the Sustainable Use License.")
                    tip("Libraries", "SDL 2.0 (zlib licence), zlib and fpattern. Their notices apply to this distribution.")
                    tip("Notices", "Fallout is a trademark of Bethesda Softworks. Unofficial fan project, not affiliated with Bethesda or Interplay. You must own the games to play.")
                    footnote("The app contains no game data; bring your own installation.")
                }
                .padding(.horizontal, 22)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaultPlate(corner: 20, fill: Theme.rail)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16 + screenInsets.bottom)
    }

    /// The version as built, so a bug report can name it.
    private var appVersionShort: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var appBuild: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    private func aboutLink(_ title: String, address: String, primary: Bool) -> some View {
        wikiLink(title, address: address, primary: primary)
    }

    /// What the update check came back with: one line, and the release page when
    /// there is something newer to get.
    private struct UpdateOutcome: Equatable {
        let message: String
        let address: String?
    }

    /// Asks GitHub for the newest release. It sits with the other page links and
    /// takes the game's accent like them.
    private var checkForUpdatesButton: some View {
        Button {
            checkForUpdates()
        } label: {
            HStack(spacing: 4) {
                Text(isCheckingForUpdates ? L.t("CHECKING") : L.t("UPDATES"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(0.6)

                Image(systemName: isCheckingForUpdates ? "hourglass" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(Color.black.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCheckingForUpdates)
        .accessibilityLabel(L.t("Check for updates"))
    }

    private var resetAllButton: some View {
        Button {
            showResetAllWarning = true
        } label: {
            HStack(spacing: 4) {
                Text(L.t("RESET ALL"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(0.6)

                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(Theme.dim)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("Reset all settings"))
    }

    /// The check's answer, shown as a small popup over the launcher rather than a
    /// row on the page: a row would make the About page taller and bring in a
    /// slider's worth of layout shift.
    private var updateOutcomeAlert: Binding<Bool> {
        Binding(
            get: { updateOutcome != nil },
            set: { shown in
                if !shown {
                    updateOutcome = nil
                }
            }
        )
    }

    /// Asks GitHub for the newest release and compares it with the version this
    /// build reports. A check that could not be made says so instead of looking
    /// like a build that is up to date.
    private func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }
        // The list, not releases/latest: that endpoint skips prereleases and
        // drafts, and this project publishes its builds as a draft, so it could
        // only ever answer 404.
        guard let url = URL(string: "https://api.github.com/repos/shplash/fallout1-ce-iosimproved/releases?per_page=1") else {
            return
        }

        isCheckingForUpdates = true
        updateOutcome = nil

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let current = appVersionShort
        URLSession.shared.dataTask(with: request) { data, _, error in
            let outcome = LauncherView.outcomeFromGitHub(data: data,
                                                         error: error,
                                                         current: current)
            DispatchQueue.main.async {
                self.isCheckingForUpdates = false
                self.updateOutcome = outcome
            }
        }.resume()
    }

    /// Reads the newest release out of GitHub's list and compares its tag with
    /// this build. Anything unexpected - no network, a rate limit, a shape that
    /// changed - ends as a plain failure rather than a wrong answer, and an
    /// empty list is said plainly instead of being reported as an error.
    private static func outcomeFromGitHub(data: Data?,
                                          error: Error?,
                                          current: String) -> UpdateOutcome {
        guard error == nil,
              let data = data,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return UpdateOutcome(message: L.t("Could not check for updates. Try again later."),
                                 address: nil)
        }

        guard let release = releases.first,
              let tag = release["tag_name"] as? String else {
            return UpdateOutcome(message: L.t("No releases have been published yet."),
                                 address: nil)
        }

        // Tags are written v1.0.1 as often as 1.0.1.
        let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let address = release["html_url"] as? String

        if compareVersions(latest, current) > 0 {
            return UpdateOutcome(message: "\(L.t("Update available")) \(latest) · \(L.t("you have")) \(current)",
                                 address: address)
        }
        return UpdateOutcome(message: "\(L.t("Up to date")) · \(current)", address: address)
    }

    /// Compares version strings number by number, so 1.10 comes after 1.9, and a
    /// missing part counts as zero: 1.0 and 1.0.0 are the same release.
    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = versionNumbers(lhs)
        let right = versionNumbers(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a < b ? -1 : 1
            }
        }
        return 0
    }

    private static func versionNumbers(_ version: String) -> [Int] {
        return version
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
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
                    ("Inventory", L.t("Hold and drag an item to equip or move it.") + " " + L.t("Tap an item while INSPECT is toggled on to see its characteristics.") + " " + L.t("Hold an item with INSPECT on to open its extra actions: use, look, unload and drop.")),
                    ("Dialogue", "In Fallout 2, BARTER on the right trades with whoever you are talking to."),
                    ("Combat", "The START COMBAT button changes to SKIP TURN when combat starts."),
                    ("Auto target", "On by default: the game switches to attack mode as a fight starts, so the first tap is an attack."),
                ]
            case .survival:
                return [
                    ("Skills pay", "The skilldex covers Doctor, First Aid and Lockpick. Using them beats guessing at a door or a wound."),
                    ("Talk first", "Many fights can be talked past, and quests tend to pay better than what you can loot."),
                    ("Aim", "An aimed shot costs one more action point and can cripple a limb, which often ends a fight faster than damage."),
                    ("VATS", "The attack mode's aimed steps are the game's VATS: they show the chance to hit and cost one more action point."),
                    ("Skills", "While a skill is armed the mode button reads USE SKILL, and pressing it goes back to move or target. Arm one from the skilldex or from an object's menu."),
                ]
            case .launcher:
                return [
                    ("Import once", "Import a ZIP per game. Importing again replaces the game data and keeps your savegames."),
                    ("HALF or FULL", "HALF keeps the interface readable on a phone; FULL is sharpest on a tablet."),
                    ("Per game", "Resolution, audio, language and controls are stored separately for each game."),
                    ("Own folders", "Fallout keeps its files in Documents, Fallout 2 in Documents/Fallout2, so the two never mix."),
                    ("Layout", "Every control can be moved, resized, faded and coloured from Controls."),
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
                    .font(Vault.label(10, weight: .bold))
                    .kerning(0.6)
                    .foregroundColor(Theme.text)

                Text(L.t(text))
                    .font(Vault.label(9))
                    .kerning(0.2)
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
        sheet(title: "VIDEO", detail: "How large the game world and its interface are drawn", onReset: resetDisplay) {
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
                    HStack(spacing: 6) {
                        Text(L.t(preset.id.uppercased()))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .kerning(1.6)
                            .foregroundColor(selected ? accent : Theme.faint)

                        if preset.id == "half" {
                            Text(L.t("(recommended)"))
                                .font(.system(size: 8, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.faint)
                        } else if preset.id == "full" {
                            Text(L.t("(experimental)"))
                                .font(.system(size: 8, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.faint)
                        }
                    }

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
                    .fill(selected ? accent.opacity(0.12) : Vault.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
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
        sheet(title: "SYSTEM", detail: "Language, subtitles and how the character moves", onReset: resetGame) {
            row("Language", detail: "Game text, voice, the launcher and the controls. This does not change the in-game language used, add more with LANGUAGE FILES on HOME to add your own.") {
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
            toggleRow("Always sprint",
                      detail: "Moves at a run everywhere",
                      isOn: $model.alwaysRun)

            row("Auto quick save", detail: nil) {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            model.autoSaveMinutes = max(0, model.autoSaveMinutes - 1)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(SmallButtonStyle(accent: accent))
                        .disabled(model.autoSaveMinutes == 0)

                        Text(verbatim: model.autoSaveMinutes == 0
                                ? L.t("OFF")
                                : "\(model.autoSaveMinutes) " + L.t("MIN"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(model.autoSaveMinutes == 0 ? Theme.faint : accent)
                            .frame(width: 48)

                        Button {
                            model.autoSaveMinutes = min(10, model.autoSaveMinutes + 1)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(SmallButtonStyle(accent: accent))
                        .disabled(model.autoSaveMinutes == 10)
                    }

                    HStack(spacing: 6) {
                        Text(L.t("Haptic on save"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.dim)

                        Button {
                            model.saveHaptics.toggle()
                        } label: {
                            PillToggle(isOn: model.saveHaptics, accent: accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.t("Haptic on save"))
                    }
                }
            }
        }
    }

    private var controlsSheet: some View {
        sheet(title: "CONTROLS", detail: "Colour and opacity of the on-screen controls", onReset: resetControls) {
            toggleRow("On-screen controls",
                      detail: "Draw the touch controls over the game. Off, the screen is the game alone.",
                      isOn: $model.touchControls)

            // The layout, colour and opacity rows are greyed, not hidden, while
            // the controls are off: there is nothing on the screen to edit,
            // colour or dim then.
            row("Control scheme", detail: "Where the buttons sit and how big they are. Best judged over the game screen itself.") {
                Button {
                    showControlEditor = true
                } label: {
                    Text(L.t("EDIT LAYOUT"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
            }
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            toggleRow("Auto target in combat",
                      detail: "Switch to attack mode by itself when a fight starts.",
                      isOn: $model.autoTarget)

            row("Button colour", detail: "The colour of a control's label and the wash while you hold it") {
                Menu {
                    ForEach(ControlColour.allCases) { colour in
                        Button(L.t(colour.title)) {
                            model.buttonColour = colour.rawValue
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.controlColour.color)
                            .frame(width: 10, height: 10)

                        Text(L.t(model.controlColour.title))
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
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            row("Opacity", detail: "How solid the on-screen controls are") {
                HStack(spacing: 12) {
                    Slider(value: $model.controlsOpacity, in: 0.10...1)
                        .accentColor(accent)
                        .frame(width: 200)

                    Text(verbatim: "\(Int((model.controlsOpacity * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            // Greyed out, not hidden, while the on-screen controls are off.
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)
        }
    }

    /// Backing the saves up is harmless; putting a backup back replaces them, so
    /// that one waits out a countdown with the warning on screen.
    private var savegamesRow: some View {
        row("Saved games", detail: model.savesNotice.map { L.message($0) }) {
            HStack(spacing: 8) {
                Button {
                    model.backupSaves()
                } label: {
                    Text(L.t("BACK UP"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
                .disabled(model.isInstalling || model.install.installed == 0 || model.install.has_saves == 0)

                Button {
                    saveImportCountdown = 5
                    showSaveImportWarning = true
                } label: {
                    Text(L.t("IMPORT"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
                .disabled(model.isInstalling || model.install.installed == 0)
            }
        }
    }

    private var saveImportWarning: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(L.t("Replace your saved games?").uppercased())
                    .font(Vault.display(20))
                    .kerning(0.8)
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
            .vaultPlate(corner: 18, fill: Theme.sheet)
            .padding(24)
        }
    }

    private var resetAllWarning: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(L.t("Reset every setting?").uppercased())
                    .font(Vault.display(20))
                    .kerning(0.8)
                    .foregroundColor(Theme.text)

                Text(L.t("Every setting in the launcher goes back to its default - resolution, audio, language, subtitles and the touch controls - for both games. Your game files and your saved games are kept."))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(L.t("CANCEL")) {
                        showResetAllWarning = false
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                    Button(L.t("RESET ALL")) {
                        showResetAllWarning = false
                        model.resetEverything()
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.black.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent)
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .vaultPlate(corner: 18, fill: Theme.sheet)
            .padding(24)
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
                .font(Vault.label(9))
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
        model.subtitles = true
        model.alwaysRun = true
        model.autoSaveMinutes = 5
        model.saveHaptics = true
    }

    private func resetControls() {
        model.joystickScale = 1
        model.buttonScale = 1
        model.controlsOpacity = 1
        model.touchControls = true
        model.autoTarget = true
        model.buttonColour = ControlColour.white.rawValue
    }

    // MARK: - Sheet pieces

    private func sheet<C: View>(title: String, detail: String, onReset: (() -> Void)? = nil, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t(title))
                        .font(Vault.display(27))
                        .kerning(1.2)
                        .foregroundColor(Theme.text)

                    Text(L.t(detail))
                        .font(Vault.label(9))
                        .kerning(0.4)
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
                .fill(accent.opacity(0.55))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaultPlate(corner: 20, fill: Theme.rail)
        .padding(.horizontal, 18)
        .padding(.top, 12)
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
                        .font(Vault.label(9))
                        .kerning(0.2)
                        .foregroundColor(Theme.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func footnote(_ text: String) -> some View {
        Text(L.t(text))
            .font(Vault.label(9))
            .kerning(0.2)
            .foregroundColor(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
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
    case about

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .home: return L.t("Home").uppercased()
        case .display: return L.t("VIDEO")
        case .audio: return L.t("AUDIO")
        case .game: return L.t("SYSTEM")
        case .touch: return L.t("CONTROLS")
        case .tips: return L.t("MANUAL")
        case .about: return L.t("INFO")
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
        case .about: return "info.circle"
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
            return Vault.amber
        case .fallout2:
            return Vault.teal
        }
    }
}

private enum Theme {
    static let background = Vault.hull
    static let sheet = Vault.plate
    /// The rail's own fill. The home sheet uses it too, so the panel and the
    /// bar are one surface instead of a blue-grey plate over a darker one.
    static let rail = Vault.plate.opacity(0.55)
    static let panel = Vault.panel
    static let line = Vault.hairline
    static let hairline = Vault.hairline
    static let text = Vault.text
    static let dim = Vault.dim
    static let faint = Vault.faint
}

private struct LauncherBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.075, green: 0.082, blue: 0.094),
                    Vault.hull,
                    Color.black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [accent.opacity(0.14), accent.opacity(0)],
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
            .fill(isOn ? accent.opacity(0.9) : Color.white.opacity(0.08))
            .frame(width: 44, height: 24)
            .overlay(
                Circle()
                    .fill(isOn ? Vault.ink : Color.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .offset(x: isOn ? 10 : -10)
            )
            .overlay(
                Capsule()
                    .stroke(isOn ? accent.opacity(0.9) : Vault.hairline, lineWidth: 1)
            )
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return configuration.label
            .foregroundColor(Vault.ink)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(shape.fill(accent))
            .overlay(shape.stroke(Vault.edgeLight, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return configuration.label
            .font(Vault.label(10, weight: .semibold))
            .foregroundColor(accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                shape.fill(configuration.isPressed ? accent.opacity(0.18) : Vault.inset)
            )
            .overlay(shape.stroke(accent.opacity(configuration.isPressed ? 0.85 : 0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .modifier(DisabledDim())
    }
}

private struct DisabledDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.4)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let source = UIApplication.shared.windows.first
        controller.popoverPresentationController?.sourceView = source
        if let source = source {
            controller.popoverPresentationController?.sourceRect = CGRect(x: source.bounds.midX,
                                                                          y: source.bounds.midY,
                                                                          width: 1,
                                                                          height: 1)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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

    /// The editor's own chrome is drawn in the colour the player picked for the
    /// controls, so the tool and the thing it edits look alike. The game's own
    /// accent stays on the launcher pages, where it marks the game.
    private var accent: Color {
        return model.controlColour.color
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.ignoresSafeArea()

                previewSurface(geometry.size)

                saveAssemblyPreview(in: geometry.size)

                ForEach(TouchControl.controls(for: game)) { control in
                    let controlSize = editorSize(for: control, in: geometry.size)
                    editorControl(control, size: controlSize, selected: selected == control)
                        .position(editorCenter(for: control, in: geometry.size))
                        .gesture(dragGesture(for: control, in: geometry.size))
                        .opacity(model.controlsOpacity)
                }

                // One centred bar across the top holds the editor's controls and
                // its own HIDE/SHOW toggle. The toggle sits at the same place in
                // both states - the middle of the top edge - so it never moves
                // when the bar is hidden or shown. Hiding removes the bar and
                // leaves only the toggle.
                VStack(spacing: 0) {
                    if !barsHidden {
                        chrome(in: geometry.size)
                    }
                    barsToggle
                        .padding(.top, barsHidden ? 0 : 6)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8 + LauncherHost.safeInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .statusBar(hidden: true)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// The capsule's width is fixed so its label never moves the bar: HIDE BARS
    /// and SHOW BARS are the same nine characters in the monospaced face it is
    /// drawn in, and the label shrinks rather than spilling out if that changes.
    private static let toggleWidth: CGFloat = 116

    /// Hides the editor's own bars to give the whole screen to the layout. It is
    /// a filled capsule with a word on it, deliberately unlike the controls it
    /// sits among. It stays in the middle of the top edge in both states, so
    /// the player never has to look for it.
    private var barsToggle: some View {
        Button {
            barsHidden.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: barsHidden ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))

                Text(L.t(barsHidden ? "SHOW BARS" : "HIDE BARS"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(width: TouchControlEditor.toggleWidth)
            .background(Capsule().fill(accent))
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t(barsHidden ? "SHOW BARS" : "HIDE BARS"))
    }

    /// The editor's own controls, in one bar across the top. The controls it
    /// edits sit on the right and along the bottom, so the bar keeps to the
    /// middle of the top edge and leaves the corners free.
    ///
    /// The bar is only as wide as its two rows are: a fixed share of the screen
    /// left most of it empty, which made a small tool look like a wide toolbar.
    ///
    /// Hiding the bars takes this bar away and nothing else: only the toggle is
    /// left, in the same place, so the whole screen is free to lay out.
    private func chrome(in size: CGSize) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L.t("Touch controls").uppercased())
                    .font(Vault.display(19))
                    .kerning(1)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 14)

                presetButton("PRESET 1", profile: .half)
                presetButton("PRESET 2", profile: .full)

                Button(L.t("RESET")) {
                    ControlLayout.reset(profile: profile, game: game)
                    model.controlsOpacity = 1
                    centers = ControlLayout.allCenters(profile: profile, game: game)
                    scales = ControlLayout.allScales(profile: profile, game: game)
                    dragOrigins.removeAll()
                    selected = nil
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.dim)

                Button(L.t("DONE")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Vault.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent)
                )
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Text(L.t("OPACITY"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(1.1)
                    .foregroundColor(Theme.faint)

                Slider(value: $model.controlsOpacity, in: 0.10...1)
                    .accentColor(accent)
                    .frame(width: 76)

                Text(verbatim: "\(Int((model.controlsOpacity * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
                    .frame(width: 30, alignment: .leading)

                // SIZE belongs to the control that was pressed, and it keeps its
                // place in the row either way: the panel never changes shape
                // under the player's finger, it only lights up.
                Text(L.t("SIZE"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(1.1)
                    .foregroundColor(selected == nil ? Theme.faint : accent)

                Slider(value: scaleBinding(for: selected), in: 0.55...1.8)
                    .accentColor(accent)
                    .frame(width: 76)
                    .disabled(selected == nil)
                    .opacity(selected == nil ? 0.4 : 1)

                Text(verbatim: sizePercent)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected == nil ? Theme.faint : Theme.dim)
                    .frame(width: 30, alignment: .leading)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Its own two rows decide the width, so nothing is left over at the
        // sides. The toggle below it follows the same width in both states.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.background.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func presetButton(_ title: String, profile target: LayoutProfile) -> some View {
        Button(L.t(title)) {
            profile = target
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

    /// The game's own screen, drawn where the renderer puts it, with the
    /// interface bar marked in the place the game actually draws it: 640 by 100
    /// game pixels, centred horizontally and sitting on the bottom edge in both
    /// engines. The editor view is not the game screen, so both are mapped
    /// through the same aspect fit SDL applies, which is why the marker no
    /// longer drifts away from the real bar when the resolution changes.
    private func previewSurface(_ size: CGSize) -> some View {
        let screen = gameScreen(in: size)
        let bar = interfaceBar(in: size)

        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.056, blue: 0.062),
                    Color(red: 0.075, green: 0.076, blue: 0.083),
                    Theme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: screen.width, height: screen.height)
                .offset(x: screen.minX, y: screen.minY)

            // A plain opaque red rectangle for the in-game HUD: the exact
            // footprint the controls have to avoid. No fake interface.
            ZStack {
                Rectangle()
                    .fill(Color.red.opacity(0.85))

                Text(verbatim: "HUD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1.4)
                    .foregroundColor(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            }
            .frame(width: bar.width, height: bar.height)
            .offset(x: bar.minX, y: bar.minY)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// The interface bar's size in game pixels. Both engines draw the same
    /// 640 by 100 bar; Fallout 2's optional leather side panels are switched
    /// off in the app, so the bar is all that is left of the HUD.
    private static let interfaceBarSize = CGSize(width: 640, height: 100)

    private func gameScreen(in size: CGSize) -> CGRect {
        let gameWidth = max(CGFloat(model.width), 1)
        let gameHeight = max(CGFloat(model.height), 1)
        let scale = min(size.width / gameWidth, size.height / gameHeight)
        let shown = CGSize(width: gameWidth * scale, height: gameHeight * scale)
        return CGRect(x: (size.width - shown.width) / 2,
                      y: (size.height - shown.height) / 2,
                      width: shown.width,
                      height: shown.height)
    }

    private func interfaceBar(in size: CGSize) -> CGRect {
        let screen = gameScreen(in: size)
        let scale = screen.width / max(CGFloat(model.width), 1)
        let barWidth = min(screen.width, TouchControlEditor.interfaceBarSize.width * scale)

        // The bar is 100 game pixels tall at every resolution, so past the HALF
        // default it becomes a thin sliver of a bigger game screen. The marker
        // keeps the height it has at that default, which is the room the
        // controls need to keep clear of the HUD however large the game is set.
        let half = LauncherModel.displayResolution(divisor: 3)
        let height = min(CGFloat(model.height), CGFloat(half.1))
        let barHeight = min(screen.height,
                            TouchControlEditor.interfaceBarSize.height * screen.height / max(height, 1))

        return CGRect(x: screen.minX + (screen.width - barWidth) / 2,
                      y: screen.maxY - barHeight,
                      width: barWidth,
                      height: barHeight)
    }

    private func editorSize(for control: TouchControl, in size: CGSize) -> CGSize {
        return ControlLayout.displaySize(for: control, in: size, profile: profile, game: game)
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

    /// QUICK SAVE and the chevron share one plate in the game, with a divider
    /// between them, so the editor draws the pair the same way rather than as
    /// two buttons that are not what the player will see.
    private func saveAssembly(in size: CGSize) -> (frame: CGRect, dividerX: CGFloat) {
        let quickSize = editorSize(for: .quickSave, in: size)
        let quickCenter = editorCenter(for: .quickSave, in: size)
        let traySize = editorSize(for: .tray, in: size)
        let trayCenter = editorCenter(for: .tray, in: size)

        let quick = CGRect(x: quickCenter.x - quickSize.width / 2,
                           y: quickCenter.y - quickSize.height / 2,
                           width: quickSize.width,
                           height: quickSize.height)
        let tray = CGRect(x: trayCenter.x - traySize.width / 2,
                          y: trayCenter.y - traySize.height / 2,
                          width: traySize.width,
                          height: traySize.height)
        return (quick.union(tray), tray.minX)
    }

    private func saveAssemblyPreview(in size: CGSize) -> some View {
        let assembly = saveAssembly(in: size)
        let radius = max(6, min(min(18, assembly.frame.height * 0.20), assembly.frame.width * 0.28))
        let dividerHeight = assembly.frame.height * 0.62

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Vault.controlFill.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Vault.controlBorder, lineWidth: 1.5)
                )
                .frame(width: assembly.frame.width, height: assembly.frame.height)

            Rectangle()
                .fill(Vault.controlBorder.opacity(0.7))
                .frame(width: 1, height: dividerHeight)
                .offset(x: assembly.dividerX - assembly.frame.minX,
                        y: (assembly.frame.height - dividerHeight) / 2)
        }
        .frame(width: assembly.frame.width, height: assembly.frame.height, alignment: .topLeading)
        .position(x: assembly.frame.midX, y: assembly.frame.midY)
        .allowsHitTesting(false)
    }

    private func editorControl(_ control: TouchControl, size: CGSize, selected: Bool) -> some View {
        let shortSide = min(size.width, size.height)
        let shape = RoundedRectangle(cornerRadius: min(18, min(shortSide * 0.20, size.width * 0.28)), style: .continuous)
        let joined = control == .quickSave || control == .tray

        return Group {
            if control == .skip {
                VStack(spacing: max(0, shortSide * 0.01)) {
                    Text(L.t("START"))
                    Text(L.t("COMBAT"))
                    HStack(spacing: max(1, shortSide * 0.04)) {
                        Image(systemName: "burst")
                            .font(.system(size: max(6, min(11, shortSide * 0.16)), weight: .semibold))
                        Text(verbatim: "-")
                        Image(systemName: "forward.end")
                            .font(.system(size: max(6, min(11, shortSide * 0.16)), weight: .semibold))
                    }
                    Text(L.t("SKIP"))
                    Text(L.t("TURN"))
                }
                .font(Vault.label(max(8, min(12, shortSide * 0.17)), weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            } else if control == .quickSave {
                HStack(spacing: max(2, shortSide * 0.05)) {
                    Image(systemName: control.symbol)
                        .font(.system(size: max(9, min(24, shortSide * 0.5)), weight: .semibold))

                    Text(control.label)
                        .font(Vault.label(max(9, min(14, shortSide * 0.24)), weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal, max(3, shortSide * 0.08))
            } else {
                VStack(spacing: max(1, shortSide * 0.035)) {
                    if control == .fireMode {
                        Image(uiImage: GameControlsOverlay.fireModeImage(3).withRenderingMode(.alwaysTemplate))
                            .resizable()
                            .scaledToFit()
                            .frame(height: max(9, min(24, shortSide * 0.32)))
                    } else {
                        Image(systemName: control.symbol)
                            .font(.system(size: max(9, min(32, shortSide * 0.46)), weight: .semibold))
                    }

                    if control != .tray {
                        Text(control.label)
                            .font(Vault.label(max(9, min(13, shortSide * 0.19)), weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .foregroundColor(accent)
        .frame(width: size.width, height: size.height)
        .background(
            Group {
                if joined {
                    Color.clear
                } else if control == .joystick {
                    Circle().fill(Vault.controlFill.opacity(0.8))
                } else {
                    shape.fill(Vault.controlFill.opacity(0.8))
                }
            }
        )
        .overlay(
            Group {
                if joined {
                    if selected {
                        shape.stroke(Color.white, lineWidth: 2.4)
                    }
                } else if control == .joystick {
                    Circle().stroke(selected ? Color.white : Vault.controlBorder,
                                    lineWidth: selected ? 2.4 : 1.5)
                } else {
                    shape.stroke(selected ? Color.white : Vault.controlBorder,
                                 lineWidth: selected ? 2.4 : 1.5)
                }
            }
        )
        .contentShape(Rectangle())
    }

    /// The size of whichever control is selected, as a readout for the panel.
    private var sizePercent: String {
        guard let selected = selected, let scale = scales[selected] else {
            return "—"
        }
        return "\(Int((scale * 100).rounded()))%"
    }

    /// Drives the panel's size slider. With nothing selected it has nothing to
    /// move, so the slider is disabled and this binding holds its thumb still.
    private func scaleBinding(for control: TouchControl?) -> Binding<Double> {
        Binding(
            get: {
                guard let control = control else {
                    return 1
                }
                return Double(scales[control] ?? 1)
            },
            set: { newValue in
                guard let control = control else {
                    return
                }
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



// MARK: - Launcher log

/// A line-by-line record of what the launcher itself did: what the picker was
/// opened for, what it handed back, whether that file could be read, and what
/// each import was given. It lives beside the game data as
/// `vaultos-launcher.log`, separate from the engine's `vaultos-log.txt` because
/// the engine truncates its own file on every start.
///
/// Nothing here is for the player. It exists so that a picker which does
/// nothing can be read instead of guessed at.
enum LauncherLog {
    static func write(_ message: String) {
        NSLog("VaultOS: %@", message)

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else {
            return
        }

        let file = documents.appendingPathComponent("vaultos-launcher.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

// MARK: - Document picker

/// The document picker, in copy mode.
///
/// `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` copies
/// the chosen archive into the app's own temporary directory before handing it
/// over, so the import never depends on a security scope the app is allowed to
/// open - the difference between working and doing nothing on a sideloaded
/// install. SwiftUI's `fileImporter` has no copy mode on iOS 14, which is why
/// this is UIKit.
final class LauncherDocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = LauncherDocumentPicker()

    private var completion: ((URL?) -> Void)?

    func present(completion: @escaping (URL?) -> Void) {
        guard let controller = LauncherDocumentPicker.topViewController() else {
            LauncherLog.write("picker: no view controller to present from")
            completion(nil)
            return
        }

        self.completion = completion

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.zip], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        controller.present(picker, animated: true)
        LauncherLog.write("picker: presented")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(with: nil, reason: "cancelled")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(with: urls.first, reason: urls.isEmpty ? "nothing selected" : "selected")
    }

    private func finish(with url: URL?, reason: String) {
        if let url = url {
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            LauncherLog.write("picker: \(reason) \(url.path) (readable: \(readable))")
        } else {
            LauncherLog.write("picker: \(reason)")
        }

        completion?(url)
        completion = nil
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.windows
        let window = windows.first { $0.isKeyWindow && !$0.isHidden }
            ?? windows.first { !$0.isHidden }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
