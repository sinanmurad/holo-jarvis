import Foundation
import Speech
import AVFoundation

/// Turkish speech in/out.
/// Wake mode: keeps listening in short sessions and reacts to sentences containing "Jarvis".
/// One-shot mode: the next sentence is a command (used by the KONUŞ button / pinch).
final class Voice: NSObject, AVSpeechSynthesizerDelegate {

    var onCommand: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?      // true = listening for a command right now
    var onError: ((String) -> Void)?

    private(set) var wakeMode = true
    private(set) var authorized = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var oneShot = false
    private var running = false
    private var speaking = false
    private var lastText = ""
    private var silenceTimer: Timer?
    private var capTimer: Timer?
    private var restartWork: DispatchWorkItem?

    private static let wakeWords = ["jarvis", "carvis", "cervis", "ceyvis", "çarvis", "jarvıs", "carvıs", "şarvis", "harvis", "jar vis"]

    override init() {
        super.init()
        synth.delegate = self
    }

    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { mic in
                DispatchQueue.main.async {
                    self.authorized = (status == .authorized) && mic
                    done(self.authorized)
                }
            }
        }
    }

    func setWakeMode(_ on: Bool) {
        wakeMode = on
        if on { scheduleRestart(0.2) } else if !oneShot { stopListening() }
    }

    /// Listen for exactly one command (no wake word needed).
    func listenOnce() {
        guard authorized else { onError?("Mikrofon ya da konuşma izni yok. Ayarlar → Jarvis'ten izin ver."); return }
        synth.stopSpeaking(at: .immediate)
        speaking = false
        startListening(oneShot: true)
    }

    // MARK: - Listening

    private func scheduleRestart(_ delay: TimeInterval) {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.authorized, self.wakeMode, !self.speaking, !self.running else { return }
            self.startListening(oneShot: false)
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func startListening(oneShot: Bool) {
        stopListening()
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onError?("Türkçe konuşma tanıma şu an kullanılamıyor.")
            return
        }
        self.oneShot = oneShot
        lastText = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?("Ses oturumu açılamadı.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 16.0, *) { req.addsPunctuation = false }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { onError?("Mikrofon bulunamadı."); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { onError?("Mikrofon başlatılamadı."); return }
        running = true
        if oneShot { onStateChange?(true) }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async { self.got(text, final: isFinal) }
            } else if error != nil {
                DispatchQueue.main.async { self.finish() }
            }
        }
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: oneShot ? 12 : 50, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func got(_ text: String, final: Bool) {
        guard running else { return }
        lastText = text
        if oneShot || Voice.containsWake(text) { onPartial?(text) }
        silenceTimer?.invalidate()
        if final { finish(); return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func finish() {
        guard running else { return }
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasOneShot = oneShot
        stopListening()
        if wasOneShot {
            onStateChange?(false)
            if !text.isEmpty { onCommand?(Voice.stripWake(text)) }
            else if wakeMode { scheduleRestart(0.3) }
            return
        }
        if !text.isEmpty, Voice.containsWake(text) {
            let rest = Voice.stripWake(text)
            if rest.isEmpty {
                speak("Buyurun efendim?") { [weak self] in self?.listenOnce() }
            } else {
                onCommand?(rest)
            }
            return
        }
        if wakeMode { scheduleRestart(0.25) }
    }

    func stopListening() {
        silenceTimer?.invalidate(); silenceTimer = nil
        capTimer?.invalidate(); capTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        running = false
    }

    static func containsWake(_ s: String) -> Bool {
        let low = s.lowercased(with: Locale(identifier: "tr-TR"))
        return wakeWords.contains { low.contains($0) }
    }

    /// "… Jarvis, Galata Kulesi'ni araştır" → "Galata Kulesi'ni araştır"
    static func stripWake(_ s: String) -> String {
        let low = s.lowercased(with: Locale(identifier: "tr-TR"))
        for w in wakeWords {
            if let r = low.range(of: w) {
                let offset = low.distance(from: low.startIndex, to: r.upperBound)
                if offset <= s.count {
                    let idx = s.index(s.startIndex, offsetBy: offset)
                    return String(s[idx...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:"))
                }
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speaking

    private var afterSpeak: (() -> Void)?

    func speak(_ text: String, then: (() -> Void)? = nil) {
        stopListening()
        synth.stopSpeaking(at: .immediate)
        afterSpeak = then
        speaking = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let u = AVSpeechUtterance(string: text)
        u.voice = Voice.bestTurkishVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        u.pitchMultiplier = 0.9
        synth.speak(u)
    }

    static func bestTurkishVoice() -> AVSpeechSynthesisVoice? {
        let tr = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("tr") }
        return tr.first(where: { $0.quality == .enhanced }) ?? tr.first ?? AVSpeechSynthesisVoice(language: "tr-TR")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.doneSpeaking() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if !self.synth.isSpeaking { self.speaking = false } }
    }

    private func doneSpeaking() {
        speaking = false
        if let next = afterSpeak { afterSpeak = nil; next() }
        if wakeMode { scheduleRestart(0.35) }
    }
}
