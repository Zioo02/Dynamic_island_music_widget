// Now Playing Island
// A Dynamic Island–style "now playing" widget for the macOS menu bar.
// https://github.com/YOUR_USERNAME/now-playing-island
//
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

// =====================================================================
// SETTINGS – re-run ./install.sh after changing anything here
// =====================================================================
enum Config {
    static let islandWidth: CGFloat = 250      // island width in points (~250 fits next to the notch)
    static let islandHeight: CGFloat = 0       // 0 = match the menu bar automatically, e.g. 26 = fixed
    static let verticalInset: CGFloat = 4      // gap above and below the island (auto height only)
    static let innerPadding: CGFloat = 5       // gap between the island edge and its content
    static let glassTint: Double = 0.25        // glass darkening: 0 = clear, 1 = black
    static let showArtist = true               // true = "Title – Artist", false = title only
    static let showControls = false            // playback buttons on the island (always in the panel)
    static let showBars = true                 // equalizer bars
    static let reactToMusic = true             // bars follow the actual audio (macOS 14.2+)
    static let margin: CGFloat = 2             // gap to neighbouring menu bar icons
    static let playerAppName = "YouTube Music" // app opened from the panel
}
// =====================================================================

// MARK: - Localization (English / Polish)

enum L {
    static let polish = Locale.preferredLanguages.first?.hasPrefix("pl") ?? false
    static var nothingPlaying: String { polish ? "Nic nie gra" : "Nothing playing" }
    static var quit: String { polish ? "Zamknij wyspę" : "Quit Now Playing Island" }
    static func open(_ app: String) -> String { polish ? "Otwórz \(app)" : "Open \(app)" }
}

// MARK: - Now playing data (via media-control)

struct NowPlaying: Sendable, Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    var artwork = ""
    var elapsed: Double = 0
    var duration: Double = 0

    func sameDisplay(as other: NowPlaying) -> Bool {
        title == other.title && artist == other.artist && album == other.album
            && playing == other.playing && artwork.count == other.artwork.count
    }
}

enum MediaCLI {
    static let binary: String? = {
        let candidates = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func fetch() -> NowPlaying {
        guard let path = binary else { return NowPlaying() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["get", "--now"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return NowPlaying() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else { return NowPlaying() }
        var info = NowPlaying()
        info.title = dict["title"] as? String ?? ""
        info.artist = dict["artist"] as? String ?? ""
        info.album = dict["album"] as? String ?? ""
        info.playing = dict["playing"] as? Bool ?? false
        info.artwork = dict["artworkData"] as? String ?? ""
        info.elapsed = (dict["elapsedTimeNow"] as? Double) ?? (dict["elapsedTime"] as? Double) ?? 0
        info.duration = dict["duration"] as? Double ?? 0
        return info
    }

    static func run(_ args: [String]) {
        guard let path = binary else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - Audio analysis (low / mid / high bands)

final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bands: [Float] = [0, 0, 0]
    private var means: [Float] = [0, 0, 0]
    private var lowState: Float = 0
    private var midState: Float = 0
    private var lastSound: CFAbsoluteTime = 0

    func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        var sumLow: Float = 0
        var sumMid: Float = 0
        var sumHigh: Float = 0
        var n: Float = 0
        var heard = false
        var i = 0
        while i < count {
            let x = samples[i]
            if abs(x) > 0.00001 { heard = true }
            lowState += 0.026 * (x - lowState)   // ~200 Hz
            midState += 0.23 * (x - midState)    // ~2 kHz
            let mid = midState - lowState
            let high = x - midState
            sumLow += lowState * lowState
            sumMid += mid * mid
            sumHigh += high * high
            n += 1
            i += channels
        }
        guard n > 0 else { return }
        let rms: [Float] = [sqrt(sumLow / n), sqrt(sumMid / n), sqrt(sumHigh / n)]
        lock.lock()
        for b in 0..<3 {
            // compare against the average of the last ~2 s, so bars jump on every beat at any volume
            means[b] = means[b] * 0.995 + rms[b] * 0.005
            let ratio: Float = means[b] > 0.00005 ? rms[b] / means[b] : 0
            let target = min(1, max(0, (ratio - 0.5) / 1.6))
            let k: Float = target > bands[b] ? 0.4 : 0.1
            bands[b] += (target - bands[b]) * k
        }
        if heard { lastSound = CFAbsoluteTimeGetCurrent() }
        lock.unlock()
    }

    // nil = no audio (or no permission) – the bars fall back to a gentle idle animation
    func snapshot() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard CFAbsoluteTimeGetCurrent() - lastSound < 1.5 else { return nil }
        return bands
    }
}

let audioMeter = AudioMeter()

func defaultOutputUID() -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
    else { return nil }
    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let value = uid
    else { return nil }
    return value.takeRetainedValue() as String
}

@available(macOS 14.2, *)
final class SystemAudioTap {
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let queue = DispatchQueue(label: "island.audio")

    func setup() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }
        guard let outputUID = defaultOutputUID() else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NowPlayingIsland Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice) == noErr else { return false }
        aggregateID = aggregateDevice
        let meter = audioMeter
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, queue) { _, input, _, _, _ in
            meter.process(input)
        }
        return status == noErr && procID != nil
    }

    func start() {
        guard !running, let procID else { return }
        if AudioDeviceStart(aggregateID, procID) == noErr { running = true }
    }

    func stop() {
        guard running, let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        running = false
    }
}

// MARK: - Accent colour from the artwork

func accentColor(for image: NSImage) -> NSColor {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let raw = ctx.data else { return .white }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    let px = raw.bindMemory(to: UInt8.self, capacity: 16 * 16 * 4)
    var r = 0.0, g = 0.0, b = 0.0, total = 0.0
    for i in 0..<(16 * 16) {
        let red = Double(px[i * 4]) / 255
        let green = Double(px[i * 4 + 1]) / 255
        let blue = Double(px[i * 4 + 2]) / 255
        let mx = max(red, green, blue)
        let mn = min(red, green, blue)
        let sat = mx > 0 ? (mx - mn) / mx : 0
        let weight = 0.02 + sat * sat * mx
        r += red * weight
        g += green * weight
        b += blue * weight
        total += weight
    }
    let avg = NSColor(srgbRed: CGFloat(r / total), green: CGFloat(g / total), blue: CGFloat(b / total), alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    if s < 0.15 { return NSColor(white: 0.92, alpha: 1) }
    return NSColor(hue: h, saturation: min(1, s * 1.3), brightness: max(0.88, v), alpha: 1)
}

// MARK: - Shared views

func pixelRound(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat
    var circular = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.25)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundColor(Color(white: 0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: circular ? size / 2 : size * 0.1,
                                    style: circular ? .circular : .continuous))
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .frame(width: size * 1.7, height: size * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Menu bar island

struct IslandState {
    var title = ""
    var artist = ""
    var playing = false
    var cover: NSImage? = nil
    var accent: Color = .white
    var height: CGFloat = 26
    var onPrevious: () -> Void = {}
    var onToggle: () -> Void = {}
    var onNext: () -> Void = {}
    var onOpen: () -> Void = {}
}

struct BarsView: View {
    let playing: Bool
    let color: Color
    let maxHeight: CGFloat

    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    private let speeds: [Double] = [1.9, 2.6, 1.5, 2.2, 2.9]
    private let phases: [Double] = [0.0, 1.7, 3.1, 0.9, 2.4]

    private func levels(at t: Double) -> [CGFloat] {
        guard playing else { return [0.2, 0.2, 0.2, 0.2, 0.2] }
        if let b = audioMeter.snapshot() {
            let raw: [Float] = [b[0], (b[0] + b[1]) / 2, b[1], (b[1] + b[2]) / 2, b[2]]
            return (0..<5).map { i in
                let wobble = 0.9 + 0.1 * sin(t * 2.0 + phases[i])
                return CGFloat(0.15 + 0.8 * Double(raw[i]) * wobble)
            }
        }
        return (0..<5).map { i in
            let wave = 0.5 + 0.5 * sin(t * speeds[i] + phases[i])
            return CGFloat(0.3 + 0.45 * wave)
        }
    }

    private func content(at date: Date) -> some View {
        let values = levels(at: date.timeIntervalSinceReferenceDate)
        return HStack(spacing: BarsView.spacing) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(playing ? color : Color(white: 0.55))
                    .frame(width: BarsView.barWidth,
                           height: max(2, pixelRound(maxHeight * values[i])))
            }
        }
        .frame(width: BarsView.barWidth * 5 + BarsView.spacing * 4, height: maxHeight)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { timeline in
            content(at: timeline.date)
        }
    }
}

struct IslandView: View {
    let state: IslandState

    var body: some View {
        let h = state.height
        let pad = Config.innerPadding
        let hasTrack = !state.title.isEmpty
        let coverSize = h - pad * 2
        let fontSize = h * 0.40
        let iconSize = h * 0.32
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                CoverView(image: state.cover, size: coverSize, circular: true)
                if hasTrack {
                    textBlock(fontSize: fontSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.onOpen() }
            if hasTrack {
                if Config.showControls {
                    HStack(spacing: 0) {
                        ControlButton(symbol: "backward.fill", size: iconSize, action: state.onPrevious)
                        ControlButton(symbol: state.playing ? "pause.fill" : "play.fill",
                                      size: iconSize, action: state.onToggle)
                        ControlButton(symbol: "forward.fill", size: iconSize, action: state.onNext)
                    }
                }
                if Config.showBars {
                    BarsView(playing: state.playing, color: state.accent, maxHeight: pixelRound(h * 0.38))
                }
            }
        }
        .padding(.leading, pad)
        .padding(.trailing, hasTrack ? pad + 7 : pad)
        .frame(width: hasTrack ? Config.islandWidth : h, height: h)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(Config.glassTint)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
    }

    private func textBlock(fontSize: CGFloat) -> some View {
        let font = Font.system(size: fontSize, weight: .regular)
        let line: Text
        if Config.showArtist && !state.artist.isEmpty {
            let titleText = Text(state.title).foregroundColor(.white)
            let dash = Text(" – ").foregroundColor(Color(white: 0.5))
            let artistText = Text(state.artist).foregroundColor(Color(white: 0.72))
            line = Text("\(titleText)\(dash)\(artistText)")
        } else {
            line = Text(state.title).foregroundColor(.white)
        }
        return line
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// Hosting view that accepts the first click immediately
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel shown on click (styled after macOS "Now Playing")

@MainActor
final class PlayerModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var cover: NSImage?
    @Published var playing = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var updatedAt = Date()
    @Published var scrub: Double? = nil
    var onPrevious: () -> Void = {}
    var onToggle: () -> Void = {}
    var onNext: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onOpenPlayer: () -> Void = {}
    var onQuit: () -> Void = {}
}

struct ProgressSection: View {
    @ObservedObject var model: PlayerModel

    private func currentTime(at date: Date) -> Double {
        guard model.playing else { return model.elapsed }
        return model.elapsed + date.timeIntervalSince(model.updatedAt)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let t = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func bar(fraction: Double, duration: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(height: 5)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * CGFloat(fraction)), height: 5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.scrub = Double(min(1, max(0, value.location.x / geo.size.width)))
                    }
                    .onEnded { value in
                        let f = Double(min(1, max(0, value.location.x / geo.size.width)))
                        if duration > 0 { model.onSeek(f * duration) }
                        model.scrub = nil
                    }
            )
        }
        .frame(height: 12)
    }

    private func content(at date: Date) -> some View {
        let duration = model.duration
        let live: Double = duration > 0 ? min(1, max(0, currentTime(at: date) / duration)) : 0
        let fraction: Double = model.scrub ?? live
        return VStack(spacing: 5) {
            bar(fraction: fraction, duration: duration)
            HStack {
                Text(format(fraction * duration))
                Spacer()
                Text("−" + format(max(0, duration - fraction * duration)))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !model.playing || model.scrub != nil)) { timeline in
            content(at: timeline.date)
        }
    }
}

struct PlayerPanel: View {
    @ObservedObject var model: PlayerModel

    private var subtitle: String {
        // singles often report the track title as the album name – skip it then
        let album = model.album == model.title ? "" : model.album
        return [model.artist, album].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(image: model.cover, size: 112)
                .shadow(color: Color.black.opacity(0.25), radius: 6, y: 2)
                .contentShape(Rectangle())
                .onTapGesture { model.onOpenPlayer() }
                .help(L.open(Config.playerAppName))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title.isEmpty ? L.nothingPlaying : model.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.onOpenPlayer() }
                    .help(L.open(Config.playerAppName))
                    Spacer(minLength: 0)
                    Menu {
                        Button(L.open(Config.playerAppName)) { model.onOpenPlayer() }
                        Divider()
                        Button(L.quit) { model.onQuit() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer(minLength: 4)
                HStack(spacing: 30) {
                    ControlButton(symbol: "backward.fill", size: 19, color: .primary, action: model.onPrevious)
                    ControlButton(symbol: model.playing ? "pause.fill" : "play.fill",
                                  size: 24, color: .primary, action: model.onToggle)
                    ControlButton(symbol: "forward.fill", size: 19, color: .primary, action: model.onNext)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 4)
                ProgressSection(model: model)
            }
            .frame(height: 112)
        }
        .padding(16)
        .frame(width: 400, height: 144)
    }
}

// MARK: - Controller

@MainActor
final class Controller: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hosting: IslandHostingView<IslandView>?
    private var glass: NSVisualEffectView?
    private let popover = NSPopover()
    private let player = PlayerModel()
    private var current = NowPlaying()
    private var cover: NSImage?
    private var accent: Color = .white
    private var tap: AnyObject?
    private var holdUntil = Date.distantPast
    private var lastSeen = Date.distantPast

    override init() {
        super.init()
        statusItem.autosaveName = "NowPlayingIsland"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = NSAppearance(named: .darkAqua)   // always dark glass, regardless of what is behind it
            effect.autoresizingMask = [.minYMargin, .maxYMargin]
            button.addSubview(effect)
            glass = effect
            let view = IslandHostingView(rootView: IslandView(state: IslandState()))
            view.autoresizingMask = [.minYMargin, .maxYMargin]
            button.addSubview(view)
            hosting = view
        }

        player.onPrevious = { [weak self] in self?.previousTrack() }
        player.onToggle = { [weak self] in self?.togglePlay() }
        player.onNext = { [weak self] in self?.nextTrack() }
        player.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        player.onOpenPlayer = { [weak self] in
            self?.popover.performClose(nil)
            self?.openPlayer()
        }
        player.onQuit = { NSApp.terminate(nil) }
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 144)
        popover.contentViewController = NSHostingController(rootView: PlayerPanel(model: player))

        if Config.showBars && Config.reactToMusic {
            if #available(macOS 14.2, *) {
                let audioTap = SystemAudioTap()
                if audioTap.setup() { tap = audioTap }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        render()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.render()
        }
        startPolling()
    }

    private func startPolling() {
        Task.detached { [self] in
            while true {
                let info = MediaCLI.fetch()
                await self.apply(info)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollSoon() {
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            let info = MediaCLI.fetch()
            await self.apply(info)
        }
    }

    private func setTapRunning(_ on: Bool) {
        if #available(macOS 14.2, *) {
            guard let audioTap = tap as? SystemAudioTap else { return }
            if on { audioTap.start() } else { audioTap.stop() }
        }
    }

    private func apply(_ info: NowPlaying) {
        guard Date() >= holdUntil else { return }
        // Players briefly report "nothing playing" between tracks. Keep the previous
        // track for up to 4 s so the island does not collapse and the panel does not jump.
        if info.title.isEmpty {
            if !current.title.isEmpty && Date().timeIntervalSince(lastSeen) < 4 { return }
        } else {
            lastSeen = Date()
        }
        player.elapsed = info.elapsed
        player.duration = info.duration
        player.updatedAt = Date()
        guard !info.sameDisplay(as: current) else {
            current = info
            return
        }
        let artChanged = info.title != current.title || info.artwork.count != current.artwork.count
        current = info
        setTapRunning(info.playing)
        if artChanged {
            if !info.artwork.isEmpty,
               let data = Data(base64Encoded: info.artwork, options: .ignoreUnknownCharacters),
               let image = NSImage(data: data) {
                cover = image
                accent = Color(nsColor: accentColor(for: image))
            } else {
                cover = nil
                accent = .white
            }
        }
        player.title = info.title
        player.artist = info.artist
        player.album = info.album
        player.cover = cover
        player.playing = info.playing
        render()
    }

    private func menuBarHeight() -> CGFloat {
        var h = NSStatusBar.system.thickness
        if let b = statusItem.button?.bounds.height, b > h { h = b }
        if let w = statusItem.button?.window?.frame.height, w > h { h = w }
        return h
    }

    @objc private func screenChanged() { render() }

    private func capsuleMask(_ size: NSSize) -> NSImage {
        let radius = size.height / 2
        return NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    private func render() {
        guard let hosting, let button = statusItem.button else { return }
        let bar = menuBarHeight()
        let islandHeight = Config.islandHeight > 0
            ? Config.islandHeight
            : min(30, max(18, bar - Config.verticalInset * 2))
        var state = IslandState(title: current.title, artist: current.artist,
                                playing: current.playing, cover: cover, accent: accent,
                                height: islandHeight)
        state.onPrevious = { [weak self] in self?.previousTrack() }
        state.onToggle = { [weak self] in self?.togglePlay() }
        state.onNext = { [weak self] in self?.nextTrack() }
        state.onOpen = { [weak self] in
            Task { @MainActor [weak self] in self?.togglePanel() }
        }
        hosting.rootView = IslandView(state: state)
        let width = ceil(hosting.fittingSize.width)
        statusItem.length = width + Config.margin * 2
        let container = button.bounds.height > 0 ? button.bounds.height : bar
        let frame = NSRect(x: Config.margin,
                           y: floor((container - islandHeight) / 2),
                           width: width,
                           height: islandHeight)
        hosting.frame = frame
        if let glass {
            glass.frame = frame
            if glass.maskImage?.size != frame.size {
                glass.maskImage = capsuleMask(frame.size)
            }
        }
        let tip: String
        if current.title.isEmpty {
            tip = L.nothingPlaying
        } else if current.artist.isEmpty {
            tip = current.title
        } else {
            tip = "\(current.title) – \(current.artist)"
        }
        button.toolTip = tip
        hosting.toolTip = tip
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func previousTrack() {
        MediaCLI.run(["previous-track"])
        pollSoon()
    }

    private func togglePlay() {
        MediaCLI.run(["toggle-play-pause"])
        current.playing.toggle()
        player.playing = current.playing
        player.updatedAt = Date()
        setTapRunning(current.playing)
        holdUntil = Date().addingTimeInterval(0.8)
        render()
        pollSoon()
    }

    private func nextTrack() {
        MediaCLI.run(["next-track"])
        pollSoon()
    }

    private func seek(to seconds: Double) {
        MediaCLI.run(["seek", String(format: "%.1f", seconds)])
        player.elapsed = seconds
        player.updatedAt = Date()
        holdUntil = Date().addingTimeInterval(0.8)
        pollSoon()
    }

    private func openPlayer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", Config.playerAppName]
        try? process.run()
    }
}

// MARK: - App entry point

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = Controller()
    }
}

@main
struct NowPlayingIslandMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
