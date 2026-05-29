import SwiftUI
import Foundation

// MARK: - Markdown rendering

struct MarkdownView: View {
    let text: String
    /// Body/quote typeface. Defaults to serif for the PR description's prose
    /// look; inline review comments pass `.default` so they sit naturally in the
    /// monospaced diff instead of looking out of place.
    var bodyDesign: Font.Design = .serif
    var bodySize: CGFloat = 14

    private var bodyFont: Font  { .system(size: bodySize, design: bodyDesign) }
    private var quoteFont: Font { .system(size: bodySize, design: bodyDesign).italic() }
    private static let listFont   = Font.system(size: 13)
    private static let codeFont   = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parse(Emoji.substitute(HtmlPreprocess.apply(text))).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            VStack(alignment: .leading, spacing: 4) {
                Text(inline(s))
                    .font(headingFont(level))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 0.5)
                }
            }
            .padding(.top, level == 1 ? 8 : (level == 2 ? 4 : 2))

        case .paragraph(let s):
            Text(inline(s))
                .font(bodyFont)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.secondary.opacity(0.65))
                            .frame(width: 4, height: 4)
                            .offset(y: -2)
                        Text(inline(item))
                            .font(Self.listFont)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(inline(item))
                            .font(Self.listFont)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .task(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: item.0 ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundColor(item.0 ? .accentColor : .secondary.opacity(0.7))
                        Text(inline(item.1))
                            .font(Self.listFont)
                            .strikethrough(item.0, color: .secondary)
                            .foregroundColor(item.0 ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .code(let lang, let s):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    HStack {
                        Text(lang.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s)
                        .font(Self.codeFont)
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

        case .quote(let lines):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 2.5)
                Text(inline(lines.joined(separator: "\n")))
                    .font(quoteFont)
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let size: CGFloat
        switch level {
        case 1: size = 20
        case 2: size = 17
        case 3: size = 15
        case 4: size = 13
        default: size = 12
        }
        return .system(size: size, weight: level <= 2 ? .bold : .semibold)
    }

    private func inline(_ s: String) -> AttributedString {
        guard var attr = try? AttributedString(
            markdown: s,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else { return AttributedString(s) }

        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].backgroundColor = Color.primary.opacity(0.1)
                attr[run.range].foregroundColor = Color(red: 0.82, green: 0.36, blue: 0.45)
            }
            if run.link != nil {
                attr[run.range].foregroundColor = Color.accentColor
                attr[run.range].underlineStyle = .single
            }
        }
        return attr
    }
}

// MARK: - HTML in PR bodies → markdown equivalents

private enum HtmlPreprocess {
    static func apply(_ s: String) -> String {
        var out = s
        out = replaceRegex(out, #"<!--[\s\S]*?-->"#, with: "", caseInsensitive: false)
        out = replaceRegex(out, #"<br\s*/?>"#, with: "\n", caseInsensitive: true)
        out = replaceRegex(out, #"<hr\s*/?>"#, with: "\n\n---\n\n", caseInsensitive: true)
        out = replaceRegex(out, #"<(strong|b)>([\s\S]*?)</\1>"#, with: "**$2**", caseInsensitive: true)
        out = replaceRegex(out, #"<(em|i)>([\s\S]*?)</\1>"#, with: "*$2*", caseInsensitive: true)
        out = replaceRegex(out, #"<code>([\s\S]*?)</code>"#, with: "`$1`", caseInsensitive: true)
        out = replaceRegex(out, #"<kbd>([\s\S]*?)</kbd>"#, with: "`$1`", caseInsensitive: true)
        out = replaceRegex(
            out,
            #"<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            with: "[$2]($1)",
            caseInsensitive: true
        )
        out = replaceRegex(out, #"<summary>([\s\S]*?)</summary>"#, with: "**$1**", caseInsensitive: true)
        out = replaceRegex(out, #"</?details(\s[^>]*)?>"#, with: "", caseInsensitive: true)
        out = replaceRegex(
            out,
            #"<img\s+[^>]*?alt=["']([^"']*)["'][^>]*?src=["']([^"']+)["'][^>]*?/?>"#,
            with: "![$1]($2)",
            caseInsensitive: true
        )
        out = replaceRegex(
            out,
            #"<img\s+[^>]*?src=["']([^"']+)["'][^>]*?/?>"#,
            with: "![]($1)",
            caseInsensitive: true
        )
        let strippable = ["div", "span", "p", "section", "article", "header", "footer",
                          "nav", "small", "sub", "sup", "mark", "u", "s", "strike",
                          "ul", "ol", "li", "table", "thead", "tbody", "tfoot",
                          "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
                          "blockquote", "pre"]
        for tag in strippable {
            out = replaceRegex(out, "</?\(tag)(\\s[^>]*)?>", with: "", caseInsensitive: true)
        }
        return out
    }

    private static func replaceRegex(
        _ s: String,
        _ pattern: String,
        with template: String,
        caseInsensitive: Bool
    ) -> String {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let ns = s as NSString
        return regex.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}

// MARK: - GitHub-style emoji shortcodes (:rocket: → 🚀)

private enum Emoji {
    static let map: [String: String] = [
        "tada": "🎉", "rocket": "🚀", "bug": "🐛", "sparkles": "✨",
        "memo": "📝", "white_check_mark": "✅", "heavy_check_mark": "✔️",
        "x": "❌", "warning": "⚠️", "fire": "🔥", "bulb": "💡",
        "construction": "🚧", "wrench": "🔧", "hammer": "🔨",
        "recycle": "♻️", "art": "🎨", "zap": "⚡", "boom": "💥",
        "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "pencil": "✏️", "books": "📚", "book": "📖",
        "package": "📦", "rotating_light": "🚨",
        "tag": "🏷", "star": "⭐", "100": "💯",
        "checkered_flag": "🏁", "triangular_flag_on_post": "🚩",
        "wave": "👋", "ok_hand": "👌", "thumbsup": "👍", "+1": "👍",
        "thumbsdown": "👎", "-1": "👎", "clap": "👏", "muscle": "💪",
        "pray": "🙏", "eyes": "👀",
        "smile": "😄", "joy": "😂", "sob": "😭",
        "thinking": "🤔", "robot": "🤖",
        "calendar": "📅", "chart_with_upwards_trend": "📈",
        "clipboard": "📋", "paperclip": "📎",
        "shield": "🛡", "gem": "💎",
        "heart": "❤️", "broken_heart": "💔",
        "no_entry": "⛔", "question": "❓", "exclamation": "❗",
        "speech_balloon": "💬", "globe_with_meridians": "🌐",
        "tools": "🛠", "gear": "⚙️", "link": "🔗", "mag": "🔍",
        "bookmark": "🔖", "bell": "🔔", "alarm_clock": "⏰",
        "hourglass": "⌛", "hourglass_flowing_sand": "⏳",
        "rainbow": "🌈", "coffee": "☕",
        "envelope": "✉️", "inbox_tray": "📥",
        "trophy": "🏆", "first_place_medal": "🥇",
        "shrug": "🤷", "metal": "🤘", "v": "✌️", "saluting_face": "🫡",
    ]

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#, options: [.caseInsensitive])
    }()

    static func substitute(_ s: String) -> String {
        guard let regex = regex else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            let full = m.range
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            out += ns.substring(with: NSRange(location: last, length: full.location - last))
            out += map[name] ?? ns.substring(with: full)
            last = full.location + full.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }
}

private enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case task([(Bool, String)])
    case code(String, String)
    case quote([String])
    case rule
}

private func parse(_ source: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines = source.components(separatedBy: "\n")
    var i = 0

    var paraBuf: [String] = []
    var bulletBuf: [String] = []
    var orderedBuf: [String] = []
    var taskBuf: [(Bool, String)] = []
    var quoteBuf: [String] = []

    func flushPara()    { if !paraBuf.isEmpty    { blocks.append(.paragraph(paraBuf.joined(separator: " "))); paraBuf.removeAll() } }
    func flushBullets() { if !bulletBuf.isEmpty  { blocks.append(.bullet(bulletBuf));   bulletBuf.removeAll() } }
    func flushOrdered() { if !orderedBuf.isEmpty { blocks.append(.ordered(orderedBuf)); orderedBuf.removeAll() } }
    func flushTasks()   { if !taskBuf.isEmpty    { blocks.append(.task(taskBuf));       taskBuf.removeAll() } }
    func flushQuote()   { if !quoteBuf.isEmpty   { blocks.append(.quote(quoteBuf));     quoteBuf.removeAll() } }
    func flushAll()     { flushPara(); flushBullets(); flushOrdered(); flushTasks(); flushQuote() }

    while i < lines.count {
        let raw = lines[i]
        let line = raw.trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("```") {
            flushAll()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count,
                  !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i]); i += 1
            }
            blocks.append(.code(lang, code.joined(separator: "\n")))
            i += 1
            continue
        }

        if line == "---" || line == "***" || line == "___" {
            flushAll(); blocks.append(.rule); i += 1; continue
        }

        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes >= 1, hashes <= 6,
           line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " {
            flushAll()
            let text = String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(hashes, text))
            i += 1; continue
        }

        if let r = line.range(of: #"^[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) {
            flushPara(); flushBullets(); flushOrdered(); flushQuote()
            let prefix = String(line[..<r.upperBound]).lowercased()
            let checked = prefix.contains("[x]")
            let item = String(line[r.upperBound...])
            taskBuf.append((checked, item))
            i += 1; continue
        }

        if let r = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            flushPara(); flushOrdered(); flushTasks(); flushQuote()
            bulletBuf.append(String(line[r.upperBound...]))
            i += 1; continue
        }

        if let r = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            flushPara(); flushBullets(); flushTasks(); flushQuote()
            orderedBuf.append(String(line[r.upperBound...]))
            i += 1; continue
        }

        if line.hasPrefix(">") {
            flushPara(); flushBullets(); flushOrdered(); flushTasks()
            let stripped = line.hasPrefix("> ")
                ? String(line.dropFirst(2))
                : String(line.dropFirst())
            quoteBuf.append(stripped)
            i += 1; continue
        }

        if line.isEmpty {
            flushAll()
            i += 1; continue
        }

        flushBullets(); flushOrdered(); flushTasks(); flushQuote()
        paraBuf.append(line)
        i += 1
    }
    flushAll()
    return blocks
}
