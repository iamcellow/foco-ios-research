import CoreImage
import SwiftUI
import UniformTypeIdentifiers

actor DetailReader {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    func crop(_ url: URL, point: CGPoint, side: Int) throws -> CGImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])?.atOrigin else { throw FocoError.message("Referência ilegível.") }
        let w = min(CGFloat(side), image.extent.width), h = min(CGFloat(side), image.extent.height)
        let x = min(image.extent.width - w, max(0, image.extent.width * point.x - w / 2))
        let y = min(image.extent.height - h, max(0, image.extent.height * (1 - point.y) - h / 2))
        guard let cg = ci.createCGImage(image, from: CGRect(x: floor(x), y: floor(y), width: w, height: h)) else { throw FocoError.message("Não foi possível ler o detalhe.") }
        return cg
    }
}

struct Inspection: View {
    let jpeg: Exported
    let source: URL
    let start: CGPoint
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var ref: URL?
    @State private var segment = 1
    @State private var image: CGImage?
    @State private var error: String?
    @State private var picking = false
    @State private var reader = DetailReader()
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { geo in
            let side = max(1, Int(min(geo.size.width - 32, geo.size.height * 0.48) * scale))
            VStack(alignment: .leading, spacing: 12) {
                Text("Inspecionar pixels").font(.title2.bold())
                Picker("Comparação", selection: $segment) {
                    Text("Original").tag(0); Text("Foco").tag(1); if ref != nil {
                        Text("PC").tag(2)
                    }
                }.pickerStyle(.segmented)
                ZStack {
                    Color.black
                    if let image {
                        Image(decorative: image, scale: scale).interpolation(.none)
                    }
                }.frame(maxWidth: .infinity).frame(height: CGFloat(side) / scale).clipped()
                Text("Recorte a 100%").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Horizontal"); Slider(value: $center.x, in: 0 ... 1) }
                HStack { Text("Vertical"); Slider(value: $center.y, in: 0 ... 1) }
                Button("Abrir referência do PC…") { picking = true }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
            }.padding(16).onAppear { center = start }
                .task(id: "\(center.x)/\(center.y)/\(segment)/\(side)/\(ref?.lastPathComponent ?? "")") {
                    do {
                        try await Task.sleep(for: .milliseconds(65))
                        let target = segment == 0 ? source : segment == 2 ? (ref ?? jpeg.url) : jpeg.url
                        let region = try await reader.crop(target, point: center, side: side)
                        try Task.checkCancellation(); image = region; error = nil
                    } catch is CancellationError {} catch {
                        if !Task.isCancelled {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.jpeg, .heic, .png]) { result in
                    do { let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                        defer {
                            if scoped {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        guard let im = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), im.extent.size == jpeg.dimensions else { throw FocoError.message("Use uma referência com as mesmas dimensões e orientação.") }
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: dest); ref = dest; segment = 2
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
}
