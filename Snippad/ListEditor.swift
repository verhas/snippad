import AppKit
import SwiftUI

/// The settings of one history list, in the history window's detail pane:
/// its name and icon, where copies come from, and its Paste Guard rules.
struct ListEditor: View {
    let listID: String
    @State private var store = SettingsStore.shared
    @State private var choosing = false
    @State private var choosingSources = false

    static let icons = [
        "tray", "tray.full", "folder", "briefcase", "house", "person", "person.2", "lock", "key", "shield",
        "iphone", "ipad", "laptopcomputer.and.iphone", "desktopcomputer", "laptopcomputer", "camera.viewfinder",
        "eye.slash", "globe", "network", "terminal", "chevron.left.forwardslash.chevron.right", "doc.text",
        "photo", "link", "envelope", "bubble.left", "cart", "creditcard", "star", "heart", "flag", "bookmark",
        "tag", "bolt", "flame", "leaf", "hammer", "wrench.and.screwdriver", "gamecontroller", "music.note",
        "book", "graduationcap", "building.2", "airplane", "car", "cloud", "server.rack", "cpu", "testtube.2",
    ]

    private var index: Int? { store.value.lists.firstIndex { $0.id == listID } }

    private func browserNote(_ list: ClipList) -> String {
        var text = "Stops a paste from this list into a normal browser window. Safari and Arc do not tell which windows are private, so nothing from this list is pasted into them."
        switch list.guardMode {
        case .anyApp: break
        case .onlyListed:
            text += " The browser must also be one of the applications above: \u{201C}Only these applications\u{201D} stops every other application, browsers included."
        case .allExceptListed:
            text += " The browser must also not be among the applications above: those get nothing from this list, private window or not."
        }
        return text
    }

    private var privateExplanation: String {
        let others = store.value.privateBrowsingList.flatMap { id in id == listID ? nil : store.value.lists.first { $0.id == id }?.name }
        var text = "When on, whatever you copy in a private (incognito) window of Chrome, Brave, Edge, Vivaldi, Firefox or Tor Browser goes to this list, whichever list the browser itself uses. Only one list can do this; its sidebar row shows a lock."
        if let others { text += " Now it is \u{201C}\(others)\u{201D}: switching this on moves that job here." }
        return text
    }

    var body: some View {
        if let index {
            form($store.value.lists[index])
        } else {
            ContentUnavailableView("The list is gone", systemImage: "tray")
        }
    }

    private func form(_ list: Binding<ClipList>) -> some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: list.name).textFieldStyle(.roundedBorder).labelsHidden()
                }
                LabeledContent("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 11), spacing: 4) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            Button {
                                list.wrappedValue.icon = symbol == "tray" ? nil : symbol
                            } label: {
                                Image(systemName: symbol)
                                    .frame(width: 24, height: 22)
                                    .background(list.wrappedValue.symbol == symbol ? Color.accentColor.opacity(0.3) : .clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(symbol)
                        }
                    }
                }
                Toggle("Preferred list (highlighted, and shown by the picker, ⇧⌘V)", isOn: Binding(
                    get: { store.value.preferredList == listID },
                    set: { store.value.preferredList = $0 ? listID : nil }))
                LabeledContent("Copies from") {
                    let apps = store.value.appLists.filter { $0.value == listID }.keys.sorted()
                    HStack {
                        Text(listID == ClipList.defaultID && apps.isEmpty ? "every application not assigned elsewhere"
                             : apps.isEmpty ? "no application yet"
                             : apps.map(AppCatalog.shared.name(for:)).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Applications…") { choosingSources = true }
                            .help("Tick the applications whose copies go to this list")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { store.value.privateBrowsingList == listID },
                        set: { store.value.privateBrowsingList = $0 ? listID : nil })) {
                        Label("Collects every copy made in a private browser window", systemImage: "lock.fill")
                    }
                    Text(privateExplanation)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(
                    get: { (store.value.screenshotList ?? ClipList.defaultID) == listID },
                    set: { store.value.screenshotList = $0 ? listID : nil })) {
                    Label("Screenshots go to this list", systemImage: "camera.viewfinder")
                }
                .help("Take Screenshot in the menu bar puts its pictures here; only one list can have them, the first list unless another is chosen")
                Toggle(isOn: Binding(
                    get: { store.value.remoteList == listID },
                    set: {
                        store.value.remoteList = $0 ? listID : nil
                        if $0 { store.value.remoteListOptOut = false }
                    })) {
                    Label("Collects every copy from iPhone, iPad and other Macs", systemImage: "laptopcomputer.and.iphone")
                }
                .help("Universal Clipboard copies from all your other devices go to this one list; only one list can do this")
            }
            Section("Paste Guard") {
                Picker("May be pasted into", selection: list.guardMode) {
                    Text("Any application").tag(GuardMode.anyApp)
                    Text("Only these applications").tag(GuardMode.onlyListed)
                    Text("Any application except these").tag(GuardMode.allExceptListed)
                }
                if list.wrappedValue.guardMode != .anyApp {
                    ForEach(list.wrappedValue.guardApps, id: \.self) { id in
                        HStack {
                            Image(nsImage: AppCatalog.shared.icon(for: id)).resizable().frame(width: 16, height: 16)
                            Text(AppCatalog.shared.name(for: id))
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") { list.wrappedValue.guardApps.removeAll { $0 == id } }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                    Button("Add Application…") { choosing = true }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("In web browsers, only into private windows", isOn: list.privateBrowsingOnly)
                    Text(browserNote(list.wrappedValue))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !store.value.pasteGuardEnabled {
                    HStack {
                        Label("The Paste Guard is off; these rules apply once it is switched on.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Switch On") { store.value.pasteGuardEnabled = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $choosingSources) {
            SourceAppsChooser(listID: listID)
        }
        .sheet(isPresented: $choosing) {
            AppChooser { id in
                if !list.wrappedValue.guardApps.contains(id) { list.wrappedValue.guardApps.append(id) }
            }
        }
    }
}

/// Picks an application from the catalog, or from the disk.
struct AppChooser: View {
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?

    private var apps: [AppRecord] {
        AppCatalog.shared.sorted.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack {
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(apps, selection: $selection) { app in
                HStack {
                    Image(nsImage: AppCatalog.shared.icon(for: app.bundleID)).resizable().frame(width: 16, height: 16)
                    Text(app.name)
                }
                .tag(app.bundleID)
            }
            HStack {
                Button("Other…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
                        choose(id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let selection { choose(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding()
        .frame(width: 380, height: 440)
    }
}

/// Seen from the list: tick the applications whose copies go to it. The
/// same setting as the List column of Settings > Applications, approached
/// from the other side.
private struct SourceAppsChooser: View {
    let listID: String
    @Environment(\.dismiss) private var dismiss
    @State private var store = SettingsStore.shared
    @State private var query = ""
    @State private var onlyTicked = false

    private var isDefault: Bool { listID == ClipList.defaultID }

    private func goesHere(_ app: AppRecord) -> Bool { store.listID(for: app.bundleID) == listID }

    private var apps: [AppRecord] {
        AppCatalog.shared.sorted.filter { app in
            (query.isEmpty || app.name.localizedCaseInsensitiveContains(query) || app.bundleID.localizedCaseInsensitiveContains(query))
                && (!onlyTicked || goesHere(app))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copies from the ticked applications go to \u{201C}\(store.list(listID).name)\u{201D}.").font(.headline)
            if isDefault {
                Text("This is the first list: every application not given another list sends its copies here. Untick an application by giving it another list, from that list or in Settings > Applications.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Ticking an application that goes to another list moves it here; unticking sends its copies back to \u{201C}\(store.value.lists[0].name)\u{201D}.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search applications", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Only ticked", isOn: $onlyTicked)
            }
            List(apps) { app in
                HStack {
                    Toggle(isOn: Binding(
                        get: { goesHere(app) },
                        set: { on in store.value.appLists[app.bundleID] = on && !isDefault ? listID : nil })) {
                        HStack {
                            Image(nsImage: AppCatalog.shared.icon(for: app.bundleID)).resizable().frame(width: 16, height: 16)
                            Text(app.name)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isDefault && goesHere(app))
                    Spacer()
                    let current = store.listID(for: app.bundleID)
                    if current != listID {
                        Text("now: \(store.list(current).name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480, height: 520)
    }
}
