import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Fixed window: a page rail, the selected page as a sheet of rows, and Play at
// the bottom of the rail. Nothing scrolls; a scroll view in the engine's nested
// run loop hung the launcher.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onPlay: () -> Void

    @State private var page: LauncherPage = .home
    @State private var showControlEditor = false
    @State private var tipGroup: TipGroup = .touch
    @State private var musicMuted = LauncherMusic.isMuted
    /// What the ZIP picker is being opened for.
    @State private var pendingImport: LauncherImport = .game
    @State private var savesScroll: CGFloat = 0
    @State private var savesDragStart: CGFloat?
    /// The picked save. Picking loads nothing; CONTINUE does that.
    @State private var selectedSlot: Int?
    /// The saves box's frame and slide limit in card coordinates, so a drag on
    /// it is not mistaken for a page turn.
    @State private var savesBox = SavesBox()
    @State private var pagingDrag = false
    @State private var showSaveImportWarning = false
    @State private var saveImportCountdown = 0
    @State private var showNewGameWarning = false
    @State private var newGameCountdown = 0
    /// How many dots follow INSTALLING while an import is going.
    @State private var installingDots = 0
    @State private var showResetAllWarning = false
    /// Set while the update check runs; the answer is shown once over About.
    @State private var isCheckingForUpdates = false
    @State private var updateOutcome: UpdateOutcome?
    @State private var homeDrag: CGFloat = 0
    @State private var homeAtEdge = false
    @State private var hasSwipedHome = false
    @State private var dragWatchdog: DispatchWorkItem?
    @State private var homeNudge: CGFloat = 0
    @State private var isPaging = false
    @State private var swipeHintTask: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        return model.selectedGame.accent
    }

    /// Below this size the launcher scales instead of clipping a page to fit.
    /// A phone or tablet is always above it, so nothing scales there.
    private static let smallestLayout = CGSize(width: 560, height: 320)

    /// Coordinate space of the home card, so a saves drag can be told from a
    /// page turn.
    private static let cardSpace = "launcher.homeCard"

    /// What the display keeps for the sensor housing and home indicator. The
    /// launcher draws edge to edge and keeps its content inside these.
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
        // Edge to edge like the game: leaving the safe area to SwiftUI shrank
        // the launcher into a box with black bands on cut-out devices.
        .ignoresSafeArea()
        .overlay(
            Group {
                if showSaveImportWarning {
                    saveImportWarning
                }
                if showNewGameWarning {
                    newGameWarning
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
            model.refreshSaves()
            scheduleSwipeHint()
            if !musicMuted {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .onDisappear {
            swipeHintTask?.cancel()
            swipeHintTask = nil
            dragWatchdog?.cancel()
            dragWatchdog = nil
            model.saveSettingsNow()
        }
        .onChange(of: page) { _ in
            model.savesNotice = nil
            model.importSummary = nil
            if page == .home {
                scheduleSwipeHint()
            } else {
                swipeHintTask?.cancel()
                swipeHintTask = nil
            }
        }
        .onChange(of: model.install.installed) { installed in
            if installed == 1 {
                LauncherMusic.shared.playIfAvailable()
            }
        }
        .onChange(of: model.selectedGame) { _ in
            // A picked save belongs to the game and scroll position it was
            // picked in.
            selectedSlot = nil
            savesScroll = 0
        }
        .onChange(of: model.saves.count) { _ in
            if selectedSave == nil {
                selectedSlot = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // The Documents folder is in the Files app, so files can be dropped
            // in while the launcher is in the background: look again on return.
            model.refreshInstall()
            model.refreshSaves()

            // Saves can still be locked for a moment after the app is let back
            // in while the device unlocks: read them again once that settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.refreshSaves()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Move the dots so a long import is seen to be running.
            if model.isInstalling {
                installingDots = (installingDots + 1) % 3
            } else {
                installingDots = 0
            }

            // Only the countdowns need a tick; without this the launcher
            // redrew every second.
            if showSaveImportWarning && saveImportCountdown > 0 {
                saveImportCountdown -= 1
            }
            if showNewGameWarning && newGameCountdown > 0 {
                newGameCountdown -= 1
            }
        }
        .onChange(of: model.showImporter) { shown in
            guard shown else {
                return
            }

            // One picker serves all three imports; its kind must be read now
            // because the answer arrives later.
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

    /// Opens the picker in copy mode and hands the choice to the model.
    /// LauncherDocumentPicker explains why the copy matters.
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(LauncherPage.allCases) { item in
                    railItem(item)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            playButton
                .padding(.top, 14)
        }
        .padding(.leading, Metrics.outer + leading)
        .padding(.trailing, Metrics.outer)
        .padding(.top, Metrics.outer)
        .padding(.bottom, Metrics.outer + bottom)
        .frame(width: 172 + leading, alignment: .leading)
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
                    .frame(width: 3, height: 18)

                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)

                Text(item.title)
                    .font(Vault.label(13, weight: selected ? .bold : .regular))
                    .kerning(1.0)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? Theme.text : Theme.faint)
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.05) : Color.clear)
                    .padding(.vertical, 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxHeight: 52)
    }

    /// The saves, from the hero's divider to the card's bottom. That divider is
    /// the header, so the slots get the room a header would take.
    private func savesColumn(game: FalloutGame,
                             width: CGFloat,
                             rowHeight: CGFloat,
                             selected: Bool) -> some View {
        // Two whole slots and a fifth: the sliver at the right edge is what
        // shows the row slides.
        let spacing: CGFloat = 8
        let visible: CGFloat = 2.2
        let cardWidth = max(48, (width - spacing) / visible)
        // The picture carries its own name, so a card takes the full row height.
        let cardHeight = max(40, rowHeight)
        let content = CGFloat(10) * cardWidth + CGFloat(9) * spacing
        let limit = min(0, width - content)

        return savesRow(game: game,
                        width: width,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        limit: limit)
            .frame(width: width, height: rowHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            // Only the box on screen reports its frame; the other card is laid
            // out a page away.
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SavesBoxKey.self,
                        value: selected
                            ? SavesBox(rect: geometry.frame(in: .named(LauncherView.cardSpace)),
                                       limit: limit)
                            : SavesBox())
                }
            )
    }

    /// The game data, right of the saves and ending where they end. While an
    /// import runs or has just been reported, the bar and message take the
    /// buttons' place.
    @ViewBuilder
    private func gameDataColumn(game: FalloutGame,
                                info: LauncherInstallInfo,
                                width: CGFloat,
                                height: CGFloat) -> some View {
        // The heading's line and the two gaps around the buttons come out of
        // the height.
        let spacing: CGFloat = 4
        let buttonHeight = max(22, (height - 14 - spacing * 2) / 2)

        VStack(alignment: .leading, spacing: spacing) {
            headerLine(L.t("Game data"),
                       badge: info.installed == 1 ? "DONE" : "NEEDED")

            if model.isInstalling || model.importSummary != nil {
                gameDataStatus(game: game)
            } else {
                Button {
                    pendingImport = .language
                    model.showImporter = true
                } label: {
                    Text(L.t("LANGUAGE FILES"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SmallButtonStyle(accent: game.accent, minHeight: buttonHeight))
                .disabled(model.isInstalling || info.installed == 0)

                Button {
                    pendingImport = .game
                    model.showImporter = true
                } label: {
                    Text(L.t(info.installed == 1 ? "REPLACE FILES" : "IMPORT ZIP"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SmallButtonStyle(accent: game.accent, minHeight: buttonHeight))
                .disabled(model.isInstalling)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func gameDataStatus(game: FalloutGame) -> some View {
        if model.isInstalling {
            ProgressView(value: min(max(model.progress, 0), 1))
                .accentColor(game.accent)

            Text(installingLabel)
                .font(Vault.label(10, weight: .regular))
                .foregroundColor(Theme.faint)
                .lineLimit(1)
        } else if let summary = model.importSummary {
            Text(summary)
                .font(Vault.label(10, weight: .regular))
                .foregroundColor(Theme.faint)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savesRow(game: FalloutGame,
                          width: CGFloat,
                          cardWidth: CGFloat,
                          cardHeight: CGFloat,
                          limit: CGFloat) -> some View {
        let spacing: CGFloat = 8

        return HStack(spacing: spacing) {
            ForEach(1...10, id: \.self) { slot in
                let save = model.saves.first { $0.slot == slot }

                // The game's colour marks the save CONTINUE would open (picked,
                // or the newest); an empty slot is white only while picked.
                saveCard(slot: slot,
                         save: save,
                         active: save != nil && slot == (selectedSlot ?? model.saves.first?.slot),
                         chosen: save == nil && slot == selectedSlot,
                         width: cardWidth,
                         height: cardHeight)
            }
        }
        .offset(x: min(0, max(limit, savesScroll)))
        .frame(width: width, alignment: .leading)
        .frame(height: cardHeight, alignment: .leading)
        .clipped()
    }

    private func saveCard(slot: Int,
                          save: LauncherModel.LauncherSave?,
                          active: Bool,
                          chosen: Bool,
                          width: CGFloat,
                          height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        // Inset equally from every corner so the plate reads as laid on the
        // shot.
        let inset = max(4, min(width, height) * 0.03)

        return Group {
            if let save = save {
                savePicture(save: save, width: width, height: height)
                    .overlay(
                        // The shot carries its name, time and level, so no line
                        // is needed below.
                        savePlate(save: save, width: width - inset * 2)
                            .padding(inset),
                        alignment: .topLeading
                    )
            } else {
                // An empty slot: a save mark and EMPTY SLOT in the notes'
                // grey.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: width, height: height)
                    .overlay(
                        VStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(Theme.faint)

                            Text(L.t("EMPTY SLOT"))
                                .font(Vault.label(8, weight: .regular))
                                .kerning(1.0)
                                .foregroundColor(Theme.faint)
                        }
                    )
            }
        }
        // Borders are drawn inside the picture's edge: grey on every slot, the
        // game's colour on the save CONTINUE opens, white on a picked empty
        // slot. Drawn inside, they cover the scaled shot's edge.
        .overlay(shape.strokeBorder(Color(white: 0.72).opacity(0.30), lineWidth: 1))
        .overlay(shape.strokeBorder(active ? accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .overlay(shape.strokeBorder(chosen ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // Any slot can be picked, empty or not; picking it again lets it
            // go.
            selectedSlot = selectedSlot == slot ? nil : slot
        }
        .contextMenu {
            if let save = save {
                deleteItem(save)
            }
        }
    }

    /// The save's picture, filling the card and clipped to its corners, so the
    /// border lands on its outer pixels.
    @ViewBuilder
    private func savePicture(save: LauncherModel.LauncherSave,
                             width: CGFloat,
                             height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

        if let url = save.preview, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
                .clipShape(shape)
        } else {
            shape
                .fill(Color.white.opacity(0.05))
                .frame(width: width, height: height)
        }
    }

    /// The save's name and detail on a small plate over its shot, as wide as
    /// the detail needs.
    private func savePlate(save: LauncherModel.LauncherSave, width: CGFloat) -> some View {
        // Eighteen percent under the card's own type, so the plate stays a
        // note on the shot.
        let scale: CGFloat = 0.82
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let detail = saveDetail(save)
        let detailWidth = ceil((detail as NSString).size(withAttributes: [
            .font: VaultUI.label(9 * scale),
            .kern: 0.6
        ]).width)
        // The row's width plus the plate's padding, and no more: a long name
        // is cut instead of widening it.
        let plateWidth = min(max(40, detailWidth + 15 * scale), max(40, width))

        return VStack(alignment: .leading, spacing: 1) {
            Text(save.name)
                .font(Vault.label(10 * scale, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(detail)
                .font(Vault.label(9 * scale, weight: .regular))
                .kerning(0.6)
                .foregroundColor(Theme.faint)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 5 * scale)
        .frame(width: plateWidth)
        .background(shape.fill(Color.black.opacity(0.34)))
        .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 5),
            alignment: .top
        )
    }

    /// Play time and level, or the date for saves written before the game kept
    /// a time.
    private func saveDetail(_ save: LauncherModel.LauncherSave) -> String {
        var parts: [String] = []
        if let played = save.played {
            parts.append(played)
        }

        if save.level > 0 {
            parts.append("\(L.t("LVL")) \(save.level)")
        }

        // Close, but not tight enough to read as one word.
        return parts.isEmpty ? save.saved : parts.joined(separator: "·")
    }

    /// Destructive roles need iOS 15; on iOS 14 the item is a plain button.
    @ViewBuilder
    private func deleteItem(_ save: LauncherModel.LauncherSave) -> some View {
        if #available(iOS 15.0, *) {
            Button(role: .destructive) {
                model.delete(save: save)
            } label: {
                Text(L.t("Delete"))
            }
        } else {
            Button {
                model.delete(save: save)
            } label: {
                Text(L.t("Delete"))
            }
        }
    }

    private var playButton: some View {
        // Kerning includes the space after the last letter, which pushes the
        // line off centre by half of it; take it back with trailing padding.
        let titleKerning: CGFloat = 1.6
        let nameKerning: CGFloat = 1.3
        let detailKerning: CGFloat = 1.4

        return Button {
            // An empty slot starts the game rather than loading a save that is
            // not there.
            if selectedSlot == nil || selectedSave != nil,
               let save = selectedSave ?? model.saves.first {
                LauncherMusic.shared.stop()
                model.play(onPlay: onPlay, loadSlot: save.slot)
            } else {
                // A new game shares this game's slots rather than making its
                // own, so it asks first, with the music still playing.
                newGameCountdown = 5
                showNewGameWarning = true
            }
        } label: {
            VStack(spacing: 3) {
                Text(buttonTitle)
                    .font(Vault.display(24))
                    .kerning(titleKerning)
                    .padding(.trailing, -titleKerning)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                Text(statusText)
                    .font(Vault.label(10, weight: .bold))
                    .kerning(nameKerning)
                    .foregroundColor(Vault.ink.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, -nameKerning)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                // Time played and level under the name, in a thinner face.
                if let detail = continueDetail {
                    Text(detail)
                        .font(Vault.label(9, weight: .regular))
                        .kerning(detailKerning)
                        .foregroundColor(Vault.ink.opacity(0.46))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.trailing, -detailKerning)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            // The height is set inside the style so the fill is that height
            // too, and PLAY stays as tall as CONTINUE without a detail line.
            .frame(maxWidth: .infinity, minHeight: LauncherView.continueHeight - 20)
        }
        .buttonStyle(PrimaryButtonStyle(accent: accent))
        .disabled(model.install.installed == 0 || model.isInstalling)
        .opacity(model.install.installed == 1 ? 1 : 0.35)
    }

    /// The save on the picked slot, if it has one.
    private var selectedSave: LauncherModel.LauncherSave? {
        guard let slot = selectedSlot else {
            return nil
        }

        return model.saves.first { $0.slot == slot }
    }

    /// Whether the picked slot is empty, which means the next game rather than a
    /// save to go back to.
    private var picksEmptySlot: Bool {
        return selectedSlot != nil && selectedSave == nil
    }

    /// PLAY on an empty pick or with no saves, CONTINUE otherwise.
    private var buttonTitle: String {
        if model.saves.isEmpty || picksEmptySlot {
            return L.t("PLAY")
        }

        return L.t("CONTINUE")
    }

    /// INSTALLING with the dots that show a long import still running.
    private var installingLabel: String {
        return L.t("INSTALLING") + String(repeating: ".", count: installingDots + 1)
    }

    private var statusText: String {
        if model.isInstalling {
            return installingLabel
        }

        // An empty slot names the game it starts instead of a save.
        if picksEmptySlot {
            return L.t("NEW GAME")
        }

        if let save = selectedSave ?? model.saves.first {
            return save.name.uppercased()
        }

        return L.t(model.install.installed == 1 ? "READY" : "NEEDS FILES")
    }

    /// The save's play time and level under its name; a new game has neither.
    private var continueDetail: String? {
        guard !model.isInstalling, !picksEmptySlot else {
            return nil
        }

        guard let save = selectedSave ?? model.saves.first else {
            return nil
        }

        // Saves from before play time was kept would read as `0:00 · LEVEL 0`,
        // so only what they carry is listed.
        var parts: [String] = []
        if let played = save.played {
            parts.append(played)
        }

        if save.level > 0 {
            parts.append("\(L.t("LVL")) \(save.level)")
        }

        // Close, but not tight enough to read as one word.
        return parts.isEmpty ? nil : parts.joined(separator: "·")
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home:
            homePager
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

    private var homePager: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let currentIndex = model.selectedGame == .fallout1 ? 0 : 1
            let raw = homeDrag
            let drag = homeAtEdge ? raw * 0.28 : raw
            let pageWidth = width

            ZStack(alignment: .top) {
                ForEach(FalloutGame.allCases) { game in
                    let index = game == .fallout1 ? 0 : 1
                    let relative = CGFloat(index - currentIndex)
                    let offset = relative * (pageWidth + 6) + drag + homeNudge
                    let isSelected = game == model.selectedGame

                    homeSheet(game: game,
                              info: model.installInfos[game] ?? LauncherInstallInfo(),
                              width: pageWidth,
                              height: geometry.size.height,
                              selected: isSelected)
                        .frame(width: pageWidth, height: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .opacity(isSelected ? 1 : 0.45)
                        .offset(x: offset)
                        .allowsHitTesting(isSelected && !isPaging)
                }
            }
            // The card runs from the top of the page to the bottom of Play beside
            // it.
            .frame(width: width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            // One gesture for the whole card: a drag that begins in the saves box
            // slides its slots, any other turns the page. Two competing gestures
            // left the box scrolling the page instead of itself.
            .coordinateSpace(name: LauncherView.cardSpace)
            .simultaneousGesture(homePagingGesture(width: pageWidth))
            .onPreferenceChange(SavesBoxKey.self) { box in
                savesBox = box
            }
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.top, Metrics.outer)
        .padding(.bottom, Metrics.outer + screenInsets.bottom)
    }

    private func homePagingGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // A drag that began in the saves box slides its slots and leaves
                // the page alone.
                if savesBox.rect.contains(value.startLocation) {
                    if savesDragStart == nil {
                        savesDragStart = savesScroll
                    }
                    savesScroll = min(0, max(savesBox.limit,
                                             (savesDragStart ?? 0) + value.translation.width))
                    pagingDrag = false
                    homeDrag = 0
                    return
                }

                guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else {
                    return
                }
                pagingDrag = true
                homeDrag = value.translation.width
                homeAtEdge = (model.selectedGame == .fallout1 && value.translation.width > 0)
                    || (model.selectedGame == .fallout2 && value.translation.width < 0)
                isPaging = true
                scheduleDragWatchdog()
                if !hasSwipedHome {
                    hasSwipedHome = true
                    swipeHintTask?.cancel()
                    swipeHintTask = nil
                }
            }
            .onEnded { value in
                dragWatchdog?.cancel()
                dragWatchdog = nil

                // The slots stay where the finger left them, with nothing to
                // settle.
                if savesDragStart != nil {
                    savesDragStart = nil
                    savesScroll = min(0, max(savesBox.limit, savesScroll))
                    return
                }

                guard pagingDrag else {
                    return
                }
                pagingDrag = false

                var target = model.selectedGame
                if abs(value.translation.width) > abs(value.translation.height) * 1.2 {
                    let index = model.selectedGame == .fallout1 ? 0 : 1
                    let raw = value.translation.width
                    let atEdge = (index == 0 && raw > 0) || (index == 1 && raw < 0)
                    let drag = atEdge ? raw * 0.28 : raw
                    let predicted = value.predictedEndTranslation.width
                    let direction = abs(predicted) > abs(drag) ? predicted : drag
                    let shouldChange = abs(drag) > width * 0.22 || abs(predicted) > width * 0.35
                    let nextIndex = shouldChange ? min(max(index + (direction < 0 ? 1 : -1), 0), 1) : index
                    target = nextIndex == 0 ? FalloutGame.fallout1 : .fallout2
                }

                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86)) {
                    homeDrag = 0
                    if target != model.selectedGame {
                        model.selectedGame = target
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    isPaging = false
                }
            }
    }

    private func scheduleDragWatchdog() {
        dragWatchdog?.cancel()
        let task = DispatchWorkItem {
            isPaging = false
            pagingDrag = false
            guard abs(homeDrag) > 0.5 else {
                return
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.86)) {
                homeDrag = 0
            }
        }
        dragWatchdog = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    /// The two games as one switch, exactly as wide as the word FALLOUT, so it
    /// reads as part of the title and never reaches into the 2.
    private func gameSwitcher(width: CGFloat) -> some View {
        let segment = width / 2
        let progress = model.selectedGame == .fallout1 ? CGFloat(0) : 1

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(accent.opacity(0.18))
                .frame(width: segment, height: LauncherView.switchHeight)
                .offset(x: progress * segment)

            HStack(spacing: 0) {
                ForEach(FalloutGame.allCases) { game in
                    Button {
                        switchHome(to: game)
                    } label: {
                        Text(game.title)
                            .font(Vault.label(12, weight: .semibold))
                            .kerning(1.2)
                            .foregroundColor(model.selectedGame == game ? accent : Theme.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: LauncherView.switchHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(game.title)
                    .accessibilityAddTraits(model.selectedGame == game ? .isSelected : [])
                }
            }
        }
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .frame(width: width, height: LauncherView.switchHeight)
    }

    private func switchHome(to game: FalloutGame) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.82)) {
            model.selectedGame = game
        }
    }

    private func scheduleSwipeHint() {
        guard page == .home,
              !reduceMotion,
              !UserDefaults.standard.bool(forKey: "launcher.swipeHintShown") else { return }
        let task = DispatchWorkItem {
            guard !hasSwipedHome, page == .home else { return }
            UserDefaults.standard.set(true, forKey: "launcher.swipeHintShown")
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                homeNudge = -24
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    homeNudge = 0
                }
            }
        }
        swipeHintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
    }

    private func homeSheet(game: FalloutGame,
                           info: LauncherInstallInfo,
                           width: CGFloat,
                           height: CGFloat,
                           selected: Bool) -> some View {
        let gameAccent = game.accent
        let buttonFont = VaultUI.label(10, weight: .semibold)
        let columns = width - Metrics.sheetInset * 2
        // The game data is as wide as its buttons and sits at the far right.
        let labels = [L.t("LANGUAGE FILES"),
                      L.t(info.installed == 1 ? "REPLACE FILES" : "IMPORT ZIP")]
        let widest = labels.reduce(CGFloat(0)) { widest, name in
            max(widest, ceil((name as NSString).size(withAttributes: [.font: buttonFont]).width))
        }
        // A button carries its own padding, so the column fits the widest label
        // without clipping at the card's edge.
        let filesWidth = max(126, widest + 30)
        let savesWidth = max(columns - filesWidth - 19, 90)
        return VStack(alignment: .leading, spacing: 0) {
            hero(game: game)

            Rectangle()
                .fill(gameAccent.opacity(0.8))
                .frame(height: 1)

            // The saves sit on the card's bottom line, the line Play beside them
            // ends on.
            Spacer(minLength: Metrics.gap)

            HStack(alignment: .top, spacing: 0) {
                savesColumn(game: game,
                            width: savesWidth,
                            rowHeight: LauncherView.continueHeight,
                            selected: selected)

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)

                gameDataColumn(game: game,
                               info: info,
                               width: filesWidth,
                               height: LauncherView.continueHeight)
                    .padding(.leading, 18)
            }
            .frame(height: LauncherView.continueHeight)
            .padding(.horizontal, Metrics.sheetInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .homePlate(corner: 20)
    }

    private static let heroTitleSize: CGFloat = 68

    /// Tagline and edition sizes: large enough to read as branding, not as notes.
    private static let heroTaglineSize: CGFloat = 16
    private static let heroEditionSize: CGFloat = 12

    /// The room the game switch takes above the title.
    private static let switchHeight: CGFloat = 30

    /// Diameter of the two link discs; everything about a disc is a share of
    /// this one number.
    private static let linkDisc: CGFloat = 16

    /// Tap height of a link, taller than the disc and the word it draws.
    private static let linkTapHeight: CGFloat = 44

    /// The height CONTINUE is drawn at; the saves row beside it matches, so the
    /// two read as one band across the launcher.
    private static var continueHeight: CGFloat {
        let title = VaultUI.display(24).lineHeight
        let name = VaultUI.label(10, weight: .bold).lineHeight
        let detail = VaultUI.label(9, weight: .regular).lineHeight
        // Two gaps between the three lines, plus the button's own padding.
        return title + name + detail + 6 + 20
    }

    /// Width of the word FALLOUT, which the game switch above it matches so it
    /// ends where the word ends.
    private static var heroTitleWidth: CGFloat {
        let font = VaultUI.display(heroTitleSize)
        let width = (("FALLOUT" as NSString).size(withAttributes: [.font: font, .kern: 1.4])).width
        return ceil(width)
    }

    /// Width of COMMUNITY EDITION, which the two links under it match so the row
    /// belongs to that line.
    private static var heroEditionWidth: CGFloat {
        let font = VaultUI.label(heroEditionSize, weight: .bold)
        let width = ((L.t("COMMUNITY EDITION") as NSString).size(withAttributes: [.font: font, .kern: 2.4])).width
        return ceil(width)
    }

    private static var heroHeight: CGFloat {
        let title = VaultUI.display(heroTitleSize).lineHeight
        let tagline = VaultUI.label(heroTaglineSize).lineHeight
        let edition = VaultUI.label(heroEditionSize, weight: .bold).lineHeight
        // The tagline is pulled twelve points up under the name and the edition
        // two more, so the three lines read as one block.
        return 14 + switchHeight + 8 + title + 2 - 12 + tagline + 2 - 2 + edition + 2 + 7 + 20 + 14
    }

    private func hero(game: FalloutGame) -> some View {
        GeometryReader { geometry in
            let artWidth = min(min(geometry.size.width * 0.54, 340), geometry.size.height * 4 / 3)
            let artHeight = artWidth * 3 / 4

            ZStack(alignment: .leading) {
                heroArt(game: game, width: artWidth, height: artHeight)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .id(game)
                    .transition(.opacity)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    // The switch sits in the name's column, as wide as FALLOUT
                    // alone, so both start at the same edge.
                    gameSwitcher(width: min(LauncherView.heroTitleWidth,
                                            max(120, geometry.size.width * 0.62 - Metrics.sheetInset)))
                        .padding(.bottom, 6)

                    Text(game.title.uppercased())
                        .font(Vault.display(LauncherView.heroTitleSize))
                        .kerning(1.4)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(L.t(game.tagline))
                        .font(Vault.body(LauncherView.heroTaglineSize))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                        .padding(.top, -12)

                    Text(L.t("COMMUNITY EDITION"))
                        .font(Vault.label(LauncherView.heroEditionSize, weight: .bold))
                        .kerning(2.4)
                        .foregroundColor(game.accent)
                        .padding(.top, -2)

                    // The two links, each a frosted disc with its mark cut out,
                    // set to the width of the line above.
                    HStack(spacing: 0) {
                        plainLink("GITHUB", address: "https://github.com/shplash/vaultos") {
                            Image("github-mark")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: LauncherView.linkDisc * 0.84,
                                       height: LauncherView.linkDisc * 0.84)
                        }

                        Spacer(minLength: 10)

                        plainLink(L.t("SUPPORT ME"), address: "https://ko-fi.com/shplash") {
                            Image("donate-mark")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: LauncherView.linkDisc * 0.84,
                                       height: LauncherView.linkDisc * 0.84)
                        }
                    }
                    .frame(width: LauncherView.heroEditionWidth, alignment: .leading)
                    // The tap area reaches further up and down than the marks it
                    // draws; pulling the row up by that much leaves the marks
                    // where they were.
                    .padding(.top, -5)
                }
                .padding(.top, 14)
                .padding(.bottom, 14)
                .padding(.leading, Metrics.sheetInset)
                .frame(maxWidth: geometry.size.width * 0.62, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minHeight: LauncherView.heroHeight, maxHeight: .infinity)
    }

    /// A link under the edition: a frosted disc with its mark cut out, then the
    /// name. The disc is the whole icon, and the button is taller than it so a
    /// finger can find it.
    private func plainLink<Glyph: View>(_ title: String,
                                        address: String,
                                        @ViewBuilder glyph: () -> Glyph) -> some View {
        return Button {
            if let url = URL(string: address) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 5) {
                CutoutIconDisc(diameter: LauncherView.linkDisc, glyph: glyph)

                Text(title)
                    .font(Vault.label(10, weight: .semibold))
                    .kerning(1.0)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(Theme.dim)
            .frame(minHeight: LauncherView.linkTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title)")
    }

    private func heroArt(game: FalloutGame, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let image = artwork(for: game) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .saturation(0.82)
                    .brightness(-0.03)
                    .overlay(Color(red: 0.40, green: 0.25, blue: 0.11).opacity(0.16))
                    .overlay(
                        LinearGradient(colors: [Color.clear, Theme.rail.opacity(0.92)],
                                       startPoint: .center, endPoint: .bottom)
                    )
                    .overlay(
                        RadialGradient(colors: [Color.clear, Color.black.opacity(0.45)],
                                       center: .center, startRadius: width * 0.22, endRadius: width * 0.64)
                    )
                    .mask(
                        LinearGradient(gradient: Gradient(stops: [
                            .init(color: Color.black.opacity(0), location: 0),
                            .init(color: Color.black.opacity(0.55), location: 0.30),
                            .init(color: Color.black, location: 0.58)
                        ]), startPoint: .leading, endPoint: .trailing)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private static var artworkCache: [FalloutGame: UIImage] = [:]

    /// Each game's own still, bundle first and kept, so a redraw never reads it
    /// again.
    private func artwork(for game: FalloutGame) -> UIImage? {
        if let cached = LauncherView.artworkCache[game] {
            return cached
        }

        let isFallout2 = game == .fallout2
        let name = isFallout2 ? "fallout2" : "fallout1"
        let image = UIImage(named: name)
            ?? Bundle.main.url(forResource: name, withExtension: isFallout2 ? "jpeg" : "webp")
                .flatMap { UIImage(contentsOfFile: $0.path) }

        if let image = image {
            LauncherView.artworkCache[game] = image
        }
        return image
    }

    private var tipsSheet: some View {
        sheet(title: "MANUAL", detail: tipGroup.detail) {
            HStack(spacing: 8) {
                ForEach(TipGroup.allCases) { group in
                    tipPill(group, selected: tipGroup == group)
                }
                Spacer(minLength: 0)

                Text(verbatim: "WIKI:")
                    .font(Vault.label(9))
                    .kerning(0.8)
                    .foregroundColor(Theme.faint)

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

            ForEach(0..<((tipGroup.items.count + 1) / 2), id: \.self) { pair in
                HStack(alignment: .top, spacing: Metrics.sheetInset) {
                    tip(tipGroup.items[pair * 2].title,
                        tipGroup.items[pair * 2].text,
                        divider: false)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if pair * 2 + 1 < tipGroup.items.count {
                        tip(tipGroup.items[pair * 2 + 1].title,
                            tipGroup.items[pair * 2 + 1].text,
                            divider: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxWidth: .infinity)
                    }
                }
                .overlay(
                    Rectangle()
                        .fill((pair + 1) * 2 < tipGroup.items.count ? Theme.hairline : Color.clear)
                        .frame(height: 1),
                    alignment: .bottom
                )
            }
        }
    }

    private func tipPill(_ group: TipGroup, selected: Bool) -> some View {
        Button {
            tipGroup = group
        } label: {
            Text(L.t(group.title))
                .kerning(0.8)
        }
        .buttonStyle(ChipStyle(accent: accent, look: selected ? .selected : .unselected))
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
                    .kerning(0.8)
                    .lineLimit(1)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .fixedSize()
        }
        .buttonStyle(ChipStyle(accent: accent, look: primary ? .selected : .unselected))
        .accessibilityLabel("Open \(title)")
    }

    /// Where to report things, and who to credit for the rest.
    ///
    /// The links stay in the header, outside the scroll view, so a bug report
    /// can never scroll out of reach. Only the credits scroll.
    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("INFO", detail: "Who made this, and what it is built on") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: "v\(appVersionShort)")
                        .font(Vault.label(14, weight: .bold))
                        .foregroundColor(Theme.dim)

                    Text(verbatim: "build \(appBuild)")
                        .font(Vault.label(9))
                        .foregroundColor(Theme.faint)
                }
            }

            HStack(spacing: 8) {
                aboutLink(L.t("REQUEST"), address: "https://github.com/shplash/vaultos/issues/new?template=feature_request.yml", primary: true)
                aboutLink(L.t("BUG"), address: "https://github.com/shplash/vaultos/issues/new?template=bug_report.yml", primary: true)
                checkForUpdatesButton

                Spacer(minLength: 0)

                resetAllButton
            }
            .padding(.horizontal, Metrics.sheetInset)
            .padding(.bottom, 10)

            Rectangle()
                .fill(accent.opacity(0.55))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    tip("shplash", "The iOS app, its launcher and touch controls.")
                    // The licence asks a modified copy to say so: this is that
                    // notice.
                    tip("Engines", "A modified version of Fallout Community Edition and Fallout 2 Community Edition by Alexander Batalov (alexbatalov), under the Sustainable Use License. The launcher, the iOS port and the touch controls are added here.")
                    tip("Libraries", "SDL 2.0 (zlib licence), zlib and fpattern. Their notices apply to this distribution.")
                    tip("Notices", "Fallout is a trademark of Bethesda Softworks. Unofficial fan project, not affiliated with Bethesda or Interplay. You must own the games to play.")
                    footnote("The app contains no game data; bring your own installation.")
                }
                .padding(.horizontal, Metrics.sheetInset)
                .padding(.top, 2)
                .padding(.bottom, Metrics.outer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaultPlate(corner: 20, fill: Theme.rail)
        .padding(.leading, Metrics.outer)
        .padding(.trailing, Metrics.outer)
        .padding(.top, Metrics.outer)
        .padding(.bottom, Metrics.outer + screenInsets.bottom)
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

    /// The update check's answer: one line, and the release page if newer.
    private struct UpdateOutcome: Equatable {
        let message: String
        let address: String?
    }

    /// Asks GitHub for the newest release, styled like the other page links.
    private var checkForUpdatesButton: some View {
        Button {
            checkForUpdates()
        } label: {
            HStack(spacing: 4) {
                Text(isCheckingForUpdates ? L.t("CHECKING") : L.t("UPDATES"))
                    .kerning(0.8)

                Image(systemName: isCheckingForUpdates ? "hourglass" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .buttonStyle(ChipStyle(accent: accent, look: .selected))
        .disabled(isCheckingForUpdates)
        .accessibilityLabel(L.t("Check for updates"))
    }

    private var resetAllButton: some View {
        Button {
            showResetAllWarning = true
        } label: {
            HStack(spacing: 4) {
                Text(L.t("RESET ALL"))
                    .kerning(0.8)

                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .buttonStyle(ChipStyle(accent: accent, look: .quiet))
        .accessibilityLabel(L.t("Reset all settings"))
    }

    /// Shown as a popup: a row on the page would make About taller and shift
    /// the layout.
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

    /// Compares this build with the newest release; a check that could not be
    /// made says so instead of looking up to date.
    private func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }
        // The list, not releases/latest: that skips drafts and prereleases,
        // which is all this project publishes.
        guard let url = URL(string: "https://api.github.com/repos/shplash/vaultos/releases?per_page=1") else {
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

    /// Compares the newest release's tag with this build. No network, a rate
    /// limit or an unexpected shape is a plain failure, not a wrong answer.
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

    /// Compares versions number by number, so 1.10 comes after 1.9; a missing
    /// part counts as zero.
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
                    ("Cursor", "One finger moves it, a tap clicks. Two-finger tap or ACTION switches between move, action and target."),
                    ("Inventory", L.t("Hold and drag an item to equip or move it.") + " " + L.t("Tap an item while INSPECT is toggled on to see its characteristics.") + " " + L.t("Hold an item with INSPECT on to open its extra actions: use, look, unload and drop.")),
                    ("Dialogue", "In Fallout 2, BARTER on the right trades with whoever you are talking to."),
                    ("Combat", "The START COMBAT button changes to SKIP TURN when combat starts."),
                    ("Auto target", "On by default: the game switches to attack mode as a fight starts, so the first tap is an attack."),
                    ("Look around", "Either the joystick or a two-finger drag moves the view."),
                ]
            case .survival:
                return [
                    ("Skills pay", "The skilldex covers Doctor, First Aid and Lockpick. Using them beats guessing at a door or a wound."),
                    ("Talk first", "Many fights can be talked past, and quests tend to pay better than what you can loot."),
                    ("Aim", "An aimed shot costs one more action point and can cripple a limb, which often ends a fight faster than damage."),
                    ("VATS", "The attack mode's aimed steps are the game's VATS: they show the chance to hit and cost one more action point."),
                    ("Skills", "While a skill is armed the mode button reads USE SKILL, and pressing it goes back to move or target. Arm one from the skilldex or from an object's menu."),
                    ("Red isn't always hostile", "A red outline can belong to a neutral who will fight back. Fallout 1's Friendly Foe perk turns your own side green; Fallout 2 does that by default."),
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

    private func tip(_ title: String, _ text: String, divider: Bool = true) -> some View {
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
        .frame(minHeight: Metrics.rowMinHeight - 10, alignment: .leading)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(divider ? Theme.hairline : Color.clear)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var displaySheet: some View {
        sheet(title: "VIDEO", detail: "Resolution, pixel quality and frame rate", onReset: resetDisplay) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ForEach(model.presets) { preset in
                        presetTile(preset)
                    }
                }
                .padding(.top, 10)

                Text(L.t("HALF keeps text and buttons larger on a phone. FULL is sharper, best on a tablet."))
                    .font(Vault.label(9))
                    .kerning(0.2)
                    .foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.bottom, 8)
            .overlay(
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1),
                alignment: .bottom
            )

            row("Pixel quality", detail: "NONE = original. SMOOTH = softer. ENHANCED = soft + sharp blend.") {
                HStack(spacing: 8) {
                    ForEach(0..<LauncherView.scalingTitles.count, id: \.self) { index in
                        scalingPill(index)
                    }
                }
            }

            row("Frame rate", detail: "30 saves battery, 60 is smoother") {
                HStack(spacing: 8) {
                    frameRatePill(30)
                    frameRatePill(60)
                }
            }

            toggleRow("Vibrant",
                      detail: "Lifts muted colours without washing out the strong ones",
                      divider: false,
                      isOn: $model.shaderVibrant)
        }
    }

    private static let scalingTitles = ["NONE", "SMOOTH", "ENHANCED"]

    private func frameRatePill(_ rate: Int) -> some View {
        let selected = model.frameRate == rate

        return Button {
            model.frameRate = rate
        } label: {
            Text(verbatim: "\(rate)")
                .kerning(0.8)
        }
        .buttonStyle(ChipStyle(accent: accent, look: selected ? .selected : .unselected))
        .accessibilityLabel("\(rate) " + L.t("frames per second"))
    }

    private func scalingPill(_ index: Int) -> some View {
        let selected = model.imageScaling == index

        return Button {
            model.imageScaling = index
        } label: {
            Text(L.t(LauncherView.scalingTitles[index]))
                .kerning(0.8)
        }
        .buttonStyle(ChipStyle(accent: accent, look: selected ? .selected : .unselected))
        .accessibilityLabel(LauncherView.scalingTitles[index])
    }

    private func presetTile(_ preset: DisplayPreset) -> some View {
        let selected = model.selected(preset: preset)

        return Button {
            model.apply(preset: preset)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L.t(preset.id.uppercased()))
                            .font(Vault.label(9))
                            .kerning(1.6)
                            .foregroundColor(selected ? accent : Theme.faint)

                        // HALF on a phone, FULL on a tablet: the preset this
                        // screen starts on.
                        if preset.id == model.startingPreset.id {
                            Text(L.t("(recommended)"))
                                .font(Vault.label(9, weight: .regular))
                                .foregroundColor(Theme.faint)
                        } else {
                            Text(L.t("(experimental)"))
                                .font(Vault.label(9, weight: .regular))
                                .foregroundColor(Theme.faint)
                        }
                    }

                    Text(verbatim: "\(preset.width) × \(preset.height)")
                        .font(Vault.label(18, weight: .bold))
                        .foregroundColor(selected ? Theme.text : Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)

                if selected {
                    Text(L.t("IN USE"))
                        .font(Vault.label(9))
                        .foregroundColor(accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? accent.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? accent.opacity(0.8) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var audioSheet: some View {
        sheet(title: "AUDIO", detail: "Volumes, kept per game", onReset: resetAudio) {
            volumeRow("Master", value: $model.masterVolume)
            volumeRow("Music", value: $model.musicVolume)
            volumeRow("Effects", value: $model.sfxVolume)
            volumeRow("Speech", value: $model.speechVolume)

            toggleRow("Subtitles",
                      detail: "Spoken lines appear as text",
                      isOn: $model.subtitles)

            toggleRow("Launcher music",
                      detail: "Play music while you are in this launcher",
                      divider: false,
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

    private func volumeRow(_ title: String, value: Binding<Double>) -> some View {
        row(title, detail: nil) {
            HStack(spacing: 12) {
                Slider(value: value, in: 0...100)
                    .accentColor(accent)
                    .frame(width: 220)

                Text(verbatim: "\(Int(value.wrappedValue.rounded()))%")
                    .font(Vault.label(10))
                    .foregroundColor(Theme.dim)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var gameSheet: some View {
        sheet(title: "SYSTEM", detail: "Language, movement, haptics and saving", onReset: resetGame) {
            row("Language", detail: "Game text, voice, this launcher and the buttons") {
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
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(Vault.label(10, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Metrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                }
            }

            toggleRow("Always sprint",
                      detail: "Your character runs instead of walking",
                      isOn: $model.alwaysRun)

            toggleRow("Button haptics",
                      detail: "Vibrate when you press an on-screen button",
                      isOn: $model.buttonHaptics)

            row("Auto quick save", detail: "The game quick-saves by itself at this interval. OFF stops it.") {
                HStack(spacing: 8) {
                    Button {
                        model.autoSaveMinutes = max(0, model.autoSaveMinutes - 1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent, square: true))
                    .disabled(model.autoSaveMinutes == 0)

                    Text(verbatim: model.autoSaveMinutes == 0
                            ? L.t("OFF")
                            : "\(model.autoSaveMinutes) " + L.t("MIN"))
                        .font(Vault.label(10))
                        .foregroundColor(model.autoSaveMinutes == 0 ? Theme.faint : accent)
                        .frame(width: 48)

                    Button {
                        model.autoSaveMinutes = min(10, model.autoSaveMinutes + 1)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent, square: true))
                    .disabled(model.autoSaveMinutes == 10)
                }
            }

            toggleRow("Haptic on save",
                      detail: "Vibrate when a save finishes",
                      isOn: $model.saveHaptics)

            // The saves row, with its count beside the title.
            row("Saved games",
                detail: model.savesNotice.map { L.message($0) } ?? L.t("Keep your saves intact"),
                badge: "· \(model.saves.count)",
                divider: false) {
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
    }

    private var controlsSheet: some View {
        sheet(title: "CONTROLS", detail: "Layout, colour and opacity of the on-screen buttons", onReset: resetControls) {
            toggleRow("On-screen controls",
                      detail: "Show the touch buttons over the game. Off, you get the bare game screen.",
                      isOn: $model.touchControls)

            // The layout, colour and opacity rows are greyed, not hidden, while
            // the controls are off: there is nothing to edit then.
            row("Button layout", detail: "Move and resize the buttons. Best judged over the game itself.") {
                Button {
                    showControlEditor = true
                } label: {
                    Text(L.t("EDIT LAYOUT"))
                }
                .buttonStyle(SmallButtonStyle(accent: accent))
            }
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            row("Button colour", detail: "Colour of the button labels and of the glow while you hold one") {
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
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(Vault.label(10, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Metrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                }
            }
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            row("Opacity", detail: "How solid the buttons are. Lower is more see-through.") {
                HStack(spacing: 12) {
                    Slider(value: $model.controlsOpacity, in: 0.10...1)
                        .accentColor(accent)
                        .frame(width: 220)

                    Text(verbatim: "\(Int((model.controlsOpacity * 100).rounded()))%")
                        .font(Vault.label(10))
                        .foregroundColor(Theme.dim)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            // Greyed while the controls are off, like the rows above.
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            toggleRow("Auto target in combat",
                      detail: "Switch to attack mode by itself when a fight starts.",
                      divider: false,
                      isOn: $model.autoTarget)
        }
    }

    private func headerLine(_ title: String,
                            badge: String? = nil,
                            badgeColour: Color? = nil) -> some View {
        return HStack(spacing: 6) {
            Text(title)
                .font(Vault.body(12, weight: .medium))
                .foregroundColor(Theme.text)
                .lineLimit(1)

            // A note beside the header, in the game's own colour.
            if let badge = badge {
                Text(L.t(badge))
                    .font(Vault.label(9, weight: .bold))
                    .kerning(0.8)
                    .foregroundColor(badgeColour ?? Theme.faint)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
    }

    /// Importing replaces the saves, so it waits out a countdown with the
    /// warning on screen. Backing up is harmless.
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
                    .buttonStyle(SmallButtonStyle(accent: accent, tint: Theme.dim, minHeight: 36))

                    Button(saveImportCountdown > 0
                        ? "\(L.t("IMPORT")) \(saveImportCountdown)"
                        : L.t("IMPORT")) {
                        showSaveImportWarning = false
                        pendingImport = .saves
                        model.showImporter = true
                    }
                    .buttonStyle(ChipStyle(accent: accent, look: .selected, minHeight: 36))
                    .disabled(saveImportCountdown > 0)
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .warningPlate()
            .padding(24)
        }
    }

    /// A new game keeps the same slots, so it asks before it starts: its first
    /// save would otherwise take a slot that holds a game already.
    private var newGameWarning: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(L.t("Start a new game?").uppercased())
                    .font(Vault.display(20))
                    .kerning(0.8)
                    .foregroundColor(Theme.text)

                Text(L.t("A new game is not a separate save: it shares this game's slots, so a quick save can replace one that is already there."))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L.t("Back up first: SYSTEM > Saved games > BACK UP, and IMPORT restores your backup."))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(L.t("CANCEL")) {
                        showNewGameWarning = false
                        newGameCountdown = 0
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent, tint: Theme.dim, minHeight: 36))

                    Button(newGameCountdown > 0
                        ? "\(L.t("PLAY")) \(newGameCountdown)"
                        : L.t("PLAY")) {
                        showNewGameWarning = false
                        newGameCountdown = 0
                        LauncherMusic.shared.stop()
                        model.play(onPlay: onPlay)
                    }
                    .buttonStyle(ChipStyle(accent: accent, look: .selected, minHeight: 36))
                    .disabled(newGameCountdown > 0)
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .warningPlate()
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
                    .buttonStyle(SmallButtonStyle(accent: accent, tint: Theme.dim, minHeight: 36))

                    Button(L.t("RESET ALL")) {
                        showResetAllWarning = false
                        model.resetEverything()
                    }
                    .buttonStyle(ChipStyle(accent: accent, look: .selected, minHeight: 36))
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .warningPlate()
            .padding(24)
        }
    }

    private func toggleRow(_ title: String, detail: String? = nil, divider: Bool = true, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail, divider: divider) {
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

    // MARK: - Resetting a page

    private func resetDisplay() {
        model.apply(preset: model.startingPreset)
        model.imageScaling = 2
        model.frameRate = 60
        model.shaderVibrant = false
    }

    private func resetAudio() {
        model.sound = true
        model.music = true
        model.speech = true
        model.subtitles = true
        model.masterVolume = 70
        model.musicVolume = 70
        model.sfxVolume = 70
        model.speechVolume = 70
    }

    private func resetGame() {
        model.language = 0
        model.alwaysRun = true
        model.targetHighlight = 1
        model.autoSaveMinutes = 5
        model.saveHaptics = true
        model.buttonHaptics = false
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

    private func sheetHeader<Trailing: View>(_ title: String,
                                             detail: String,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L.t(title))
                    .font(Vault.display(27))
                    .kerning(1.2)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(L.t(detail))
                    .font(Vault.label(9))
                    .kerning(0.4)
                    .foregroundColor(Theme.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: Metrics.gap)

            trailing()
        }
        .padding(.horizontal, Metrics.sheetInset)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func sheet<C: View>(title: String, detail: String, onReset: (() -> Void)? = nil, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader(title, detail: detail) {
                if let onReset = onReset {
                    Button(action: onReset) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .bold))

                            Text(L.t("RESET"))
                                .kerning(0.8)
                        }
                    }
                    .buttonStyle(ChipStyle(accent: accent, look: .quiet))
                    .accessibilityLabel("Reset \(title) to defaults")
                }
            }

            Rectangle()
                .fill(accent.opacity(0.55))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .padding(.horizontal, Metrics.sheetInset)
            .padding(.top, 2)
            .padding(.bottom, Metrics.outer)

            Spacer(minLength: 0)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaultPlate(corner: 20, fill: Theme.rail)
        .padding(.leading, Metrics.outer)
        .padding(.trailing, Metrics.outer)
        .padding(.top, Metrics.outer)
        .padding(.bottom, Metrics.outer + screenInsets.bottom)
    }

    private func row<C: View>(_ title: String,
                              detail: String?,
                              badge: String? = nil,
                              divider: Bool = true,
                              @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L.t(title))
                        .font(Vault.body(13, weight: .medium))
                        .foregroundColor(Theme.text)

                    // A grey count beside the title.
                    if let badge = badge {
                        Text(verbatim: badge)
                            .font(Vault.label(11, weight: .regular))
                            .foregroundColor(Theme.faint)
                    }
                }

                if let detail = detail {
                    Text(L.t(detail))
                        .font(Vault.label(9))
                        .kerning(0.2)
                        .foregroundColor(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Metrics.gap)

            control()
        }
        .frame(minHeight: Metrics.rowMinHeight - 10, alignment: .leading)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(divider ? Theme.hairline : Color.clear)
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

// MARK: - Dismissing

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

/// The saves box's frame and slide limit in the card's coordinates, so the
/// card's drag knows which drags belong to the box.
private struct SavesBox: Equatable {
    var rect: CGRect = .zero
    var limit: CGFloat = 0
}

private struct SavesBoxKey: PreferenceKey {
    static var defaultValue: SavesBox {
        return SavesBox()
    }

    static func reduce(value: inout SavesBox, nextValue: () -> SavesBox) {
        // Only the card on screen has a box: an empty answer never replaces a
        // real one.
        let next = nextValue()
        if next.rect != .zero {
            value = next
        }
    }
}

private enum Metrics {
    static let outer: CGFloat = 16
    static let sheetInset: CGFloat = 22
    static let rowMinHeight: CGFloat = 34
    static let rowMaxHeight: CGFloat = 46
    static let controlHeight: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let gap: CGFloat = 8
}

private enum Theme {
    static let background = Vault.hull
    /// The rail's fill, used by the home sheet too so both read as one surface.
    static let rail = Vault.plate.opacity(0.55)
    static let alert = Color(white: 0.072)
    static let line = Vault.hairline
    static let hairline = Vault.hairline
    static let text = Vault.text
    static let dim = Vault.dim
    static let faint = Vault.faint
}

private extension View {
    func warningPlate() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .background(shape.fill(Color.white.opacity(0.04)))
            .background(shape.fill(Theme.alert))
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// The home card's plate: the rail's fill and edges that both fade out at
    /// the bottom, so the card ends in the black instead of on a hard edge.
    func homePlate(corner: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let fill = LinearGradient(stops: [
            .init(color: Theme.rail, location: 0),
            .init(color: Theme.rail, location: 0.58),
            .init(color: Theme.rail.opacity(0), location: 0.98)
        ], startPoint: .top, endPoint: .bottom)
        let edge = LinearGradient(stops: [
            .init(color: Color.white.opacity(0.09), location: 0),
            .init(color: Color.white.opacity(0.09), location: 0.50),
            .init(color: Color.white.opacity(0), location: 0.90)
        ], startPoint: .top, endPoint: .bottom)

        return self
            .background(shape.fill(fill))
            .overlay(shape.stroke(edge, lineWidth: 1))
            .overlay(
                Rectangle()
                    .fill(Vault.edgeLight)
                    .frame(height: 1)
                    .padding(.horizontal, corner),
                alignment: .top
            )
    }
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
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(shape.fill(accent))
            .overlay(shape.stroke(Vault.edgeLight, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    let accent: Color
    var tint: Color? = nil
    var square = false
    var minHeight: CGFloat = Metrics.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        let label = configuration.label
            .font(Vault.label(10, weight: .semibold))
            .foregroundColor(tint ?? accent)

        return Group {
            if square {
                label.frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
            } else {
                label.padding(.horizontal, 14).frame(minHeight: minHeight)
            }
        }
        .background(
            shape.fill(configuration.isPressed ? accent.opacity(0.18) : Color.white.opacity(0.04))
        )
        .overlay(shape.stroke(configuration.isPressed ? Vault.edgeLight : Theme.hairline, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.9 : 1)
        .modifier(DisabledDim())
    }
}

private struct ChipStyle: ButtonStyle {
    enum Look {
        case selected
        case unselected
        case quiet
    }

    let accent: Color
    let look: Look
    var minHeight: CGFloat = Metrics.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)

        return configuration.label
            .font(Vault.label(10, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: minHeight)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .contentShape(Rectangle())
            .modifier(DisabledDim())
    }

    private var foreground: Color {
        switch look {
        case .selected: return Vault.ink
        case .unselected: return Theme.faint
        case .quiet: return Theme.dim
        }
    }

    private var fill: Color {
        return look == .selected ? accent : Color.white.opacity(0.04)
    }

    private var stroke: Color {
        return look == .selected ? Color.clear : Theme.hairline
    }
}

private struct DisabledDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.4)
    }
}

/// A link's mark cut out of a frosted disc: the page shows through the glyph.
/// The disc is the whole icon, with no ring around it.
private struct CutoutIconDisc<Glyph: View>: View {
    let diameter: CGFloat
    let glyph: Glyph

    init(diameter: CGFloat, @ViewBuilder glyph: () -> Glyph) {
        self.diameter = diameter
        self.glyph = glyph()
    }

    var body: some View {
        ZStack {
            // ultraThinMaterial needs iOS 15; older systems get a flat grey of
            // the same weight.
            if #available(iOS 15.0, *) {
                Circle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            } else {
                Circle()
                    .fill(Color(white: 0.34))
            }

            Circle()
                .fill(Color.white.opacity(0.24))
        }
        .frame(width: diameter, height: diameter)
        // The disc is the mask and the glyph is cut out of it, so the page
        // shows through the mark.
        .mask(
            Rectangle()
                .overlay(glyph.blendMode(.destinationOut))
                .compositingGroup()
        )
        .clipShape(Circle())
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
    @State private var revision = 0
    @State private var shareFile: URL?

    init(model: LauncherModel) {
        self.model = model
        let profile = ControlLayout.profileForCurrentResolution()
        let game = model.selectedGame
        _profile = State(initialValue: profile)
        _game = State(initialValue: game)
        _centers = State(initialValue: ControlLayout.allCenters(profile: profile, game: game))
        _scales = State(initialValue: ControlLayout.allScales(profile: profile, game: game))
    }

    /// The colour the player picked for the controls, so the editor and the
    /// controls look alike. The game's accent stays on the launcher pages.
    private var accent: Color {
        return model.controlColour.color
    }

    private var traySymbol: String {
        return ControlLayout.traySide(profile: profile, game: game) == .left ? "chevron.left" : "chevron.right"
    }

    var body: some View {
        GeometryReader { geometry in
            let _ = revision
            ZStack {
                Theme.background.ignoresSafeArea()

                previewSurface(geometry.size)

                saveAssemblyPreview(in: geometry.size)
                    .opacity(model.controlsOpacity)

                ForEach(TouchControl.controls(for: game)) { control in
                    let controlSize = editorSize(for: control, in: geometry.size)
                    editorControl(control, size: controlSize, selected: selected == control)
                        .position(editorCenter(for: control, in: geometry.size))
                        .gesture(dragGesture(for: control, in: geometry.size))
                        .opacity(model.controlsOpacity)
                }

                // One centred bar across the top holds the controls and the
                // HIDE/SHOW toggle, which stays in the same place in both
                // states; hiding removes only the bar.
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
        .sheet(isPresented: Binding(
            get: { shareFile != nil },
            set: { shown in
                if !shown {
                    shareFile = nil
                }
            }
        )) {
            if let url = shareFile {
                ShareSheet(items: [url])
            }
        }
    }

    /// Fixed so the label never moves the bar: HIDE BARS and SHOW BARS are the
    /// same length in the monospaced face it is drawn in.
    private static let toggleWidth: CGFloat = 116

    /// Hides the editor's bars to give the whole screen to the layout. A filled
    /// capsule, deliberately unlike the controls, in the middle of the top edge
    /// in both states.
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

    /// The editor's controls in one bar across the middle of the top edge, so
    /// the corners stay free for the controls it edits. The bar is only as wide
    /// as its two rows: a fixed share of the screen left most of it empty.
    /// Hiding the bars takes this bar away and leaves the toggle in place.
    private func chrome(in size: CGSize) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                iconButton("square.and.arrow.up", label: "Copy layout") {
                    shareFile = layoutText(in: size)
                }

                Spacer(minLength: 0)

                iconButton("square.and.arrow.down", label: "Import layout") {
                    LauncherDocumentPicker.shared.present(contentTypes: [UTType.plainText]) { url in
                        guard let url = url else {
                            return
                        }
                        applyLayout(from: url)
                    }
                }

                Spacer(minLength: 0)

                chromeButton(L.t("PRESET 1"), selected: profile == .half) {
                    profile = .half
                    centers = ControlLayout.allCenters(profile: .half, game: game)
                    scales = ControlLayout.allScales(profile: .half, game: game)
                    dragOrigins.removeAll()
                    selected = nil
                }

                Spacer(minLength: 0)

                chromeButton(L.t("PRESET 2"), selected: profile == .full) {
                    profile = .full
                    centers = ControlLayout.allCenters(profile: .full, game: game)
                    scales = ControlLayout.allScales(profile: .full, game: game)
                    dragOrigins.removeAll()
                    selected = nil
                }

                Spacer(minLength: 0)

                chromeButton(L.t("RESET"), selected: false) {
                    ControlLayout.reset(profile: profile, game: game)
                    model.controlsOpacity = 1
                    centers = ControlLayout.allCenters(profile: profile, game: game)
                    scales = ControlLayout.allScales(profile: profile, game: game)
                    dragOrigins.removeAll()
                    selected = nil
                }

                Spacer(minLength: 0)

                chromeButton(L.t("DONE"), selected: true) {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .frame(maxWidth: .infinity)

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

                // SIZE keeps its place whether a control is selected or not, so
                // the panel never changes shape under the finger.
                Text(L.t("SIZE"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(1.1)
                    .foregroundColor(Theme.faint)

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
        // The two rows decide the width; the toggle below follows it in both
        // states.
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

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t(label))
    }

    private func chromeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(0.6)
                .foregroundColor(selected ? Color.black.opacity(0.85) : accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? accent : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(selected ? Color.white.opacity(0.28) : Theme.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func applyLayout(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            LauncherLog.write("layout import: \(url.lastPathComponent) could not be read")
            return
        }

        var applied = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 8, let control = TouchControl(rawValue: String(fields[0])) else {
                let entry = String(line).trimmingCharacters(in: .whitespaces)
                if entry.hasPrefix("tray:") {
                    let side = String(entry.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    ControlLayout.setTraySide(side == "left" ? .left : .right, profile: profile, game: game)
                } else if entry.hasPrefix("preset:") {
                    profile = entry.contains("1") ? .half : .full
                }
                continue
            }
            guard control != .tray,
                  let x = Double(String(fields[1])),
                  let y = Double(String(fields[2])),
                  let scale = Double(String(fields[5])) else {
                continue
            }

            ControlLayout.setCenter(CGPoint(x: x, y: y), for: control, profile: profile, game: game)
            ControlLayout.setScale(CGFloat(scale), for: control, profile: profile, game: game)
            applied += 1
        }

        centers = ControlLayout.allCenters(profile: profile, game: game)
        scales = ControlLayout.allScales(profile: profile, game: game)
        dragOrigins.removeAll()
        selected = nil
        revision += 1
        LauncherLog.write("layout import: \(url.lastPathComponent) applied \(applied) controls")
    }

    private func layoutText(in size: CGSize) -> URL? {
        let device = UIDevice.current
        let screen = UIScreen.main
        var lines = [
            "VaultOS touch controls",
            "device: \(device.model) \(device.systemName) \(device.systemVersion)",
            "screen: \(Int(screen.bounds.width.rounded()))x\(Int(screen.bounds.height.rounded())) @\(Int(screen.scale.rounded()))x",
            "editor: \(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            "game: \(game.title)",
            "preset: \(profile == .full ? "PRESET 2" : "PRESET 1")",
            "resolution: \(model.width)x\(model.height)",
            "tray: \(ControlLayout.traySide(profile: profile, game: game) == .left ? "left" : "right")",
            "opacity: \(Int((model.controlsOpacity * 100).rounded()))%",
            "",
            "control\tx\ty\tcx\tcy\tscale\twidth\theight"
        ]

        for control in TouchControl.controls(for: game) {
            let point = editorCenter(for: control, in: size)
            let controlSize = editorSize(for: control, in: size)
            let stored = centers[control] ?? CGPoint(x: point.x / max(size.width, 1),
                                                     y: point.y / max(size.height, 1))
            lines.append(String(format: "%@\t%.4f\t%.4f\t%.1f\t%.1f\t%.2f\t%.1f\t%.1f",
                                control.rawValue,
                                Double(stored.x),
                                Double(stored.y),
                                Double(point.x),
                                Double(point.y),
                                Double(scales[control] ?? 1),
                                Double(controlSize.width),
                                Double(controlSize.height)))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vaultos-controls.txt")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            LauncherLog.write("controls report: \(error.localizedDescription)")
            return nil
        }
    }

    /// The game's screen as the renderer places it, with the 640x100 interface
    /// bar marked at the bottom edge, both through the aspect fit SDL applies so
    /// the marker stays on the real bar at any resolution.
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

            // Flat red for the in-game HUD footprint the controls must avoid.
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

    /// The 640x100 bar both engines draw. Fallout 2's leather side panels are
    /// switched off in the app, so the bar is all that is left of the HUD.
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

        // Past the HALF default the bar is a sliver of a bigger screen, so the
        // marker keeps its HALF height: the room the controls need to clear.
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
        if control == .tray {
            return ControlLayout.centerPoint(for: control, profile: profile, game: game, in: size)
        }

        let stored = centers[control] ?? control.defaultCenter(for: profile)
        let point = CGPoint(x: stored.x * size.width, y: stored.y * size.height)
        let controlSize = editorSize(for: control, in: size)
        let halfWidth = controlSize.width / 2
        let halfHeight = controlSize.height / 2
        // Clamped to the whole screen, so a control can be dragged to the edge.
        return CGPoint(
            x: min(max(point.x, halfWidth), size.width - halfWidth),
            y: min(max(point.y, halfHeight), size.height - halfHeight)
        )
    }

    private func frame(for control: TouchControl, in size: CGSize) -> CGRect {
        let center = editorCenter(for: control, in: size)
        let controlSize = editorSize(for: control, in: size)
        return CGRect(x: center.x - controlSize.width / 2,
                      y: center.y - controlSize.height / 2,
                      width: controlSize.width,
                      height: controlSize.height)
    }

    /// QUICK SAVE and the chevron share one plate in the game, so the editor
    /// draws the pair the same way.
    private func saveAssembly(in size: CGSize) -> (frame: CGRect, dividerX: CGFloat) {
        let quick = frame(for: .quickSave, in: size)
        let tray = frame(for: .tray, in: size)
        return (quick.union(tray), tray.midX > quick.midX ? tray.minX : tray.maxX)
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
                .offset(x: assembly.dividerX - assembly.frame.minX - 0.5,
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
                        Image(systemName: control == .tray ? traySymbol : control.symbol)
                            .font(.system(size: max(9, min(32, shortSide * 0.46)), weight: .semibold))
                    }

                    if control != .tray {
                        Text(control.label)
                            .font(Vault.label(max(9, min(13, shortSide * 0.19)), weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
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
            return "100%"
        }
        return "\(Int((scale * 100).rounded()))%"
    }

    /// Drives the size slider; with nothing selected the slider is disabled and
    /// this holds its thumb still.
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
                    let start = editorCenter(for: control, in: size)
                    dragOrigins[control] = CGPoint(x: start.x / max(size.width, 1),
                                                   y: start.y / max(size.height, 1))
                }
                guard let origin = dragOrigins[control] else {
                    return
                }

                let moved = CGPoint(x: origin.x * size.width + value.translation.width,
                                    y: origin.y * size.height + value.translation.height)

                switch control {
                case .tray:
                    let quick = frame(for: .quickSave, in: size)
                    ControlLayout.setTraySide(moved.x < quick.midX ? .left : .right,
                                              profile: profile,
                                              game: game)
                    revision += 1
                default:
                    let controlSize = editorSize(for: control, in: size)
                    let halfWidth = controlSize.width / 2
                    let halfHeight = controlSize.height / 2
                    let x = min(max(moved.x / max(size.width, 1),
                                    (halfWidth + 4) / max(size.width, 1)),
                                (size.width - halfWidth - 4) / max(size.width, 1))
                    let y = min(max(moved.y / max(size.height, 1),
                                    (halfHeight + 4) / max(size.height, 1)),
                                (size.height - halfHeight - 4) / max(size.height, 1))

                    centers[control] = CGPoint(x: x, y: y)
                    ControlLayout.setCenter(CGPoint(x: x, y: y), for: control, profile: profile, game: game)
                    if control == .quickSave {
                        revision += 1
                    }
                }
            }
            .onEnded { _ in
                dragOrigins[control] = nil
            }
    }
}



// MARK: - Launcher log

/// What the launcher itself did: each picker, what it handed back and what each
/// import was given. Kept in `VaultOS/vaultos-launcher.log`, beside the engines'
/// own logs, which each truncate their file on every start. Nothing here is for
/// the player: it exists so a picker that does nothing can be read instead of
/// guessed at.
enum LauncherLog {
    static func write(_ message: String) {
        NSLog("VaultOS: %@", message)

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        // The launcher's own files sit in a folder, so the Documents list keeps
        // to the two game folders and their saves.
        let folder = documents.appendingPathComponent("VaultOS", isDirectory: true)
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else {
            return
        }

        let file = folder.appendingPathComponent("vaultos-launcher.log")
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
/// `asCopy: true` copies the chosen file into the app's own temporary directory
/// first, so the import never depends on a security scope a sideloaded install
/// may not open. `fileImporter` has no copy mode on iOS 14, hence UIKit.
final class LauncherDocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = LauncherDocumentPicker()

    private var completion: ((URL?) -> Void)?

    func present(contentTypes: [UTType] = [UTType.zip], completion: @escaping (URL?) -> Void) {
        guard let controller = LauncherDocumentPicker.topViewController() else {
            LauncherLog.write("picker: no view controller to present from")
            completion(nil)
            return
        }

        self.completion = completion

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
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
