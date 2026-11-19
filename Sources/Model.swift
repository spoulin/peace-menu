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

/// Where a group's separator sits relative to its icons.
enum TitleSide: String, Codable, CaseIterable, Identifiable {
    case automatic, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .left: return "Left of the icons"
        case .right: return "Right of the icons"
        }
    }
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
    var titleSide: TitleSide = .automatic

    /// A name reads like a title, so it goes left; a symbol, a line, a dot or a space closes
    /// the group on its right.
    var titleOnLeft: Bool {
        switch titleSide {
        case .left: return true
        case .right: return false
        case .automatic: return style == .label
        }
    }
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
        titleSide = try c.decodeIfPresent(TitleSide.self, forKey: .titleSide) ?? .automatic
    }
}

/// What happens when an icon of a folded group changes.
enum ChangeSignal: String, Codable, CaseIterable, Identifiable {
    case off, badge, peek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Nothing"
        case .badge: return "Dot on ☮"
        case .peek: return "Dot, and show the hidden groups for a moment"
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

/// What a profile does with a group, or with the icons in no group.
enum GroupMode: String, Codable, CaseIterable, Identifiable {
    /// Always in the menu bar.
    case always
    /// Hidden; a click on ☮ shows it for a while.
    case onDemand
    /// Never shown.
    case off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return "Always"
        case .onDemand: return "On demand"
        case .off: return "Off"
        }
    }
}

struct ProfileGroup: Codable, Hashable {
    var id: UUID
    var mode: GroupMode
}

struct Profile: Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// The profile's groups, from left to right in the bar, each with its mode.
    var groups: [ProfileGroup] = []
    var ungrouped: GroupMode = .onDemand
    /// Before modes (config files up to 1.1): the groups shown, and whether ungrouped icons were.
    var legacyVisible: [UUID]? = nil
    var legacyShowUngrouped = false

    func mode(of id: UUID) -> GroupMode { groups.first { $0.id == id }?.mode ?? .off }

    mutating func setMode(_ mode: GroupMode, for id: UUID) {
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].mode = mode } else { groups.append(ProfileGroup(id: id, mode: mode)) }
    }

    /// Every group, in this profile's order; groups it doesn't know yet come last, Off.
    func entries(for all: [MenuGroup]) -> [ProfileGroup] {
        let known = Set(all.map(\.id))
        let mine = groups.filter { known.contains($0.id) }
        let seen = Set(mine.map(\.id))
        return mine + all.filter { !seen.contains($0.id) }.map { ProfileGroup(id: $0.id, mode: .off) }
    }
}

extension Profile: Codable {
    enum CodingKeys: String, CodingKey { case id, name, groups, ungrouped, visibleGroups, showUngrouped }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groups = try c.decodeIfPresent([ProfileGroup].self, forKey: .groups) ?? []
        ungrouped = try c.decodeIfPresent(GroupMode.self, forKey: .ungrouped) ?? .onDemand
        legacyVisible = try c.decodeIfPresent([UUID].self, forKey: .visibleGroups)
        legacyShowUngrouped = try c.decodeIfPresent(Bool.self, forKey: .showUngrouped) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(groups, forKey: .groups)
        try c.encode(ungrouped, forKey: .ungrouped)
    }
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
    var orderVersion = 2
    var menuIcon: MenuIcon = .classic
    /// Running apps and their notification badges, in the ☮ menu and as a red badge on ☮.
    var showApps = true
    /// Held down, shows the Dock's apps on a ring around the pointer. None by default.
    var ringShortcut: Shortcut? = nil

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
        showApps = try c.decodeIfPresent(Bool.self, forKey: .showApps) ?? true
        ringShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .ringShortcut)
    }

    static var starter: Config {
        var c = Config()
        let normal = Profile(name: "Normal")
        c.profiles = [normal, Profile(name: "Show All", ungrouped: .always), Profile(name: "Focus")]
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
            if c.orderVersion < 2 {
                // From shown groups and folding to modes. A group shown and open is Always, shown
                // but folded is On demand, not shown is Off. Before version 1, the bar's order was
                // the reverse of `groups`.
                let leftToRight = Array(c.groups.map(\.id).reversed())
                for i in c.profiles.indices {
                    var shown = c.profiles[i].legacyVisible ?? []
                    if c.orderVersion < 1 { let s = Set(shown); shown = leftToRight.filter { s.contains($0) } }
                    let folded = Set(c.groups.filter(\.collapsed).map(\.id))
                    c.profiles[i].groups = shown.map { ProfileGroup(id: $0, mode: folded.contains($0) ? .onDemand : .always) }
                    c.profiles[i].ungrouped = c.profiles[i].legacyShowUngrouped ? .always : .onDemand
                }
                c.orderVersion = 2
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
            c.profiles[i].groups.append(ProfileGroup(id: g.id, mode: .always))
        }
        config = c
        return g.id
    }

    func removeGroup(_ id: UUID) {
        var c = config
        c.groups.removeAll { $0.id == id }
        for i in c.profiles.indices { c.profiles[i].groups.removeAll { $0.id == id } }
        config = c
    }
}
