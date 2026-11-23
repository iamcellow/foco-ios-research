import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The graph remains in global coordinates. Core Image requests each filter's
/// neighborhood beyond a strip, including highlights that cross a strip boundary.
func writeOriginalJPEG(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace, to url: URL) throws {
    let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
    guard width > 0, height > 0 else { throw FocoError.message("Dimensões inválidas para exportar.") }
    let rowBytes = 4 * width
    let cache = url.deletingPathExtension().appendingPathExtension("rgba")
    guard FileManager.default.createFile(atPath: cache.path, contents: nil) else { throw FocoError.message("Sem espaço para revelar a foto.") }
    defer { try? FileManager.default.removeItem(at: cache) }
    let handle = try FileHandle(forWritingTo: cache)
    do {
        for top in stride(from: 0, to: height, by: 384) {
            try autoreleasepool {
                let rows = min(384, height - top)
                let region = CGRect(x: 0, y: height - top - rows, width: width, height: rows)
                guard let strip = context.createCGImage(image, from: region, format: .RGBA8, colorSpace: colorSpace) else {
                    throw FocoError.message("Falha no bloco de exportação da linha \(top).")
                }
                var data = Data(count: rowBytes * rows)
                try data.withUnsafeMutableBytes { buffer in
                    guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                    else {
                        throw FocoError.message("Memória indisponível para o bloco de exportação.")
                    }
                    bitmap.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
                }
                try handle.write(contentsOf: data)
            }
        }
        try handle.close()
    } catch { try? handle.close(); throw error }
    guard let provider = CGDataProvider(url: cache as CFURL),
          let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
        throw FocoError.message("Falha ao iniciar o arquivo JPEG.")
    }
    CGImageDestinationAddImage(target, cg, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
    guard CGImageDestinationFinalize(target) else {
        try? FileManager.default.removeItem(at: url)
        throw FocoError.message("Falha ao gravar o JPEG. Verifique o espaço disponível.")
    }
}
