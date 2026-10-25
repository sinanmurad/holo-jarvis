import UIKit

/// Colours shared by every holographic panel.
enum Theme {
    static let holo = UIColor(red: 0.37, green: 0.95, blue: 1.0, alpha: 1)
    static let amber = UIColor(red: 1.0, green: 0.71, blue: 0.28, alpha: 1)
    static let ink = UIColor(red: 0.86, green: 0.94, blue: 0.95, alpha: 1)
    static let dim = UIColor(red: 0.55, green: 0.70, blue: 0.73, alpha: 1)
    static let bg = UIColor(red: 0.012, green: 0.055, blue: 0.075, alpha: 1)
}

/// Draws panel textures. Every panel is opaque dark glass with glowing text,
/// so it stays readable in any room light (the material is unlit).
enum Painter {

    static func canvas(_ size: CGSize, accent: UIColor = Theme.holo, _ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            Theme.bg.setFill()
            ctx.fill(rect)
            frame(ctx.cgContext, rect, accent)
            draw(ctx.cgContext, rect)
        }
    }

    static func frame(_ c: CGContext, _ r: CGRect, _ col: UIColor) {
        let i = r.insetBy(dx: 6, dy: 6)
        c.setStrokeColor(col.withAlphaComponent(0.45).cgColor)
        c.setLineWidth(3)
        c.stroke(i)
        c.setStrokeColor(col.cgColor)
        c.setLineWidth(9)
        let L: CGFloat = 64
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (i.minX, i.minY, 1, 1), (i.maxX, i.minY, -1, 1),
            (i.minX, i.maxY, 1, -1), (i.maxX, i.maxY, -1, -1)
        ]
        for (x, y, sx, sy) in corners {
            c.move(to: CGPoint(x: x + L * sx, y: y))
            c.addLine(to: CGPoint(x: x, y: y))
            c.addLine(to: CGPoint(x: x, y: y + L * sy))
            c.strokePath()
        }
    }

    @discardableResult
    static func text(_ s: String, _ rect: CGRect, size: CGFloat, weight: UIFont.Weight = .regular,
                     color: UIColor = Theme.ink, mono: Bool = false, align: NSTextAlignment = .left,
                     glow: Bool = false) -> CGFloat {
        let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : UIFont.systemFont(ofSize: size, weight: weight)
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if glow {
            let sh = NSShadow()
            sh.shadowColor = color
            sh.shadowBlurRadius = size * 0.35
            sh.shadowOffset = .zero
            attrs[.shadow] = sh
        }
        let str = s as NSString
        let opts: NSStringDrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        str.draw(with: rect, options: opts, attributes: attrs, context: nil)
        let used = str.boundingRect(with: rect.size, options: opts, attributes: attrs, context: nil)
        return min(rect.height, ceil(used.height))
    }

    static func header(_ c: CGContext, _ r: CGRect, _ title: String, right: String? = nil, rightColor: UIColor = Theme.holo) {
        text(title, CGRect(x: 44, y: 30, width: r.width * 0.6, height: 50), size: 38, weight: .heavy, color: Theme.holo, glow: true)
        if let right = right {
            text(right, CGRect(x: r.width * 0.4, y: 38, width: r.width * 0.6 - 44, height: 40), size: 26, weight: .bold,
                 color: rightColor, mono: true, align: .right, glow: true)
        }
        c.setFillColor(Theme.holo.withAlphaComponent(0.6).cgColor)
        c.fill(CGRect(x: 44, y: 88, width: r.width - 88, height: 2))
    }

    // MARK: - Panels

    static func title(clock: String, date: String, name: String, weather: String?) -> UIImage {
        canvas(CGSize(width: 1400, height: 300)) { _, r in
            text("J.A.R.V.I.S.", CGRect(x: 50, y: 60, width: 520, height: 100), size: 72, weight: .heavy, color: Theme.holo, glow: true)
            text(name.isEmpty ? "Kişisel asistan" : "Hoş geldin \(name)", CGRect(x: 54, y: 175, width: 520, height: 50), size: 30, color: Theme.ink, mono: true)
            text(clock, CGRect(x: 0, y: 50, width: r.width, height: 120), size: 100, weight: .bold, color: Theme.holo, mono: true, align: .center, glow: true)
            text(date, CGRect(x: 0, y: 180, width: r.width, height: 50), size: 30, color: Theme.ink, align: .center)
            text(weather ?? "Hava durumu alınıyor…", CGRect(x: r.width - 560, y: 90, width: 510, height: 140), size: 34, weight: .semibold,
                 color: Theme.ink, align: .right)
        }
    }

    static func dialog(you: String, answer: String, state: String, stateColor: UIColor, listening: Bool) -> UIImage {
        canvas(CGSize(width: 1024, height: 640), accent: listening ? Theme.amber : Theme.holo) { c, r in
            header(c, r, "JARVIS", right: state, rightColor: stateColor)
            var y: CGFloat = 112
            if !you.isEmpty {
                let h = text("Sen: " + you, CGRect(x: 50, y: y, width: r.width - 100, height: 84), size: 30, color: Theme.dim)
                y += h + 18
            }
            let big = answer.count < 110
            text(answer, CGRect(x: 50, y: y, width: r.width - 100, height: r.height - y - 130), size: big ? 50 : 38, weight: .bold,
                 color: Theme.holo, glow: true)
            let btn = micButtonRect(r)
            c.setFillColor((listening ? Theme.amber : Theme.holo).withAlphaComponent(listening ? 0.28 : 0.14).cgColor)
            c.fill(btn)
            c.setStrokeColor((listening ? Theme.amber : Theme.holo).cgColor)
            c.setLineWidth(4)
            c.stroke(btn)
            text(listening ? "● DİNLİYORUM" : "● KONUŞ", btn.insetBy(dx: 0, dy: 16), size: 34, weight: .heavy,
                 color: listening ? Theme.amber : Theme.holo, align: .center, glow: true)
            text("Çimdikle = bas · Çimdikle ve tut = taşı · İki elle = büyüt", CGRect(x: 50, y: r.height - 96, width: r.width - 420, height: 60),
                 size: 22, color: Theme.dim, mono: true)
        }
    }

    static func micButtonRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.width - 360, y: r.height - 120, width: 310, height: 80)
    }

    static func list(title: String, right: String, items: [(String, String)], empty: String, checked: [Bool] = []) -> UIImage {
        canvas(CGSize(width: 800, height: 760)) { c, r in
            header(c, r, title, right: right, rightColor: Theme.amber)
            if items.isEmpty {
                text(empty, CGRect(x: 44, y: 120, width: r.width - 88, height: 300), size: 30, color: Theme.dim)
            }
            for (i, item) in items.prefix(6).enumerated() {
                let y = 106 + CGFloat(i) * 106
                var x: CGFloat = 44
                if i < checked.count {
                    let box = CGRect(x: 44, y: y + 18, width: 36, height: 36)
                    c.setStrokeColor((checked[i] ? Theme.amber : Theme.holo).cgColor)
                    c.setLineWidth(4)
                    c.stroke(box)
                    if checked[i] {
                        c.move(to: CGPoint(x: box.minX + 7, y: box.midY))
                        c.addLine(to: CGPoint(x: box.minX + 16, y: box.maxY - 8))
                        c.addLine(to: CGPoint(x: box.maxX - 6, y: box.minY + 7))
                        c.strokePath()
                    }
                    x = 100
                }
                let done = i < checked.count && checked[i]
                text(item.0, CGRect(x: x, y: y + 6, width: r.width - x - 44, height: 48), size: 36, weight: .bold,
                     color: done ? Theme.dim : Theme.holo, glow: !done)
                if !item.1.isEmpty {
                    text(item.1, CGRect(x: x, y: y + 56, width: r.width - x - 44, height: 34), size: 24, color: Theme.dim)
                }
                c.setFillColor(Theme.holo.withAlphaComponent(0.25).cgColor)
                c.fill(CGRect(x: 44, y: y + 98, width: r.width - 88, height: 1))
            }
        }
    }

    static func info(title: String, body: String, source: String?) -> UIImage {
        canvas(CGSize(width: 900, height: 760), accent: Theme.holo) { c, r in
            header(c, r, "ARAŞTIRMA", right: "✕ KAPAT", rightColor: Theme.amber)
            let h = text(title, CGRect(x: 44, y: 110, width: r.width - 88, height: 110), size: 46, weight: .heavy, color: Theme.holo, glow: true)
            text(body, CGRect(x: 44, y: 110 + h + 16, width: r.width - 88, height: r.height - h - 210), size: 29, color: Theme.ink)
            if let source = source {
                text(source, CGRect(x: 44, y: r.height - 58, width: r.width - 88, height: 30), size: 20, color: Theme.dim, mono: true)
            }
        }
    }

    static func image(_ img: UIImage?, caption: String) -> UIImage {
        canvas(CGSize(width: 800, height: 800)) { c, r in
            guard let img = img, img.size.width > 0, img.size.height > 0 else {
                text(caption, CGRect(x: 0, y: r.midY - 30, width: r.width, height: 60), size: 32, color: Theme.dim, align: .center)
                return
            }
            let box = r.insetBy(dx: 24, dy: 24)
            let k = min(box.width / img.size.width, box.height / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            let dst = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
            img.draw(in: dst)
            c.setStrokeColor(Theme.holo.cgColor)
            c.setLineWidth(5)
            c.stroke(dst)
        }
    }
}
