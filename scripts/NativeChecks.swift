import CoreGraphics
import CoreImage
import CoreML
import Metal
import Foundation
import ImageIO

@main
struct NativeChecks {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let layout = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue

    // Gradients encode orientation. Three-pixel lines straddle export strips.
    // The central patch has single-pixel luminance detail to detect resampling.
    static func pixel(x: Int, y: Int, width: Int, height: Int) -> (Int, Int, Int) {
        if abs(x - width / 2) < 64, abs(y - height / 2) < 32 {
            let level = x.isMultiple(of: 2) ? 42 : 209
            return (level, level, level)
        }
        let line = (y + 1) % 384 < 3 ? 48 : 0
        return (24 + x * 160 / width + line, 16 + y * 170 / height + line, 32 + line)
    }

    static func image(width: Int, height: Int, textured: Bool = false) throws -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var (r, g, b) = pixel(x: x, y: y, width: width, height: height)
                if textured {
                    let cx = (Double(x) - 0.51 * Double(width)) / (0.31 * Double(width))
                    let cy = (Double(y) - 0.61 * Double(height)) / (0.31 * Double(width))
                    let radius = cx * cx + cy * cy
                    if radius < 1 {
                        let light = max(0, 0.7 * sqrt(1 - radius) - 0.45 * cx - 0.5 * cy)
                        (r, g, b) = (Int(65 + 140 * light), Int(32 + 80 * light), Int(25 + 45 * light))
                    } else if y < height / 2 {
                        (r, g, b) = (122 + y * 64 / height, 161 + y * 52 / height, 210)
                    }
                }
                let base = (y * width + x) * 4
                let grain = textured ? (((x / 3 + y / 3).isMultiple(of: 2)) ? 18 : -18) : 0
                rgba[base] = UInt8(clamping: r + grain)
                rgba[base + 1] = UInt8(clamping: g + grain)
                rgba[base + 2] = UInt8(clamping: b + grain)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: layout),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FocoError.message("Could not create synthetic image") }
        return CIImage(cgImage: cg)
    }

    static func verifyJPEG(_ input: CIImage, context: CIContext) throws {
        let width = Int(input.extent.width), height = Int(input.extent.height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOriginalJPEG(input, context: context, colorSpace: space, to: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), cg.width == width, cg.height == height
        else { throw FocoError.message("Unexpected JPEG dimensions or decoding failure") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let bitmap = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: space, bitmapInfo: layout)
            else { throw FocoError.message("Could not decode pixels") }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var samples = [(Int, Int)]()
        for y in [0, 1, 2, height - 2, height - 1] {
            for x in [0, 1, width - 2, width - 1] { samples.append((x,y)) }
        }
        for seam in stride(from: 384, to: height, by: 384) {
            for y in (seam - 4)...min(seam + 4, height - 1) {
                for x in [15, width / 3, width - 20] { samples.append((x,y)) }
            }
        }
        for x in (width / 2 - 25)...(width / 2 + 25) { samples.append((x, height / 2)) }
        var worst = 0
        for (x,y) in samples {
            let (r,g,b) = pixel(x: x, y: y, width: width, height: height)
            let base = (y * width + x) * 4
            let delta = max(abs(Int(bytes[base]) - r), abs(Int(bytes[base + 1]) - g), abs(Int(bytes[base + 2]) - b))
            guard delta <= 12 else { throw FocoError.message("JPEG error \(delta) at (\(x),\(y)) in \(width)x\(height)") }
            worst = max(worst, delta)
        }
        print("JPEG \(width)x\(height): \(samples.count) pixel probes passed, max channel delta \(worst)/255")
    }

    static func decodedRGB(_ url: URL, size: CGSize) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Int(size.width), image.height == Int(size.height)
        else { throw FocoError.message("Invalid exported image or dimensions") }
        return try pixels(image)
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let size = CGSize(width: image.width, height: image.height)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { storage in
            guard let bitmap = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                         bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: space, bitmapInfo: layout)
            else { throw FocoError.message("Could not allocate editor result") }
            bitmap.draw(image, in: CGRect(origin: .zero, size: size))
        }
        return rgba
    }

    static func focusTargets(_ map: CIImage, context: CIContext) throws -> (CGPoint, CGPoint) {
        // Choose distinct predicted planes. A 2D synthetic scene has no known metric depth.
        let w = 12, h = 16
        let scaled = map.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / map.extent.width,
                                                          y: CGFloat(h) / map.extent.height))
        var samples = [(Float, CGPoint)]()
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var value: Float = 0
                context.render(scaled, toBitmap: &value, rowBytes: 4, bounds: CGRect(x:x, y:y, width:1, height:1), format: .Rf, colorSpace:nil)
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(w), y: 1 - (CGFloat(y) + 0.5) / CGFloat(h))
                samples.append((value, point))
            }
        }
        samples.sort { $0.0 < $1.0 }
        let far = samples[0], near = samples[samples.count - 1]
        print("Selected focus planes:", far.0, near.0)
        guard near.0 - far.0 > 0.2 else { throw FocoError.message("Fixture lacks two distinct depth planes") }
        return (far.1, near.1)
    }

    static func verifyEditor(_ scene: CIImage, targets: (CGPoint, CGPoint), context: CIContext) async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: input) }
        try context.writePNGRepresentation(of: scene, to: input, format: .RGBA8, colorSpace: space)
        let lab = Laboratory()
        let (_, _, size) = try await lab.open(input)
        var edit = Edit()
        edit.aperture = 1.4
        edit.focus = targets.0
        let first = try await lab.export(edit, .maximum)
        defer { try? FileManager.default.removeItem(at: first.url) }
        edit.focus = targets.1
        let other = try await lab.export(edit, .maximum)
        defer { try? FileManager.default.removeItem(at: other.url) }
        edit.film = .silver
        _ = try await lab.preview(edit, .maximum)
        let silver = try await lab.export(edit, .maximum)
        defer { try? FileManager.default.removeItem(at: silver.url) }
        let depth = try await lab.preview(edit, .maximum, mapOnly: true)
        guard depth.width == Int(size.width), depth.height == Int(size.height) else {
            throw FocoError.message("Depth preview dimensions differ from the photograph")
        }
        let gray = try pixels(depth)
        var mapMin = 255, mapMax = 0
        for i in stride(from: 0, to: gray.count, by: 4) {
            guard abs(Int(gray[i]) - Int(gray[i+2])) <= 1 else { throw FocoError.message("Depth preview is tinted") }
            mapMin = min(mapMin, Int(gray[i])); mapMax = max(mapMax, Int(gray[i]))
        }
        guard mapMax - mapMin > 90 else { throw FocoError.message("Depth preview is flat") }
        var looks: [Film: [UInt8]] = [:]
        edit.texture = 0
        for film in Film.allCases {
            edit.film = film
            let bitmap = try await lab.preview(edit, .maximum)
            looks[film] = try pixels(bitmap)
        }
        for (index, film) in Film.allCases.enumerated() {
            for other in Film.allCases.dropFirst(index + 1) {
                let left = looks[film]!, right = looks[other]!
                var total = 0
                for i in stride(from: 0, to: left.count, by: 16) {
                    for c in 0..<3 { total += abs(Int(left[i+c]) - Int(right[i+c])) }
                }
                let mean = Double(total) / (3 * ceil(Double(left.count) / 16))
                print("Film pair", film.rawValue, other.rawValue, "mean channel delta", mean)
                guard mean > 2.0 else { throw FocoError.message("Film curves too similar") }
            }
        }
        let a = try decodedRGB(first.url, size: size), b = try decodedRGB(other.url, size: size)
        let mono = try decodedRGB(silver.url, size: size)
        var different = 0, chromatic = 0, peakMonoChroma = 0
        var minLuma = 255, maxLuma = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if (0..<3).contains(where: { abs(Int(a[i+$0]) - Int(b[i+$0])) > 5 }) { different += 1 }
            if abs(Int(a[i]) - Int(a[i+2])) > 16 { chromatic += 1 }
            let lo = min(mono[i], mono[i+1], mono[i+2]), hi = max(mono[i], mono[i+1], mono[i+2])
            peakMonoChroma = max(peakMonoChroma, Int(hi) - Int(lo))
            minLuma = min(minLuma, Int(lo))
            maxLuma = max(maxLuma, Int(hi))
        }
        print("Editor: focus changed", different, "pixels; neutral color pixels", chromatic,
              "silver channel spread", peakMonoChroma, "silver levels", minLuma, maxLuma)
        guard different > 20, chromatic > a.count / 40, peakMonoChroma <= 4, maxLuma - minLuma > 80
        else { throw FocoError.message("Optical or film render failed its pixel checks") }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        for (width,height) in [(3024,4032),(1023,769)] {
            try autoreleasepool { try verifyJPEG(image(width: width, height: height), context: context) }
        }
        let scene = try image(width: 511, height: 683, textured: true)
        let engine = DepthBase()
        print("Metal device:", MTLCreateSystemDefaultDevice()?.name ?? "none")
        let map: DepthBase.Map
        do {
            map = try engine.estimate(scene, size: .normal, context: context)
        } catch {
            print("Production inference:", error.localizedDescription)
            guard let resource = Bundle.main.url(forResource: "DepthBase", withExtension: "mlmodelc")
            else { throw error }
            for unit in [MLComputeUnits.cpuOnly, .cpuAndGPU, .all] {
                for function in [nil, "res_1280x720"] as [String?] {
                    let config = MLModelConfiguration()
                    config.computeUnits = unit
                    config.functionName = function
                    do {
                        let probe = try MLModel(contentsOf: resource, configuration: config)
                        print("Loaded", unit.rawValue, function ?? "default", probe.modelDescription.inputDescriptionsByName["frame"]?.multiArrayConstraint?.shape ?? [])
                    } catch {
                        let reason = error as NSError
                        print("Load probe", unit.rawValue, function ?? "default", reason.domain, reason.code, reason.localizedDescription)
                    }
                }
            }
            throw error
        }
        guard map.image.extent == scene.extent, map.low.isFinite, map.high.isFinite, map.high > map.low
        else { throw FocoError.message("Invalid dimensions or disparity range from Core ML") }
        print("Core ML Base 1280x720: prediction succeeded, registered to 511x683, range \(map.low)...\(map.high)")
        try await verifyEditor(scene, targets: focusTargets(map.image, context: context), context: context)
    }
}
