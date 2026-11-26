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
    /// How far the strip of the other saves has been dragged, and where a drag
    /// on it began, in the card's own points.
    @State private var stripScroll: CGFloat = 0
    @State private var stripDragStart: CGFloat?
    /// The save the player picked. Choosing one loads nothing: CONTINUE does
    /// that, so a slot can be looked at before a game is taken from it.
    @State private var selectedSlot: Int?
    /// Where each save's card sits on the home card, and where the featured
    /// picture sits, in the card's own coordinates, so a card that is tapped
    /// is seen to grow into the picture rather than swap for it.
    @State private var saveCards: [Int: CGRect] = [:]
    @State private var savePictureBox = CGRect.zero
    /// The card on its way from the strip to the featured picture.
    @State private var saveFlight: SaveFlight?
    @State private var showSaveImportWarning = false
    @State private var saveImportCountdown = 0
    /// How many dots follow INSTALLING while an import is going.
    @State private var installingDots = 0
    @State private var showResetAllWarning = false
    /// The update check runs only while the player waits for it, and its answer
    /// is shown once in a note over the About page.
    @State private var isCheckingForUpdates = false
    @State private var updateOutcome: UpdateOutcome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        return model.selectedGame.accent
    }

    /// The launcher is drawn for the space it is given and never scrolls, so
    /// below this size it would have to clip a page to fit. Scaling the whole
    /// launcher instead keeps every control reachable on a window this small,
    /// and leaves it untouched at the size of a phone or tablet.
    private static let smallestLayout = CGSize(width: 560, height: 320)

    /// The name of the space the home card's positions are measured in, so a
    /// save card that is tapped is seen to grow into the featured picture
    /// from where it sat.
    private static let cardSpace = "launcher.homeCard"

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
            model.refreshSaves()
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
        .onChange(of: model.selectedGame) { _ in
            // A picked save belongs to the game it was picked in, and the
            // strip it was scrolled to.
            selectedSlot = nil
            stripScroll = 0
            saveCards = [:]
            savePictureBox = .zero
            saveFlight = nil
        }
        .onChange(of: model.saves.count) { _ in
            if selectedSave == nil {
                selectedSlot = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // The app's Documents folder is in the Files app now, so game files
            // and saves can be dropped in while the launcher is in the
            // background. Look at both again when it comes back to the front.
            model.refreshInstall()
            model.refreshSaves()

            // A save's own files can be out of reach for the moment the app
            // is let back in, while the device finishes unlocking: read them
            // again once that has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.refreshSaves()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // The dots after INSTALLING move, so a long import is seen to be
            // going rather than stopped.
            if model.isInstalling {
                installingDots = (installingDots + 1) % 3
            } else {
                installingDots = 0
            }

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

    /// How far an import has got, in the row under the game's own files: a
    /// bar while it is going, and what it did once it has stopped.
    @ViewBuilder
    private func gameDataStatus(game: FalloutGame) -> some View {
        if model.isInstalling || model.importSummary != nil {
            VStack(alignment: .leading, spacing: 4) {
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
            .padding(.vertical, 8)
        }
    }

    // MARK: - The saves

    /// The picture every save is written with, as wide as it is tall: the game
    /// renders it 224 by 133, so a card drawn at that ratio shows all of it
    /// rather than a cropped middle.
    private static let saveArtRatio: CGFloat = 224 / 133

    /// The save that is open: the picture the game wrote on the left, at its
    /// own ratio, and everything the save holds on the right, so no detail is
    /// behind a menu.
    private func featuredCard(save: LauncherModel.LauncherSave?, width: CGFloat) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = 14
            let inner = max(80, geometry.size.width - 22)
            let room = max(56, geometry.size.height - 22 - 20)
            let artWidth = min(inner * 0.5, room * LauncherView.saveArtRatio)
            let artHeight = artWidth / LauncherView.saveArtRatio
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .leading, spacing: 6) {
                    savePicture(save: save,
                                game: model.selectedGame,
                                width: artWidth,
                                height: artHeight)
                        .background(
                            GeometryReader { box in
                                Color.clear.preference(key: SavePictureKey.self,
                                                       value: box.frame(in: .named(LauncherView.cardSpace)))
                            }
                        )

                    if let save = save {
                        Text(LauncherView.slotTitle(save.slot))
                            .font(Vault.label(9, weight: .bold))
                            .kerning(1.1)
                            .foregroundColor(Theme.faint)
                            .lineLimit(1)
                    }
                }

                saveInfo(save: save, width: max(64, inner - artWidth - gap))
            }
            // The save sits in the middle of the plate, so a card given more
            // height than its save needs stays a plate around it rather than
            // a panel with a gap under it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(11)
            // The outline a picked slot was drawn with, kept as the one sign
            // of which save is open: no second indicator competes with it.
            .background(shape.fill(Color.white.opacity(0.025)))
            .overlay(shape.stroke(Color.white.opacity(0.72), lineWidth: 1))
        }
    }

    /// What a save knows about itself, as one panel: the character, the level,
    /// the map the game was left on, how long it has been played and when it
    /// was written. A save that does not carry one of them leaves it out
    /// rather than showing a made-up value.
    private func saveInfo(save: LauncherModel.LauncherSave?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(save?.name ?? L.t("NO SAVES YET"))
                .font(Vault.body(17, weight: .semibold))
                .foregroundColor(save == nil ? Theme.dim : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let save = save {
                if !save.detail.isEmpty, save.detail != save.name {
                    Text(save.detail)
                        .font(Vault.label(10, weight: .regular))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 2)
                }

                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if save.level > 0 {
                        detailLine(L.t("LEVEL"), value: "\(save.level)")
                    }

                    if let location = save.location {
                        detailLine(L.t("LOCATION"), value: location)
                    }
                }
                .padding(.top, 9)

                if let played = save.played {
                    detailLine(L.t("PLAYED"), value: played)
                        .padding(.top, 7)
                }

                detailLine(L.t("SAVED"), value: save.saved)
                    .padding(.top, 7)
            } else {
                Text(L.t("PLAY starts a new game."))
                    .font(Vault.label(10))
                    .foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// One of the things a save holds: what it is called, and what it is, on
    /// one line so a short card still shows all of them.
    private func detailLine(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(Vault.label(8, weight: .bold))
                .kerning(1.0)
                .foregroundColor(Theme.faint)
                .lineLimit(1)
                .fixedSize()

            Text(verbatim: value)
                .font(Vault.label(11, weight: .regular))
                .foregroundColor(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    /// A save's own picture, or the game's still while a save has none, so a
    /// slot is never an empty grey box.
    private func savePicture(save: LauncherModel.LauncherSave?,
                             game: FalloutGame,
                             width: CGFloat,
                             height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        return Group {
            if let save = save,
               let url = save.preview,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let art = artwork(for: game) {
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(0.55)
                    .opacity(0.45)
            } else {
                Color.white.opacity(0.04)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
    }

    /// The saves that are not open, in a strip under the featured one. The
    /// strip shows the cards that fit whole and the edge of the next one, so
    /// it is seen to go on; a drag slides it to the rest.
    private func saveStrip(width: CGFloat) -> some View {
        let slots = otherSlots
        let cardWidth = LauncherView.stripCardWidth(width: width)
        let limit = LauncherView.stripLimit(width: width, cards: slots.count)
        let hasMore = stripScroll > limit + 1

        return HStack(alignment: .top, spacing: Metrics.gap) {
            ForEach(slots, id: \.self) { slot in
                collapsedCard(slot: slot,
                              save: model.saves.first { $0.slot == slot },
                              width: cardWidth)
            }
        }
        .offset(x: min(0, max(limit, stripScroll)))
        .frame(width: width, height: LauncherView.stripHeight(width: width), alignment: .topLeading)
        .clipped()
        .simultaneousGesture(stripGesture(width: width))
        .overlay(
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.faint)
                    .frame(width: 16)
                    .opacity(hasMore ? 1 : 0)
            },
            alignment: .trailing
        )
    }

    /// A save that is not open: its picture small, its slot and its name
    /// under it, and a chevron saying it opens. Tapping it makes it the
    /// featured save, and the one that was featured takes its place here.
    private func collapsedCard(slot: Int,
                               save: LauncherModel.LauncherSave?,
                               width: CGFloat) -> some View {
        let height = width / LauncherView.saveArtRatio

        return VStack(alignment: .leading, spacing: 5) {
            savePicture(save: save, game: model.selectedGame, width: width, height: height)
                // The slot is over the picture's corner, so the sliver of the
                // next card says which save it is without its picture.
                .overlay(
                    Text(verbatim: String(format: "%02d", slot))
                        .font(Vault.label(9, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 5)
                        .frame(height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(5),
                    alignment: .topLeading
                )
                .background(
                    GeometryReader { box in
                        Color.clear.preference(key: SaveCardKey.self,
                                               value: [slot: box.frame(in: .named(LauncherView.cardSpace))])
                    }
                )

            HStack(spacing: 4) {
                Text(save?.name ?? L.t("EMPTY"))
                    .font(Vault.label(9, weight: .semibold))
                    .foregroundColor(save == nil ? Theme.faint : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.faint)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            feature(slot)
        }
        .contextMenu {
            if let save = save {
                deleteItem(save)
            }
        }
    }

    /// How many save cards the strip sets side by side before the one that
    /// only peeks: as many as the page has room for, so a card keeps a card's
    /// width in every layout rather than shrinking into a sliver.
    private static func stripColumns(width: CGFloat) -> CGFloat {
        let columns = ((width - LauncherView.stripPeek) / 104).rounded()
        return min(max(columns, 2), 6)
    }

    /// How much of the next card is left showing at the edge of the page.
    private static let stripPeek: CGFloat = 24

    /// The width the strip gives a card: the cards and the one that peeks
    /// share the page between them.
    private static func stripCardWidth(width: CGFloat) -> CGFloat {
        let columns = stripColumns(width: width)
        let share = (width - stripPeek - (columns - 1) * Metrics.gap) / columns
        return max(44, share)
    }

    /// How far the strip may slide, which is nothing while every card fits.
    private static func stripLimit(width: CGFloat, cards: Int) -> CGFloat {
        guard cards > 0 else {
            return 0
        }

        let cardWidth = stripCardWidth(width: width)
        let content = CGFloat(cards) * cardWidth + CGFloat(cards - 1) * Metrics.gap
        return min(0, width - content)
    }

    /// The room the strip takes: a card's picture and the line under it.
    private static func stripHeight(width: CGFloat) -> CGFloat {
        return stripCardWidth(width: width) / saveArtRatio + 22
    }

    /// The saves that are not open, in slot order, so the strip never
    /// rearranges itself for no reason.
    private var otherSlots: [Int] {
        let featured = featuredSlot
        return model.saves.map { $0.slot }.filter { $0 != featured }.sorted()
    }

    /// The save that is open: the one the player picked, or the newest one
    /// while nothing has been picked yet.
    private var featuredSlot: Int? {
        return selectedSave?.slot ?? model.saves.first?.slot
    }

    /// The save the featured card shows.
    private var featuredSave: LauncherModel.LauncherSave? {
        guard let slot = featuredSlot else {
            return nil
        }

        return model.saves.first { $0.slot == slot }
    }

    private static func slotTitle(_ slot: Int) -> String {
        return L.t("SLOT") + " " + String(format: "%02d", slot)
    }

    /// Opens a save that was tapped. Where its card sat and where the
    /// featured picture sits are both known, so the card is seen to grow into
    /// the picture while the save it replaces takes its place in the strip.
    private func feature(_ slot: Int) {
        guard slot != featuredSlot else {
            return
        }

        if !reduceMotion, let from = saveCards[slot], savePictureBox != .zero {
            let save = model.saves.first { $0.slot == slot }
            saveFlight = SaveFlight(slot: slot, preview: save?.preview, from: from, to: savePictureBox)

            DispatchQueue.main.asyncAfter(deadline: .now() + SaveFlightView.duration) {
                if saveFlight?.slot == slot {
                    saveFlight = nil
                }
            }
        }

        // The strip's cards slide into the room the tapped one leaves, while
        // the featured panel changes under the picture on its way there.
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 0.9)) {
            selectedSlot = slot
        }
    }

    private func stripGesture(width: CGFloat) -> some Gesture {
        let limit = LauncherView.stripLimit(width: width, cards: otherSlots.count)

        return DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                if stripDragStart == nil {
                    stripDragStart = stripScroll
                }

                stripScroll = min(0, max(limit, (stripDragStart ?? 0) + value.translation.width))
            }
            .onEnded { value in
                stripDragStart = nil

                // A short flick carries on where the finger was going, as a
                // strip of cards of the system's own would.
                let predicted = value.predictedEndTranslation.width - value.translation.width
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.9)) {
                    stripScroll = min(0, max(limit, stripScroll + predicted))
                }
            }
    }

    /// Deleting is a long press away on a save card. A button's role is what
    /// marks the item as destructive, and roles start at iOS 15 while the app
    /// still runs on iOS 14: there the item is a plain one and says the same.
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
        Button {
            LauncherMusic.shared.stop()
            if let save = selectedSave ?? model.saves.first {
                model.play(onPlay: onPlay, loadSlot: save.slot)
            } else {
                model.play(onPlay: onPlay)
            }
        } label: {
            VStack(spacing: 4) {
                Text(L.t(model.saves.isEmpty ? "PLAY" : "CONTINUE"))
                    .font(Vault.display(24))
                    .kerning(1.6)

                Text(statusText)
                    .font(Vault.label(10, weight: .bold))
                    .kerning(1.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(Vault.ink.opacity(0.62))
            }
        }
        .buttonStyle(PrimaryButtonStyle(accent: accent))
        .disabled(model.install.installed == 0 || model.isInstalling)
        .opacity(model.install.installed == 1 ? 1 : 0.35)
    }

    /// The save the player picked, if it is still there.
    private var selectedSave: LauncherModel.LauncherSave? {
        guard let slot = selectedSlot else {
            return nil
        }

        return model.saves.first { $0.slot == slot }
    }

    /// INSTALLING with the dots after it moving, so a long import is seen to
    /// be going rather than stopped.
    private var installingLabel: String {
        return L.t("INSTALLING") + String(repeating: ".", count: installingDots + 1)
    }

    private var statusText: String {
        if model.isInstalling {
            return installingLabel
        }

        if let save = selectedSave ?? model.saves.first {
            return save.name.uppercased()
        }

        return L.t(model.install.installed == 1 ? "READY" : "NEEDS FILES")
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home:
            homeCard
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

    // MARK: - Home

    /// The home page: the game that is open and the way to the other one at
    /// the top, the save that is open under it, and the rest of the saves in a
    /// strip along the bottom. The strip is the last thing above the Play
    /// button in the rail beside it, so the saves run down towards Play
    /// instead of a switch of their own taking a row at the bottom.
    private var homeCard: some View {
        GeometryReader { geometry in
            let inner = max(140, geometry.size.width - Metrics.sheetInset * 2)
            // A card as short as a phone's in landscape has no room for the
            // tagline of its own: it goes beside the name instead, and the
            // saves keep the height below it.
            let short = geometry.size.height < 460

            VStack(alignment: .leading, spacing: 0) {
                homeHeader(game: model.selectedGame, width: inner, short: short)

                Rectangle()
                    .fill(accent.opacity(0.55))
                    .frame(height: 1)
                    .padding(.top, Metrics.gap)

                featuredCard(save: featuredSave, width: inner)
                    .padding(.top, Metrics.gap)

                if !otherSlots.isEmpty {
                    saveStrip(width: inner)
                        .padding(.top, Metrics.gap)
                }
            }
            .padding(.horizontal, Metrics.sheetInset)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .vaultPlate(corner: 20, fill: Theme.rail)
            .coordinateSpace(name: LauncherView.cardSpace)
            .overlay(saveFlightView, alignment: .topLeading)
            .onPreferenceChange(SaveCardKey.self) { cards in
                saveCards = cards
            }
            .onPreferenceChange(SavePictureKey.self) { box in
                savePictureBox = box
            }
        }
        .padding(.leading, Metrics.outer)
        .padding(.trailing, Metrics.outer)
        .padding(.top, Metrics.outer)
        .padding(.bottom, Metrics.outer + screenInsets.bottom)
    }

    /// The card on its way from the strip to the featured picture, drawn over
    /// both so it is not cut off by the strip it left.
    private var saveFlightView: some View {
        return Group {
            if let flight = saveFlight {
                SaveFlightView(preview: flight.preview,
                               from: flight.from,
                               to: flight.to)
            }
        }
    }

    /// The game's name and edition, the two games as words under it, and the
    /// way to the project beside them. None of it is a switch: the game that
    /// is open is the one the saves under it belong to.
    private func homeHeader(game: FalloutGame, width: CGFloat, short: Bool) -> some View {
        let titleSize = min(short ? 34 : 44, max(24, width * 0.155))
        // The tagline, the edition and the links cannot share a narrow column
        // without one of them being cut, so the links wait for the room.
        let showLinks = width >= 440

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(game.title.uppercased())
                    .font(Vault.display(titleSize))
                    .kerning(1.4)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if short {
                    Text(L.t(game.tagline))
                        .font(Vault.body(12))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Text(L.t("COMMUNITY EDITION"))
                    .font(Vault.label(9, weight: .bold))
                    .kerning(1.8)
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 0)

                if showLinks {
                    plainLink("GITHUB", address: "https://github.com/shplash/vaultos")
                    plainLink(L.t("SUPPORT ME"), address: "https://ko-fi.com/shplash")
                }
            }

            if !short {
                Text(L.t(game.tagline))
                    .font(Vault.body(12))
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }

            HStack(alignment: .center, spacing: 18) {
                ForEach(FalloutGame.allCases) { item in
                    gameTab(item, selected: item == game)
                }

                Spacer(minLength: 0)

                if model.install.installed == 0 {
                    Text(L.t("FILES NEEDED"))
                        .font(Vault.label(9, weight: .bold))
                        .kerning(1.2)
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, short ? 7 : 9)
        }
    }

    /// A game as a word of its own, in its accent when it is the one open and
    /// with a line under it: a tab, rather than a button filling a capsule.
    private func gameTab(_ game: FalloutGame, selected: Bool) -> some View {
        Button {
            selectGame(game)
        } label: {
            Text(game.title.uppercased())
                .font(Vault.label(12, weight: selected ? .bold : .regular))
                .kerning(1.4)
                .foregroundColor(selected ? accent : Theme.faint)
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, 5)
                .overlay(
                    Rectangle()
                        .fill(selected ? accent : Color.clear)
                        .frame(height: 2),
                    alignment: .bottom
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectGame(_ game: FalloutGame) {
        guard game != model.selectedGame else {
            return
        }

        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.82)) {
            model.selectedGame = game
        }
    }

    private func plainLink(_ title: String, address: String) -> some View {
        Button {
            if let url = URL(string: address) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(Vault.label(10, weight: .semibold))
                    .kerning(1.0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(Theme.dim)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title)")
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
    /// The links sit in the header, outside the scroll view: the way to a bug
    /// report can never scroll out of reach, and only the credits - text nobody
    /// taps, in a fixed order - move. This is the launcher's only scroll view,
    /// and it holds static rows only.
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
                    tip("Engines", "Fallout Community Edition and Fallout 2 Community Edition by Alexander Batalov (alexbatalov), under the Sustainable Use License.")
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
                    ("Cursor", "One finger moves it, a tap clicks. Two-finger tap or ACTION switches between move, action and target."),
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

                        // The preset this screen starts on is the one that
                        // keeps the game's interface near iOS's text sizes:
                        // HALF on a phone, FULL on a tablet.
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

    // Channel switching is done with the volume sliders; 0% mutes a channel.

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
            // The game's own files sit here rather than on the home card:
            // that card is all saves now, and importing is a setting of the
            // game like the ones below it.
            row("Game data",
                detail: model.install.installed == 1
                    ? L.t("Your game files are in place")
                    : L.t("Import the game's ZIP to play"),
                badge: L.t(model.install.installed == 1 ? "DONE" : "NEEDED")) {
                HStack(spacing: 8) {
                    Button {
                        pendingImport = .language
                        model.showImporter = true
                    } label: {
                        Text(L.t("LANGUAGE FILES"))
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent, minHeight: 30))
                    .disabled(model.isInstalling || model.install.installed == 0)

                    Button {
                        pendingImport = .game
                        model.showImporter = true
                    } label: {
                        Text(L.t(model.install.installed == 1 ? "REPLACE FILES" : "IMPORT ZIP"))
                    }
                    .buttonStyle(SmallButtonStyle(accent: accent, minHeight: 30))
                    .disabled(model.isInstalling)
                }
            }

            gameDataStatus(game: model.selectedGame)

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

            // The saves are a row like the others, with their count in grey
            // beside the title and the two buttons at the right.
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
            // the controls are off: there is nothing on the screen to edit,
            // colour or dim then.
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
            // Greyed out, not hidden, while the on-screen controls are off.
            .disabled(!model.touchControls)
            .opacity(model.touchControls ? 1 : 0.4)

            toggleRow("Auto target in combat",
                      detail: "Switch to attack mode by itself when a fight starts.",
                      divider: false,
                      isOn: $model.autoTarget)
        }
    }

    /// Backing the saves up is harmless; putting a backup back replaces them, so
    /// that one waits out a countdown with the warning on screen.
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

                    // A grey note beside the title, for a count that belongs
                    // to the row rather than to a line of its own.
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

/// Where each save's card sits on the home card, measured in the card's own
/// coordinates, so a card that is tapped is seen to grow from where it sat.
private struct SaveCardKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] {
        return [:]
    }

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// Where the featured save's picture sits, for the same reason: a card that
/// is tapped grows into it.
private struct SavePictureKey: PreferenceKey {
    static var defaultValue: CGRect {
        return .zero
    }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        // Both a save with a picture and one without report a box, and an
        // empty answer - nothing laid out - never replaces a real one.
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// A save's card on its way from the strip to the featured picture.
private struct SaveFlight {
    let slot: Int
    let preview: URL?
    let from: CGRect
    let to: CGRect
}

/// The card that is travelling: it is drawn over both places rather than in
/// either, so the save turns from a card into the featured picture in one
/// movement instead of one card fading out as another fades in.
private struct SaveFlightView: View {
    /// How long the card takes to reach the picture, and how long it is kept
    /// after that so it is never seen to vanish before it lands.
    static let duration: Double = 0.48

    let preview: URL?
    let from: CGRect
    let to: CGRect

    @State private var progress: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        return Group {
            if let preview = preview, let image = UIImage(contentsOfFile: preview.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: from.width, height: from.height)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
        .modifier(SaveFlightPath(from: from, to: to, progress: progress))
        .offset(x: from.minX, y: from.minY)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                progress = 1
            }
        }
    }
}

/// Carries the travelling card from where it was tapped to the featured
/// picture: its middle moves there and its width grows to the picture's, so
/// the card and the picture are the same thing at both ends of the move.
private struct SaveFlightPath: GeometryEffect {
    let from: CGRect
    let to: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { return progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let travel = min(max(progress, 0), 1)
        let scale = 1 + (to.width / max(from.width, 1) - 1) * travel
        let x = (to.midX - from.midX) * travel + size.width / 2 * (1 - scale)
        let y = (to.midY - from.midY) * travel + size.height / 2 * (1 - scale)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale))
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
    /// The rail's own fill. The home sheet uses it too, so the panel and the
    /// bar are one surface instead of a blue-grey plate over a darker one.
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

    /// The editor's own chrome is drawn in the colour the player picked for the
    /// controls, so the tool and the thing it edits look alike. The game's own
    /// accent stays on the launcher pages, where it marks the game.
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

                // SIZE belongs to the control that was pressed, and it keeps its
                // place in the row either way: the panel never changes shape
                // under the player's finger, it only lights up.
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
        if control == .tray {
            return ControlLayout.centerPoint(for: control, profile: profile, game: game, in: size)
        }

        let stored = centers[control] ?? control.defaultCenter(for: profile)
        let point = CGPoint(x: stored.x * size.width, y: stored.y * size.height)
        let controlSize = editorSize(for: control, in: size)
        let halfWidth = controlSize.width / 2
        let halfHeight = controlSize.height / 2
        // The whole screen here too, so a control can still be dragged to the
        // edge it belongs on.
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

    /// QUICK SAVE and the chevron share one plate in the game, with a divider
    /// between them, so the editor draws the pair the same way rather than as
    /// two buttons that are not what the player will see.
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
