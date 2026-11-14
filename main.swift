import SwiftUI
import AppKit
import AVFoundation
import IOKit.hid
import Carbon.HIToolbox
import os

// MARK: - Deckelwinkel-Sensor

final class LidSensor {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                     kIOHIDPrimaryUsagePageKey: 0x0020, kIOHIDPrimaryUsageKey: 0x008A] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, match)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            device = devices.first { IOHIDDeviceOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess }
        }
    }

    var available: Bool { device != nil }

    func angle() -> Double? {
        guard let device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(buf.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess, len >= 3 else { return nil }
        return Double(UInt16(buf[1]) | UInt16(buf[2]) << 8)
    }
}

// MARK: - Klang

struct Reed { var ratio: Double; var level: Double }

enum Register: String, CaseIterable, Identifiable {
    case musette = "Musette", klarinette = "Klarinette", bandoneon = "Bandoneon", master = "Master"
    var id: String { rawValue }
    var reeds: [Reed] {
        func cents(_ c: Double) -> Double { pow(2, c / 1200) }
        switch self {
        case .musette:    return [Reed(ratio: 1, level: 1), Reed(ratio: cents(14), level: 0.85), Reed(ratio: cents(-14), level: 0.85)]
        case .klarinette: return [Reed(ratio: 1, level: 1.4)]
        case .bandoneon:  return [Reed(ratio: 1, level: 1), Reed(ratio: 0.5, level: 0.9)]
        case .master:     return [Reed(ratio: 0.5, level: 0.6), Reed(ratio: 1, level: 1), Reed(ratio: cents(12), level: 0.75), Reed(ratio: 2, level: 0.45)]
        }
    }
}

final class Synth {
    static let maxVoices = 32, maxReeds = 4, maxFrames = 4096

    private struct Voice { var tag = -1; var freq = 0.0; var gain = 0.0; var target = 0.0; var active = false }

    private var voices = [Voice](repeating: Voice(), count: maxVoices)
    private var phases = [Double](repeating: 0, count: maxVoices * maxReeds)
    private var reeds = Register.musette.reeds
    private var pressureTarget = 0.0
    private var pressure = 0.0
    private var lp1 = 0.0, lp2 = 0.0, dcX = 0.0, dcY = 0.0
    private let mix = UnsafeMutablePointer<Double>.allocate(capacity: maxFrames)
    private let vbuf = UnsafeMutablePointer<Double>.allocate(capacity: maxFrames)
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let engine = AVAudioEngine()
    private var sr = 48000.0
    private var noteAtk = 0.0, noteRel = 0.0, pAtk = 0.0, pRel = 0.0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sr = hw > 0 ? hw : 48000
        noteAtk = 1 - exp(-1 / (0.004 * sr))
        noteRel = 1 - exp(-1 / (0.030 * sr))
        pAtk = 1 - exp(-1 / (0.035 * sr))
        pRel = 1 - exp(-1 / (0.090 * sr))

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            var offset = 0
            while offset < n {
                let chunk = min(Synth.maxFrames, n - offset)
                os_unfair_lock_lock(self.lock)
                self.render(chunk)
                os_unfair_lock_unlock(self.lock)
                for b in buffers {
                    let p = b.mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<chunk { p[offset + i] = Float(self.mix[i]) }
                }
                offset += chunk
            }
            return noErr
        }
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 16
        engine.attach(src)
        engine.attach(reverb)
        engine.connect(src, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }

    private func withLock(_ body: () -> Void) {
        os_unfair_lock_lock(lock); body(); os_unfair_lock_unlock(lock)
    }

    func noteOn(tag: Int, notes: [(midi: Int, level: Double)]) {
        withLock {
            for note in notes {
                var idx = voices.firstIndex { !$0.active }
                if idx == nil {
                    idx = voices.indices.min { voices[$0].gain < voices[$1].gain }
                }
                guard let i = idx else { continue }
                voices[i].tag = tag
                voices[i].freq = 440 * pow(2, Double(note.midi - 69) / 12)
                voices[i].target = note.level
                if !voices[i].active { voices[i].gain = 0 }
                voices[i].active = true
                for r in 0..<Synth.maxReeds { phases[i * Synth.maxReeds + r] = Double.random(in: 0..<1) }
            }
        }
    }

    func noteOff(tag: Int) {
        withLock { for i in voices.indices where voices[i].tag == tag { voices[i].target = 0 } }
    }

    func allOff() {
        withLock { for i in voices.indices { voices[i].target = 0 } }
    }

    func setPressure(_ p: Double) { withLock { pressureTarget = p } }
    func setRegister(_ r: Register) { withLock { reeds = r.reeds } }

    @inline(__always) private static func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    // Durchschlagzunge: Mischung aus bandbegrenztem Sägezahn und schmalem Puls
    @inline(__always) private static func reed(_ t: Double, _ dt: Double) -> Double {
        let saw = 2 * t - 1 - blep(t, dt)
        let duty = 0.22
        var pulse = t < duty ? 1.0 : -1.0
        pulse += blep(t, dt)
        var t2 = t + 1 - duty
        if t2 >= 1 { t2 -= 1 }
        pulse -= blep(t2, dt)
        return 0.5 * saw + 0.5 * pulse
    }

    private func render(_ n: Int) {
        for i in 0..<n { mix[i] = 0 }
        let nr = reeds.count
        for vi in 0..<Synth.maxVoices where voices[vi].active {
            for i in 0..<n { vbuf[i] = 0 }
            for r in 0..<nr {
                let dt = voices[vi].freq * reeds[r].ratio / sr
                let lvl = reeds[r].level
                var ph = phases[vi * Synth.maxReeds + r]
                for i in 0..<n {
                    vbuf[i] += lvl * Synth.reed(ph, dt)
                    ph += dt
                    if ph >= 1 { ph -= 1 }
                }
                phases[vi * Synth.maxReeds + r] = ph
            }
            var g = voices[vi].gain
            let t = voices[vi].target
            let k = t > g ? noteAtk : noteRel
            for i in 0..<n { g += (t - g) * k; mix[i] += vbuf[i] * g }
            voices[vi].gain = g
            if t == 0 && g < 1e-4 { voices[vi].active = false; voices[vi].tag = -1 }
        }
        for i in 0..<n {
            pressure += (pressureTarget - pressure) * (pressureTarget > pressure ? pAtk : pRel)
            let x = mix[i]
            let y = x - dcX + 0.995 * dcY
            dcX = x; dcY = y
            // Mehr Balgdruck = hellerer Klang
            let a = 1 - exp(-2 * .pi * (450 + 6500 * pressure) / sr)
            lp1 += (y - lp1) * a
            lp2 += (lp1 - lp2) * a
            mix[i] = tanh(lp2 * pressure * 0.3)
        }
    }
}

// MARK: - Tastenbelegung

let noteNames = ["C", "Cis", "D", "Dis", "E", "F", "Fis", "G", "Gis", "A", "B", "H"]
func noteName(_ midi: Int) -> String { noteNames[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)" }

struct PianoKey { let code: UInt16; let semitone: Int; let black: Bool; let center: Double }

let pianoKeys: [PianoKey] = {
    let whites: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 42]
    let whiteSemis = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19]
    var keys = zip(whites, whiteSemis).enumerated().map { PianoKey(code: $1.0, semitone: $1.1, black: false, center: Double($0) + 0.5) }
    let blacks: [(UInt16, Int, Double)] = [(13, 1, 1), (14, 3, 2), (17, 6, 4), (16, 8, 5), (32, 10, 6), (31, 13, 8), (35, 15, 9), (30, 18, 11)]
    keys += blacks.map { PianoKey(code: $0.0, semitone: $0.1, black: true, center: $0.2) }
    return keys
}()

// Wechseltönige Knopfreihe (C-Reihe einer Steirischen): Druck und Zug klingen verschieden
let diatonicCodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41]
let diatonicPush = [52, 55, 60, 64, 67, 72, 76, 79, 84, 88]
let diatonicPull = [55, 59, 62, 65, 69, 71, 74, 77, 81, 83]

struct ChordKey { let code: UInt16; let root: Int; let minor: Bool
    var name: String { noteNames[root] + (minor ? "m" : "") }
}

let chordKeys: [ChordKey] = [
    ChordKey(code: 18, root: 0, minor: false), ChordKey(code: 19, root: 7, minor: false),
    ChordKey(code: 20, root: 5, minor: false), ChordKey(code: 21, root: 9, minor: true),
    ChordKey(code: 23, root: 2, minor: true), ChordKey(code: 22, root: 4, minor: true),
    ChordKey(code: 26, root: 2, minor: false), ChordKey(code: 28, root: 4, minor: false),
    ChordKey(code: 25, root: 9, minor: false), ChordKey(code: 29, root: 10, minor: false),
]

func keyLabel(_ code: UInt16) -> String {
    guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var len = 0
    data.withUnsafeBytes { raw in
        let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
    }
    return String(utf16CodeUnits: chars, count: len).uppercased()
}

// MARK: - Akkordeon

enum Mode: String, CaseIterable, Identifiable {
    case chromatisch = "Chromatisch", wechsel = "Wechseltönig"
    var id: String { rawValue }
}

enum Bellows { case push, pull }

final class Accordion: ObservableObject {
    @Published var angle = 0.0
    @Published var speed = 0.0
    @Published var pressure = 0.0
    @Published var direction = Bellows.push
    @Published var held = Set<UInt16>()
    @Published var octave = 0
    @Published var register = Register.musette { didSet { synth.setRegister(register) } }
    @Published var mode = Mode.chromatisch { didSet { synth.allOff(); held.removeAll() } }

    let sensor = LidSensor()
    let labels: [UInt16: String]
    private let synth = Synth()
    private var history: [(t: Double, a: Double)] = []
    private var smoothedVelocity = 0.0
    private var virtualOffset = 0.0
    private var timer: Timer?
    private var monitor: Any?
    private var tick = 0

    init() {
        var l = [UInt16: String]()
        for c in pianoKeys.map(\.code) + chordKeys.map(\.code) { l[c] = keyLabel(c) }
        labels = l
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel]) { [weak self] e in
            guard let self else { return e }
            switch e.type {
            case .keyDown:
                if e.modifierFlags.contains(.command) { return e }
                return self.keyDown(e.keyCode, repeat: e.isARepeat) ? nil : e
            case .keyUp:
                return self.keyUp(e.keyCode) ? nil : e
            case .scrollWheel:
                self.virtualOffset += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.35 : 3)
                return e
            default:
                return e
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.synth.allOff()
            self?.held.removeAll()
        }
    }

    private func isMapped(_ code: UInt16) -> Bool {
        notes(for: code) != nil
    }

    func notes(for code: UInt16) -> [(midi: Int, level: Double)]? {
        if let c = chordKeys.first(where: { $0.code == code }) {
            let n = 48 + c.root
            return [(36 + c.root, 0.9), (n, 0.38), (n + (c.minor ? 3 : 4), 0.38), (n + 7, 0.38)]
        }
        switch mode {
        case .chromatisch:
            guard let k = pianoKeys.first(where: { $0.code == code }) else { return nil }
            return [(60 + octave * 12 + k.semitone, 1)]
        case .wechsel:
            guard let i = diatonicCodes.firstIndex(of: code) else { return nil }
            return [((direction == .push ? diatonicPush : diatonicPull)[i] + octave * 12, 1)]
        }
    }

    private func keyDown(_ code: UInt16, repeat isRepeat: Bool) -> Bool {
        if code == UInt16(kVK_LeftArrow) { if !isRepeat { octave = max(-2, octave - 1) }; return true }
        if code == UInt16(kVK_RightArrow) { if !isRepeat { octave = min(2, octave + 1) }; return true }
        guard let n = notes(for: code) else { return false }
        if isRepeat || held.contains(code) { return true }
        held.insert(code)
        synth.noteOn(tag: Int(code), notes: n)
        return true
    }

    private func keyUp(_ code: UInt16) -> Bool {
        guard held.contains(code) else { return isMapped(code) }
        held.remove(code)
        synth.noteOff(tag: Int(code))
        return true
    }

    private func update() {
        let now = CACurrentMediaTime()
        let sensorAngle = sensor.angle()
        let a = (sensorAngle ?? 100) + virtualOffset
        history.append((now, a))
        while history.count > 2 && now - history[0].t > 0.18 { history.removeFirst() }
        let span = now - history[0].t
        let v = span > 0.04 ? (a - history[0].a) / span : 0
        smoothedVelocity += (v - smoothedVelocity) * 0.35

        let s = abs(smoothedVelocity)
        let p = s < 2 ? 0 : min(1, pow((s - 2) / 70, 0.75))
        synth.setPressure(p)

        if s > 4 {
            let d: Bellows = smoothedVelocity > 0 ? .pull : .push
            if d != direction {
                direction = d
                if mode == .wechsel { retriggerTreble() }
            }
        }

        tick += 1
        if tick % 3 == 0 {
            angle = sensorAngle ?? min(max(100 + virtualOffset, 0), 160)
            speed = s
            pressure = p
        }
    }

    private func retriggerTreble() {
        for code in held where diatonicCodes.contains(code) {
            synth.noteOff(tag: Int(code))
            if let n = notes(for: code) { synth.noteOn(tag: Int(code), notes: n) }
        }
    }
}

// MARK: - Oberfläche

extension Color {
    static let bg = Color(red: 0.09, green: 0.075, blue: 0.065)
    static let panel = Color(red: 0.15, green: 0.125, blue: 0.11)
    static let bellowsRed = Color(red: 0.74, green: 0.13, blue: 0.17)
    static let bellowsDark = Color(red: 0.42, green: 0.06, blue: 0.09)
    static let ivory = Color(red: 0.96, green: 0.93, blue: 0.86)
    static let brass = Color(red: 0.86, green: 0.70, blue: 0.38)
    static let dim = Color(white: 0.62)
}

struct BellowsView: View {
    let angle: Double
    let pressure: Double
    let direction: Bellows

    var body: some View {
        Canvas { ctx, size in
            let open = CGFloat(min(max(angle / 135, 0), 1))
            let plate: CGFloat = 30
            let minW: CGFloat = 140
            let maxW = size.width - 2 * plate - 24
            let w = minW + (maxW - minW) * open
            let h = size.height - 20
            let x0 = (size.width - w) / 2
            let y0: CGFloat = 10
            let n = 20
            let pw = w / CGFloat(n)
            for i in 0..<n {
                let x = x0 + CGFloat(i) * pw
                let r = CGRect(x: x, y: y0 + 8, width: pw, height: h - 16)
                let colors: [Color] = i % 2 == 0 ? [.bellowsRed, .bellowsDark] : [.bellowsDark, .bellowsRed]
                ctx.fill(Path(r), with: .linearGradient(Gradient(colors: colors),
                                                         startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
                if i > 0 {
                    var fold = Path()
                    fold.move(to: CGPoint(x: x, y: r.minY))
                    fold.addLine(to: CGPoint(x: x, y: r.maxY))
                    ctx.stroke(fold, with: .color(.white.opacity(i % 2 == 0 ? 0.28 : 0.08)), lineWidth: 1)
                    let cap = CGSize(width: 7, height: 7)
                    ctx.fill(Path(CGRect(origin: CGPoint(x: x - 3.5, y: r.minY - 2), size: cap)), with: .color(.brass))
                    ctx.fill(Path(CGRect(origin: CGPoint(x: x - 3.5, y: r.maxY - 5), size: cap)), with: .color(.brass))
                }
            }
            for px in [x0 - plate, x0 + w] {
                let r = CGRect(x: px, y: y0, width: plate, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(Color(white: 0.08)))
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 3, dy: 3), cornerRadius: 4), with: .color(.brass.opacity(0.7)), lineWidth: 1.5)
            }
        }
        .shadow(color: .bellowsRed.opacity(pressure * 0.9), radius: 6 + 22 * pressure)
        .overlay(alignment: .top) {
            Text(direction == .pull ? "←  ZUG  →" : "→  DRUCK  ←")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(Color.ivory)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .opacity(pressure > 0.04 ? 1 : 0)
                .offset(y: -6)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dim).textCase(.uppercase)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Color.ivory)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panel))
    }
}

struct PressureMeter: View {
    let pressure: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Luftdruck").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dim).textCase(.uppercase)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5))
                    Capsule().fill(LinearGradient(colors: [.brass, .bellowsRed], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, g.size.width * pressure))
                }
            }
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panel))
    }
}

struct PianoView: View {
    @ObservedObject var acc: Accordion
    let whiteW: CGFloat = 56

    var body: some View {
        let whites = pianoKeys.filter { !$0.black }
        let blacks = pianoKeys.filter { $0.black }
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(whites, id: \.code) { k in
                    let on = acc.held.contains(k.code)
                    VStack(spacing: 3) {
                        Spacer()
                        Text(noteName(60 + acc.octave * 12 + k.semitone)).font(.system(size: 10, weight: .medium)).foregroundStyle(.black.opacity(0.45))
                        Text(acc.labels[k.code] ?? "").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.8))
                    }
                    .padding(.bottom, 10)
                    .frame(width: whiteW - 3, height: 130)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.brass : Color.ivory))
                    .frame(width: whiteW)
                }
            }
            ForEach(blacks, id: \.code) { k in
                let on = acc.held.contains(k.code)
                VStack(spacing: 2) {
                    Spacer()
                    Text(acc.labels[k.code] ?? "").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.ivory)
                }
                .padding(.bottom, 8)
                .frame(width: 36, height: 80)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.bellowsRed : Color(white: 0.1)))
                .offset(x: CGFloat(k.center) * whiteW - 18)
            }
        }
        .frame(width: whiteW * 12, height: 130, alignment: .topLeading)
    }
}

struct ButtonRowView: View {
    @ObservedObject var acc: Accordion
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(diatonicCodes.enumerated()), id: \.element) { i, code in
                let on = acc.held.contains(code)
                let pushNote = noteName(diatonicPush[i] + acc.octave * 12)
                let pullNote = noteName(diatonicPull[i] + acc.octave * 12)
                VStack(spacing: 6) {
                    Text(acc.labels[code] ?? "").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.8))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(on ? Color.brass : Color.ivory))
                    Text(pullNote).font(.system(size: 11, weight: acc.direction == .pull ? .bold : .regular))
                        .foregroundStyle(acc.direction == .pull ? Color.ivory : Color.dim.opacity(0.6))
                    Text(pushNote).font(.system(size: 11, weight: acc.direction == .push ? .bold : .regular))
                        .foregroundStyle(acc.direction == .push ? Color.ivory : Color.dim.opacity(0.6))
                }
            }
        }
        .frame(height: 130)
    }
}

struct ChordRowView: View {
    @ObservedObject var acc: Accordion
    var body: some View {
        HStack(spacing: 8) {
            ForEach(chordKeys, id: \.code) { c in
                let on = acc.held.contains(c.code)
                VStack(spacing: 2) {
                    Text(c.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(acc.labels[c.code] ?? "").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
                .foregroundStyle(on ? Color.black : Color.ivory)
                .frame(width: 58, height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.brass : Color.panel))
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var acc: Accordion

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Klappkordeon").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Color.ivory)
                Spacer()
                Text(acc.sensor.available ? "Deckelsensor aktiv" : "Kein Deckelsensor – Zwei-Finger-Scrollen ist der Balg")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(acc.sensor.available ? Color.brass : Color.bellowsRed)
            }

            BellowsView(angle: acc.angle, pressure: acc.pressure, direction: acc.direction)
                .frame(height: 150)

            HStack(spacing: 12) {
                Stat(title: "Deckelwinkel", value: "\(Int(acc.angle.rounded()))°")
                Stat(title: "Balg-Tempo", value: "\(Int(acc.speed.rounded()))°/s")
                PressureMeter(pressure: acc.pressure)
            }

            HStack(spacing: 16) {
                Picker("Register", selection: $acc.register) {
                    ForEach(Register.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Spielart", selection: $acc.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .labelsHidden()

            VStack(spacing: 6) {
                HStack {
                    Text("Diskant").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dim).textCase(.uppercase)
                    Spacer()
                    Text("Oktave \(acc.octave >= 0 ? "+" : "")\(acc.octave)   ← →").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dim)
                }
                if acc.mode == .chromatisch { PianoView(acc: acc) } else { ButtonRowView(acc: acc) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Bass + Akkord").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dim).textCase(.uppercase)
                ChordRowView(acc: acc)
            }

            Text(acc.mode == .chromatisch
                 ? "Tasten halten und den Deckel bewegen. Ohne Bewegung keine Luft, also kein Ton. Je schneller, desto lauter."
                 : "Wechseltönig: Deckel öffnen (Zug) und schließen (Druck) spielen auf derselben Taste verschiedene Töne.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dim)
        }
        .padding(24)
        .frame(width: 720)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .onAppear { acc.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KlappkordeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var acc = Accordion()

    var body: some Scene {
        WindowGroup("Klappkordeon") {
            ContentView(acc: acc)
        }
        .windowResizability(.contentSize)
    }
}
