import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            RecentsView().tabItem { Label("Naujausi", systemImage: "clock") }.tag(AppModel.Tab.recents)
            ContactsView().tabItem { Label("Kontaktai", systemImage: "person.crop.circle") }.tag(AppModel.Tab.contacts)
            KeypadView().tabItem { Label("Klaviatura", systemImage: "circle.grid.3x3") }.tag(AppModel.Tab.keypad)
            CRMView().tabItem { Label("CRM", systemImage: "briefcase") }.tag(AppModel.Tab.crm)
        }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
    }
}

private struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            List(model.recentCalls) { item in
                Button { model.call(number: item.phoneNumber) } label: {
                    HStack {
                        Image(systemName: item.direction == "incoming" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .foregroundStyle(item.answered ? .primary : .red)
                        VStack(alignment: .leading) {
                            Text(item.displayName ?? item.phoneNumber).foregroundStyle(.primary)
                            Text(item.phoneNumber).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.startedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if model.recentCalls.isEmpty { ContentUnavailableView("Skambuciu nera", systemImage: "phone") } }
            .navigationTitle("Naujausi")
            .toolbar { Button { Task { await model.loadRecents() } } label: { Image(systemName: "arrow.clockwise") } }
        }
    }
}

private struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(filtered) { contact in
                Button { model.call(number: contact.number) } label: {
                    VStack(alignment: .leading) {
                        Text(contact.name).foregroundStyle(.primary)
                        Text(contact.number).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if model.contacts.permissionDenied {
                    ContentUnavailableView("Kontaktai nepasiekiami", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
            .searchable(text: $search, prompt: "Vardas arba numeris")
            .navigationTitle("Kontaktai")
            .task { await model.contacts.load() }
        }
    }

    private var filtered: [PhoneContact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.number.contains(search) }
    }
}

private struct KeypadView: View {
    @EnvironmentObject private var model: AppModel
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TextField("Telefono numeris", text: $model.number)
                    .keyboardType(.phonePad).font(.title2).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                    ForEach(keys, id: \.self) { key in
                        Button(key) { model.number += key; if model.status == .active { model.sendDTMF(key) } }
                            .font(.title2).frame(maxWidth: .infinity, minHeight: 48).buttonStyle(.bordered)
                    }
                }
                if model.status == .idle || model.status == .ended {
                    Button { Task { await model.call() } } label: {
                        Label("Skambinti", systemImage: "phone.fill").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent)
                } else if model.usesCarrierCalling {
                    Label("Skambuti valdo iPhone", systemImage: "iphone.gen3")
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.secondary)
                } else { CallControls() }
                Spacer()
            }
            .padding().navigationTitle("CRM Phone")
            .toolbar { Button { model.showSettings = true } label: { Image(systemName: "gearshape") } }
        }
    }
}

private struct CallControls: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                control("mic.slash.fill", "Nutildyti", model.isMuted) { model.setMuted(!model.isMuted) }
                control("pause.fill", "Laikyti", model.isHeld) { model.setHeld(!model.isHeld) }
                Menu {
                    ForEach(model.audioRoutes) { route in Button(route.name) { model.selectAudioRoute(route) } }
                } label: {
                    VStack { Image(systemName: "airplayaudio"); Text("Garsas").font(.caption) }.frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.borderedProminent).tint(.gray)
            }
            Button(role: .destructive) { model.end() } label: {
                Label("Baigti", systemImage: "phone.down.fill").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent)
        }
    }

    private func control(_ icon: String, _ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack { Image(systemName: icon); Text(title).font(.caption) }.frame(maxWidth: .infinity, minHeight: 52)
        }.buttonStyle(.borderedProminent).tint(selected ? .blue : .gray)
    }
}

private struct CRMView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            Group {
                if let url = model.crmURL { CRMWebView(url: url) }
                else { ContentUnavailableView("CRM nesukonfiguruotas", systemImage: "gearshape") }
            }
            .navigationTitle("CRM").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { model.showSettings = true } label: { Image(systemName: "gearshape") } }
        }
    }
}

private struct CRMWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url { webView.load(URLRequest(url: url)) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Leidimai") {
                    PermissionRow(title: "Mikrofonas", state: model.permissions.microphone)
                    PermissionRow(title: "Kontaktai", state: model.permissions.contacts)
                    PermissionRow(title: "Pranesimai", state: model.permissions.notifications)
                    Button("Suteikti leidimus") { Task { await model.permissions.requestAll() } }
                }
                Section("Base44") {
                TextField("https://...base44.app/", text: $model.settings.baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Brokerio ID", text: $model.settings.brokerID)
                SecureField("Base44 prieigos tokenas", text: $model.settings.accessToken)
                }
                Section("Skambucio kelias") {
                    Picker("Rezimas", selection: $model.settings.callMode) {
                        ForEach(AppModel.CallMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.settings.callMode == .tele2SIP {
                    Section("Tele2 SIP endpointas") {
                        TextField("Registrar address", text: $model.settings.sipRegistrar)
                            .textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("Username", text: $model.settings.sipUsername)
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $model.settings.sipPassword)
                        Picker("Transportas", selection: $model.settings.sipTransport) {
                            Text("TCP").tag("tcp")
                            Text("UDP").tag("udp")
                        }.pickerStyle(.segmented)
                        Text("Pilotui galima naudoti Mobili stotelė endpointą. Produkcijoje įveskite mūsų gateway registrar ir trumpalaikį credential; password saugomas iOS Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Nustatymai")
            .toolbar { Button("Issaugoti") { dismiss(); Task { await model.connect() } } }
        }
    }

    private var modeDescription: String {
        switch model.settings.callMode {
        case .tele2SIP:
            "Pilnas mūsų skambučio UI per Tele2 VoIP endpointą; numerį ir įrašymą valdo Mobili stotelė."
        case .tele2Carrier:
            "Naudoja tą pačią Tele2 SIM/eSIM. Įrašas gaunamas iš Mobilios stotelės, bet pokalbio valdiklius rodo iPhone."
        case .telnyxVoIP:
            "Tik diagnostinis VoIP kelias; nenaudoja brokerio Tele2 numerio."
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let state: PermissionCenter.State
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: icon).foregroundStyle(color)
        }
    }
    private var icon: String {
        switch state { case .allowed: "checkmark.circle.fill"; case .denied: "xmark.circle.fill"; case .unknown: "questionmark.circle" }
    }
    private var color: Color {
        switch state { case .allowed: .green; case .denied: .red; case .unknown: .secondary }
    }
}
