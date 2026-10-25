import Foundation
import UIKit

/// Network helpers: AI answers (Groq), Wikipedia research, Commons images, weather.
enum Brain {

    struct Info { let title: String; let text: String; let imageURL: URL?; let enTitle: String? }

    static var groqKey: String {
        let user = UserDefaults.standard.string(forKey: "groqKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return user.isEmpty ? Secrets.groqKey : user
    }

    static func system(name: String, city: String, focus: [String], notes: [String], weather: String?) -> String {
        var s = "Sen J.A.R.V.I.S.'sin: \(name.isEmpty ? "kullanıcının" : name + " adlı kişinin") kişisel yapay zekâ asistanı. "
        s += "Odada holografik paneller olarak görünüyorsun. "
        if !city.isEmpty { s += "Kullanıcı \(city)'da. " }
        if !focus.isEmpty { s += "Projeleri ve odakları: \(focus.joined(separator: ", ")). " }
        if !notes.isEmpty { s += "Açık notları: \(notes.prefix(5).joined(separator: "; ")). " }
        if let w = weather { s += "Hava: \(w). " }
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "d MMMM yyyy EEEE HH:mm"
        s += "Şu an: \(f.string(from: Date())). "
        s += "Her zaman Türkçe, sakin, zeki ve hafif esprili konuş; kullanıcıya \"efendim\" de. Cevapların en fazla 3 kısa cümle, somut ve uygulanabilir olsun. Markdown, liste, emoji kullanma. Bilmediğin güncel bilgiyi uydurma."
        return s
    }

    enum BrainError: Error { case noKey, badKey, rate, network, empty }

    static func ask(_ q: String, system: String, history: [[String: String]]) async throws -> String {
        let key = groqKey
        guard !key.isEmpty else { throw BrainError.noKey }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += history.suffix(8)
        messages.append(["role": "user", "content": q])
        for model in ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "llama-3.1-8b-instant"] {
            var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 25
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.7, "max_tokens": 400]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let result: (Data, URLResponse)
            do { result = try await URLSession.shared.data(for: req) } catch { throw BrainError.network }
            let data = result.0
            let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw BrainError.badKey }
            if code == 429 { throw BrainError.rate }
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { continue }
            let clean = content.replacingOccurrences(of: "[*#_`]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        throw BrainError.empty
    }

    static func message(for error: Error) -> String {
        switch error as? BrainError {
        case .noKey: return "Beynimi bağlamak için ayarlardan Groq anahtarını ekleyin efendim."
        case .badKey: return "Groq anahtarı geçersiz görünüyor efendim."
        case .rate: return "Biraz hızlı gittik efendim, birkaç saniye sonra tekrar deneyin."
        case .network: return "İnternete ulaşamıyorum efendim."
        default: return "Şu an cevap veremedim efendim, tekrar deneyin."
        }
    }

    // MARK: - JSON helper

    static func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("HoloJarvis/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/"))) ?? s
    }

    // MARK: - Wikipedia

    static func wiki(_ q: String, lang: String) async -> Info? {
        guard let s = URL(string: "https://\(lang).wikipedia.org/w/api.php?action=query&list=search&srlimit=1&format=json&srsearch=\(enc(q))"),
              let j = await getJSON(s),
              let query = j["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]],
              let title = hits.first?["title"] as? String else { return nil }
        let path = enc(title.replacingOccurrences(of: " ", with: "_"))
        guard let u = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)"),
              let sum = await getJSON(u) else { return Info(title: title, text: "", imageURL: nil, enTitle: nil) }
        var img: URL? = nil
        if let th = sum["thumbnail"] as? [String: Any], let src = th["source"] as? String {
            img = URL(string: src.replacingOccurrences(of: "/\\d+px-", with: "/800px-", options: .regularExpression))
        } else if let o = sum["originalimage"] as? [String: Any], let src = o["source"] as? String {
            img = URL(string: src)
        }
        var en: String? = lang == "en" ? title : nil
        if lang != "en",
           let lu = URL(string: "https://\(lang).wikipedia.org/w/api.php?action=query&prop=langlinks&lllang=en&format=json&titles=\(enc(title))"),
           let lj = await getJSON(lu),
           let lq = lj["query"] as? [String: Any],
           let pages = lq["pages"] as? [String: Any],
           let first = pages.values.first as? [String: Any],
           let links = first["langlinks"] as? [[String: Any]],
           let t = links.first?["*"] as? String { en = t }
        return Info(title: (sum["title"] as? String) ?? title, text: (sum["extract"] as? String) ?? "", imageURL: img, enTitle: en)
    }

    static func research(_ q: String) async -> Info? {
        if let i = await wiki(q, lang: "tr") { return i }
        return await wiki(q, lang: "en")
    }

    static func commonsImages(_ q: String, count: Int = 4) async -> [URL] {
        guard let u = URL(string: "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrnamespace=6&gsrlimit=\(count * 3)&gsrsearch=\(enc("filetype:bitmap " + q))&prop=imageinfo&iiprop=url|mime&iiurlwidth=800&format=json"),
              let j = await getJSON(u),
              let query = j["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else { return [] }
        let sorted = pages.values.compactMap { $0 as? [String: Any] }
            .sorted { (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0) }
        var out: [URL] = []
        for p in sorted {
            guard let infos = p["imageinfo"] as? [[String: Any]], let ii = infos.first,
                  let mime = ii["mime"] as? String, mime.contains("jpeg") || mime.contains("png"),
                  let s = (ii["thumburl"] as? String) ?? (ii["url"] as? String), let url = URL(string: s) else { continue }
            out.append(url)
            if out.count >= count { break }
        }
        return out
    }

    static func image(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("HoloJarvis/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        return UIImage(data: result.0)
    }

    // MARK: - Weather (Open-Meteo, no key)

    static func geocode(_ city: String) async -> (String, Double, Double)? {
        guard let u = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(enc(city))&count=1&language=tr&format=json"),
              let j = await getJSON(u), let res = j["results"] as? [[String: Any]], let g = res.first,
              let lat = g["latitude"] as? Double, let lon = g["longitude"] as? Double else { return nil }
        return ((g["name"] as? String) ?? city, lat, lon)
    }

    static func weather(lat: Double, lon: Double) async -> (temp: Double, text: String, min: Double, max: Double)? {
        guard let u = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"),
              let j = await getJSON(u),
              let cur = j["current"] as? [String: Any], let t = cur["temperature_2m"] as? Double,
              let daily = j["daily"] as? [String: Any],
              let mx = (daily["temperature_2m_max"] as? [Double])?.first,
              let mn = (daily["temperature_2m_min"] as? [Double])?.first else { return nil }
        let code = (cur["weather_code"] as? Int) ?? -1
        let names: [Int: String] = [0: "açık", 1: "az bulutlu", 2: "parçalı bulutlu", 3: "kapalı", 45: "sisli", 48: "sisli",
                                    51: "çisenti", 53: "çisenti", 55: "çisenti", 61: "hafif yağmurlu", 63: "yağmurlu", 65: "şiddetli yağmur",
                                    71: "hafif kar", 73: "karlı", 75: "yoğun kar", 80: "sağanak", 81: "sağanak", 82: "şiddetli sağanak",
                                    95: "gök gürültülü", 96: "dolu", 99: "dolu"]
        return (t, names[code] ?? "—", mn, mx)
    }
}
