import SwiftUI

/// Search only keys on the displayed layout, so every result can open the key editor.
struct QuickSearchResult: Identifiable {
    let usage: Usage
    let title: String
    let detail: String
    let terms: [String]
    var id: Usage { usage }
}

enum QuickSearchIndex {
    static func results(query: String, keys: [KeyDef], profile: Profile?, iso: Bool) -> [QuickSearchResult] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<Usage>()
        return keys.compactMap { key -> QuickSearchResult? in
            guard !key.fixed, seen.insert(key.usage).inserted else { return nil }
            let name = Keys.name(key.usage, iso: iso)
            let legend = Keys.legend(key.usage, iso: iso)
            let action = profile?.actions[key.usage]
            let target = profile?.map[key.usage]
            let dual = profile?.dualRole[key.usage]
            let behavior = dual.map { "Tap \(Keys.name($0.tap, iso: iso)) · Hold \(Keys.name($0.hold, iso: iso))" }
            let detail = behavior ?? action.map { $0.label(iso: iso) } ?? target.map { Keys.name($0, iso: iso) } ?? "Default"
            let aliases: String
            switch key.usage {
            case HID.key(0x29): aliases = "Escape Esc"
            case HID.key(0x28): aliases = "Return Enter"
            case HID.key(0x2A): aliases = "Backspace Delete"
            case HID.key(0xE0), HID.key(0xE4): aliases = "Control Ctrl"
            case HID.key(0xE2), HID.key(0xE6): aliases = "Option Alt"
            case HID.key(0xE3), HID.key(0xE7): aliases = "Command Cmd Win Windows"
            default: aliases = ""
            }
            let terms = [aliases, name, key.label ?? "", legend.main, legend.top ?? "", detail, action?.kind.rawValue ?? ""]
            guard words.allSatisfy({ word in terms.contains { $0.localizedStandardContains(word) } }) else { return nil }
            return QuickSearchResult(usage: key.usage, title: name, detail: detail, terms: terms)
        }
    }
}

/// Embed in a popover or panel. The callback should switch to the keyboard workspace and select the usage.
private final class QuickSearchState: ObservableObject {
    @Published var query = ""
}

struct QuickSearch: View {
    @ObservedObject var store: ProfileStore
    let onSelect: (Usage) -> Void
    @StateObject private var state = QuickSearchState()

    var body: some View {
        let results = QuickSearchIndex.results(query: state.query, keys: Keys.layout(store.layout, iso: store.iso), profile: store.active, iso: store.iso)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys and mappings", text: $state.query).textFieldStyle(.plain)
                if !state.query.isEmpty {
                    Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Search the current keyboard by key, action or mapping.").font(.callout).foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("No matching keys on this layout.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { result in
                            Button { onSelect(result.usage) } label: {
                                HStack {
                                    Image(systemName: "keyboard").foregroundStyle(ForgePalette.violet).frame(width: 22)
                                    Text(result.title).fontWeight(.medium)
                                    Spacer()
                                    Text(result.detail).foregroundStyle(.secondary).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 300)
            }
        }
        .padding(16).frame(width: 360, alignment: .leading)
    }
}
