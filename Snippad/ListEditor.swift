import AppKit
import SwiftUI

/// The settings of one history list, in the history window's detail pane:
/// its name and icon, where copies come from, and its Paste Guard rules.
struct ListEditor: View {
    let listID: String
    @State private var store = SettingsStore.shared
    @State private var choosing = false

    static let icons = [
        "tray", "tray.full", "folder", "briefcase", "house", "person", "person.2", "lock", "key", "shield",
        "eye.slash", "globe", "network", "terminal", "chevron.left.forwardslash.chevron.right", "doc.text",
        "photo", "link", "envelope", "bubble.left", "cart", "creditcard", "star", "heart", "flag", "bookmark",
        "tag", "bolt", "flame", "leaf", "hammer", "wrench.and.screwdriver", "gamecontroller", "music.note",
        "book", "graduationcap", "building.2", "airplane", "car", "cloud", "server.rack", "cpu", "testtube.2",
    ]

    private var index: Int? { store.value.lists.firstIndex { $0.id == listID } }

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
                Toggle("Preferred list (highlighted, and shown by ⇧⌘V)", isOn: Binding(
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
                        Button("Choose Applications…") { SettingsWindow.show(tab: .applications, appsOfList: listID) }
                            .help("Opens Settings > Applications, showing the applications whose copies go to this list; switch the filter off there to assign others")
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
                Toggle("In web browsers, only into private windows", isOn: list.privateBrowsingOnly)
                    .help("Stops a paste from this list into a normal browser window. Safari does not tell which windows are private, so with this on nothing from this list is pasted into Safari.")
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
