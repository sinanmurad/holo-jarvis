import SwiftUI
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let engine: JarvisEngine
    func makeUIView(context: Context) -> ARView { engine.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

private let holo = Color(red: 0.37, green: 0.95, blue: 1.0)
private let amber = Color(red: 1.0, green: 0.71, blue: 0.28)
private let glass = Color(red: 0.016, green: 0.063, blue: 0.08).opacity(0.78)

/// Glowing fingertip markers so you can see what Jarvis sees.
struct CursorLayer: View {
    let cursors: [Cursor]
    var body: some View {
        ZStack {
            ForEach(cursors) { c in
                let col = c.grab || c.pinch ? amber : holo
                Path { p in
                    p.move(to: c.thumb)
                    p.addLine(to: c.index)
                }
                .stroke(col.opacity(0.8), lineWidth: 2)
                Circle().fill(Color.white).frame(width: 9, height: 9).position(c.thumb)
                Circle().fill(Color.white).frame(width: 9, height: 9).position(c.index)
                Circle()
                    .stroke(col, lineWidth: c.pinch ? 5 : 3)
                    .frame(width: c.pinch ? 30 : 46, height: c.pinch ? 30 : 46)
                    .shadow(color: col, radius: 10)
                    .position(c.point)
            }
        }
    }
}

struct HudButton: View {
    let title: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(on ? amber : holo)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Capsule().fill(glass))
                .overlay(Capsule().stroke((on ? amber : holo).opacity(0.55), lineWidth: 1))
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = JarvisEngine()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            ARViewContainer(engine: engine).ignoresSafeArea()
            CursorLayer(cursors: engine.cursors).ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 10) {
                HStack {
                    HudButton(title: "⟲ ORTALA") { engine.recenter() }
                    Spacer()
                    HudButton(title: engine.wake ? "● JARVIS DİNLİYOR" : "○ DİNLEME KAPALI", on: engine.wake) { engine.setWake(!engine.wake) }
                    HudButton(title: "⚙") { showSettings = true }
                }
                if !engine.status.isEmpty {
                    Text(engine.status)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(holo)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(glass))
                }
                Spacer()
                Text(engine.handInfo)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(holo)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(glass))
                Button(action: { engine.listenOnce() }) {
                    Text(engine.listening ? "DİNLİYORUM" : "KONUŞ")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.listening ? amber : holo)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(glass))
                        .overlay(Circle().stroke(engine.listening ? amber : holo, lineWidth: 2))
                        .shadow(color: engine.listening ? amber : .clear, radius: 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .onAppear {
            engine.start()
            if engine.name.isEmpty { showSettings = true }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }
}

struct SettingsView: View {
    let engine: JarvisEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var city = ""
    @State private var key = ""
    @State private var wake = true

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Sen")) {
                    TextField("Adın", text: $name)
                    TextField("Şehrin (hava durumu)", text: $city)
                }
                Section(header: Text("Ses"), footer: Text("Açıkken “Jarvis, …” diye başlayan cümleleri dinler.")) {
                    Toggle("“Jarvis” uyandırma kelimesi", isOn: $wake)
                }
                Section(header: Text("Yapay zekâ"),
                        footer: Text(Secrets.groqKey.isEmpty ? "Groq anahtarı gerekli: console.groq.com/keys" : "Derlemedeki Groq anahtarı kullanılıyor. Başka anahtar istersen buraya yaz.")) {
                    SecureField("Groq API anahtarı (isteğe bağlı)", text: $key)
                }
                Section(header: Text("Nasıl kullanılır")) {
                    Text("✋ Elini kameranın önüne uzat. Başparmak ve işaret parmağını birleştir: panele basar.")
                    Text("✊ Çimdikle ve tut: paneli havada taşırsın.")
                    Text("🤲 İki elle çimdikle, açıp kapat: büyüt/küçült.")
                    Text("🎙 “Jarvis, Galata Kulesi'ni araştır” · “Jarvis, aslan resimleri göster” · “Jarvis, not al: …” · “Jarvis, ortala”")
                }
            }
            .navigationTitle("Jarvis Ayarları")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        engine.applySettings(name: name, city: city, groqKey: key, wake: wake)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            name = engine.name
            city = engine.city
            key = UserDefaults.standard.string(forKey: "groqKey") ?? ""
            wake = engine.wake
        }
    }
}
