import SwiftUI

/// Third-party components linked into Brêge and their licenses (generated at build time by
/// scripts/generate-notices.py).
struct AcknowledgementsView: View {
    struct Component: Decodable, Identifiable, Hashable {
        let name: String
        let version: String
        let license: String
        let homepage: String
        let text: String?
        var id: String { name + version }
    }

    private struct Notices: Decodable {
        let components: [Component]
        let texts: [String: String]
    }

    @State private var notices: Notices?
    @State private var selection: Component?
    @State private var search = ""

    private var components: [Component] {
        let all = notices?.components ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? all : all.filter { $0.name.lowercased().contains(query) || $0.license.lowercased().contains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(components, selection: $selection) { component in
                VStack(alignment: .leading, spacing: 1) {
                    Text(component.name)
                    Text(component.license).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(component)
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let component = selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(component.name).font(.title2.weight(.semibold))
                        Text("Version \(component.version) · \(component.license)").foregroundStyle(.secondary)
                        if let url = URL(string: component.homepage), !component.homepage.isEmpty {
                            Link(component.homepage, destination: url).font(.callout)
                        }
                        Divider().padding(.vertical, 4)
                        Text(LicenseText.reflow(component.text.flatMap { notices?.texts[$0] } ?? ""))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Brêge is built with open-source software.").font(.headline)
                    Text("\(notices?.components.count ?? 0) components. Select one to read its license.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear(perform: load)
    }

    private func load() {
        guard notices == nil, let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        notices = try? JSONDecoder().decode(Notices.self, from: data)
    }
}

/// License files are wrapped at about 80 columns; shown in a narrower window those breaks land
/// mid-sentence. Joins the lines of each paragraph so the text wraps to the window. Blank lines,
/// list items, copyright lines, separator lines and lines after a short line (headings, addresses)
/// keep their own line.
enum LicenseText {
    static func reflow(_ text: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        var previous = ""
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
            } else if current.isEmpty {
                current = line
            } else if previous.count < 40 || startsOwnLine(line) || isSeparator(line) || isSeparator(previous) {
                current += "\n" + line
            } else if previous.hasSuffix("-"), previous.dropLast().last?.isLetter == true {
                current += line
            } else {
                current += " " + line
            }
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func startsOwnLine(_ line: String) -> Bool {
        line.range(of: #"^([-*•·]|\(?[0-9A-Za-z]{1,3}[.)])\s"#, options: .regularExpression) != nil
            || line.hasPrefix("Copyright") || line.hasPrefix("©")
    }

    private static func isSeparator(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { "=-_*#~".contains($0) }
    }
}
