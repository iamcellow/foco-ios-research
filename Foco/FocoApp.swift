import CoreTransferable
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct FocoApp: App {
    var body: some Scene {
        WindowGroup { Studio().preferredColorScheme(.dark) }
    }
}

struct Imported: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(item.file.pathExtension)
            try FileManager.default.copyItem(at: item.file, to: url)
            return Imported(url: url)
        }
    }
}

enum Surface: String, CaseIterable { case camera = "Câmera", lab = "Revelar" }
enum Tool: String, CaseIterable { case lens = "Óptica", film = "Filme", light = "Luz" }
struct Studio: View {
    @StateObject private var cam = Camera()
    @State private var lab = Laboratory()
    @State private var mode: Surface = .camera
    @State private var tool: Tool = .lens
    @State private var picked: PhotosPickerItem?
    @State private var pickFiles = false
    @State private var pickGallery = false
    @State private var original: CGImage?
    @State private var result: CGImage?
    @State private var metadata = ""
    @State private var dimensions = CGSize.zero
    @State private var edit = Edit()
    @State private var depthSize: DepthSize = .normal
    @State private var comparing = false
    @State private var status = ""
    @State private var error: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var busy = false
    @State private var loading = false
    @State private var rev = UUID()
    @State private var exported: Exported?
    @State private var sourceURL: URL?
    @State private var inspecting = false
    @State private var manual = false
    @State private var profile: CaptureProfile = .neutral
    @State private var shotEdit = Edit()
    @State private var iso: Double = 100
    @State private var shutter: Double = 125
    @State private var bias: Double = 0
    @State private var lensPos: Double = 0.5
    @State private var control = "EV"
    @State private var preferRAW = true
    @State private var showFocus = false
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color(red: 0.91, green: 0.95, blue: 0.64)
    private let pad = Color(white: 0.09)
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack {
                    Text("Foco").font(.system(.title2, design: .rounded, weight: .bold))
                    Spacer()
                    Picker("Espaço", selection: $mode) { ForEach(Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }}.pickerStyle(.segmented).frame(maxWidth: 210)
                    Spacer()
                    Menu {
                        Button { pickGallery = true } label: { Label("Galeria", systemImage: "photo.on.rectangle") }
                        Button { pickFiles = true } label: { Label("Arquivos e negativos DNG", systemImage: "folder") }
                    } label: { Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44) }.accessibilityLabel("Importar foto").disabled(busy || loading)
                }.padding(.horizontal, 14)
                if geo.size.width > geo.size.height {
                    HStack(spacing: 0) { stage; controls.frame(width: min(330, geo.size.width * 0.39)) }
                } else {
                    VStack(spacing: 0) { stage; controls.fixedSize(horizontal: false, vertical: true) }
                }
            }.background(Color.black).tint(accent)
        }
        .onAppear {
            if mode == .camera {
                cam.start()
            }
        }
        .onDisappear { cam.stop(); renderTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, mode == .camera {
                cam.start()
            } else if phase != .active {
                cam.stop()
            }
        }
        .onChange(of: mode) {
            _, next in if next == .camera {
                cam.start()
            } else {
                cam.stop()
            }
        }
        .onChange(of: picked) {
            _, item in if let item {
                importPhoto(item)
            }
        }
        .photosPicker(isPresented: $pickGallery, selection: $picked, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $pickFiles, allowedContentTypes: [.image, .rawImage]) { choice in
            do {
                let url = try choice.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                try FileManager.default.copyItem(at: url, to: copy)
                Task { await open(copy) }
            } catch { report(error) }
        }
        .onReceive(cam.$finished) {
            url in if let url {
                let look = shotEdit
                cam.finished = nil; Task { await open(url, initial: look) }
            }
        }
        .onChange(of: edit) { _, _ in refresh() }
        .onChange(of: depthSize) { _, _ in refresh() }
        .alert("Foco", isPresented: Binding(get: { error != nil }, set: {
            if !$0 {
                error = nil
            }
        })) { Button("OK", role: .cancel) {}} message: { Text(error ?? "") }
        .sheet(item: $exported) { item in
            NavigationStack { VStack(spacing: 20) {
                Image(systemName: "checkmark.circle").font(.largeTitle)
                Text("JPEG revelado").font(.title2.bold())
                Text("\(Int(item.dimensions.width)) × \(Int(item.dimensions.height)) px · \(item.seconds, specifier: "%.1f") s").monospacedDigit()
                ShareLink(item: item.url) { Label("Compartilhar ou salvar", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                Button("Salvar em Fotos") { save(item) }
                if sourceURL != nil {
                    Button("Comparar a 100%") { inspecting = true }
                }
            }.navigationDestination(isPresented: $inspecting) {
                if let sourceURL {
                    Inspection(jpeg: item, source: sourceURL, start: edit.focus)
                }
            }
            }.presentationDetents(inspecting ? [.large] : [.medium, .large])
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            if mode == .camera {
                Finder(camera: cam)
                if let message = cam.message {
                    Text(message).multilineTextAlignment(.center).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            } else if let frame = (comparing ? original : result) ?? original {
                GeometryReader { proxy in
                    let k = min(proxy.size.width / CGFloat(frame.width), proxy.size.height / CGFloat(frame.height))
                    let w = CGFloat(frame.width) * k, h = CGFloat(frame.height) * k
                    ZStack(alignment: .topLeading) {
                        Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                        if showFocus, !comparing {
                            Image(systemName: "viewfinder").font(.title2).foregroundStyle(accent)
                                .position(x: edit.focus.x * w, y: edit.focus.y * h).allowsHitTesting(false)
                        }
                    }.frame(width: w, height: h).contentShape(Rectangle()).onTapGesture { p in
                        edit.focus = CGPoint(x: max(0, min(1, p.x / w)), y: max(0, min(1, p.y / h))); showFocus = true
                    }.accessibilityLabel("Foto em edição").accessibilityHint("Toque na imagem para escolher o plano nítido.")
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            } else {
                ContentUnavailableView("Abra uma foto", systemImage: "photo", description: Text("Use a galeria ou fotografe na câmera."))
            }
            if !status.isEmpty {
                VStack { Spacer(); Text(status).font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(8) }.allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if mode == .camera {
                cameraControls
            } else if original != nil {
                HStack {
                    Text(metadata).font(.caption).lineLimit(2); Spacer()
                    Button { comparing.toggle() } label: { Image(systemName: comparing ? "circle.lefthalf.filled" : "circle.righthalf.filled").frame(width: 44, height: 44) }.accessibilityLabel(comparing ? "Mostrar edição" : "Comparar com o original")
                    Button { exportPhoto() } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.disabled(busy || loading).accessibilityLabel("Exportar na resolução original")
                }
                Picker("Ferramenta", selection: $tool) { ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }}.pickerStyle(.segmented)
                switch tool {
                case .lens:
                    chips(Lens.allCases.map(\.rawValue), selection: edit.lens.rawValue) {
                        if let value = Lens(rawValue: $0) {
                            edit.lens = value
                        }
                    }
                    HStack { Text("Abertura"); Slider(value: $edit.aperture, in: 1.2 ... 16, step: 0.1); Text(String(format: "ƒ/%.1f", Double(edit.aperture))).monospacedDigit() }
                    Picker("Precisão do mapa", selection: $depthSize) { ForEach(DepthSize.allCases) { Text($0.title).tag($0) }}.pickerStyle(.menu)
                case .film:
                    chips(Film.allCases.map(\.rawValue), selection: edit.film.rawValue) {
                        if let value = Film(rawValue: $0) {
                            edit.film = value
                        }
                    }
                    HStack { Text("Textura"); Slider(value: $edit.texture, in: 0 ... 2); Text(edit.texture, format: .number.precision(.fractionLength(1))).monospacedDigit() }.disabled(edit.film == .clear)
                case .light:
                    HStack { Text("Exposição"); Slider(value: $edit.ev, in: -2 ... 2, step: 0.1); Text(String(format: "%+.1f EV", Double(edit.ev))).monospacedDigit() }
                    Button("Restaurar edição") { edit = Edit(); comparing = false; showFocus = false }
                }
            }
        }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity).background(pad)
    }

    private func chips(_ items: [String], selection: String, action: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(items, id: \.self) { item in
            Button(item) { action(item) }.padding(.horizontal, 12).frame(minHeight: 44).background(selection == item ? accent : Color(white: 0.16), in: Capsule())
                .foregroundStyle(selection == item ? Color.black : Color.white).accessibilityAddTraits(selection == item ? .isSelected : [])
        }}}.scrollIndicators(.hidden)
    }

    @ViewBuilder private var cameraControls: some View {
        HStack {
            Button(manual ? "Manual" : "Auto") { manual.toggle(); control = manual ? "ISO" : "EV"; applyExposure() }.frame(minHeight: 44)
            Spacer()
            Button(cam.rawAvailable && preferRAW ? "Bayer RAW" : "JPEG") { preferRAW.toggle() }.disabled(!cam.rawAvailable).frame(minHeight: 44)
        }
        Menu {
            Picker("Receita de captura", selection: $profile) {
                ForEach(CaptureProfile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: { Label(profile.rawValue, systemImage: "camera.filters").frame(minHeight: 44) }
            .onChange(of: profile) {
                _, next in if !manual {
                    bias = next.bias; applyExposure()
                }
            }
        chips(manual ? ["ISO", "Tempo", "Foco"] : ["EV", "Foco"], selection: control) { control = $0 }
        HStack {
            switch control {
            case "ISO": stopSlider($iso, range: cam.isoRange, label: "Sensibilidade"); Text("ISO \(Int(iso.rounded()))")
            case "Tempo": stopSlider($shutter, range: cam.shutterRange, label: "Tempo de exposição")
                Text(shutter >= 1 ? "1/\(Int(shutter.rounded())) s" : String(format: "%.2f s", 1 / shutter))
            case "Foco": Slider(value: $lensPos, in: 0 ... 1, onEditingChanged: {
                    if !$0 {
                        cam.manualFocus(Float(lensPos))
                    }
                }); Text(lensPos, format: .number.precision(.fractionLength(2)))
            default: Slider(value: $bias, in: -2 ... 2, step: 1.0 / 3, onEditingChanged: {
                    if !$0 {
                        applyExposure()
                    }
                }); Text(String(format: "%+.1f EV", bias))
            }
        }.monospacedDigit()
        Button { let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation
            let angle: CGFloat = orientation == .landscapeLeft ? 0 : orientation == .landscapeRight ? 180 : orientation == .portraitUpsideDown ? 270 : 90
            shotEdit = profile.edit; shotEdit.focus = cam.frameFocus
            cam.capture(raw: preferRAW && cam.rawAvailable, angle: angle)
        } label: { ZStack { Circle().stroke(.white, lineWidth: 2); Circle().fill(cam.shooting ? .gray : .white).padding(5) }.frame(width: 64, height: 64) }
            .accessibilityLabel("Fotografar").disabled(!cam.ready || cam.shooting || loading).padding(.vertical, 2)
    }

    private func applyExposure() {
        cam.exposure(manual: manual, iso: Float(iso), seconds: 1 / shutter, bias: Float(bias))
    }

    private func stopSlider(_ value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        let low = log2(max(0.000001, range.lowerBound)), high = max(low + 0.0001, log2(max(0.000001, range.upperBound)))
        return Slider(value: Binding(get: { min(high, max(low, log2(value.wrappedValue))) }, set: {
            value.wrappedValue = max(range.lowerBound, min(range.upperBound, pow(2, ($0 * 3).rounded() / 3)))
        }), in: low ... high, onEditingChanged: {
            if !$0 {
                applyExposure()
            }
        }).accessibilityLabel(label)
    }

    private func report(_ e: Error) {
        Logger().error("Editor: \(e.localizedDescription)"); error = e.localizedDescription
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            do { guard let file = try await item.loadTransferable(type: Imported.self) else { throw FocoError.message("A biblioteca não forneceu o arquivo.") }
                guard item == picked else { return }; await open(file.url)
            } catch { report(error) }
        }
    }

    @MainActor private func open(_ url: URL, initial: Edit = Edit()) async {
        let token = UUID(); rev = token; renderTask?.cancel(); loading = true; mode = .lab; status = "Abrindo original…"
        do { let (frame, info, dim) = try await lab.open(url)
            guard token == rev else { return }; original = frame; result = nil; dimensions = dim; metadata = info
            sourceURL = url; edit = initial; comparing = false; showFocus = false; loading = false; refresh()
        } catch {
            if token == rev {
                loading = false; status = ""; report(error)
            }
        }
    }

    private func refresh() {
        guard original != nil,!loading else { return }
        renderTask?.cancel()
        let settings = edit, size = depthSize
        renderTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(170)); status = "Calculando prévia…"
                let frame = try await lab.preview(settings, size)
                try Task.checkCancellation(); result = frame; status = ""
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    status = ""; report(error)
                }
            }
        }
    }

    private func exportPhoto() {
        guard !busy else { return }
        busy = true; status = "Revelando \(Int(dimensions.width)) × \(Int(dimensions.height))…"
        renderTask?.cancel()
        let settings = edit, size = depthSize
        Task { @MainActor in defer { busy = false; status = "" }
            do { exported = try await lab.export(settings, size) } catch { report(error) }
        }
    }

    private func save(_ item: Exported) {
        Task { @MainActor in
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else { exported = nil; error = "Autorize salvar em Fotos nos Ajustes."; return }
            do { try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.url) }
                exported = nil; status = "Salva em Fotos"
            } catch { exported = nil; report(error) }
        }
    }
}
