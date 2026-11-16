import Foundation
import Combine

/// How a group's separator looks in the menu bar.
enum SeparatorStyle: String, Codable, CaseIterable, Identifiable {
    case line, dot, label, symbol, space
    var id: String { rawValue }
    var title: String {
        switch self {
        case .line: return "Line"
        case .dot: return "Dot"
        case .label: return "Group name"
        case .symbol: return "Symbol"
        case .space: return "Blank space"
        }
    }
}

/// A menu bar item remembered by the configuration. `key` is stable across launches:
/// the item's accessibility identifier, else "<bundle id>#<index within its app>".
struct ItemRef: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var bundleID: String
    var id: String { key }
}

struct MenuGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol = "square.grid.2x2"
    var style: SeparatorStyle = .line
    var items: [ItemRef] = []
    /// Only the separator is in the bar; the icons wait behind ‹. A click on the separator
    /// shows or folds them.
    var collapsed = false
    /// The color of the group's title in the menu bar, as "#RRGGBB"; nil follows the menu bar.
    var color: String? = nil
}

extension MenuGroup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2"
        style = try c.decodeIfPresent(SeparatorStyle.self, forKey: .style) ?? .line
        items = try c.decodeIfPresent([ItemRef].self, forKey: .items) ?? []
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

/// What happens when an icon of a folded group changes.
enum ChangeSignal: String, Codable, CaseIterable, Identifiable {
    case off, badge, peek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Nothing"
        case .badge: return "Dot on the group title"
        case .peek: return "Dot, and show the icon for a moment"
        }
    }
}

/// How ☮ looks in the menu bar.
enum MenuIcon: String, Codable, CaseIterable, Identifiable {
    case classic, rainbow, stripes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .rainbow: return "Rainbow"
        case .stripes: return "70s stripes"
        }
    }
}

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// The groups this profile shows, from left to right in the bar.
    var visibleGroups: [UUID] = []
    var showUngrouped = false
}

struct Config: Codable {
    var groups: [MenuGroup] = []
    var profiles: [Profile] = []
    var activeProfile: UUID?
    /// Seconds before revealed icons hide again; 0 means never.
    var autoHideDelay: Double = 10
    var hideOnLaunch = true
    var changeSignal: ChangeSignal = .peek
    /// 1 once each profile's visibleGroups is in bar order (left to right). Before, the bar
    /// followed the order of `groups`, first group rightmost.
    var orderVersion = 1
    var menuIcon: MenuIcon = .classic

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([MenuGroup].self, forKey: .groups) ?? []
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        activeProfile = try c.decodeIfPresent(UUID.self, forKey: .activeProfile)
        autoHideDelay = try c.decodeIfPresent(Double.self, forKey: .autoHideDelay) ?? 10
        hideOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .hideOnLaunch) ?? true
        changeSignal = try c.decodeIfPresent(ChangeSignal.self, forKey: .changeSignal) ?? .peek
        orderVersion = try c.decodeIfPresent(Int.self, forKey: .orderVersion) ?? 0
        menuIcon = try c.decodeIfPresent(MenuIcon.self, forKey: .menuIcon) ?? .classic
    }

    static var starter: Config {
        var c = Config()
        let normal = Profile(name: "Normal")
        c.profiles = [normal, Profile(name: "Show All", showUngrouped: true), Profile(name: "Focus")]
        c.activeProfile = normal.id
        return c
    }
}

/// Holds the configuration and saves it to
/// ~/Library/Application Support/PeaceMenu/config.json on every change.
final class Store: ObservableObject {
    static let shared = Store()

    @Published var config: Config {
        didSet { save(); onChange?() }
    }
    var onChange: (() -> Void)?

    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeaceMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(Config.self, from: data) {
            if c.orderVersion < 1 {
                // Keep the bar as it looks: put each profile's groups in the order the bar used.
                let leftToRight = c.groups.map(\.id).reversed()
                for i in c.profiles.indices {
                    let shown = Set(c.profiles[i].visibleGroups)
                    c.profiles[i].visibleGroups = leftToRight.filter { shown.contains($0) }
                }
                c.orderVersion = 1
            }
            config = c
            save()
        } else {
            config = .starter
            save()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) { try? data.write(to: url, options: .atomic) }
    }

    var activeProfile: Profile? {
        config.profiles.first { $0.id == config.activeProfile } ?? config.profiles.first
    }

    func groupIndex(containing key: String) -> Int? {
        config.groups.firstIndex { $0.items.contains { $0.key == key } }
    }

    /// Puts an item in a group, taking it out of any other group first.
    func assign(_ ref: ItemRef, to groupID: UUID) {
        var c = config
        for i in c.groups.indices { c.groups[i].items.removeAll { $0.key == ref.key } }
        if let i = c.groups.firstIndex(where: { $0.id == groupID }) { c.groups[i].items.append(ref) }
        config = c
    }

    func addGroup(named name: String) -> UUID {
        let g = MenuGroup(name: name)
        var c = config
        c.groups.append(g)
        // A new group shows in the active profile; the others are edited by hand.
        if let i = c.profiles.firstIndex(where: { $0.id == (c.activeProfile ?? c.profiles.first?.id) }) {
            c.profiles[i].visibleGroups.append(g.id)
        }
        config = c
        return g.id
    }

    func removeGroup(_ id: UUID) {
        var c = config
        c.groups.removeAll { $0.id == id }
        for i in c.profiles.indices { c.profiles[i].visibleGroups.removeAll { $0 == id } }
        config = c
    }
}
