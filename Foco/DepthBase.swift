import CoreGraphics
import CoreImage
import CoreML
import Foundation

enum FocoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(s) = self {
            return s
        }; return nil
    }
}

enum DepthSize: String, CaseIterable, Identifiable {
    case compact = "640x360", normal = "854x480", fine = "1138x640"
    var id: Self {
        self
    }

    var title: String {
        switch self { case .compact: return "Econômico"; case .normal: return "Normal"; case .fine: return "Detalhado" }
    }
}

/// Called only from the serial image worker. State starts empty for each still.
final class DepthBase {
    private var loaded: (DepthSize, MLModel)?
    struct Map {
        var image: CIImage
        let low: Float
        let high: Float
        /// Width of the padded model frame expressed in source pixels.
        let frameWidth: CGFloat
    }

    func estimate(_ image: CIImage, size: DepthSize, context: CIContext) throws -> Map {
        let model: MLModel
        if let (last, existing) = loaded, last == size {
            model = existing
        } else {
            loaded = nil
            guard let url = Bundle.main.url(forResource: "DepthBase", withExtension: "mlmodelc") else {
                throw FocoError.message("Pacote Base ausente no aplicativo.")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            configuration.functionName = "res_" + size.rawValue
            model = try MLModel(contentsOf: url, configuration: configuration)
            loaded = (size, model)
        }
        guard let shape = model.modelDescription.inputDescriptionsByName["frame"]?.multiArrayConstraint?.shape,
              shape.count == 4 else { throw FocoError.message("Entrada Core ML incompatível.") }
        let w = shape[3].intValue, h = shape[2].intValue
        // A sideways portrait changes the model's scene priors. Letterbox in
        // the upright orientation and remove the padding after prediction.
        let src = image.atOrigin
        let scale = min(CGFloat(w) / src.extent.width, CGFloat(h) / src.extent.height)
        let fitted = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (CGFloat(w) - fitted.extent.width) / 2, dy = (CGFloat(h) - fitted.extent.height) / 2
        let padded = fitted.transformed(by: CGAffineTransform(translationX: dx, y: dy)).clampedToExtent()
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let frame = context.createCGImage(padded, from: rect, format: .RGBA8, colorSpace: space) else {
            throw FocoError.message("Falha ao preparar a entrada RGB.")
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let cg = CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else {
                throw FocoError.message("Falha ao alocar o quadro RGB.")
            }
            cg.draw(frame, in: rect)
        }
        let input = try MLMultiArray(shape: shape, dataType: .float16)
        let dst = input.dataPointer.assumingMemoryBound(to: Float16.self)
        let strides = input.strides.map(\.intValue)
        let lut = (0 ... 255).map { Float16(Float($0) / 255) }
        for y in 0 ..< h {
            for x in 0 ..< w {
                let pixel = 4 * (y * w + x), base = y * strides[2] + x * strides[3]
                for c in 0 ..< 3 {
                    dst[c * strides[1] + base] = lut[Int(bytes[pixel + c])]
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["frame": MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: provider, using: model.makeState())
        guard let depth = result.featureValue(for: "inverse_depth")?.multiArrayValue,
              depth.dataType == .float16, depth.shape.suffix(2).map(\.intValue) == [h, w]
        else {
            throw FocoError.message("Mapa de profundidade incompatível.")
        }
        let pointer = depth.dataPointer.assumingMemoryBound(to: Float16.self)
        let step = depth.strides.map(\.intValue)
        var values = [Float](repeating: 0, count: w * h)
        var valid = [Float]()
        for y in 0 ..< h {
            for x in 0 ..< w {
                let value = Float(pointer[y * step[step.count - 2] + x * step[step.count - 1]])
                guard value.isFinite else { throw FocoError.message("O modelo retornou profundidade inválida.") }
                values[y * w + x] = value
                if x % 3 == 0, y % 3 == 0, CGFloat(x) >= dx, CGFloat(x) < CGFloat(w) - dx, CGFloat(y) >= dy, CGFloat(y) < CGFloat(h) - dy {
                    valid.append(value)
                }
            }
        }
        guard !valid.isEmpty else { throw FocoError.message("A proporção da imagem impede estimar profundidade.") }
        valid.sort()
        let lo = valid[Int(Double(valid.count - 1) * 0.004)], hi = valid[Int(Double(valid.count - 1) * 0.996)]
        for i in values.indices {
            values[i] = max(0, min(1, (values[i] - lo) / max(hi - lo, 0.000001)))
        }
        let data = values.withUnsafeBytes { Data($0) }
        let gray = CIImage(bitmapData: data, bytesPerRow: w * 4, size: rect.size, format: .Rf, colorSpace: nil)
        let crop = CGRect(x: dx, y: dy, width: fitted.extent.width, height: fitted.extent.height)
        let restored = gray.cropped(to: crop).atOrigin.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return Map(image: restored.atOrigin.cropped(to: image.extent),
                   low: lo, high: hi, frameWidth: CGFloat(w) / scale)
    }
}

extension CIImage {
    var atOrigin: CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
