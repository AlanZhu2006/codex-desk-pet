import AppKit
import CoreGraphics
import Foundation

enum PortraitBrightness: String, CaseIterable {
    case original, bright, brighter

    var title: String {
        switch self {
        case .original: return "原色"
        case .bright: return "明亮"
        case .brighter: return "更明亮"
        }
    }

    var gamma: Double {
        switch self {
        case .original: return 1
        case .bright: return 0.90
        case .brighter: return 0.80
        }
    }
}

/// Lift the sRGB midtones once when artwork is loaded. Alpha and geometry are
/// kept byte-for-byte; no display-time white overlay or repeated blending is
/// involved. Unsupported representations safely retain their original image.
enum PortraitColor {
    static func adjusted(_ image: CGImage, brightness: PortraitBrightness) -> CGImage {
        guard let sourceSpace = image.colorSpace,
              sourceSpace.model == .rgb,
              sourceSpace.name == CGColorSpace.sRGB else { return image }

        let source = NSBitmapImageRep(cgImage: image)
        guard source.bitsPerSample == 8, source.samplesPerPixel == 4,
              source.bitsPerPixel == 32, !source.isPlanar, source.hasAlpha,
              source.bitmapFormat.contains(.alphaNonpremultiplied),
              let pixels = source.bitmapData else { return image }

        let width = image.width, height = image.height
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !countOverflow,
              source.bytesPerRow >= rowBytes, byteCount <= 128_000_000 else { return image }

        let lookup: [UInt8] = (0...255).map { value in
            UInt8(min(255, max(0, Int((255 * pow(Double(value) / 255, brightness.gamma)).rounded()))))
        }
        let alphaFirst = source.bitmapFormat.contains(.alphaFirst)
        let alphaOffset = alphaFirst ? 0 : 3
        let redOffset = alphaFirst ? 1 : 0
        var output = [UInt8](repeating: 0, count: byteCount)
        for y in 0..<height {
            let sourceRow = y * source.bytesPerRow
            let targetRow = y * rowBytes
            for x in 0..<width {
                let input = sourceRow + x * 4
                let target = targetRow + x * 4
                let alpha = pixels[input + alphaOffset]
                output[target + 3] = alpha
                // Fully transparent RGB is intentionally zero. It cannot affect
                // visible color and stays safe for interpolation at the edge.
                guard alpha != 0 else { continue }
                output[target] = lookup[Int(pixels[input + redOffset])]
                output[target + 1] = lookup[Int(pixels[input + redOffset + 1])]
                output[target + 2] = lookup[Int(pixels[input + redOffset + 2])]
            }
        }

        // `output` is straight RGBA. Declaring it premultiplied here would
        // brighten translucent edges incorrectly and change their appearance.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(output) as CFData),
              let result = CGImage(width: width, height: height,
                                   bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: rowBytes, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: image.shouldInterpolate,
                                   intent: image.renderingIntent) else { return image }
        return result
    }

    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.PortraitColor", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                    shouldInterpolate: true, intent: .defaultIntent)!
        }
        func rgba(_ image: CGImage) -> [UInt8] {
            let rep = NSBitmapImageRep(cgImage: image)
            let source = rep.bitmapData!
            let first = rep.bitmapFormat.contains(.alphaFirst)
            let alpha = first ? 0 : 3, red = first ? 1 : 0
            var bytes: [UInt8] = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * rep.bytesPerRow + x * 4
                    bytes += [source[offset + red], source[offset + red + 1],
                              source[offset + red + 2], source[offset + alpha]]
                }
            }
            return bytes
        }

        let input: [UInt8] = [
            0, 0, 0, 255,       255, 255, 255, 255, 128, 128, 128, 255,
            64, 128, 192, 127,  90, 140, 210, 23,   44, 88, 132, 0
        ]
        let source = image(input, width: 3, height: 2)
        let natural = rgba(adjusted(source, brightness: .original))
        let brightImage = adjusted(source, brightness: .bright)
        let bright = rgba(brightImage)
        let brighter = rgba(adjusted(source, brightness: .brighter))
        try require(Array(bright[0..<4]) == [0, 0, 0, 255], "Brightness must retain black")
        try require(Array(bright[4..<8]) == [255, 255, 255, 255], "Brightness must retain white")
        try require(Array(bright[8..<12]) == [137, 137, 137, 255], "Bright midtone fixture should map 128 to 137")
        try require(brighter[8] == 147 && brighter[8] > bright[8], "Brighter must lift midtones further")
        try require(Array(bright[12..<16]) == [73, 137, 198, 127], "Translucent pixels need straight RGB adjustment, not a premultiplied lift")
        for index in stride(from: 3, to: input.count, by: 4) {
            try require(natural[index] == input[index] && bright[index] == input[index] && brighter[index] == input[index],
                        "Brightness changed alpha or the opaque shape")
        }
        try require(Array(natural[0..<20]) == Array(input[0..<20]), "Original mode should retain all visible source colors")
        for output in [natural, bright, brighter] {
            try require(Array(output[20..<24]) == [0, 0, 0, 0], "Hidden transparent RGB should be zero")
        }
        try require(brightImage.width == 3 && brightImage.height == 2 && brightImage.colorSpace?.name == CGColorSpace.sRGB,
                    "Brightness must preserve geometry and output sRGB")
        try require(brightImage.alphaInfo == .last, "Straight RGB data must be declared as straight alpha")

        // Non-sRGB or already-premultiplied inputs are deliberately left alone;
        // they must not be interpreted as this straight-RGBA representation.
        let premultiplied = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: CGDataProvider(data: Data([UInt8(32), 64, 96, 127]) as CFData)!,
                                    decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        try require(adjusted(premultiplied, brightness: .bright) === premultiplied,
                    "Unsupported premultiplied inputs should safely retain the source")
    }
}
