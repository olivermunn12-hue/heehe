import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ArchiveIndex: Decodable {
    let item: String?
    let files: [ArchiveFile]
}
struct ArchiveFile: Decodable, Identifiable {
    let name: String
    let size: String?
    let md5: String?
    let sha1: String?
    let format: String?
    var id: String { name }
    var displayName: String {
        URL(fileURLWithPath: name).lastPathComponent
            .replacingOccurrences(of: ".ipa", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "--", with: " — ")
    }
    var byteCount: Int64 { Int64(size ?? "") ?? 0 }
    var sizeLabel: String {
        guard byteCount > 0 else { return "Size unavailable" }
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: byteCount)
    }
    var downloadURL: URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://archive.org/download/legacy_ios_apps/\(encoded)")
    }
}

struct StoreAPIApp: Decodable, Identifiable {
    let appID: IntOrString?
    let name: String?
    let title: String?
    let version: String?
    let icon_url: String?
    let description: String?
    let developer: String?
    enum CodingKeys: String, CodingKey { case appID = "id", name, title, version, icon_url, description, developer }
    var id: String { appID?.stringValue ?? name ?? title ?? "unknown-app" }
    var label: String { name ?? title ?? "Untitled app" }
}
enum IntOrString: Decodable {
    case int(Int), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }
    var stringValue: String { switch self { case .int(let i): return String(i); case .string(let s): return s } }
}

@MainActor final class StoreModel: ObservableObject {
    @Published var query = ""
    @Published var archiveResults: [ArchiveFile] = []
    @Published var apiResults: [StoreAPIApp] = []
    @Published var isSearching = false
    @Published var status = "Ready"
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloaded: [URL] = []
    @Published var errorMessage: String?
    private var allFiles: [ArchiveFile] = []

    private var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    init() {
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        refreshDownloads()
        if let url = Bundle.main.url(forResource: "archive_legacy_ios_apps", withExtension: "json"),
           let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(ArchiveIndex.self, from: data) {
            allFiles = index.files
        }
        archiveResults = Array(allFiles.prefix(100))
        status = "\(allFiles.count) archived IPA entries indexed"
    }
    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { archiveResults = Array(allFiles.prefix(100)); apiResults = []; status = "Showing archived IPA catalog"; return }
        isSearching = true; status = "Searching catalog…"
        archiveResults = allFiles.filter { $0.name.localizedCaseInsensitiveContains(q) }.sorted { versionKey($0.name) > versionKey($1.name) }.prefix(150).map{$0}
        Task {
            defer { isSearching = false }
            do {
                var components = URLComponents(string: "https://legacystore.app/api/v1/apps")!
                components.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "50")]
                var request = URLRequest(url: components.url!); request.setValue("LegacyiOSStore-iOS/1.0", forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 25
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let decoded = try JSONDecoder().decode(LooseAppResponse.self, from: data)
                apiResults = decoded.apps
                status = "\(archiveResults.count) archive matches · \(apiResults.count) store matches"
            } catch {
                apiResults = []
                status = "Archive search available; online catalog unavailable"
            }
        }
    }
    func download(_ file: ArchiveFile) {
        guard let remote = file.downloadURL else { errorMessage = "This entry has no valid download URL."; return }
        let safe = URL(fileURLWithPath: file.displayName).lastPathComponent
        let filename = safe.lowercased().hasSuffix(".ipa") ? safe : safe + ".ipa"
        let destination = downloadsDirectory.appendingPathComponent(filename)
        let key = file.id
        status = "Downloading \(file.displayName)…"; downloadProgress[key] = 0
        let task = URLSession.shared.downloadTask(with: remote) { [weak self] temp, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.errorMessage = error.localizedDescription; self.status = "Download failed"; self.downloadProgress.removeValue(forKey: key); return }
                guard let temp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { self.errorMessage = "The source did not return an IPA file."; self.status = "Download failed"; self.downloadProgress.removeValue(forKey: key); return }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: temp, to: destination)
                    self.refreshDownloads(); self.status = "Saved to Files → On My iPhone → Legacy iOS Store → Downloads"; self.downloadProgress[key] = 1
                } catch { self.errorMessage = error.localizedDescription; self.status = "Could not save download" }
            }
        }
        task.resume()
    }
    func installWithTrollStore(_ file: ArchiveFile) {
        guard let ipaURL = file.downloadURL else {
            errorMessage = "This archive entry has no valid download URL."
            return
        }
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipaURL.absoluteString)]
        guard let installURL = components.url else {
            errorMessage = "Could not create the TrollStore install link."
            return
        }
        UIApplication.shared.open(installURL, options: [:]) { opened in
            if opened {
                self.status = "Sent \(file.displayName) to TrollStore for installation"
            } else {
                self.errorMessage = "iOS did not open the TrollStore install link. Check that TrollStore Lite is installed and its URL scheme is available. You can still download the IPA and open it from Files."
            }
        }
    }
    func importIPA(from source: URL) {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "ipa" else {
            errorMessage = "Please choose an .ipa file."
            return
        }
        do {
            let destination = uniqueDestination(for: source.lastPathComponent)
            if source.deletingLastPathComponent().standardizedFileURL == downloadsDirectory.standardizedFileURL {
                refreshDownloads()
                status = "IPA is already in Downloads"
                return
            }
            try FileManager.default.copyItem(at: source, to: destination)
            refreshDownloads()
            status = "Imported \(destination.lastPathComponent) into Downloads"
        } catch {
            errorMessage = "Could not import IPA: \(error.localizedDescription)"
        }
    }
    private func uniqueDestination(for proposedName: String) -> URL {
        let cleaned = URL(fileURLWithPath: proposedName).lastPathComponent
        let base = cleaned.lowercased().hasSuffix(".ipa") ? String(cleaned.dropLast(4)) : cleaned
        var candidate = downloadsDirectory.appendingPathComponent(base + ".ipa")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloadsDirectory.appendingPathComponent("\(base) (\(suffix)).ipa")
            suffix += 1
        }
        return candidate
    }
    func refreshDownloads() {
        let folder = downloadsDirectory
        downloaded = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
    private func versionKey(_ s: String) -> [Int] {
        let base = URL(fileURLWithPath: s).lastPathComponent
        let re = try! NSRegularExpression(pattern: #"\d+(?:\.\d+){0,4}"#)
        let ns = base as NSString
        guard let m = re.matches(in: base, range: NSRange(location: 0, length: ns.length)).last else { return [] }
        return ns.substring(with: m.range).split(separator: ".").compactMap { Int($0) }
    }
}
struct LooseAppResponse: Decodable {
    let apps: [StoreAPIApp]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([StoreAPIApp].self) { apps = a; return }
        let d = try c.decode([String: JSONValue].self)
        for key in ["data", "apps", "results", "items"] {
            if let v = d[key], let a = v.arrayValue, let mapped = try? JSONDecoder().decode([StoreAPIApp].self, from: JSONSerialization.data(withJSONObject: a)) { apps = mapped; return }
            if let v = d[key], let obj = v.objectValue {
                for inner in ["apps", "results", "items", "data"] { if let arr = obj[inner]?.arrayValue, let mapped = try? JSONDecoder().decode([StoreAPIApp].self, from: JSONSerialization.data(withJSONObject: arr)) { apps = mapped; return } }
            }
        }
        apps = []
    }
}
struct JSONValue: Decodable {
    let raw: Any
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let v = try? c.decode(String.self) { raw = v } else if let v = try? c.decode([JSONValue].self) { raw = v.map{$0.raw} } else if let v = try? c.decode([String: JSONValue].self) { raw = v.mapValues{$0.raw} } else if let v = try? c.decode(Int.self) { raw = v } else { raw = NSNull() } }
    var arrayValue: [Any]? { raw as? [Any] }
    var objectValue: [String: Any]? { raw as? [String: Any] }
}

struct StoreView: View {
    @StateObject private var model = StoreModel()
    @State private var tab = 0
    @State private var selectedIPA: URL?
    @State private var showIPAActions = false
    @State private var showShareSheet = false
    @State private var showFileImporter = false
    @State private var showActionMessage = false
    @State private var actionMessage = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps and IPA versions", text: $model.query).submitLabel(.search).onSubmit { model.search() }
                    if !model.query.isEmpty { Button { model.query = ""; model.search() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                    Button { model.search() } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
                Picker("Catalog", selection: $tab) { Text("Archive IPAs").tag(0); Text("Online Store").tag(1); Text("Downloads").tag(2) }.pickerStyle(.segmented).padding()
                if tab == 0 { archiveList } else if tab == 1 { onlineList } else { downloadsList }
                HStack(spacing: 8) { Circle().fill(model.isSearching ? .orange : .green).frame(width: 7,height: 7); Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer() }.padding(.horizontal).padding(.vertical, 8).background(.ultraThinMaterial)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarHidden(true)
            .onAppear { model.refreshDownloads() }
            .confirmationDialog(selectedIPA?.lastPathComponent ?? "IPA actions", isPresented: $showIPAActions, titleVisibility: .visible) {
                if let url = selectedIPA {
                    Button { showShareSheet = true } label: { Label("Open / Share IPA", systemImage: "square.and.arrow.up") }
                    Button { showShareSheet = true } label: { Label("Send to TrollStore Lite (Share Sheet)", systemImage: "shippingbox.fill") }
                    Button("Legacy Store Sign / Install") {
                        actionMessage = "The on-device signing and privileged install engine is not implemented in this build yet. AppSync Unified can allow compatible unsigned apps to install, but it does not sign the IPA by itself. For now, use Open / Share IPA and choose a compatible installer such as TrollStore Lite or Filza if offered."
                        showActionMessage = true
                    }
                    Button("Delete IPA", role: .destructive) {
                        do { try FileManager.default.removeItem(at: url); model.refreshDownloads(); model.status = "Deleted \(url.lastPathComponent)" }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Legacy iOS Store", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK", role: .cancel) { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
            .alert("IPA action", isPresented: $showActionMessage) { Button("OK", role: .cancel) { } } message: { Text(actionMessage) }
            .sheet(isPresented: $showShareSheet) {
                if let url = selectedIPA {
                    ActivityView(activityItems: [url])
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls { model.importIPA(from: url) }
                case .failure(let error):
                    model.errorMessage = "Could not open Files picker: \(error.localizedDescription)"
                }
            }
        }.tint(Color(red: 0.30, green: 0.43, blue: 0.98))
    }
    private var header: some View {
        HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(red:0.35,green:0.43,blue:1),Color(red:0.58,green:0.25,blue:0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.white) }.frame(width: 52,height: 52)
            VStack(alignment: .leading, spacing: 3) { Text("Legacy iOS Store").font(.title2.bold()); Text("Classic apps · IPA archive").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
        }.padding(.horizontal).padding(.top, 12).padding(.bottom, 16)
    }
    private var archiveList: some View {
        List(model.archiveResults) { file in
            HStack(spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)); Image(systemName: "app.dashed").font(.title3).foregroundStyle(Color.accentColor) }.frame(width: 46,height: 46)
                VStack(alignment: .leading, spacing: 4) { Text(file.displayName).font(.subheadline.weight(.semibold)).lineLimit(2); Text("\(file.sizeLabel) · Internet Archive").font(.caption).foregroundStyle(.secondary); Text(file.name.contains("/") ? String(file.name.split(separator: "/").first ?? "Archive") : "Legacy IPA archive").font(.caption2).foregroundStyle(.tertiary) }
                Spacer(minLength: 2)
                VStack(spacing: 8) {
                    Button { model.download(file) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }.buttonStyle(.plain).accessibilityLabel("Download \(file.displayName)")
                    Button { model.installWithTrollStore(file) } label: { Image(systemName: "shippingbox.fill").font(.title3) }.buttonStyle(.plain).accessibilityLabel("Install \(file.displayName) with TrollStore")
                }
            }.padding(.vertical, 4)
        }.listStyle(.plain).overlay { if model.archiveResults.isEmpty { EmptyState(title: "No archive matches", symbol: "magnifyingglass", detail: "Try another app name or version.") } }
    }
    private var onlineList: some View {
        List(model.apiResults) { app in
            HStack(spacing: 12) {
                Image(systemName: "app.fill").font(.title2).foregroundStyle(.indigo).frame(width: 44,height: 44).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) { Text(app.label).font(.subheadline.bold()); Text([app.version, app.developer].compactMap{$0}.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary); if let desc = app.description { Text(desc).font(.caption2).lineLimit(2).foregroundStyle(.tertiary) } }
                Spacer()
            }.padding(.vertical, 3)
        }.listStyle(.plain).overlay { if model.apiResults.isEmpty { EmptyState(title: "Search the online store", symbol: "globe", detail: "Enter an app name above, then tap the arrow to search Legacy Store.") } }
    }
    private var downloadsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showFileImporter = true } label: {
                    Label("Import IPA", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { model.refreshDownloads() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 8)

            List(model.downloaded, id: \.absoluteString) { url in
                Button {
                    selectedIPA = url
                    showIPAActions = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.zipper").font(.title2).foregroundStyle(.indigo).frame(width: 44, height: 44).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).font(.subheadline.bold()).lineLimit(2).multilineTextAlignment(.leading)
                            Text("IPA file · Tap for actions").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if model.downloaded.isEmpty {
                    EmptyState(title: "No downloads yet", symbol: "arrow.down.to.line", detail: "Download an IPA from the catalog or tap Import IPA to choose one in Files. Files are stored in On My iPhone → Legacy iOS Store → Downloads. Tap a file for sharing or installer options.")
                }
            }
        }
    }

}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct EmptyState: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) { Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary); Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}
