import SwiftUI
import AppKit

// MARK: - Models

enum ServiceHealth: String {
    case operational = "operational"
    case incident = "incident"
    case error = "error"
    case checking = "checking"

    var icon: String {
        switch self {
        case .operational: return "●"
        case .incident:    return "▲"
        case .error:       return "■"
        case .checking:    return "○"
        }
    }

    var color: Color {
        switch self {
        case .operational: return .green
        case .incident:    return .orange
        case .error:       return .red
        case .checking:    return .secondary
        }
    }
}

struct ServiceStatus: Identifiable {
    let id: String
    let name: String
    var health: ServiceHealth = .checking
    var message: String = "Checking…"
    var incidentURL: String? = nil
    var lastCheck: Date? = nil
    let feedURL: String
    let statusPageURL: String
}

// MARK: - RSS Parser

struct RSSItem {
    var title: String = ""
    var link: String = ""
    var pubDate: String = ""
    var description: String = ""
}

class RSSParser: NSObject, XMLParserDelegate {
    private var items: [RSSItem] = []
    private var currentItem: RSSItem?
    private var currentElement: String = ""
    private var currentText: String = ""
    private var insideItem = false

    func parse(data: Data) -> [RSSItem] {
        items = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" || elementName == "entry" {
            insideItem = true
            currentItem = RSSItem()
        }
        // Atom link
        if elementName == "link", insideItem, let href = attributes["href"] {
            currentItem?.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem {
            switch elementName {
            case "title": currentItem?.title = text
            case "link": if currentItem?.link.isEmpty == true { currentItem?.link = text }
            case "pubDate", "published", "updated": currentItem?.pubDate = text
            case "description", "content", "summary": currentItem?.description = text
            default: break
            }
        }
        if elementName == "item" || elementName == "entry" {
            if let item = currentItem {
                items.append(item)
            }
            insideItem = false
            currentItem = nil
        }
    }
}

// MARK: - Date Parsing

private let dateFormatters: [DateFormatter] = {
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
    ]
    return formats.map { fmt in
        let df = DateFormatter()
        df.dateFormat = fmt
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }
}()

func parseDate(_ string: String) -> Date? {
    for formatter in dateFormatters {
        if let date = formatter.date(from: string) { return date }
    }
    return nil
}

// MARK: - Status Monitor

class StatusMonitor: ObservableObject {
    private var started = false

    @Published var services: [ServiceStatus] = [
        ServiceStatus(
            id: "claude", name: "Claude",
            feedURL: "https://status.anthropic.com/history.rss",
            statusPageURL: "https://status.anthropic.com"
        ),
        ServiceStatus(
            id: "openai", name: "OpenAI",
            feedURL: "https://status.openai.com/history.rss",
            statusPageURL: "https://status.openai.com"
        ),
    ]

    @Published var lastRefresh: Date? = nil

    private var timer: Timer?

    var overallHealth: ServiceHealth {
        let healths = services.map(\.health)
        if healths.contains(.error) || healths.filter({ $0 == .incident }).count > 1 {
            return .error
        }
        if healths.contains(.incident) {
            return .incident
        }
        if healths.contains(.checking) {
            return .checking
        }
        return .operational
    }

    var menuBarIcon: String {
        overallHealth.icon
    }

    func startMonitoring() {
        guard !started else { return }
        started = true
        checkAll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.checkAll()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func checkAll() {
        for i in services.indices {
            checkService(index: i)
        }
    }

    private func checkService(index: Int) {
        let service = services[index]
        guard let url = URL(string: service.feedURL) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.services[index].health = .error
                    self.services[index].message = "Fetch error: \(error.localizedDescription)"
                    self.services[index].lastCheck = Date()
                    return
                }

                guard let data = data else {
                    self.services[index].health = .error
                    self.services[index].message = "No data received"
                    self.services[index].lastCheck = Date()
                    return
                }

                let parser = RSSParser()
                let items = parser.parse(data: data)
                self.processItems(items, forIndex: index)
                self.services[index].lastCheck = Date()
                self.lastRefresh = Date()
            }
        }.resume()
    }

    private func processItems(_ items: [RSSItem], forIndex index: Int) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        // Find recent incidents (last 24h)
        let recentItems = items.filter { item in
            if let date = parseDate(item.pubDate) {
                return date > cutoff
            }
            return false
        }

        if recentItems.isEmpty {
            services[index].health = .operational
            services[index].message = "All systems operational"
            services[index].incidentURL = nil
            return
        }

        // Check if the most recent incident is resolved
        let latest = recentItems.first!
        let titleLower = latest.title.lowercased()
        let descLower = latest.description.lowercased()

        if titleLower.contains("resolved") || descLower.contains("resolved") ||
           titleLower.contains("completed") || descLower.contains("this incident has been resolved") {
            services[index].health = .operational
            services[index].message = "Resolved: \(truncate(latest.title, to: 40))"
        } else {
            services[index].health = .incident
            services[index].message = truncate(latest.title, to: 50)
        }
        services[index].incidentURL = latest.link.isEmpty ? nil : latest.link
    }

    private func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }
}

// MARK: - Menu Bar View

struct StatusMenuView: View {
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("AI Service Status")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()

            // Services
            ForEach(monitor.services) { service in
                ServiceRow(service: service)
            }

            Divider()

            // Last refresh
            if let last = monitor.lastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            // Actions
            Button(action: { monitor.checkAll() }) {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .padding(.bottom, 4)
        }
        .frame(width: 280)
    }
}

struct ServiceRow: View {
    let service: ServiceStatus

    var body: some View {
        Button(action: {
            let urlStr = service.incidentURL ?? service.statusPageURL
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Text(service.health.icon)
                    .foregroundColor(service.health.color)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(service.message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App

@main
struct AIStatusMonitorApp: App {
    @StateObject private var monitor: StatusMonitor = {
        let m = StatusMonitor()
        m.startMonitoring()
        return m
    }()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(monitor: monitor)
        } label: {
            Text(monitor.menuBarIcon)
                .font(.system(size: 12))
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 280, height: 200)
    }
}
