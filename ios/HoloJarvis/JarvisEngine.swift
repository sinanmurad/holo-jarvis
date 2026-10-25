import Foundation
import UIKit
import ARKit
import RealityKit
import AudioToolbox

/// A flat holographic screen floating in the room.
final class Panel {
    let name: String
    let entity: ModelEntity
    let pixels: CGSize
    let width: Float
    var userScale: Float = 1
    var onTap: ((CGPoint) -> Void)?          // pixel position inside the texture

    init(name: String, pixels: CGSize, width: Float) {
        self.name = name
        self.pixels = pixels
        self.width = width
        let h = width * Float(pixels.height / pixels.width)
        entity = ModelEntity(mesh: .generatePlane(width: width, height: h), materials: [UnlitMaterial(color: .black)])
        entity.name = name
        entity.generateCollisionShapes(recursive: false)
    }

    var height: Float { width * Float(pixels.height / pixels.width) }

    func show(_ image: UIImage) {
        guard let cg = image.cgImage,
              let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) else { return }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        entity.model?.materials = [m]
    }
}

struct Cursor: Identifiable {
    let id: Int
    var point: CGPoint
    var thumb: CGPoint
    var index: CGPoint
    var pinch: Bool
    var grab: Bool
}

final class JarvisEngine: NSObject, ObservableObject, ARSessionDelegate {

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published var cursors: [Cursor] = []
    @Published var status = "Telefonu önüne doğru tut, oda taranıyor…"
    @Published var listening = false
    @Published var wake = UserDefaults.standard.object(forKey: "wake") as? Bool ?? true
    @Published var handInfo = "✋ el bekleniyor"

    // profile
    var name = UserDefaults.standard.string(forKey: "name") ?? ""
    var city = UserDefaults.standard.string(forKey: "city") ?? "İstanbul"
    private var lat = UserDefaults.standard.object(forKey: "lat") as? Double ?? 41.01
    private var lon = UserDefaults.standard.object(forKey: "lon") as? Double ?? 28.97

    // panels
    private var anchor: AnchorEntity?
    private var panels: [Panel] = []
    private var research: [Panel] = []
    private var pTitle: Panel!
    private var pDialog: Panel!
    private var pProj: Panel!
    private var pNotes: Panel!

    // conversation
    private let voice = Voice()
    private var you = ""
    private var answer = "Tüm sistemler çevrimiçi. Bugün ne inşa ediyoruz, efendim?"
    private var mode = "idle"
    private var history: [[String: String]] = []
    private var noteNext = false
    private var weatherText: String?
    private var weatherShort: String?

    // data
    private var notes: [(text: String, done: Bool)] = []
    private var focus: [(name: String, desc: String)] = []

    // hands
    private var placed = false
    private var frameCount = 0
    private var visionBusy = false
    private let visionQueue = DispatchQueue(label: "holojarvis.hands", qos: .userInitiated)
    private var hands: [HandState] = []
    private var scaleOp: (panel: Panel, d0: CGFloat, s0: Float)?
    private var handFrames = 0
    private var handT0 = Date()
    private var handFps = 0

    private var clockTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let tr = Locale(identifier: "tr-TR")

    // MARK: - Start

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        loadData()
        guard ARWorldTrackingConfiguration.isSupported else { status = "Bu cihaz AR desteklemiyor."; return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)   // your real hand appears in front of the panels
        }
        arView.session.delegate = self
        arView.session.run(config)
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        buildPanels()

        voice.onCommand = { [weak self] text in self?.command(text) }
        voice.onPartial = { [weak self] text in
            guard let self = self else { return }
            self.you = text
            self.drawDialog()
        }
        voice.onStateChange = { [weak self] on in
            guard let self = self else { return }
            self.listening = on
            if on { self.mode = "listening" } else if self.mode == "listening" { self.mode = "idle" }
            self.drawDialog()
        }
        voice.onError = { [weak self] msg in
            guard let self = self else { return }
            self.answer = msg
            self.drawDialog()
        }
        voice.requestPermissions { [weak self] ok in
            guard let self = self else { return }
            if ok { self.voice.setWakeMode(self.wake) }
            else { self.answer = "Sesli komut için mikrofon ve konuşma tanıma iznine ihtiyacım var. Ayarlar → Jarvis."; self.drawDialog() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.drawTitle() }
        Task { await self.loadWeather() }
    }

    func applySettings(name: String, city: String, groqKey: String, wake: Bool) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.name, forKey: "name")
        UserDefaults.standard.set(groqKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "groqKey")
        setWake(wake)
        let c = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty && c != self.city { Task { await self.setCity(c, announce: false) } }
        drawTitle()
    }

    func setWake(_ on: Bool) {
        wake = on
        UserDefaults.standard.set(on, forKey: "wake")
        voice.setWakeMode(on)
        drawDialog()
    }

    func listenOnce() {
        voice.listenOnce()
    }

    // MARK: - Panels

    private func buildPanels() {
        pTitle = Panel(name: "title", pixels: CGSize(width: 1400, height: 300), width: 1.05)
        pDialog = Panel(name: "dialog", pixels: CGSize(width: 1024, height: 640), width: 0.95)
        pProj = Panel(name: "proj", pixels: CGSize(width: 800, height: 760), width: 0.55)
        pNotes = Panel(name: "notes", pixels: CGSize(width: 800, height: 760), width: 0.55)
        panels = [pTitle!, pDialog!, pProj!, pNotes!]

        pDialog.onTap = { [weak self] _ in self?.listenOnce() }
        pTitle.onTap = { [weak self] _ in
            guard let self = self else { return }
            self.say(self.weatherText.map { "Şu an \($0)." } ?? "Hava durumu henüz gelmedi efendim.")
        }
        pProj.onTap = { [weak self] px in
            guard let self = self else { return }
            let row = Int((px.y - 106) / 106)
            guard row >= 0, row < self.focus.count else { return }
            let f = self.focus[row]
            self.command("\(f.name) projem için bugün atabileceğim tek somut adım ne?" + (f.desc.isEmpty ? "" : " Proje: \(f.desc)."), direct: true)
        }
        pNotes.onTap = { [weak self] px in
            guard let self = self else { return }
            if px.y < 96 && px.x > 400 {
                self.noteNext = true
                self.answer = "Notunuzu söyleyin efendim."
                self.drawDialog()
                self.listenOnce()
                return
            }
            let row = Int((px.y - 106) / 106)
            guard row >= 0, row < self.notes.count else { return }
            if self.notes[row].done { self.notes.remove(at: row) } else { self.notes[row].done = true }
            self.saveData()
            self.drawNotes()
        }
        drawTitle(); drawDialog(); drawProjects(); drawNotes()
    }

    private func drawTitle() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm"
        let clock = f.string(from: Date())
        f.dateFormat = "EEEE · d MMMM yyyy"
        pTitle?.show(Painter.title(clock: clock, date: f.string(from: Date()), name: name, weather: weatherShort))
    }

    private func drawDialog() {
        let state: (String, UIColor)
        switch mode {
        case "listening": state = ("● DİNLİYORUM", Theme.amber)
        case "thinking": state = ("◌ İŞLENİYOR", Theme.amber)
        case "speaking": state = ("▶ KONUŞUYOR", Theme.holo)
        default: state = wake ? ("● “JARVIS” DE", Theme.amber) : ("● ÇEVRİMİÇİ", Theme.holo)
        }
        pDialog?.show(Painter.dialog(you: you, answer: answer, state: state.0, stateColor: state.1, listening: mode == "listening"))
    }

    private func drawProjects() {
        pProj?.show(Painter.list(title: "PROJELERİM", right: "ÇİMDİKLE → ODAK", items: focus.map { ($0.name, $0.desc) },
                                 empty: "“Jarvis, projelere ekle: …” de."))
    }

    private func drawNotes() {
        pNotes?.show(Painter.list(title: "NOTLAR", right: "+ EKLE", items: notes.map { ($0.text, "") },
                                  empty: "“Jarvis, not al: …” de ya da + EKLE'yi çimdikle.", checked: notes.map { $0.done }))
    }

    /// Put the whole HUD in front of the user, in the room. Called once tracking is ready, and by "ortala".
    func placeHUD() {
        let cam = arView.cameraTransform
        let eye = cam.translation
        let c2 = cam.matrix.columns.2
        var fwd = SIMD3<Float>(-c2.x, 0, -c2.z)
        if simd_length(fwd) < 0.01 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = simd_normalize(fwd)

        anchor?.removeFromParent()
        let a = AnchorEntity(world: eye)
        arView.scene.addAnchor(a)
        anchor = a

        let layout: [(Panel, Float, Float, Float)] = [
            (pTitle!, 0, 1.75, 0.52), (pDialog!, 0, 1.5, -0.02),
            (pProj!, 36, 1.55, 0.0), (pNotes!, -36, 1.55, 0.0)
        ]
        for (p, angle, dist, dy) in layout {
            let local = JarvisEngine.rotateY(fwd, angle) * dist + SIMD3<Float>(0, dy, 0)
            p.entity.removeFromParent()
            a.addChild(p.entity)
            p.entity.position = local
            face(p)
        }
        for p in research { p.entity.removeFromParent(); a.addChild(p.entity) }
        status = ""
    }

    func recenter() {
        clearResearch()
        for p in panels { p.userScale = 1 }
        placeHUD()
        click(); haptic.impactOccurred()
    }

    private static func rotateY(_ v: SIMD3<Float>, _ deg: Float) -> SIMD3<Float> {
        let r = deg * .pi / 180
        return SIMD3<Float>(v.x * cos(r) + v.z * sin(r), v.y, -v.x * sin(r) + v.z * cos(r))
    }

    /// Turn a panel so its front faces the camera, staying upright.
    private func face(_ p: Panel) {
        let pos = p.entity.position(relativeTo: nil)
        var eye = arView.cameraTransform.translation
        eye.y = pos.y
        guard simd_length(pos - eye) > 0.05 else { return }
        let away = pos + (pos - eye)
        p.entity.look(at: away, from: pos, relativeTo: nil)
        p.entity.scale = SIMD3<Float>(repeating: p.userScale)
    }

    // MARK: - Research panels

    private func clearResearch() {
        for p in research { p.entity.removeFromParent() }
        panels.removeAll { p in research.contains { $0 === p } }
        research.removeAll()
    }

    private func spawn(_ p: Panel, angle: Float, dist: Float, dy: Float) {
        guard let a = anchor else { return }
        let cam = arView.cameraTransform
        let c2 = cam.matrix.columns.2
        var fwd = SIMD3<Float>(-c2.x, 0, -c2.z)
        if simd_length(fwd) < 0.01 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = simd_normalize(fwd)
        let world = cam.translation + JarvisEngine.rotateY(fwd, angle) * dist + SIMD3<Float>(0, dy, 0)
        a.addChild(p.entity)
        p.entity.setPosition(world, relativeTo: nil)
        face(p)
        research.append(p)
        panels.append(p)
    }

    private func doResearch(_ q: String, images: Bool) {
        clearResearch()
        mode = "thinking"; answer = "Arıyorum efendim…"; drawDialog()
        whoosh()
        Task {
            let info = await Brain.research(q)
            if images {
                var found = await Brain.commonsImages(info?.enTitle ?? info?.title ?? q, count: 4)
                if found.isEmpty, let u = info?.imageURL { found = [u] }
                let urls = found
                await MainActor.run {
                    if urls.isEmpty { self.say("Görsel bulamadım efendim."); return }
                    let angles: [Float] = urls.count == 1 ? [0] : [-24, -8, 8, 24]
                    for (k, url) in urls.enumerated() where k < angles.count {
                        let p = self.imagePanel(url)
                        self.spawn(p, angle: angles[k], dist: 1.15, dy: -0.12)
                    }
                    self.say("\(info?.title ?? q) için \(urls.count) görsel buldum efendim. Çimdikleyip tutabilir, iki elle büyütebilirsiniz.")
                }
                return
            }
            await MainActor.run {
                guard let info = info, !info.text.isEmpty else { self.say("Bu konuda kaynak bulamadım efendim."); return }
                let p = Panel(name: "info", pixels: CGSize(width: 900, height: 760), width: 0.62)
                p.show(Painter.info(title: info.title, body: info.text, source: "Kaynak: Vikipedi"))
                p.onTap = { [weak self] px in if px.y < 96 && px.x > 450 { self?.clearResearch() } }
                self.spawn(p, angle: 14, dist: 1.1, dy: -0.08)
                if let u = info.imageURL { self.spawn(self.imagePanel(u), angle: -16, dist: 1.1, dy: -0.08) }
                let firstTwo = info.text.components(separatedBy: ". ").prefix(2).joined(separator: ". ")
                self.say(firstTwo.isEmpty ? info.title : firstTwo)
            }
        }
    }

    private func imagePanel(_ url: URL) -> Panel {
        let p = Panel(name: "image", pixels: CGSize(width: 800, height: 800), width: 0.34)
        p.show(Painter.image(nil, caption: "Yükleniyor…"))
        p.onTap = { [weak self, weak p] _ in
            guard let self = self, let p = p else { return }
            p.userScale = p.userScale > 1.5 ? 1 : 2.2
            self.face(p)
        }
        Task {
            let img = await Brain.image(url)
            await MainActor.run { p.show(Painter.image(img, caption: "Görsel yüklenemedi")) }
        }
        return p
    }

    // MARK: - Commands

    func command(_ raw: String, direct: Bool = false) {
        let txt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty else { return }
        you = direct ? "" : txt
        drawDialog()
        if noteNext { noteNext = false; addNote(txt); return }
        if direct { ask(txt); return }
        let low = txt.lowercased(with: tr)

        for key in ["not al", "not et", "not yaz", "hatırlat"] {
            if let r = low.range(of: key) { addNote(JarvisEngine.tail(txt, low, after: r)); return }
        }
        for key in ["projelere ekle", "projelerime ekle", "odağa ekle"] {
            if let r = low.range(of: key) {
                let t = JarvisEngine.tail(txt, low, after: r)
                if !t.isEmpty { focus.append((name: t, desc: "")); saveData(); drawProjects(); say("\(t) projelere eklendi efendim.") }
                return
            }
        }
        if low.hasPrefix("şehrim") || low.hasPrefix("şehrimi") {
            let t = txt.split(separator: " ").dropFirst().joined(separator: " ")
                .replacingOccurrences(of: "(?i)\\s*(olsun|yap|ayarla)$", with: "", options: .regularExpression)
            Task { await self.setCity(t, announce: true) }
            return
        }
        if ["kapat", "temizle", "görselleri kapat", "panelleri kapat"].contains(where: { low.hasPrefix($0) }) {
            clearResearch(); say("Temizlendi efendim."); return
        }
        if ["ortala", "düzen", "yerleştir", "toparla"].contains(where: { low.hasPrefix($0) }) {
            recenter(); say("Panelleri önünüze aldım efendim."); return
        }
        if low.contains("hava") && (low.contains("nasıl") || low.contains("durum")) {
            say(weatherText.map { "Şu an \($0) efendim." } ?? "Hava durumu henüz gelmedi efendim."); return
        }
        let imageWords = ["resim", "resmi", "görsel", "fotoğraf", "foto"]
        let showWords = ["göster", "bul", "getir", "ara"]
        if imageWords.contains(where: { low.contains($0) }) && showWords.contains(where: { low.contains($0) }) {
            let q = JarvisEngine.term(low)
            if !q.isEmpty { doResearch(q, images: true); return }
        }
        if ["araştır", "nedir", "kimdir", "neresidir", "hakkında", "anlat"].contains(where: { low.contains($0) }) || low.hasPrefix("ara ") {
            let q = JarvisEngine.term(low)
            if !q.isEmpty { doResearch(q, images: false); return }
        }
        ask(txt)
    }

    /// Text after `r` (found in the lower-cased copy) taken from the original string.
    static func tail(_ original: String, _ low: String, after r: Range<String.Index>) -> String {
        let offset = low.distance(from: low.startIndex, to: r.upperBound)
        guard offset <= original.count else { return "" }
        let idx = original.index(original.startIndex, offsetBy: offset)
        return String(original[idx...]).trimmingCharacters(in: CharacterSet(charactersIn: " :,.-"))
    }

    /// "galata kulesi'ni araştır" → "galata kulesi"
    static func term(_ low: String) -> String {
        var s = low.replacingOccurrences(of: "['’][a-zçğıöşü]+", with: "", options: .regularExpression)
        let stop = "jarvis|bana|lütfen|bir|biraz|hakkında|bilgi|ver|getir|nedir|kimdir|neresidir|araştır|araştırır|mısın|misin|ara|bul|göster|gösterir|anlat|resim\\S*|resmi\\S*|görsel\\S*|fotoğraf\\S*|foto\\S*"
        s = s.replacingOccurrences(of: "(^|\\s)(\(stop))(?=\\s|$)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(^|\\s)(\(stop))(?=\\s|$)", with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
    }

    private func addNote(_ t: String) {
        let text = t.trimmingCharacters(in: CharacterSet(charactersIn: " :,.-"))
        guard !text.isEmpty else { say("Not boş kaldı efendim."); return }
        notes.insert((text: text, done: false), at: 0)
        saveData(); drawNotes(); click()
        say("Not aldım efendim.")
    }

    private func ask(_ q: String) {
        mode = "thinking"; answer = "…"; drawDialog()
        let sys = Brain.system(name: name, city: city, focus: focus.map { $0.name }, notes: notes.filter { !$0.done }.map { $0.text }, weather: weatherText)
        let hist = history
        Task {
            do {
                let a = try await Brain.ask(q, system: sys, history: hist)
                await MainActor.run {
                    self.history.append(["role": "user", "content": q])
                    self.history.append(["role": "assistant", "content": a])
                    self.say(a)
                }
            } catch {
                await MainActor.run { self.say(Brain.message(for: error)) }
            }
        }
    }

    private func say(_ text: String) {
        answer = text
        mode = "speaking"
        drawDialog()
        voice.speak(text) { [weak self] in
            guard let self = self else { return }
            if self.mode == "speaking" { self.mode = "idle"; self.drawDialog() }
        }
    }

    // MARK: - Weather

    private func setCity(_ name: String, announce: Bool) async {
        guard let g = await Brain.geocode(name) else {
            await MainActor.run { if announce { self.say("\(name) şehrini bulamadım efendim.") } }
            return
        }
        await MainActor.run {
            self.city = g.0; self.lat = g.1; self.lon = g.2
            UserDefaults.standard.set(g.0, forKey: "city")
            UserDefaults.standard.set(g.1, forKey: "lat")
            UserDefaults.standard.set(g.2, forKey: "lon")
        }
        await loadWeather()
        await MainActor.run { if announce { self.say(self.weatherText.map { "Konum \(self.city). Şu an \($0)." } ?? "Konum \(self.city) olarak ayarlandı.") } }
    }

    private func loadWeather() async {
        guard let w = await Brain.weather(lat: lat, lon: lon) else { return }
        await MainActor.run {
            self.weatherText = "\(self.city)'da \(Int(w.temp.rounded())) derece, \(w.text). En düşük \(Int(w.min.rounded())), en yüksek \(Int(w.max.rounded())) derece"
            self.weatherShort = "\(self.city)\n\(Int(w.temp.rounded()))° · \(w.text)\n\(Int(w.min.rounded()))° / \(Int(w.max.rounded()))°"
            self.drawTitle()
        }
    }

    // MARK: - Data

    private func loadData() {
        let d = UserDefaults.standard
        if let n = d.array(forKey: "notes") as? [[String: Any]] {
            notes = n.compactMap { e -> (text: String, done: Bool)? in
                guard let t = e["t"] as? String else { return nil }
                return (text: t, done: (e["d"] as? Bool) ?? false)
            }
        }
        if let f = d.array(forKey: "focus") as? [[String: String]] {
            focus = f.map { e -> (name: String, desc: String) in (name: e["n"] ?? "", desc: e["d"] ?? "") }.filter { !$0.name.isEmpty }
        } else {
            focus = [("Famira", "Instagram kayıtları için AI ikinci beyin"), ("Atlas", "Finansal sinyal platformu"),
                     ("FreelanceLedger", "Freelancer gelir-gider takibi"), ("PromptForge", "Web tabanlı AI prompt ürünü"),
                     ("Holo-Jarvis", "Bu sistem"), ("Bahçem Peyzaj", "Peyzaj işi")]
        }
    }

    private func saveData() {
        let d = UserDefaults.standard
        d.set(notes.prefix(20).map { ["t": $0.text, "d": $0.done] as [String: Any] }, forKey: "notes")
        d.set(focus.prefix(6).map { ["n": $0.name, "d": $0.desc] }, forKey: "focus")
    }

    // MARK: - Feedback

    private func click() { AudioServicesPlaySystemSound(1104) }
    private func whoosh() { AudioServicesPlaySystemSound(1105) }

    // MARK: - Screen taps (always available)

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: arView)
        if let hit = hitPanel(p) { activate(hit.0, hit.1) }
    }

    private func hitPanel(_ point: CGPoint) -> (Panel, CGPoint)? {
        let hits = arView.hitTest(point, query: .nearest, mask: .all)
        guard let hit = hits.first,
              let panel = panels.first(where: { $0.entity === hit.entity }) else { return nil }
        let local = panel.entity.convert(position: hit.position, from: nil)
        let u = CGFloat(local.x / panel.width + 0.5)
        let v = CGFloat(0.5 - local.y / panel.height)
        return (panel, CGPoint(x: u * panel.pixels.width, y: v * panel.pixels.height))
    }

    private func activate(_ panel: Panel, _ px: CGPoint) {
        click(); haptic.impactOccurred()
        panel.onTap?(px)
    }

    // MARK: - AR frames → hands

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if !placed, case .normal = frame.camera.trackingState {
            placed = true
            placeHUD()
            say(name.isEmpty ? "Tüm sistemler çevrimiçi. Bugün ne inşa ediyoruz, efendim?" : "Tüm sistemler çevrimiçi \(name). Bugün ne inşa ediyoruz, efendim?")
        }
        frameCount += 1
        guard placed, frameCount % 2 == 0, !visionBusy else { return }
        let size = arView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        visionBusy = true
        let buffer = frame.capturedImage
        let transform = frame.displayTransform(for: .portrait, viewportSize: size)
        let time = frame.timestamp
        visionQueue.async { [weak self] in
            let found = HandDetector.detect(buffer, transform: transform, size: size)
            DispatchQueue.main.async {
                self?.handleHands(found, time: time)
                self?.visionBusy = false
            }
        }
    }

    private func handleHands(_ found: [HandSample], time: TimeInterval) {
        handFrames += 1
        if Date().timeIntervalSince(handT0) > 1 { handFps = handFrames; handFrames = 0; handT0 = Date() }

        // match detections to tracked hands
        var used = Set<Int>()
        for h in hands {
            var best = -1
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (k, f) in found.enumerated() where !used.contains(k) {
                let c = JarvisEngine.mid(f.thumb, f.index)
                let d = hypot(c.x - h.x, c.y - h.y)
                if d < bestDist { bestDist = d; best = k }
            }
            if best >= 0 && bestDist < 260 { used.insert(best); h.sample = found[best]; h.seen = time } else { h.sample = nil }
        }
        for (k, f) in found.enumerated() where !used.contains(k) {
            let c = JarvisEngine.mid(f.thumb, f.index)
            let h = HandState(x: c.x, y: c.y, seen: time)
            h.sample = f
            hands.append(h)
        }
        hands.removeAll { h in
            guard h.sample == nil && time - h.seen > 0.4 else { return false }
            if h.dragging { AudioServicesPlaySystemSound(1104) }
            return true
        }

        for h in hands {
            guard let f = h.sample else { continue }
            let c = JarvisEngine.mid(f.thumb, f.index)
            let a = min(0.85, 0.3 + hypot(c.x - h.x, c.y - h.y) / 200)
            h.x += (c.x - h.x) * a
            h.y += (c.y - h.y) * a
            let handSize = max(30, hypot(f.wrist.x - f.middle.x, f.wrist.y - f.middle.y))
            let ratio = hypot(f.thumb.x - f.index.x, f.thumb.y - f.index.y) / handSize
            let was = h.pinch
            h.pinch = was ? ratio < 0.45 : ratio < 0.28
            let p = h.point

            if h.pinch && !was {
                h.startPoint = p
                h.startTime = time
                let hit = hitPanel(p)
                h.startPanel = hit?.0
                h.startPixel = hit?.1
                if hit != nil { haptic.impactOccurred(intensity: 0.5) }
            }
            if h.pinch, let panel = h.startPanel, scaleOp == nil {
                let moved = hypot(p.x - h.startPoint.x, p.y - h.startPoint.y)
                if !h.dragging && (moved > 28 || time - h.startTime > 0.45) { beginDrag(h, panel) }
                if h.dragging { drag(h, panel, to: p) }
            }
            if !h.pinch && was {
                if h.dragging {
                    h.dragging = false
                    click()
                } else if let panel = h.startPanel, let px = h.startPixel,
                          time - h.startTime < 0.7, hypot(p.x - h.startPoint.x, p.y - h.startPoint.y) < 30 {
                    activate(panel, px)
                }
                h.startPanel = nil
                h.startPixel = nil
            }
        }

        // two pinching hands → resize
        let pinching = hands.filter { $0.sample != nil && $0.pinch }
        if pinching.count == 2 {
            let target = scaleOp?.panel ?? pinching.compactMap { $0.startPanel }.first
            if let t = target {
                let d = hypot(pinching[0].x - pinching[1].x, pinching[0].y - pinching[1].y)
                if scaleOp == nil {
                    scaleOp = (t, max(60, d), t.userScale)
                    haptic.impactOccurred()
                }
                if let op = scaleOp {
                    t.userScale = max(0.35, min(3.5, op.s0 * Float(d / op.d0)))
                    t.entity.scale = SIMD3<Float>(repeating: t.userScale)
                }
                for h in pinching { h.dragging = false; h.startPanel = nil }
            }
        } else if scaleOp != nil {
            scaleOp = nil
            click()
        }

        cursors = hands.compactMap { h -> Cursor? in
            guard let f = h.sample else { return nil }
            return Cursor(id: ObjectIdentifier(h).hashValue, point: h.point, thumb: f.thumb, index: f.index, pinch: h.pinch, grab: h.dragging || scaleOp != nil)
        }
        let state = hands.filter { $0.sample != nil }.map { $0.dragging ? "TUTUYOR" : ($0.pinch ? "ÇİMDİK" : "AÇIK") }.joined(separator: " + ")
        handInfo = state.isEmpty ? "✋ el görülmüyor · \(handFps) fps" : "✋ \(state) · \(handFps) fps"
    }

    private func beginDrag(_ h: HandState, _ panel: Panel) {
        let cam = arView.cameraTransform.translation
        let pos = panel.entity.position(relativeTo: nil)
        h.grabDistance = max(0.4, simd_length(pos - cam))
        if let ray = arView.ray(through: h.startPoint) {
            h.grabOffset = pos - (ray.origin + ray.direction * h.grabDistance)
        } else {
            h.grabOffset = SIMD3<Float>(0, 0, 0)
        }
        h.dragging = true
        haptic.impactOccurred()
    }

    private func drag(_ h: HandState, _ panel: Panel, to p: CGPoint) {
        guard let ray = arView.ray(through: p) else { return }
        let target = ray.origin + ray.direction * h.grabDistance + h.grabOffset
        panel.entity.setPosition(target, relativeTo: nil)
        face(panel)
    }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
