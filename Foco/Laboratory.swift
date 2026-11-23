import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import Metal
import os
import UniformTypeIdentifiers

enum Film: String, CaseIterable, Identifiable {
    case clear = "Neutro", portrait = "Negativo 160", daylight = "Dia 50", cinema = "Cinema 250D", tungsten = "Noite 500T", chrome = "Cromo 100", silver = "Prata 400"
    var id: Self {
        self
    }

    /// Artist-authored shadow and highlight dye biases in linear RGB.
    var split: (CIVector, CIVector) {
        switch self {
        case .portrait: return (.init(x: 0.96, y: 1.08, z: 1.01), .init(x: 1.13, y: 1.02, z: 0.89))
        case .daylight: return (.init(x: 0.89, y: 1.07, z: 1.13), .init(x: 1.10, y: 1.04, z: 0.91))
        case .cinema: return (.init(x: 0.65, y: 1.16, z: 1.23), .init(x: 1.22, y: 1.02, z: 0.78))
        case .tungsten: return (.init(x: 0.72, y: 0.92, z: 1.36), .init(x: 1.25, y: 0.98, z: 0.76))
        case .chrome: return (.init(x: 1.03, y: 0.91, z: 1.17), .init(x: 1.05, y: 0.99, z: 1.02))
        case .clear, .silver: return (.init(x: 1, y: 1, z: 1), .init(x: 1, y: 1, z: 1))
        }
    }

    /// contrast, saturation, shoulder, toe / grain, red halo, bloom, grain diameter / RGB gains
    var recipe: ([CGFloat], [CGFloat], [CGFloat]) {
        switch self {
        case .clear: ([1, 1, 0, 0], [0, 0, 0, 1], [1, 1, 1])
        case .portrait: ([0.91, 0.83, 0.28, 0.008], [0.028, 0.09, 0.024, 1.6], [1.13, 1.01, 0.88])
        case .daylight: ([1.16, 1.23, 0.14, 0.002], [0.016, 0.055, 0.012, 1.1], [1.022, 1.018, 0.977])
        case .cinema: ([1.18, 0.92, 0.34, 0.009], [0.043, 0.13, 0.026, 1.9], [1.035, 1, 0.975])
        case .tungsten: ([1.13, 0.88, 0.38, 0.008], [0.068, 0.34, 0.038, 2.4], [0.84, 0.97, 1.23])
        case .chrome: ([1.29, 1.28, 0.22, 0.001], [0.022, 0.045, 0.008, 1.25], [1.014, 1, 0.986])
        case .silver: ([1.28, 0, 0.20, 0.005], [0.082, 0.09, 0.018, 2.1], [1, 1, 1])
        }
    }
}

enum Lens: String, CaseIterable, Identifiable {
    case street = "Rua 35", normal = "Normal 50", portrait = "Retrato 85", classic = "Clássica 58", tele = "Tele 105", scope = "Anamórfica"
    var id: Self {
        self
    }

    var character: (strength: CGFloat, stretch: CGFloat) {
        switch self { case .street: return (0.58, 1); case .normal: return (0.78, 1); case .portrait: return (1, 1)
        case .classic: return (0.84, 1.18);case .tele: return (1.3, 1);case .scope: return (1.08, 1.7) }
    }

    var focalMM: CGFloat {
        switch self { case .street: return 35;case .normal: return 50;case .portrait: return 85
        case .classic: return 58;case .tele: return 105;case .scope: return 55 }
    }
}

struct Edit: Equatable {
    var focus = CGPoint(x: 0.5, y: 0.5)
    var aperture: CGFloat = 4
    var ev: CGFloat = 0
    var film: Film = .clear
    var lens: Lens = .portrait
    var texture: CGFloat = 1
}

enum CaptureProfile: String, CaseIterable {
    case neutral = "Neutra", street = "Rua de dia", soft = "Retrato suave", night = "Noite de cinema", mono = "Rua em prata"
    var bias: Double {
        switch self {
        case .night: -2.0 / 3
        case .street, .mono: -1.0 / 3
        default: 0
        }
    }

    var edit: Edit {
        var e = Edit()
        switch self {
        case .neutral: break
        case .street: e.lens = .street; e.aperture = 5.6; e.film = .daylight
        case .soft: e.lens = .portrait; e.aperture = 4; e.film = .portrait
        case .night: e.lens = .scope; e.aperture = 2.8; e.film = .tungsten
        case .mono: e.lens = .classic; e.aperture = 4; e.film = .silver
        }
        return e
    }
}

struct SourcePhoto {
    let image: CIImage
    let disparity: CIImage?
    let raw: Bool
    let seed: CGFloat
    let originalURL: URL
    let exif: String
    let focalPixels: CGFloat?
}

struct Exported: Identifiable {
    let id = UUID()
    let url: URL
    let dimensions: CGSize
    let seconds: TimeInterval
}

actor Laboratory {
    private let model = DepthBase()
    private let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var kernels = [String: CIColorKernel]()
    private var photo: SourcePhoto?
    private var personMask: CIImage?
    private var checkedPerson = false
    private var cached: (DepthSize, DepthBase.Map)?
    init() {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh,
                                               .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]
        if let gpu = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: gpu, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    private func kernel(_ name: String, _ extent: CGRect, _ args: [Any]) throws -> CIImage {
        if kernels[name] == nil {
            guard let url = Bundle.main.url(forResource: "FocoLab", withExtension: "metallib") else { throw FocoError.message("Biblioteca óptica Metal ausente.") }
            kernels[name] = try CIColorKernel(functionName: name, fromMetalLibraryData: Data(contentsOf: url))
        }
        guard let result = kernels[name]?.apply(extent: extent, arguments: args) else { throw FocoError.message("Falha no estágio " + name) }
        return result
    }

    func open(_ url: URL) throws -> (CGImage, String, CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FocoError.message("Arquivo de imagem ilegível.") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let raw = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }?.conforms(to: .rawImage) == true || url.pathExtension.lowercased() == "dng"
        let input: CIImage?
        if raw, let filter = CIRAWFilter(imageURL: url) {
            filter.boostAmount = 0
            filter.localToneMapAmount = 0
            filter.sharpnessAmount = 0
            input = filter.outputImage
        } else {
            input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let image = input?.atOrigin, !image.extent.isEmpty else { throw FocoError.message("Não foi possível revelar o arquivo.") }
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        var sensor: CIImage?
        var focalPixels: CGFloat?
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let dict = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] else { continue }
            do {
                let aux = try AVDepthData(fromDictionaryRepresentation: dict)
                    .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
                if let calibration = aux.cameraCalibrationData {
                    let ref = calibration.intrinsicMatrixReferenceDimensions
                    let scale = hypot(image.extent.width, image.extent.height) / max(1, hypot(ref.width, ref.height))
                    focalPixels = CGFloat(calibration.intrinsicMatrix.columns.0.x) * scale
                }
                let registered = CIImage(cvPixelBuffer: aux.depthDataMap, options: [.colorSpace: NSNull()]).oriented(forExifOrientation: orientation).atOrigin
                let sx = image.extent.width / registered.extent.width, sy = image.extent.height / registered.extent.height
                if abs(sx / sy - 1) < 0.02 {
                    sensor = registered.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                }
            } catch { Logger().info("Profundidade auxiliar indisponível: \(error.localizedDescription)") }
            break
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if focalPixels == nil, let equiv = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber, equiv.doubleValue > 0 {
            focalPixels = CGFloat(equiv.doubleValue) * hypot(image.extent.width, image.extent.height) / hypot(36, 24)
        }
        var info = [raw ? "RAW" : "Foto"]
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first {
            info.append("ISO " + iso.stringValue)
        }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber {
            info.append(String(format: "%0.1f mm", focal.doubleValue))
        }
        if let sec = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber, sec.doubleValue > 0 {
            info.append(String(format: "1/%0.0f s", 1 / sec.doubleValue))
        }
        let preview = try display(image)
        let prefix = try FileHandle(forReadingFrom: url)
        defer { try? prefix.close() }
        let bytes = try prefix.read(upToCount: 8192) ?? Data()
        let seed = bytes.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        photo = SourcePhoto(image: image, disparity: sensor, raw: raw, seed: CGFloat(seed % 32749), originalURL: url, exif: info.joined(separator: " · "), focalPixels: focalPixels)
        cached = nil
        checkedPerson = false
        personMask = nil
        return (preview, info.joined(separator: " · "), image.extent.size)
    }

    private func display(_ image: CIImage) throws -> CGImage {
        return try raster(resize(image, edge: 1152))
    }

    private func raster(_ scaled: CIImage) throws -> CGImage {
        guard let result = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: space) else { throw FocoError.message("Falha na prévia.") }
        return result
    }

    private func resize(_ image: CIImage, edge: CGFloat) -> CIImage {
        let ratio = min(1, edge / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
    }

    private func alignSensor(_ aux: CIImage, with depth: CIImage) throws -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: 48, height: 48)
        func grid(_ im: CIImage) -> [Float] {
            var v = [Float](repeating: 0, count: 48 * 48)
            let img = im.transformed(by: CGAffineTransform(scaleX: 48 / im.extent.width, y: 48 / im.extent.height))
            v.withUnsafeMutableBytes { context.render(img, toBitmap: $0.baseAddress!, rowBytes: 48 * 4, bounds: rect, format: .Rf, colorSpace: nil) }
            return v
        }
        let samples = zip(grid(aux), grid(depth)).filter { $0.0.isFinite && $0.0 > 0 && $0.1.isFinite }
        guard samples.count > 200 else { return depth }
        let n = Float(samples.count), mx = samples.reduce(0) { $0 + $1.0 } / n, my = samples.reduce(0) { $0 + $1.1 } / n
        var xx: Float = 0, xy: Float = 0, yy: Float = 0
        for (x, y) in samples {
            xx += (x - mx) * (x - mx); xy += (x - mx) * (y - my); yy += (y - my) * (y - my)
        }
        guard xy > 0, xy * xy > 0.7 * xx * yy, xx > 1e-7 else { return depth }
        return try kernel("fuse", depth.extent, [depth, aux, xy / xx, my - (xy / xx) * mx])
    }

    private func depth(_ src: SourcePhoto, _ size: DepthSize) throws -> DepthBase.Map {
        if let (last, map) = cached, last == size {
            return map
        }
        var map = try model.estimate(src.image, size: size, context: context)
        if let aux = src.disparity {
            map.image = try alignSensor(aux, with: map.image)
        }
        cached = (size, map)
        return map
    }

    // Vision supplies a soft portrait prior. The depth model still determines
    // ordering and the focus plane, including when people are at different distances.
    private func portraitPrior(_ src: SourcePhoto) -> CIImage? {
        if checkedPerson { return personMask }
        checkedPerson = true
        let guide = resize(src.image, edge: 1536)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: guide, options: [:]).perform([request])
            if let buffer = request.results?.first?.pixelBuffer {
                let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                personMask = mask.transformed(by: CGAffineTransform(scaleX: src.image.extent.width / mask.extent.width,
                                                                      y: src.image.extent.height / mask.extent.height))
            }
        } catch { Logger().info("Contorno de pessoa indispon�vel: \(error.localizedDescription)") }
        return personMask
    }

    private func guided(_ prior: CIImage, by image: CIImage, radius: CGFloat) throws -> CIImage {
        let r = image.extent
        func mean(_ value: CIImage) -> CIImage {
            value.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: r)
        }
        let moments = try kernel("moments", r, [image, prior])
        let cross = try kernel("crossMoment", r, [image, prior])
        let coefficients = try kernel("coefficients", r, [mean(moments), mean(cross)])
        return try kernel("refine", r, [image, mean(coefficients), prior])
    }

    private func render(_ src: SourcePhoto, _ edit: Edit, _ size: DepthSize, edge: CGFloat?, mapOnly: Bool = false) throws -> CIImage {
        let img = edge.map { resize(src.image, edge: $0) } ?? src.image
        let r = img.extent
        let ratio = r.width / src.image.extent.width
        let map = try depth(src, size)
        let transform = CGAffineTransform(scaleX: ratio, y: ratio)
        let prior = map.image.transformed(by: transform)
        func blurred(_ value: CIImage, _ radius: CGFloat) -> CIImage {
            value.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: r)
        }
        let radius = max(1.4, max(r.width, r.height) / 380)
        let z = try guided(prior, by: img, radius: radius)
        if mapOnly { return z }
        let pos = CGPoint(x: min(r.maxX - 1, max(0, edit.focus.x * r.width)), y: min(r.maxY - 1, max(0, (1 - edit.focus.y) * r.height)))
        var focus: Float = 0
        context.render(z, toBitmap: &focus, rowBytes: 4, bounds: CGRect(x: floor(pos.x), y: floor(pos.y), width: 1, height: 1), format: .Rf, colorSpace: nil)
        let lens = edit.lens.character
        let relativeStrength = max(r.width, r.height) * 0.039 * lens.strength / edit.aperture
        var strength = relativeStrength
        if let focal = src.focalPixels, focal > 0 {
            // Depth Pro inverse_depth = f_px / (modelWidth * distanceMeters).
            let units = map.frameWidth / focal, span = CGFloat(map.high - map.low) * units
            let focusedDiopters = (CGFloat(map.low) + CGFloat(focus) * CGFloat(map.high - map.low)) * units
            let virtualFocal = edit.lens.focalMM / 1000
            let denominator = 1 - virtualFocal * focusedDiopters
            if denominator > 0.15, span.isFinite, span > 0 {
                let physical = focal * ratio * virtualFocal * span / (2 * edit.aperture * denominator)
                strength = min(max(r.width, r.height) * 0.035, max(0, physical))
            }
        }
        let count = 12, width = 1 / CGFloat(count)
        var comp = blurred(img, max(0.5, strength * 0.4))
        for i in 0 ... count {
            let center = CGFloat(i) * width
            let coc = max(0, abs(center - CGFloat(focus)) - 0.032) * strength
            var band = try kernel("plane", r, [img, z, center, width])
            if coc > 0.55 {
                let squeeze = CGAffineTransform(scaleX: 1, y: 1 / lens.stretch)
                band = band.clampedToExtent().transformed(by: squeeze).applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: coc])
                    .transformed(by: squeeze.inverted()).cropped(to: r)
            }
            comp = try kernel("overPlane", r, [comp, band, z, center, width])
        }
        comp = try kernel("focusDetail", r, [comp, img, z, focus, strength])
        if let prior = portraitPrior(src) {
            let alpha = try guided(prior.transformed(by: transform), by: img, radius: radius)
            var onPerson: Float = 0
            context.render(alpha, toBitmap: &onPerson, rowBytes: 4,
                           bounds: CGRect(x: floor(pos.x), y: floor(pos.y), width: 1, height: 1), format: .Rf, colorSpace: nil)
            if onPerson > 0.6 {
                let away = try kernel("backSample", r, [img, alpha])
                let defocused = try kernel("backSample", r, [comp, alpha])
                let extent = max(2, radius * 1.6)
                let nearby = blurred(away, extent), backdrop = blurred(defocused, extent)
                let support = try kernel("focusSupport", r, [z, alpha, focus])
                comp = try kernel("portraitEdge", r, [comp, img, alpha, nearby, backdrop, blurred(support, extent), z, focus])
            }
        }
        if edit.film == .clear, edit.ev == 0 {
            return comp
        }
        let (t, g, c) = edit.film.recipe
        func v(_ a: [CGFloat]) -> CIVector {
            CIVector(x: a[0], y: a[1], z: a[2], w: a[3])
        }
        let hot = try kernel("highlights", r, [comp, edit.ev])
        let halo = blurred(hot, max(0.7, max(r.width, r.height) / 350))
        return try kernel("develop", r, [comp, halo, hot, v(t), v([g[0] * edit.texture, g[1] * edit.texture, g[2] * edit.texture, g[3]]),
                                         v(c + [1]), edit.film.split.0, edit.film.split.1, edit.ev, max(r.width, r.height) / 4032, src.seed])
    }

    func preview(_ edit: Edit, _ size: DepthSize, edge: CGFloat = 1152, mapOnly: Bool = false) throws -> CGImage {
        guard let src = photo else { throw FocoError.message("Abra uma foto.") }
        let graph = try render(src, edit, size, edge: edge, mapOnly: mapOnly)
        return try raster(graph)
    }

    func originalPreview(edge: CGFloat) throws -> CGImage {
        guard let src = photo else { throw FocoError.message("Abra uma foto.") }
        return try raster(resize(src.image, edge: edge))
    }

    func export(_ edit: Edit, _ size: DepthSize) throws -> Exported {
        guard let src = photo else { throw FocoError.message("Abra uma foto.") }
        let started = ProcessInfo.processInfo.systemUptime
        let graph = try render(src, edit, size, edge: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Foco-" + UUID().uuidString + ".jpg")
        try writeOriginalJPEG(graph, context: context, colorSpace: space, to: url)
        return Exported(url: url, dimensions: graph.extent.size, seconds: ProcessInfo.processInfo.systemUptime - started)
    }
}
