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

    static func image(width: Int, height: Int) throws -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x: x, y: y, width: width, height: height)
                let base = (y * width + x) * 4
                rgba[base] = UInt8(r)
                rgba[base + 1] = UInt8(g)
                rgba[base + 2] = UInt8(b)
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

    static func verifyEditor(_ scene: CIImage, context: CIContext) async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: input) }
        try context.writePNGRepresentation(of: scene, to: input, format: .RGBA8, colorSpace: space)
        let lab = Laboratory()
        let (_, _, size) = try await lab.open(input)
        var edit = Edit()
        edit.aperture = 1.4
        edit.focus = CGPoint(x: 0.12, y: 0.15)
        let first = try await lab.export(edit, .normal)
        defer { try? FileManager.default.removeItem(at: first.url) }
        edit.focus = CGPoint(x: 0.85, y: 0.85)
        let other = try await lab.export(edit, .normal)
        defer { try? FileManager.default.removeItem(at: other.url) }
        edit.film = .silver
        _ = try await lab.preview(edit, .normal)
        let silver = try await lab.export(edit, .normal)
        defer { try? FileManager.default.removeItem(at: silver.url) }
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
        let scene = try image(width: 511, height: 683)
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
                for function in [nil, "res_854x480"] as [String?] {
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
        print("Core ML Base 854x480: prediction succeeded, registered to 511x683, range \(map.low)...\(map.high)")
        try await verifyEditor(scene, context: context)
    }
}
