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

// The UIScrollView owns the transform. Swapping renders, the original, or
// the depth map therefore never moves the detail underneath the user's finger.
struct PhotoViewport: UIViewRepresentable {
    let frame: CGImage
    let focus: CGPoint?
    let onFocus: (CGPoint) -> Void
    let onCompare: (Bool) -> Void
    let onDetail: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomCanvas { ZoomCanvas() }
    func updateUIView(_ canvas: ZoomCanvas, context: Context) {
        canvas.onFocus = onFocus
        canvas.onCompare = onCompare
        canvas.onDetail = onDetail
        canvas.present(frame, focus: focus)
    }

    final class ZoomCanvas: UIScrollView, UIScrollViewDelegate {
        let picture = UIImageView()
        let marker = CAShapeLayer()
        var onFocus: ((CGPoint) -> Void)?
        var onCompare: ((Bool) -> Void)?
        var onDetail: ((Bool) -> Void)?
        private var lastSize = CGSize.zero
        private var detail = false
        private var aspect: CGFloat = 1

        init() {
            super.init(frame: .zero)
            delegate = self
            maximumZoomScale = 6
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            backgroundColor = .black
            addSubview(picture)
            picture.layer.addSublayer(marker)
            marker.fillColor = UIColor.clear.cgColor
            marker.strokeColor = UIColor(red: 0.91, green: 0.95, blue: 0.64, alpha: 1).cgColor
            let once = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let twice = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            twice.numberOfTapsRequired = 2
            once.require(toFail: twice)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(press(_:)))
            hold.minimumPressDuration = 0.28
            once.require(toFail: hold)
            [once, twice, hold].forEach(addGestureRecognizer)
            isAccessibilityElement = true
            accessibilityLabel = "Foto em edição"
            accessibilityHint = "Use dois dedos para ampliar. Segure para ver o original."
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Alternar ampliação", target: self, selector: #selector(accessZoom))]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) indisponível") }

        func present(_ frame: CGImage, focus: CGPoint?) {
            if picture.image?.cgImage !== frame {
                picture.image = UIImage(cgImage: frame)
                let next = CGFloat(frame.width) / CGFloat(frame.height)
                if picture.bounds.isEmpty || abs(aspect - next) > 0.003 {
                    aspect = next
                    lastSize = .zero
                    setNeedsLayout()
                }
            }
            marker.isHidden = focus == nil
            if let focus {
                let x = picture.bounds.width * focus.x, y = picture.bounds.height * focus.y
                let side = 30 / zoomScale
                marker.lineWidth = 1.5 / zoomScale
                marker.path = UIBezierPath(roundedRect: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side), cornerRadius: 4 / zoomScale).cgPath
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            if lastSize != size {
                lastSize = size
                setZoomScale(1, animated: false)
                let w = min(size.width, size.height * aspect)
                picture.frame = CGRect(x: 0, y: 0, width: w, height: w / aspect)
                contentSize = picture.frame.size
            }
            centerPhoto()
        }
        private func centerPhoto() {
            let x = max(0, (bounds.width - picture.frame.width) / 2)
            let y = max(0, (bounds.height - picture.frame.height) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if contentInset != inset { contentInset = inset }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let next = scale > 1.15
            if next != detail { detail = next; onDetail?(next) }
        }
        @objc private func tap(_ g: UITapGestureRecognizer) {
            let p = g.location(in: picture)
            guard picture.bounds.contains(p) else { return }
            onFocus?(CGPoint(x: p.x / picture.bounds.width, y: p.y / picture.bounds.height))
        }
        @objc private func doubleTap(_ g: UITapGestureRecognizer) { toggleZoom(g.location(in: picture)) }
        @objc private func accessZoom() -> Bool {
            toggleZoom(CGPoint(x: picture.bounds.midX, y: picture.bounds.midY))
            return true
        }
        private func toggleZoom(_ p: CGPoint) {
            guard picture.bounds.contains(p) else { return }
            if zoomScale > 1.05 { setZoomScale(1, animated: true); return }
            let w = bounds.width / 3, h = bounds.height / 3
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
        @objc private func press(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                if picture.bounds.contains(g.location(in: picture)) { onCompare?(true) }
            case .ended, .cancelled, .failed: onCompare?(false)
            default: break
            }
        }
    }
}
