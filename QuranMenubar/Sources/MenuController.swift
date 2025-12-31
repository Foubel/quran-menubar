import AppKit
import SwiftUI
import Combine
import Foundation
import Carbon.HIToolbox

final class MenuController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let player = QuranPlayer.shared
    private let hotKeyManager = GlobalHotKeyManager()
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    private let popoverWidth: CGFloat = 320
    private let popoverHeight: CGFloat = 500

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        print("[MenuController] applicationDidFinishLaunching")
        #endif
        configureStatusItem()
        configurePopover()
        bindPlayerState()
        registerHotKeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appearanceObservation?.invalidate()
        hotKeyManager.invalidate()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        #if DEBUG
        print("[MenuController] status item button created: \(button)")
        #endif
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = statusIcon(active: false)
        button.title = ""
        #if DEBUG
        if let window = button.window {
            print("[MenuController] status item window frame: \(window.frame)")
        } else {
            print("[MenuController] status item window not ready; scheduling frame log")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak button] in
                if let window = button?.window {
                    print("[MenuController] status item window frame (delayed): \(window.frame)")
                } else {
                    print("[MenuController] status item window still nil")
                }
            }
        }
        #endif
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.appearsDisabled = false
        button.toolTip = "Quran Menubar"
        button.wantsLayer = true
        button.isEnabled = true
        if button.cell?.isBordered == true {
            button.cell?.isBordered = false
        }
    }

    private func configurePopover() {
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: QuranPopoverView(player: player))
    }

    private func bindPlayerState() {
        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard let self, let button = self.statusItem.button else { return }
                button.image = self.statusIcon(active: isPlaying)
            }
            .store(in: &cancellables)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self, let button = self.statusItem.button else { return }
            DispatchQueue.main.async {
                button.image = self.statusIcon(active: self.player.isPlaying)
            }
        }
    }

    private func registerHotKeys() {
        hotKeyManager.register(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey), identifier: 1) { [weak self] in
            DispatchQueue.main.async {
                self?.player.playPauseToggle()
            }
        }

        hotKeyManager.register(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | cmdKey), identifier: 2) { [weak self] in
            DispatchQueue.main.async {
                self?.player.playNextSurah()
            }
        }

        hotKeyManager.register(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | cmdKey), identifier: 3) { [weak self] in
            DispatchQueue.main.async {
                self?.player.playPreviousSurah()
            }
        }
    }

    private func statusIcon(active: Bool) -> NSImage {
        let symbolName = active ? "moon.stars.fill" : "moon"
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: active ? [NSColor.controlAccentColor] : [NSColor.labelColor]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Quran Menubar")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = !active
        return image ?? NSImage()
    }
}

// MARK: - SwiftUI Popover

struct QuranPopoverView: View {
    @ObservedObject var player: QuranPlayer
    @State private var searchText: String = ""
    @State private var selection: QuranPlayer.Surah.ID?
    @FocusState private var listIsFocused: Bool
    @State private var showDownloadAllConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var showClearAllCacheConfirmation = false
    @State private var showReciterPicker = false
    @State private var filterWorkItem: DispatchWorkItem?
    @State private var searchIsFocused = false

    var body: some View {
        VStack(spacing: 8) {
            if case let .preparing(progress) = player.preparationState {
                PreparationBanner(progress: progress)
            } else if case let .error(message) = player.preparationState {
                ErrorBanner(message: message)
            }

            ReciterHeaderView(
                player: player,
                showDownloadAllConfirmation: $showDownloadAllConfirmation,
                showClearCacheConfirmation: $showClearCacheConfirmation,
                showClearAllCacheConfirmation: $showClearAllCacheConfirmation,
                showReciterPicker: $showReciterPicker
            )
            .padding(.horizontal, 10)
            .padding(.top, 2)

            SearchField(
                text: $searchText,
                isFocused: $searchIsFocused,
                onCommit: { applyFilter(resetSelection: false) },
                onMoveFocusDown: {
                    listIsFocused = true
                    if let currentSelection = selection,
                       let surah = player.filteredSurahs.first(where: { $0.id == currentSelection }) {
                        if player.currentSurah?.id != surah.id {
                            player.play(surah: surah, resumeFromLastTime: false)
                        }
                    } else if let first = player.filteredSurahs.first {
                        selection = first.id
                        player.play(surah: first, resumeFromLastTime: false)
                    }
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            )

            SurahListView(
                player: player,
                selection: $selection,
                isFocused: $listIsFocused
            )
            .animation(.easeInOut(duration: 0.12), value: selection)

            Divider()
                .background(Color.clear)

            PlaybackControlsView(player: player)
                .padding([.leading, .trailing, .bottom], 10)
        }
        .padding(.vertical, 6)
        .background(
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
        )
        .frame(width: 320)
        .onChange(of: searchText) { _ in
            scheduleFilter(resetSelection: true)
        }
        .onAppear {
            applyFilter(resetSelection: false)
            selection = player.currentSurah?.id ?? selection
            selection = SurahSelectionLogic.selectionAfterFiltering(
                previousSelection: selection,
                filteredSurahs: player.filteredSurahs
            )
        }
        .onChange(of: player.currentSurah?.id) { currentId in
            selection = SurahSelectionLogic.selectionAfterCurrentChange(
                currentSurahID: currentId,
                currentSelection: selection,
                filteredSurahs: player.filteredSurahs
            )
        }
        .confirmationDialog(
            "Download all surahs for this reciter",
            isPresented: $showDownloadAllConfirmation
        ) {
            Button("Download all (this reciter)", role: .destructive) {
                player.downloadAllSurahs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can download hundreds of MB depending on the selected reciter.")
        }
        .confirmationDialog(
            "Clear cached audio for this reciter",
            isPresented: $showClearCacheConfirmation
        ) {
            Button("Clear cache (this reciter)", role: .destructive) {
                player.clearCacheForCurrentReciter()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all downloaded surahs for the current reciter.")
        }
        .confirmationDialog(
            "Clear all cached audio",
            isPresented: $showClearAllCacheConfirmation
        ) {
            Button("Clear all cache", role: .destructive) {
                player.clearAllCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all downloaded surahs for all reciters.")
        }
        .popover(isPresented: $showReciterPicker, arrowEdge: .top) {
            ReciterPickerView(player: player, isPresented: $showReciterPicker)
        }
    }

    private func applyFilter(resetSelection: Bool) {
        player.filterSurahs(with: searchText)
        let baseSelection = resetSelection ? nil : selection
        selection = SurahSelectionLogic.selectionAfterFiltering(
            previousSelection: baseSelection,
            filteredSurahs: player.filteredSurahs
        )
    }

    private func scheduleFilter(resetSelection: Bool) {
        filterWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak player] in
            guard player != nil else { return }
            applyFilter(resetSelection: resetSelection)
        }
        filterWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        if resetSelection {
            selection = nil
        }
    }

}

// MARK: - Subviews

private struct SurahListView: View {
    @ObservedObject var player: QuranPlayer
    @Binding var selection: QuranPlayer.Surah.ID?
    @FocusState.Binding var isFocused: Bool
    @State private var hoveredID: QuranPlayer.Surah.ID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(player.filteredSurahs) { surah in
                    let isCached = player.cachedSurahIDs.contains(surah.number)
                    SurahRow(
                        surah: surah,
                        isActive: surah.id == player.currentSurah?.id,
                        isSelected: surah.id == selection,
                        isHovered: surah.id == hoveredID,
                        isCached: isCached
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = surah.id
                        if player.currentSurah?.id != surah.id {
                            player.play(surah: surah, resumeFromLastTime: false)
                        }
                    }
                    .onHover { hovering in
                        hoveredID = hovering ? surah.id : nil
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .overlay {
            if player.filteredSurahs.isEmpty {
                Text("No surah found")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxHeight: 280)
        .onChange(of: player.filteredSurahs) { _ in
            guard let selection else {
                self.selection = player.filteredSurahs.first?.id
                return
            }
            if !player.filteredSurahs.contains(where: { $0.id == selection }) {
                self.selection = player.filteredSurahs.first?.id
            }
        }
    }

}

private struct SurahRow: View {
    let surah: QuranPlayer.Surah
    let isActive: Bool
    let isSelected: Bool
    let isHovered: Bool
    let isCached: Bool

    var body: some View {
        HStack {
            Text(String(format: "%03d", surah.number))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(numberColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(surah.nameFr)
                    .font(.system(size: 13, weight: fontWeight))
                    .lineLimit(1)
                Text(surah.nameAr)
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
            }
            Spacer()
            Text("\(surah.verses) v")
                .font(.system(size: 11))
                .foregroundColor(secondaryTextColor)
            if !isCached {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
    }

    private var fontWeight: Font.Weight {
        isActive ? .semibold : .regular
    }

    private var secondaryTextColor: Color {
        if isSelected {
            return Color(nsColor: .selectedMenuItemTextColor)
        }
        return .secondary
    }

    private var numberColor: Color {
        if isSelected {
            return Color(nsColor: .selectedMenuItemTextColor)
        }
        return isActive ? Color.primary.opacity(0.8) : .secondary
    }

    private var rowBackground: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.6)
        }
        if isActive {
            return Color(nsColor: .controlAccentColor).opacity(0.15)
        }
        return Color.clear
    }
}

private struct PlaybackControlsView: View {
    @ObservedObject var player: QuranPlayer
    @State private var isInteractingWithSlider = false
    private let timeFormatter = PlaybackTimeFormatter()

    var body: some View {
        VStack(spacing: 8) {
            if let current = player.currentSurah {
                HStack {
                    Text(current.nameFr)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(current.nameAr)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Text("Select a surah")
                        .font(.system(size: 13))
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Button(action: player.playPreviousSurah) {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: player.playPauseToggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: player.playNextSurah) {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .imageScale(.medium)

            SliderView(player: player, timeFormatter: timeFormatter)
        }
    }
}

private struct SliderView: View {
    @ObservedObject var player: QuranPlayer
    let timeFormatter: PlaybackTimeFormatter
    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            PlaybackSlider(
                value: Binding(get: {
                    guard player.duration > 0 else { return 0 }
                    return player.playbackPosition / player.duration
                }, set: { ratio in
                    guard player.duration > 0 else { return }
                    let newValue = ratio * player.duration
                    sliderValue = newValue
                    player.seek(to: newValue)
                }),
                isEnabled: player.currentSurah != nil
            )
            .frame(height: 18)

            HStack {
                Text(timeFormatter.format(player.playbackPosition))
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                let remaining = max(player.duration - player.playbackPosition, 0)
                Text("-" + timeFormatter.format(remaining))
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(.secondary)
        }
    }
}

private struct PlaybackSlider: NSViewRepresentable {
    @Binding var value: Double
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = ClickableSlider(value: 0, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.allowsTickMarkValuesOnly = false
        slider.numberOfTickMarks = 0
        slider.minValue = 0
        slider.maxValue = 1
        slider.altIncrementValue = 0.01
        slider.translatesAutoresizingMaskIntoConstraints = false
        if let cell = slider.cell as? NSSliderCell {
            cell.controlSize = .small
        }
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
        nsView.isEnabled = isEnabled
        nsView.alphaValue = isEnabled ? 1.0 : 0.5
    }

    final class Coordinator: NSObject {
        private var parent: PlaybackSlider

        init(_ parent: PlaybackSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.doubleValue
        }
    }

    private final class ClickableSlider: NSSlider {
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let cell = cell as? NSSliderCell {
                let knob = Double(cell.knobThickness)
                let usableWidth = Double(bounds.width) - knob
                if usableWidth > 0 {
                    let ratio = max(0, min(1, (Double(point.x) - knob / 2) / usableWidth))
                    doubleValue = minValue + ratio * (maxValue - minValue)
                    if let action = action {
                        NSApp.sendAction(action, to: target, from: self)
                    }
                }
            }
            super.mouseDown(with: event)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = emphasized ? .active : .followsWindowActiveState
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = emphasized ? .active : .followsWindowActiveState
        nsView.isEmphasized = emphasized
    }
}

private struct PreparationBanner: View {
    let progress: Double

    var body: some View {
        HStack {
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(maxWidth: .infinity)
            Text("Downloading… \(Int(progress * 100))%")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .padding(.horizontal, 12)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 12)
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = "Search surah"
    var onCommit: () -> Void
    var onMoveFocusDown: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(string: text)
        searchField.delegate = context.coordinator
        searchField.controlSize = .small
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.placeholderString = placeholder
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.sendsSearchStringImmediately = true
            cell.sendsWholeSearchString = false
        }
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused, let window = nsView.window {
            if window.firstResponder !== nsView {
                window.makeFirstResponder(nsView)
            }
            DispatchQueue.main.async {
                isFocused = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate, NSControlTextEditingDelegate {
        private let parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                parent.text = field.stringValue
                parent.onCommit()
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) ||
                commandSelector == #selector(NSResponder.complete(_:)) {
                parent.onMoveFocusDown()
                return true
            }
            return false
        }
    }
}

private struct ReciterHeaderView: View {
    @ObservedObject var player: QuranPlayer
    @Binding var showDownloadAllConfirmation: Bool
    @Binding var showClearCacheConfirmation: Bool
    @Binding var showClearAllCacheConfirmation: Bool
    @Binding var showReciterPicker: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Reciter")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                Spacer()
                Menu {
                    Button("Download all (this reciter)") {
                        showDownloadAllConfirmation = true
                    }
                    Button("Clear cache (this reciter)") {
                        showClearCacheConfirmation = true
                    }
                    Divider()
                    Button("Clear all cache") {
                        showClearAllCacheConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18, height: 18)
            }

            switch player.reciterLoadingState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading reciters…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    Spacer()
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded, .idle:
                Button(action: { showReciterPicker = true }) {
                    HStack(spacing: 6) {
                        Text(player.selectedReciterDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text("\(player.formattedCacheSize) • \(player.formattedCacheSizeAll)")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ReciterPickerView: View {
    @ObservedObject var player: QuranPlayer
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var searchIsFocused = true
    @State private var hoveredID: Int?

    private var filteredReciters: [QuranPlayer.Reciter] {
        let normalized = SurahSearch.normalize(query)
        guard !normalized.isEmpty else { return player.reciters }
        return player.reciters.filter { reciter in
            let name = SurahSearch.normalize(reciter.name)
            let arabic = SurahSearch.normalize(reciter.arabicName ?? "")
            return name.contains(normalized) || arabic.contains(normalized)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Choose a reciter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            SearchField(
                text: $query,
                isFocused: $searchIsFocused,
                placeholder: "Search reciter",
                onCommit: {},
                onMoveFocusDown: {}
            )
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredReciters) { reciter in
                        ReciterRowView(
                            reciter: reciter,
                            isSelected: reciter.id == player.selectedReciterID,
                            isHovered: reciter.id == hoveredID
                        ) {
                            player.selectedReciterID = reciter.id
                            isPresented = false
                        }
                        .onHover { hovering in
                            hoveredID = hovering ? reciter.id : nil
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
        .background(
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
        )
        .cornerRadius(10)
    }
}

private struct ReciterRowView: View {
    let reciter: QuranPlayer.Reciter
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reciter.normalizedName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(primaryColor)
                    if let arabic = reciter.arabicName, !arabic.isEmpty {
                        Text(arabic)
                            .font(.system(size: 11))
                            .foregroundColor(secondaryColor)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: .controlAccentColor))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.7)
        }
        return Color.clear
    }

    private var primaryColor: Color {
        if isSelected {
            return Color(nsColor: .selectedMenuItemTextColor)
        }
        return Color(nsColor: .labelColor)
    }

    private var secondaryColor: Color {
        if isSelected {
            return Color(nsColor: .selectedMenuItemTextColor).opacity(0.85)
        }
        return Color(nsColor: .secondaryLabelColor)
    }
}

// MARK: - Utilities

private final class PlaybackTimeFormatter {
    func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "00:00" }
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Global Hotkeys

private final class GlobalHotKeyManager {
    typealias Handler = () -> Void

    private var hotKeys: [UInt32: (ref: EventHotKeyRef?, handler: Handler)] = [:]
    private var eventHandler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, handler: @escaping Handler) {
        installHandlerIfNeeded()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x514D4E55), id: identifier) // 'QMNU'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            hotKeys[identifier] = (hotKeyRef, handler)
        }
    }

    func invalidate() {
        for (_, entry) in hotKeys {
            if let ref = entry.ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeys.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, eventRef, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handle(event: eventRef)
        }, 1, &eventType, selfPointer, &eventHandler)
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr else { return status }
        if let entry = hotKeys[hotKeyID.id] {
            entry.handler()
        }
        return noErr
    }
}
