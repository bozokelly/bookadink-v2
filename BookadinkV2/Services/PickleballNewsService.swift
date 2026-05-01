import Foundation

// MARK: - Model

struct PickleballNewsItem: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let source: String
    let publishedAt: Date?
    let imageURL: URL?
}

// MARK: - Service

@MainActor
final class PickleballNewsService: ObservableObject {
    @Published private(set) var items: [PickleballNewsItem] = []
    @Published private(set) var isLoading = false

    private static let feedURL = "https://www.thedinkpickleball.com/feed/"
    private static let feedSource = "The Dink"
    private static let maxItems = 5

    func load() async {
        guard items.isEmpty, !isLoading else { return }
        isLoading = true

        guard let url = URL(string: Self.feedURL) else { isLoading = false; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = RSSParser.parse(data: data, source: Self.feedSource)
            items = Array(parsed
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(Self.maxItems))
        } catch {
            // Section stays hidden on failure
        }
        isLoading = false
    }
}

// MARK: - RSS / Atom XML Parser

private final class RSSParser: NSObject, XMLParserDelegate {
    private(set) var items: [PickleballNewsItem] = []
    private let source: String

    private var inEntry = false
    private var currentTitle = ""
    private var currentLink = ""
    private var currentPubDate = ""
    private var currentImageURL: String?
    private var currentContent = ""
    private var currentSource = ""
    private var buffer = ""

    private static let rfc822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let iso8601 = ISO8601DateFormatter()

    private init(source: String) { self.source = source }

    static func parse(data: Data, source: String) -> [PickleballNewsItem] {
        let delegate = RSSParser(source: source)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        let local = elementName.lowercased()
        let qualified = (qName ?? elementName).lowercased()

        if local == "item" || local == "entry" {
            inEntry = true
            currentTitle = ""; currentLink = ""; currentPubDate = ""
            currentImageURL = nil; currentContent = ""; currentSource = ""; buffer = ""
            return
        }

        guard inEntry else { buffer = ""; return }

        // Atom: <link href="..."/> — no character content
        if local == "link", let href = attributes["href"], !href.isEmpty {
            if currentLink.isEmpty { currentLink = href }
        }

        // Image: <enclosure url="..." type="image/..."/>
        if local == "enclosure",
           let type = attributes["type"], type.hasPrefix("image"),
           let url = attributes["url"], currentImageURL == nil {
            currentImageURL = url
        }

        // Image: <media:content url="..."/> or <media:thumbnail url="..."/>
        if (qualified == "media:content" || qualified == "media:thumbnail"),
           let url = attributes["url"], currentImageURL == nil {
            currentImageURL = url
        }

        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        if let s = String(data: cdataBlock, encoding: .utf8) { buffer += s }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let local = elementName.lowercased()
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard inEntry else { buffer = ""; return }

        switch local {
        case "title":
            currentTitle = trimmed
        case "link":
            if currentLink.isEmpty { currentLink = trimmed }
        case "pubdate":
            currentPubDate = trimmed
        case "published", "updated":
            if currentPubDate.isEmpty { currentPubDate = trimmed }
        case "source":
            if currentSource.isEmpty { currentSource = trimmed }
        case "description", "summary", "content":
            currentContent = trimmed
            if currentImageURL == nil {
                currentImageURL = extractImageURL(from: trimmed)
            }
        case "item", "entry":
            commitItem()
            inEntry = false
        default:
            break
        }
        buffer = ""
    }

    private func commitItem() {
        let cleanTitle = currentTitle
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8216;", with: "\u{2018}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")

        guard !cleanTitle.isEmpty, !currentLink.isEmpty,
              let url = URL(string: currentLink) else { return }

        let resolvedSource = currentSource.isEmpty ? source : currentSource
        items.append(PickleballNewsItem(
            title: cleanTitle,
            url: url,
            source: resolvedSource,
            publishedAt: parseDate(currentPubDate),
            imageURL: currentImageURL.flatMap { URL(string: $0) }
        ))
    }

    private func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let d = Self.rfc822Formatter.date(from: raw) { return d }
        if let d = Self.iso8601.date(from: raw) { return d }
        // Try ISO without sub-seconds
        let truncated = String(raw.prefix(19)) + "Z"
        return Self.iso8601.date(from: truncated)
    }

    /// Scans HTML content for the first https image URL.
    private func extractImageURL(from html: String) -> String? {
        var search = html.startIndex
        while search < html.endIndex {
            guard let range = html.range(of: "src=\"https://", range: search..<html.endIndex) else { break }
            let valueStart = range.upperBound
            guard let closeQuote = html[valueStart...].firstIndex(of: "\"") else { break }
            let candidate = String(html[valueStart..<closeQuote])
            let lower = candidate.lowercased()
            if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                || lower.hasSuffix(".png") || lower.hasSuffix(".webp")
                || lower.contains("cdn.shopify.com") || lower.contains("wp-content") {
                return candidate
            }
            search = closeQuote
        }
        return nil
    }
}
