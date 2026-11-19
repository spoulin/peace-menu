import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var live: LiveItemsModel
    let controller: Controller

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GroupsTab(store: store, live: live, controller: controller)
                    .tabItem { Label("Groups", systemImage: "square.grid.2x2") }
                ProfilesTab(store: store, controller: controller)
                    .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
                GeneralTab(store: store, controller: controller)
                    .tabItem { Label("General", systemImage: "gearshape") }
            }
            .padding([.horizontal, .top])
            Divider().padding(.top, 8)
            HStack {
                Text("Changes to groups apply to the menu bar when you click Arrange Menu Bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Arrange Menu Bar") { controller.applyLayout(thenHide: controller.isHidden) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

// MARK: - Groups

struct GroupsTab: View {
    @ObservedObject var store: Store
    @ObservedObject var live: LiveItemsModel
    let controller: Controller
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.config.groups) { g in
                        Label(g.name, systemImage: g.symbol).tag(g.id)
                    }
                    .onMove { store.config.groups.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 4) {
                    Button { selection = store.addGroup(named: "New Group") } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection { selection = nil; store.removeGroup(id) }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                Text("Each profile sets the order of its groups in the menu bar (Profiles tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 210)

            if let id = selection, store.config.groups.contains(where: { $0.id == id }) {
                GroupDetail(store: store, live: live, groupID: id, controller: controller)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Create a group with +, then add icons to it.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .onAppear { if selection == nil { selection = store.config.groups.first?.id } }
    }
}

struct GroupDetail: View {
    @ObservedObject var store: Store
    @ObservedObject var live: LiveItemsModel
    let groupID: UUID
    let controller: Controller

    private var group: Binding<MenuGroup> {
        Binding(
            get: { store.config.groups.first { $0.id == groupID } ?? MenuGroup(name: "") },
            set: { new in
                if let i = store.config.groups.firstIndex(where: { $0.id == groupID }) { store.config.groups[i] = new }
            })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: group.name)
                Picker("Separator", selection: group.style) {
                    ForEach(SeparatorStyle.allCases) { Text($0.title).tag($0) }
                }
                // With Automatic, the style decides the side.
                .onChange(of: group.wrappedValue.style) { old, new in
                    if group.wrappedValue.titleSide == .automatic && (old == .label) != (new == .label) {
                        controller.applyLayout(thenHide: controller.isHidden)
                    }
                }
                if group.wrappedValue.style == .symbol {
                    HStack {
                        TextField("SF Symbol", text: group.symbol)
                        Image(systemName: group.wrappedValue.symbol)
                    }
                }
                HStack {
                    Toggle("Color", isOn: Binding(
                        get: { group.wrappedValue.color != nil },
                        set: { group.wrappedValue.color = $0 ? (group.wrappedValue.color ?? "#FF9F0A") : nil }))
                    Spacer()
                    if group.wrappedValue.color != nil {
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: group.wrappedValue.color.flatMap(NSColor.init(hex:)) ?? .systemOrange) },
                            set: { group.wrappedValue.color = NSColor($0).hex }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Picker("Separator position", selection: group.titleSide) {
                    ForEach(TitleSide.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: group.wrappedValue.titleSide) { _, _ in controller.applyLayout(thenHide: controller.isHidden) }
                Text("Automatic: a name goes left of the icons, like a title; a symbol, a line, a dot or a space goes right. Whether this group shows is set by each profile (Profiles tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Icons in this group (right to left)") {
                if group.wrappedValue.items.isEmpty {
                    Text("No icons yet. Add some from the list below.").foregroundStyle(.secondary)
                }
                List {
                    ForEach(group.wrappedValue.items) { ref in
                        HStack {
                            ItemIcon(bundleID: ref.bundleID)
                            Text(ref.name)
                            if !live.items.contains(where: { $0.key == ref.key }) {
                                Text("not running").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { group.wrappedValue.items.removeAll { $0.key == ref.key } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    .onMove { group.wrappedValue.items.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 90)
            }
            Section("Add a menu bar icon") {
                let free = live.items.filter { item in !group.wrappedValue.items.contains { $0.key == item.key } }
                if free.isEmpty { Text("Every icon is already in this group.").foregroundStyle(.secondary) }
                ForEach(free, id: \.key) { item in
                    HStack {
                        ItemIcon(bundleID: item.bundleID)
                        Text(item.name)
                        if let gi = store.groupIndex(containing: item.key) {
                            Text("in “\(store.config.groups[gi].name)”").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.assign(item.ref, to: groupID) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ItemIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed").frame(width: 18, height: 18)
        }
    }
}

// MARK: - Profiles

struct ProfilesTab: View {
    @ObservedObject var store: Store
    let controller: Controller
    @State private var selection: UUID?

    private func binding(_ id: UUID) -> Binding<Profile> {
        Binding(
            get: { store.config.profiles.first { $0.id == id } ?? Profile(name: "") },
            set: { new in
                if let i = store.config.profiles.firstIndex(where: { $0.id == id }) { store.config.profiles[i] = new }
            })
    }

    private func modePicker(_ g: MenuGroup, in p: Binding<Profile>) -> some View {
        Picker(selection: Binding(
            get: { p.wrappedValue.mode(of: g.id) },
            set: { p.wrappedValue.setMode($0, for: g.id) })) {
            ForEach(GroupMode.allCases) { Text($0.title).tag($0) }
        } label: { Label(g.name, systemImage: g.symbol) }
    }

    private func move(_ id: UUID, by step: Int, in p: Binding<Profile>) {
        var list = p.wrappedValue.entries(for: store.config.groups)
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + step) else { return }
        list.swapAt(i, i + step)
        p.wrappedValue.groups = list
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.config.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == store.activeProfile?.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }.tag(p.id)
                    }
                    .onMove { store.config.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 4) {
                    Button {
                        let p = Profile(name: "New Profile", groups: store.config.groups.map { ProfileGroup(id: $0.id, mode: .always) })
                        store.config.profiles.append(p)
                        selection = p.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection, store.config.profiles.count > 1 {
                            selection = nil
                            store.config.profiles.removeAll { $0.id == id }
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || store.config.profiles.count < 2)
                    Spacer()
                }
                .buttonStyle(.borderless)
            }
            .frame(width: 210)

            if let id = selection, store.config.profiles.contains(where: { $0.id == id }) {
                let p = binding(id)
                Form {
                    Section { TextField("Name", text: p.name) }
                    Section {
                        if store.config.groups.isEmpty {
                            Text("No groups yet.").foregroundStyle(.secondary)
                        }
                        let groups = p.wrappedValue.entries(for: store.config.groups).compactMap { e in store.config.groups.first { $0.id == e.id } }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                            HStack {
                                modePicker(g, in: p)
                                Button { move(g.id, by: -1, in: p) } label: { Image(systemName: "chevron.up") }
                                    .disabled(i == 0).help("Move left")
                                Button { move(g.id, by: 1, in: p) } label: { Image(systemName: "chevron.down") }
                                    .disabled(i == groups.count - 1).help("Move right")
                            }
                            .buttonStyle(.borderless)
                        }
                        Picker(selection: p.ungrouped) {
                            ForEach(GroupMode.allCases) { Text($0.title).tag($0) }
                        } label: { Label("Icons in no group", systemImage: "square.dashed") }
                    } header: {
                        Text("Groups")
                    } footer: {
                        Text("Always: in the menu bar. On demand: hidden, a click on ☮ shows it for a while. Off: never shown. Top to bottom is left to right in the menu bar.")
                    }
                    Section {
                        Button(id == store.activeProfile?.id ? "Reapply This Profile" : "Activate This Profile") {
                            controller.activateProfile(id)
                        }
                    } footer: {
                        Text("Changes to the active profile apply right away.")
                    }
                }
                .formStyle(.grouped)
                // The active profile applies its changes right away.
                .onChange(of: p.wrappedValue.groups) { _, _ in
                    if id == store.activeProfile?.id { controller.activateProfile(id) }
                }
                .onChange(of: p.wrappedValue.ungrouped) { _, _ in
                    if id == store.activeProfile?.id { controller.activateProfile(id) }
                }
            } else {
                Text("Choose a profile.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .onAppear { if selection == nil { selection = store.activeProfile?.id } }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store: Store
    let controller: Controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Menu bar icon") {
                Picker("☮", selection: $store.config.menuIcon) {
                    ForEach(MenuIcon.allCases) { Text($0.title).tag($0) }
                }
                Text("The colored icons are bright on a dark menu bar and darker on a light one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Showing hidden icons") {
                Picker("Hide again after", selection: $store.config.autoHideDelay) {
                    Text("Never").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
                Toggle("Hide them at launch", isOn: $store.config.hideOnLaunch)
                Text("A click on ☮ shows what the profile has On demand; it hides again after this delay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On demand groups") {
                Picker("When an icon changes", selection: $store.config.changeSignal) {
                    ForEach(ChangeSignal.allCases) { Text($0.title).tag($0) }
                }
                Text("PeaceMenu sees a change when an app changes its icon's text or width. macOS doesn't draw hidden icons, so a change of picture alone (a Slack badge, for example) goes unnoticed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Running apps") {
                Toggle("Show running apps and notifications", isOn: $store.config.showApps)
                Toggle("Show the number of notifications on ☮", isOn: $store.config.badgeOnIcon)
                    .disabled(!store.config.showApps)
                Text("Right-click ☮ to see the running apps and the ones with a notification; choose one to bring it to the front, or one of its windows when it has several. Hold ⌥ to force quit it. When an app has a badge in the Dock (unread mail, for example), a red badge on ☮ shows the total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App switcher") {
                LabeledContent("Shortcut") { ShortcutRecorder(shortcut: $store.config.switcherShortcut) }
                Picker("Show on", selection: $store.config.switcherScreens) {
                    ForEach(SwitcherScreens.allCases) { Text($0.title).tag($0) }
                }
                Text("Press the shortcut: the apps of the Dock show in a grid, with their badges: the ones with a badge first, above a line, then the others; in each, the ones you use most first. Move with the arrows or type the start of a name, then press Return. As with ⌘⇥, you can also keep the modifier down, press the key again to move to the next app, and let go to open it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open PeaceMenu at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Permissions") {
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                        Text("To read the menu bar icons and move them.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !axTrusted { Button("Open Settings") { controller.openAccessibility() } }
                }
            }
            Section("How to use") {
                Text("Click ☮: show or hide the hidden icons.\nRight-click or ⌥-click ☮: profiles, groups and settings.\nClick a group title: show or fold its icons. Right-click it: the group's menu.\n⌘-drag an icon right of ☮: it always stays visible.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }
}
