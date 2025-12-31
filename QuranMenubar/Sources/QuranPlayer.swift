import Foundation
import AVFoundation
import Combine
import MediaPlayer
#if os(macOS) && !targetEnvironment(macCatalyst)
import CoreAudio
import AppKit
#endif

final class QuranPlayer: NSObject, ObservableObject {
    static let shared = QuranPlayer()

    struct Reciter: Identifiable, Codable, Equatable {
        let id: Int
        let name: String
        let arabicName: String?
        let relativePath: String
        let fileFormats: String?
        let sectionId: Int?
        let home: Bool

        var displayName: String {
            let normalized = Self.normalizedName(name)
            guard let arabicName, !arabicName.isEmpty else { return normalized }
            return "\(normalized) — \(arabicName)"
        }

        var normalizedName: String {
            Self.normalizedName(name)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case arabicName = "arabic_name"
            case relativePath = "relative_path"
            case fileFormats = "file_formats"
            case sectionId = "section_id"
            case home
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            arabicName = try container.decodeIfPresent(String.self, forKey: .arabicName)
            relativePath = try container.decode(String.self, forKey: .relativePath)
            fileFormats = try container.decodeIfPresent(String.self, forKey: .fileFormats)
            sectionId = try container.decodeIfPresent(Int.self, forKey: .sectionId)
            if let boolValue = try? container.decode(Bool.self, forKey: .home) {
                home = boolValue
            } else if let intValue = try? container.decode(Int.self, forKey: .home) {
                home = intValue != 0
            } else {
                home = false
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(arabicName, forKey: .arabicName)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encodeIfPresent(fileFormats, forKey: .fileFormats)
            try container.encodeIfPresent(sectionId, forKey: .sectionId)
            try container.encode(home, forKey: .home)
        }

        private static func normalizedName(_ input: String) -> String {
            let pattern = #"\\s*\\[[^\\]]+\\]"#
            let cleaned = input.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            return cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Surah: Identifiable, Codable, Equatable {
        let number: Int
        let nameFr: String
        let nameAr: String
        let verses: Int
        let audioFile: String
        let durationSeconds: TimeInterval?

        var id: Int { number }
    }

    enum PreparationState: Equatable {
        case idle
        case preparing(Double)
        case ready
        case error(String)
    }

    enum ReciterLoadingState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var surahs: [Surah] = []
    @Published private(set) var filteredSurahs: [Surah] = []
    @Published private(set) var currentSurah: Surah?
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var preparationState: PreparationState = .idle
    @Published private(set) var reciters: [Reciter] = []
    @Published private(set) var reciterLoadingState: ReciterLoadingState = .idle
    @Published private(set) var cacheVersion: Int = 0
    @Published private(set) var cachedSurahIDs: Set<Int> = []
    @Published private(set) var cacheSizeBytes: Int64 = 0
    @Published private(set) var cacheSizeAllBytes: Int64 = 0
    @Published var selectedReciterID: Int = 0 {
        didSet {
            guard oldValue != selectedReciterID else { return }
            userDefaults.set(selectedReciterID, forKey: selectedReciterIDKey)
            resetPlaybackForReciterChange()
        }
    }

    var selectedReciterDisplayName: String {
        if let reciter = selectedReciter() {
            return reciter.displayName
        }
        return reciterLoadingState == .loading ? "Loading…" : "Select a reciter"
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }

    var formattedCacheSizeAll: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeAllBytes, countStyle: .file)
    }

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var pendingPlayWorkItem: DispatchWorkItem?
    private var pendingPauseWorkItem: DispatchWorkItem?
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    private var audioSession: AVAudioSession?
#endif
    private var routeChangeObserver: NSObjectProtocol?
    private var remoteCommandTargets: [MPRemoteCommand: Any] = [:]
    private var nowPlayingInfo: [String: Any] = [:]
#if os(macOS) && !targetEnvironment(macCatalyst)
    private struct OutputDeviceInfo {
        let id: AudioObjectID
        let transport: UInt32
    }
    private let outputDeviceListenerQueue = DispatchQueue(label: "com.fouadbelhia.QuranPlayer.output-listener", qos: .utility)
    private var defaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?
    private var currentOutputDeviceInfo: OutputDeviceInfo?
#endif

    private let audioFolderName = "Audio"
    private let resumeLastPositionKey = "resumeLastPosition"
    private let lastSurahNumberKey = "lastSurahNumber"
    private let lastPlaybackTimeKey = "lastPlaybackTime"
    private let maxCacheBytesKey = "maxCacheBytes"
    private let selectedReciterIDKey = "selectedReciterID"
    private let recitersCacheFilename = "reciters.json"
    private let audioBaseURL = URL(string: "https://download.quranicaudio.com/quran/")!
    private let fadeDuration: TimeInterval = 0.28

    override private init() {
        super.init()
        loadSurahs()
        applyStoredFilters()
        restoreLastPlaybackState()
        prepareOfflineAssetsIfNeeded()
        loadReciters()
        configureAudioSession()
        setupRouteChangeMonitoring()
        setupRemoteCommandCenter()
    }

    deinit {
        progressTimer?.invalidate()
        audioPlayer?.stop()
        teardownRouteChangeMonitoring()
        teardownRemoteCommandCenter()
        deactivateAudioSession()
    }

    func filterSurahs(with query: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.filteredSurahs = SurahSearch.filter(surahs: self.surahs, query: query)
        }
    }

    func playPauseToggle() {
        if let player = audioPlayer {
            if player.isPlaying {
                pause()
            } else {
                resume()
            }
        } else if let surah = currentSurah ?? surahs.first {
            play(surah: surah, resumeFromLastTime: true)
        }
    }

    func playNextSurah() {
        guard let current = currentSurah else {
            if let first = surahs.first {
                play(surah: first, resumeFromLastTime: false)
            }
            return
        }
        let nextNumber = current.number + 1
        guard let next = surahs.first(where: { $0.number == nextNumber }) else { return }
        play(surah: next, resumeFromLastTime: false)
    }

    func playPreviousSurah() {
        guard let current = currentSurah else {
            if let first = surahs.first {
                play(surah: first, resumeFromLastTime: false)
            }
            return
        }
        let previousNumber = current.number - 1
        guard previousNumber >= 1, let previous = surahs.first(where: { $0.number == previousNumber }) else { return }
        play(surah: previous, resumeFromLastTime: false)
    }

    func play(surah: Surah, resumeFromLastTime: Bool) {
        if currentSurah?.id == surah.id, let currentPlayer = audioPlayer {
            if !currentPlayer.isPlaying {
                resume()
            }
            return
        }

        pendingPlayWorkItem?.cancel()

        let beginPlayback: () -> Void = { [weak self] in
            self?.startPlayback(for: surah, resumeFromLastTime: resumeFromLastTime)
        }

        if let currentPlayer = audioPlayer, currentPlayer.isPlaying {
            currentPlayer.setVolume(0, fadeDuration: fadeDuration)
            let workItem = DispatchWorkItem { [weak self, weak currentPlayer] in
                guard let self else { return }
                if let player = currentPlayer {
                    player.stop()
                    player.currentTime = 0
                    player.volume = 1
                }
                self.audioPlayer = nil
                beginPlayback()
            }
            pendingPlayWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: workItem)
        } else {
            beginPlayback()
        }
    }

    private func startPlayback(for surah: Surah, resumeFromLastTime: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentSurah = surah
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let fileURL = await self.ensureCachedFile(for: surah) else {
                await MainActor.run {
                    self.preparationState = .error("Unable to download this surah.")
                }
                return
            }

            do {
                let newPlayer = try AVAudioPlayer(contentsOf: fileURL)
                newPlayer.delegate = self
                newPlayer.prepareToPlay()
                newPlayer.volume = 0
                await MainActor.run {
                    self.activate(newPlayer: newPlayer, with: surah, resumeFromLastTime: resumeFromLastTime)
                    newPlayer.setVolume(1, fadeDuration: self.fadeDuration)
                }
            } catch {
                await MainActor.run {
                    self.handleCorruptedFile(for: surah, originalError: error)
                }
            }
        }
    }

    func pause() {
        guard let player = audioPlayer else { return }
        pendingPauseWorkItem?.cancel()
        player.setVolume(0, fadeDuration: fadeDuration)
        let workItem = DispatchWorkItem { [weak self, weak player] in
            guard let self else { return }
            guard let player, self.audioPlayer === player else { return }
            player.pause()
            player.volume = 1
            self.isPlaying = false
            self.stopProgressTimer()
            self.persistPlaybackTime()
            self.updateNowPlayingPlaybackState()
            self.deactivateAudioSession()
        }
        pendingPauseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: workItem)
    }

    func resume() {
        pendingPauseWorkItem?.cancel()
        guard let player = audioPlayer else { return }
        activateAudioSessionIfNeeded()
        player.volume = 0
        player.play()
        player.setVolume(1, fadeDuration: fadeDuration)
        isPlaying = true
        startProgressTimer()
        updateNowPlayingPlaybackState()
    }

    func seek(to newValue: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = max(0, min(newValue, player.duration))
        playbackPosition = player.currentTime
        persistPlaybackTime()
        updateNowPlayingPlaybackState()
    }

    func refreshPreparationStatus() {
        switch preparationState {
        case .ready:
            break
        default:
            prepareOfflineAssetsIfNeeded(force: true)
        }
    }

    func downloadAllSurahs() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.downloadAllSurahsInternal()
        }
    }

    func clearCacheForCurrentReciter() {
        let destination = destinationDirectory()
        try? fileManager.removeItem(at: destination)
        cacheVersion += 1
        cachedSurahIDs.removeAll()
        refreshCacheStats()
    }

    func clearAllCache() {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = urls.first ?? fileManager.temporaryDirectory
        let root = base.appendingPathComponent("QuranMenubar", isDirectory: true).appendingPathComponent(audioFolderName, isDirectory: true)
        try? fileManager.removeItem(at: root)
        cacheVersion += 1
        cachedSurahIDs.removeAll()
        refreshCacheStats()
    }

    func isSurahCached(_ surah: Surah) -> Bool {
        cachedSurahIDs.contains(surah.number)
    }

    // MARK: - Private helpers

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        audioSession = session
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
        } catch {
            #if DEBUG
            print("[QuranPlayer] Unable to configure audio session: \(error.localizedDescription)")
            #endif
        }
        #endif
    }

    private func activateAudioSessionIfNeeded() {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        guard let session = audioSession else { return }
        do {
            try session.setActive(true, options: [])
        } catch {
            #if DEBUG
            print("[QuranPlayer] Failed to activate audio session: \(error.localizedDescription)")
            #endif
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        guard let session = audioSession else { return }
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            #if DEBUG
            print("[QuranPlayer] Failed to deactivate audio session: \(error.localizedDescription)")
            #endif
        }
        #endif
    }

    private func setupRouteChangeMonitoring() {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }
        #elseif os(macOS)
        setupOutputDeviceMonitoring()
        #endif
    }

    private func teardownRouteChangeMonitoring() {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        #elseif os(macOS)
        teardownOutputDeviceMonitoring()
        #endif
    }

    #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            if isPlaying {
                pause()
            }
        default:
            break
        }
    }
    #endif

#if os(macOS) && !targetEnvironment(macCatalyst)
    private func setupOutputDeviceMonitoring() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChange()
        }
        defaultOutputDeviceListener = listener
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputDevicePropertyAddress,
            outputDeviceListenerQueue,
            listener
        )
        if status != noErr {
            #if DEBUG
            print("[QuranPlayer] Unable to register audio device listener: \(status)")
            #endif
        }
        currentOutputDeviceInfo = fetchCurrentOutputDeviceInfo()
    }

    private func teardownOutputDeviceMonitoring() {
        guard let listener = defaultOutputDeviceListener else { return }
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputDevicePropertyAddress,
            outputDeviceListenerQueue,
            listener
        )
        if status != noErr {
            #if DEBUG
            print("[QuranPlayer] Unable to remove audio device listener: \(status)")
            #endif
        }
        defaultOutputDeviceListener = nil
    }

    private func handleDefaultOutputDeviceChange() {
        let previousInfo = currentOutputDeviceInfo
        currentOutputDeviceInfo = fetchCurrentOutputDeviceInfo()
        guard isPlaying else { return }

        let bluetoothTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE
        ]

        if let previous = previousInfo,
           bluetoothTransports.contains(previous.transport) {
            let current = currentOutputDeviceInfo
            let deviceChanged = current?.id != previous.id
            let transportChanged = current?.transport != previous.transport
            if current == nil || deviceChanged || transportChanged {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isPlaying {
                        self.pause()
                    }
                }
            }
        }
    }

    private func fetchCurrentOutputDeviceInfo() -> OutputDeviceInfo? {
        var deviceID = AudioObjectID()
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputDevicePropertyAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )
        guard transportStatus == noErr else {
            return nil
        }
        return OutputDeviceInfo(id: deviceID, transport: transportType)
    }
#endif

    private func setupRemoteCommandCenter() {
        if #available(macOS 10.12.2, *) {
            let commandCenter = MPRemoteCommandCenter.shared()

            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.isEnabled = true
            commandCenter.nextTrackCommand.isEnabled = true
            commandCenter.previousTrackCommand.isEnabled = true
            commandCenter.stopCommand.isEnabled = true

            remoteCommandTargets[commandCenter.playCommand] = commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.handleRemotePlayCommand()
                return .success
            }

            remoteCommandTargets[commandCenter.pauseCommand] = commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.handleRemotePauseCommand()
                return .success
            }

            remoteCommandTargets[commandCenter.togglePlayPauseCommand] = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.handleRemoteToggleCommand()
                return .success
            }

            remoteCommandTargets[commandCenter.nextTrackCommand] = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                DispatchQueue.main.async {
                    self.playNextSurah()
                }
                return .success
            }

            remoteCommandTargets[commandCenter.previousTrackCommand] = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                DispatchQueue.main.async {
                    self.playPreviousSurah()
                }
                return .success
            }

            remoteCommandTargets[commandCenter.stopCommand] = commandCenter.stopCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.handleRemotePauseCommand()
                return .success
            }
        }
    }

    private func teardownRemoteCommandCenter() {
        if #available(macOS 10.12.2, *) {
            let commandCenter = MPRemoteCommandCenter.shared()
            for (command, target) in remoteCommandTargets {
                command.removeTarget(target)
            }
            remoteCommandTargets.removeAll()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func handleRemotePlayCommand() {
        DispatchQueue.main.async {
            if let player = self.audioPlayer, !player.isPlaying {
                self.resume()
            } else if self.audioPlayer == nil {
                let target = self.currentSurah ?? self.surahs.first
                if let surah = target {
                    self.play(surah: surah, resumeFromLastTime: true)
                }
            }
        }
    }

    private func handleRemotePauseCommand() {
        DispatchQueue.main.async {
            if self.isPlaying {
                self.pause()
            }
        }
    }

    private func handleRemoteToggleCommand() {
        DispatchQueue.main.async {
            self.playPauseToggle()
        }
    }

    private func updateNowPlayingMetadata(for surah: Surah?, duration: TimeInterval) {
        guard #available(macOS 10.12.2, *) else { return }
        guard let surah else {
            nowPlayingInfo = [:]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = surah.nameFr
        info[MPMediaItemPropertyArtist] = surah.nameAr
        info[MPMediaItemPropertyAlbumTitle] = "Quran"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackPosition
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = surahs.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = max(0, surah.number - 1)
#if os(macOS) && !targetEnvironment(macCatalyst)
        if #available(macOS 10.13, *) {
            if let image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: nil) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
        }
#endif
        if #available(macOS 10.13, *) {
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        }
        nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        guard #available(macOS 10.12.2, *) else { return }
        guard !nowPlayingInfo.isEmpty else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackPosition
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func loadSurahs() {
        guard let url = Bundle.main.url(forResource: "SurahList", withExtension: "json") ??
                Bundle.main.url(forResource: "SurahList", withExtension: "json", subdirectory: "Sources") else {
            preparationState = .error("Unable to load the surah list.")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            surahs = try decoder.decode([Surah].self, from: data)
            filteredSurahs = surahs
        } catch {
            preparationState = .error("Invalid SurahList.json: \(error.localizedDescription)")
        }
    }

    private func applyStoredFilters() {
        filteredSurahs = surahs
    }

    private func restoreLastPlaybackState() {
        guard shouldResumeLastPosition() else { return }
        let lastSurahNumber = userDefaults.integer(forKey: lastSurahNumberKey)
        if let surah = surahs.first(where: { $0.number == lastSurahNumber }) {
            currentSurah = surah
            playbackPosition = userDefaults.double(forKey: lastPlaybackTimeKey)
            duration = surah.durationSeconds ?? 0
        }
    }

    private func prepareOfflineAssetsIfNeeded(force: Bool = false) {
        guard force || needsPreparation() else {
            preparationState = .ready
            return
        }
        preparationState = .ready
    }

    private func needsPreparation() -> Bool {
        let destination = destinationDirectory()
        guard let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: nil) else {
            return true
        }
        var count = 0
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "mp3" {
                count += 1
            }
        }
        return count < surahs.count
    }

    private func destinationDirectory() -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = urls.first ?? fileManager.temporaryDirectory
        let reciterFolder = sanitizedReciterFolderName()
        return base
            .appendingPathComponent("QuranMenubar", isDirectory: true)
            .appendingPathComponent(audioFolderName, isDirectory: true)
            .appendingPathComponent(reciterFolder, isDirectory: true)
    }

    private func ensureCachedFile(for surah: Surah) async -> URL? {
        let destination = destinationDirectory().appendingPathComponent(surah.audioFile)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        guard let remoteURL = remoteAudioURL(for: surah) else {
            return nil
        }
        do {
            try await downloadSurah(from: remoteURL, to: destination, updatesPreparationState: true)
            return destination
        } catch {
            return nil
        }
    }

    private func enforceCacheLimitIfNeeded() {
        let maximumBytes = userDefaults.integer(forKey: maxCacheBytesKey)
        guard maximumBytes > 0 else { return }
        let destinationDir = destinationDirectory()
        guard let urls = try? fileManager.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) else {
            return
        }
        var totalSize: Int64 = 0
        var fileAttributes: [(url: URL, size: Int64, modified: Date)] = []
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(attributes?.fileSize ?? 0)
            totalSize += size
            let modified = attributes?.contentModificationDate ?? Date.distantPast
            fileAttributes.append((url, size, modified))
        }
        guard totalSize > Int64(maximumBytes) else { return }
        let sorted = fileAttributes.sorted { $0.modified < $1.modified }
        var sizeToFree = totalSize - Int64(maximumBytes)
        for entry in sorted {
            try? fileManager.removeItem(at: entry.url)
            sizeToFree -= entry.size
            if sizeToFree <= 0 { break }
        }
    }

    private func handleCorruptedFile(for surah: Surah, originalError: Error) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let destination = self.destinationDirectory().appendingPathComponent(surah.audioFile)
            try? self.fileManager.removeItem(at: destination)
            guard let remoteURL = self.remoteAudioURL(for: surah) else { return }
            do {
                try await self.downloadSurah(from: remoteURL, to: destination, updatesPreparationState: true)
                await MainActor.run {
                    self.play(surah: surah, resumeFromLastTime: false)
                }
            } catch {
                await MainActor.run {
                    self.preparationState = .error("Corrupted audio file for \(surah.nameFr). \(originalError.localizedDescription)")
                }
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.playbackPosition = player.currentTime
            self.duration = player.duration
            self.persistPlaybackTime()
            self.updateNowPlayingPlaybackState()
        }
        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func persistPlaybackTime() {
        guard shouldResumeLastPosition(), let player = audioPlayer, let surah = currentSurah else { return }
        userDefaults.set(surah.number, forKey: lastSurahNumberKey)
        userDefaults.set(player.currentTime, forKey: lastPlaybackTimeKey)
    }

    private func saveCurrentSurah() {
        guard let surah = currentSurah else { return }
        userDefaults.set(surah.number, forKey: lastSurahNumberKey)
    }

    private func shouldResumeLastPosition() -> Bool {
        return userDefaults.bool(forKey: resumeLastPositionKey)
    }

    private func activate(newPlayer: AVAudioPlayer, with surah: Surah, resumeFromLastTime: Bool) {
        audioPlayer?.stop()
        audioPlayer = newPlayer
        pendingPlayWorkItem = nil
        pendingPauseWorkItem?.cancel()
        pendingPauseWorkItem = nil
        currentSurah = surah
        duration = newPlayer.duration
        if resumeFromLastTime,
           shouldResumeLastPosition(),
           surah.number == userDefaults.integer(forKey: lastSurahNumberKey) {
            let time = userDefaults.double(forKey: lastPlaybackTimeKey)
            newPlayer.currentTime = min(time, newPlayer.duration)
        } else {
            userDefaults.set(0.0, forKey: lastPlaybackTimeKey)
            newPlayer.currentTime = 0
        }
        playbackPosition = newPlayer.currentTime
        startProgressTimer()
        activateAudioSessionIfNeeded()
        newPlayer.play()
        isPlaying = true
        saveCurrentSurah()
        updateNowPlayingMetadata(for: surah, duration: newPlayer.duration)
    }

    private func loadReciters() {
        let storedID = userDefaults.integer(forKey: selectedReciterIDKey)
        if storedID != 0 {
            selectedReciterID = storedID
        }
        refreshCachedSurahs()
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.fetchReciters()
        }
    }

    private func fetchReciters() async {
        await MainActor.run {
            reciterLoadingState = .loading
        }
        let cacheURL = recitersCacheURL()
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "https://quranicaudio.com/api/qaris")!)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw NSError(domain: "QuranPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid network response"])
            }
            let decoder = JSONDecoder()
            let reciters = try decoder.decode([Reciter].self, from: data)
                .filter { $0.fileFormats?.contains("mp3") ?? true }
            let cacheDir = cacheURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: [.atomic])
            await MainActor.run {
                self.reciters = reciters.sorted { lhs, rhs in
                    if lhs.home != rhs.home {
                        return lhs.home && !rhs.home
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                self.reciterLoadingState = .loaded
                self.applyDefaultReciterIfNeeded()
                self.refreshCachedSurahs()
            }
        } catch {
            let cached = loadCachedReciters(from: cacheURL)
            await MainActor.run {
                if let cached, !cached.isEmpty {
                    self.reciters = cached
                    self.reciterLoadingState = .loaded
                    self.applyDefaultReciterIfNeeded()
                    self.refreshCachedSurahs()
                } else {
                    self.reciterLoadingState = .failed("Unable to load reciters. Check your connection.")
                }
            }
        }
    }

    private func applyDefaultReciterIfNeeded() {
        guard !reciters.isEmpty else { return }
        if reciters.contains(where: { $0.id == selectedReciterID }) {
            return
        }
        if let home = reciters.first(where: { $0.home }) {
            selectedReciterID = home.id
        } else if let first = reciters.first {
            selectedReciterID = first.id
        }
    }

    private func loadCachedReciters(from url: URL) -> [Reciter]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Reciter].self, from: data)
    }

    private func recitersCacheURL() -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = urls.first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("QuranMenubar", isDirectory: true)
            .appendingPathComponent(recitersCacheFilename)
    }

    private func selectedReciter() -> Reciter? {
        reciters.first(where: { $0.id == selectedReciterID })
    }

    private func sanitizedReciterFolderName() -> String {
        let raw = selectedReciter()?.relativePath ?? "default"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func remoteAudioURL(for surah: Surah) -> URL? {
        guard let reciter = selectedReciter() else { return nil }
        let padded = String(format: "%03d.mp3", surah.number)
        let relative = reciter.relativePath.hasSuffix("/") ? reciter.relativePath : reciter.relativePath + "/"
        return audioBaseURL.appendingPathComponent(relative + padded)
    }

    private func downloadSurah(from url: URL, to destination: URL, updatesPreparationState: Bool) async throws {
        if updatesPreparationState {
            await MainActor.run {
                preparationState = .preparing(0)
            }
        }
        try fileManager.createDirectory(at: destinationDirectory(), withIntermediateDirectories: true)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "QuranPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download rejected"])
        }
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
        enforceCacheLimitIfNeeded()
        await MainActor.run {
            self.cacheVersion += 1
            self.refreshCachedSurahs()
        }
        if updatesPreparationState {
            await MainActor.run {
                preparationState = .ready
            }
        }
    }

    private func downloadAllSurahsInternal() async {
        guard !surahs.isEmpty else { return }
        await MainActor.run { preparationState = .preparing(0) }
        var completed = 0.0
        let total = Double(surahs.count)
        for surah in surahs {
            if let remoteURL = remoteAudioURL(for: surah) {
                let destination = destinationDirectory().appendingPathComponent(surah.audioFile)
                if !fileManager.fileExists(atPath: destination.path) {
                    try? await downloadSurah(from: remoteURL, to: destination, updatesPreparationState: false)
                }
            }
            completed += 1
            let progress = completed / total
            await MainActor.run { preparationState = .preparing(progress) }
        }
        await MainActor.run { preparationState = .ready }
        await MainActor.run { refreshCachedSurahs() }
    }

    private func resetPlaybackForReciterChange() {
        pendingPlayWorkItem?.cancel()
        pendingPauseWorkItem?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopProgressTimer()
        playbackPosition = 0
        duration = 0
        updateNowPlayingMetadata(for: nil, duration: 0)
        refreshCachedSurahs()
    }

    private func refreshCachedSurahs() {
        let destinationDir = destinationDirectory()
        guard let urls = try? fileManager.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            cachedSurahIDs = []
            refreshCacheStats()
            return
        }
        var ids = Set<Int>()
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            let filename = url.deletingPathExtension().lastPathComponent
            let number = Int(filename.prefix(3)) ?? 0
            if number > 0 {
                ids.insert(number)
            }
        }
        cachedSurahIDs = ids
        refreshCacheStats()
    }

    private func refreshCacheStats() {
        cacheSizeBytes = directorySize(at: destinationDirectory())
        cacheSizeAllBytes = directorySize(at: cacheRootDirectory())
    }

    private func cacheRootDirectory() -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = urls.first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("QuranMenubar", isDirectory: true).appendingPathComponent(audioFolderName, isDirectory: true)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

extension QuranPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopProgressTimer()
        isPlaying = false
        playbackPosition = 0
        updateNowPlayingPlaybackState()
        if flag, let current = currentSurah,
           surahs.contains(where: { $0.number == current.number + 1 }) {
            playNextSurah()
        } else {
            deactivateAudioSession()
        }
    }
}
