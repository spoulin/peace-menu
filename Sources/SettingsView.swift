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
                    .tabItem { Label("Groupes", systemImage: "square.grid.2x2") }
                ProfilesTab(store: store, controller: controller)
                    .tabItem { Label("Profils", systemImage: "person.crop.rectangle.stack") }
                GeneralTab(store: store, controller: controller)
                    .tabItem { Label("Général", systemImage: "gearshape") }
            }
            .padding([.horizontal, .top])
            Divider().padding(.top, 8)
            HStack {
                Text("Les changements de groupes s'appliquent à la barre quand tu cliques « Ranger la barre ».")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ranger la barre") { controller.applyLayout(thenHide: controller.isHidden) }
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
                    Button { selection = store.addGroup(named: "Nouveau groupe") } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection { selection = nil; store.removeGroup(id) }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                Text("Le premier groupe est le plus près de ☮. Glisse pour changer l'ordre.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 210)

            if let id = selection, store.config.groups.contains(where: { $0.id == id }) {
                GroupDetail(store: store, live: live, groupID: id, controller: controller)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Crée un groupe avec +, puis ajoutes-y des icônes.").foregroundStyle(.secondary)
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
                TextField("Nom", text: group.name)
                Picker("Séparateur", selection: group.style) {
                    ForEach(SeparatorStyle.allCases) { Text($0.title).tag($0) }
                }
                if group.wrappedValue.style == .symbol {
                    HStack {
                        TextField("Symbole SF", text: group.symbol)
                        Image(systemName: group.wrappedValue.symbol)
                    }
                }
                Toggle("Icônes repliées", isOn: Binding(
                    get: { group.wrappedValue.collapsed },
                    set: { controller.setCollapsed(groupID, $0) }))
                Text("Le séparateur reste dans la barre tant que le groupe fait partie du profil ; un clic dessus affiche ou replie les icônes du groupe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Icônes du groupe (de droite à gauche)") {
                if group.wrappedValue.items.isEmpty {
                    Text("Aucune icône. Ajoute-en depuis la liste ci-dessous.").foregroundStyle(.secondary)
                }
                List {
                    ForEach(group.wrappedValue.items) { ref in
                        HStack {
                            ItemIcon(bundleID: ref.bundleID)
                            Text(ref.name)
                            if !live.items.contains(where: { $0.key == ref.key }) {
                                Text("absente").font(.caption).foregroundStyle(.secondary)
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
            Section("Ajouter une icône de la barre") {
                let free = live.items.filter { item in !group.wrappedValue.items.contains { $0.key == item.key } }
                if free.isEmpty { Text("Toutes les icônes sont déjà dans ce groupe.").foregroundStyle(.secondary) }
                ForEach(free, id: \.key) { item in
                    HStack {
                        ItemIcon(bundleID: item.bundleID)
                        Text(item.name)
                        if let gi = store.groupIndex(containing: item.key) {
                            Text("dans « \(store.config.groups[gi].name) »").font(.caption).foregroundStyle(.secondary)
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
                        let p = Profile(name: "Nouveau profil", visibleGroups: store.config.groups.map(\.id))
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
                    Section { TextField("Nom", text: p.name) }
                    Section("Groupes affichés") {
                        if store.config.groups.isEmpty {
                            Text("Aucun groupe pour l'instant.").foregroundStyle(.secondary)
                        }
                        ForEach(store.config.groups) { g in
                            Toggle(isOn: Binding(
                                get: { p.wrappedValue.visibleGroups.contains(g.id) },
                                set: { on in
                                    p.wrappedValue.visibleGroups.removeAll { $0 == g.id }
                                    if on { p.wrappedValue.visibleGroups.append(g.id) }
                                })) { Label(g.name, systemImage: g.symbol) }
                        }
                        Toggle("Icônes sans groupe", isOn: p.showUngrouped)
                    }
                    Section {
                        Button(id == store.activeProfile?.id ? "Réappliquer ce profil" : "Activer ce profil") {
                            controller.activateProfile(id)
                        }
                    } footer: {
                        Text("Tout ce qui n'est pas affiché va derrière ‹ et apparaît d'un clic sur ☮.")
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Choisis un profil.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Section("Masquage") {
                Picker("Remasquer automatiquement après", selection: $store.config.autoHideDelay) {
                    Text("Jamais").tag(0.0)
                    Text("5 secondes").tag(5.0)
                    Text("10 secondes").tag(10.0)
                    Text("30 secondes").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
                Toggle("Masquer les icônes au démarrage", isOn: $store.config.hideOnLaunch)
            }
            Section("Groupes repliés") {
                Picker("Quand une icône change", selection: $store.config.changeSignal) {
                    ForEach(ChangeSignal.allCases) { Text($0.title).tag($0) }
                }
                Text("PeaceMenu voit un changement quand l'app modifie le texte ou la largeur de son icône. macOS ne dessine pas les icônes cachées : un changement d'image seule (une pastille Slack, par exemple) passe inaperçu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Démarrage") {
                Toggle("Ouvrir PeaceMenu à l'ouverture de session", isOn: $launchAtLogin)
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
                        Text("Accessibilité")
                        Text("Pour lire les icônes de la barre et les déplacer.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !axTrusted { Button("Ouvrir les réglages") { controller.openAccessibility() } }
                }
            }
            Section("Utilisation") {
                Text("Clic sur ☮ : afficher ou masquer les icônes cachées.\nClic droit ou ⌥-clic sur ☮ : profils, groupes et réglages.\nClic sur un séparateur : masquer son groupe.\n⌘-glisser une icône à droite de ☮ : elle reste toujours visible.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }
}
