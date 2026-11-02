import CoreGraphics
import Foundation

/// The classic Codex character is already composed inside 192x208 cells.
/// Keep the complete cell, including transparent margins and the shared foot
/// baseline, so callers can draw it at the native cell size without shrinking
/// the character a second time. Colors are intentionally left untouched.
struct CodexArtwork {
    struct Clip {
        let frames: [CGImage]
        let durations: [TimeInterval]
    }

    private struct Specification {
        let expression: String
        let row: Int
        let milliseconds: [Int]
    }

    private static let columns = 8
    private static let rows = 9
    private static let cellWidth = 192
    private static let cellHeight = 208
    private static let specifications: [Specification] = [
        Specification(expression: "smile", row: 0, milliseconds: [1680, 660, 660, 840, 840, 1920]),
        Specification(expression: "typing", row: 7, milliseconds: [120, 120, 120, 120, 120, 220]),
        Specification(expression: "notes", row: 8, milliseconds: [150, 150, 150, 150, 150, 280]),
        Specification(expression: "crying", row: 5, milliseconds: [140, 140, 140, 140, 140, 140, 140, 240]),
        Specification(expression: "knock", row: 3, milliseconds: [140, 140, 140, 280]),
        Specification(expression: "confetti", row: 4, milliseconds: [140, 140, 140, 140, 280]),
        Specification(expression: "confident", row: 6, milliseconds: [150, 150, 150, 150, 150, 260])
    ]
    private static let extraSpecifications: [Specification] = [
        Specification(expression: "smile-closed", row: 0, milliseconds: [400, 200, 200, 240, 240, 900]),
        Specification(expression: "panic", row: 1, milliseconds: [160, 160, 160, 180, 180, 480]),
        Specification(expression: "guilty", row: 2, milliseconds: [750, 220, 180, 280, 220, 1050]),
        Specification(expression: "stone", row: 3, milliseconds: [1000, 200, 400, 220, 300, 1300])
    ]

    private static func cell(in atlas: CGImage, row: Int, column: Int) -> CGImage? {
        guard (0..<(atlas.height / cellHeight)).contains(row), (0..<columns).contains(column) else { return nil }
        // CGImage cropping follows the atlas's top-left pixel coordinates.
        return atlas.cropping(to: CGRect(x: column * cellWidth, y: row * cellHeight,
                                        width: cellWidth, height: cellHeight))
    }

    static func clips(atlas: CGImage) -> [String: Clip] {
        guard atlas.width == columns * cellWidth, atlas.height == rows * cellHeight else { return [:] }
        return makeClips(atlas: atlas, specifications: specifications)
    }

    /// Four additional, genuinely redrawn expression strips. They use the same
    /// full-cell composition as the classic atlas and bypass color grading.
    static func extraClips(atlas: CGImage) -> [String: Clip] {
        guard atlas.width == columns * cellWidth, atlas.height == 4 * cellHeight else { return [:] }
        return makeClips(atlas: atlas, specifications: extraSpecifications)
    }

    static func clips(atlas: CGImage, extraAtlas: CGImage) -> [String: Clip] {
        let classic = clips(atlas: atlas)
        let extra = extraClips(atlas: extraAtlas)
        guard classic.count == 7, extra.count == 4,
              Set(classic.keys).isDisjoint(with: Set(extra.keys)) else { return [:] }
        return classic.merging(extra) { _, extra in extra }
    }

    private static func makeClips(atlas: CGImage, specifications: [Specification]) -> [String: Clip] {
        var result: [String: Clip] = [:]
        for specification in specifications {
            let frames = specification.milliseconds.indices.compactMap {
                cell(in: atlas, row: specification.row, column: $0)
            }
            guard frames.count == specification.milliseconds.count else { return [:] }
            result[specification.expression] = Clip(
                frames: frames,
                durations: specification.milliseconds.map { Double($0) / 1000 }
            )
        }
        return result
    }

    private static func rgba(_ image: CGImage) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法检查经典 Codex 图集像素"])
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data else {
            throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取经典 Codex 图集像素"])
        }
        return Data(bytes: pixels, count: image.width * image.height * 4)
    }
    private static func hasAlpha(_ bytes: Data) -> Bool {
        stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
    }

    static func selfTest(atlas: CGImage) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        try require(atlas.width == 1536 && atlas.height == 1872, "经典 Codex 图集应为1536×1872")
        try require(atlas.colorSpace?.name == CGColorSpace.sRGB, "经典 Codex 图集应按sRGB解释颜色")
        let decoded = clips(atlas: atlas)
        let expected: [String: (row: Int, milliseconds: [Int])] = [
            "smile": (0, [1680, 660, 660, 840, 840, 1920]),
            "typing": (7, [120, 120, 120, 120, 120, 220]),
            "notes": (8, [150, 150, 150, 150, 150, 280]),
            "crying": (5, [140, 140, 140, 140, 140, 140, 140, 240]),
            "knock": (3, [140, 140, 140, 280]),
            "confetti": (4, [140, 140, 140, 140, 280]),
            "confident": (6, [150, 150, 150, 150, 150, 260])
        ]
        try require(Set(decoded.keys) == Set(expected.keys), "经典 Codex 表情映射不完整")
        for (name, specification) in expected {
            guard let clip = decoded[name] else { continue }
            try require(clip.frames.count == specification.milliseconds.count
                        && clip.durations.count == clip.frames.count,
                        "经典 Codex 动画帧数或时长数量错误：\(name)")
            for index in clip.frames.indices {
                let frame = clip.frames[index]
                try require(frame.width == 192 && frame.height == 208, "必须保留完整192×208格子")
                try require(abs(clip.durations[index] - Double(specification.milliseconds[index]) / 1000) < 0.000001,
                            "经典 Codex 动画时长不符：\(name)")
                guard let original = cell(in: atlas, row: specification.row, column: index) else {
                    throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "经典 Codex 动画超出图集范围"])
                }
                let pixels = try rgba(frame)
                let reference = try rgba(original)
                try require(pixels == reference && hasAlpha(pixels), "经典 Codex 动画颜色或像素被改写：\(name)")
            }
        }

        // This is the exact source pose identified in the user's reference.
        guard let referencePose = cell(in: atlas, row: 8, column: 5),
              let notesLast = decoded["notes"]?.frames.last else {
            throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少参考图对应的看书姿态"])
        }
        let expectedPose = try rgba(referencePose)
        let actualPose = try rgba(notesLast)
        try require(actualPose == expectedPose, "看书末帧必须与经典图集第8行第5列完全一致")

        let requiredFrames = [6, 8, 8, 4, 5, 8, 6, 6, 6]
        var usedCount = 0, emptyCount = 0
        for row in 0..<9 {
            for column in 0..<8 {
                guard let frame = cell(in: atlas, row: row, column: column) else {
                    throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "经典 Codex 单格超出边界"])
                }
                let visible = hasAlpha(try rgba(frame))
                if column < requiredFrames[row] {
                    usedCount += 1
                    try require(visible, "经典 Codex 有效动画格不得为空")
                } else {
                    emptyCount += 1
                    try require(!visible, "经典 Codex 未使用的动画格必须透明")
                }
            }
        }
        try require(usedCount == 57 && emptyCount == 15, "经典 Codex 图集应含57帧与15个透明空格")
        if let singleCell = cell(in: atlas, row: 0, column: 0) {
            try require(clips(atlas: singleCell).isEmpty, "不支持的图集尺寸不得被误认为整张图集")
        }
    }

    static func selfTest(atlas: CGImage, extraAtlas: CGImage) throws {
        try selfTest(atlas: atlas)
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func changedPixels(_ left: Data, _ right: Data) -> Int {
            left.withUnsafeBytes { leftBuffer in
                right.withUnsafeBytes { rightBuffer in
                    let a = leftBuffer.bindMemory(to: UInt8.self)
                    let b = rightBuffer.bindMemory(to: UInt8.self)
                    var changed = 0
                    for offset in stride(from: 0, to: a.count, by: 4) {
                        if a[offset] != b[offset] || a[offset + 1] != b[offset + 1]
                            || a[offset + 2] != b[offset + 2] || a[offset + 3] != b[offset + 3] {
                            changed += 1
                        }
                    }
                    return changed
                }
            }
        }

        try require(extraAtlas.width == 1536 && extraAtlas.height == 832, "补充表情图集应为1536×832")
        try require(extraAtlas.colorSpace?.name == CGColorSpace.sRGB, "补充表情图集应按sRGB解释颜色")
        let extra = extraClips(atlas: extraAtlas)
        let expected: [String: (row: Int, milliseconds: [Int])] = [
            "smile-closed": (0, [400, 200, 200, 240, 240, 900]),
            "panic": (1, [160, 160, 160, 180, 180, 480]),
            "guilty": (2, [750, 220, 180, 280, 220, 1050]),
            "stone": (3, [1000, 200, 400, 220, 300, 1300])
        ]
        try require(Set(extra.keys) == Set(expected.keys), "补充表情映射必须覆盖眯眼笑、慌张、委屈、石化")
        for (name, specification) in expected {
            guard let clip = extra[name] else { continue }
            try require(clip.frames.count == 6 && clip.durations.count == 6, "每组补充表情必须有6帧：\(name)")
            var pixels: [Data] = []
            for index in clip.frames.indices {
                let frame = clip.frames[index]
                try require(frame.width == 192 && frame.height == 208, "补充表情也必须保留完整192×208格子")
                try require(abs(clip.durations[index] - Double(specification.milliseconds[index]) / 1000) < 0.000001,
                            "补充表情动画时长不符：\(name)")
                guard let original = cell(in: extraAtlas, row: specification.row, column: index) else {
                    throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "补充表情单格超出图集范围"])
                }
                let bytes = try rgba(frame)
                let reference = try rgba(original)
                try require(bytes == reference && hasAlpha(bytes), "补充表情帧像素错误或为空：\(name)")
                for x in 0..<192 {
                    try require(bytes[x * 4 + 3] == 0 && bytes[(207 * 192 + x) * 4 + 3] == 0,
                                "补充表情上下边缘不得裁切人物：\(name)")
                }
                for y in 0..<208 {
                    try require(bytes[(y * 192) * 4 + 3] == 0 && bytes[(y * 192 + 191) * 4 + 3] == 0,
                                "补充表情左右边缘不得裁切人物：\(name)")
                }
                pixels.append(bytes)
            }
            try require(Set(pixels).count == 6, "补充表情必须有6张不同画面，不能重复单张立绘：\(name)")
            for index in pixels.indices {
                try require(changedPixels(pixels[index], pixels[(index + 1) % pixels.count]) >= 32,
                            "补充表情相邻帧变化不足：\(name)")
            }
            for column in 6..<8 {
                guard let unused = cell(in: extraAtlas, row: specification.row, column: column) else {
                    throw NSError(domain: "ClaudeDeskPet.CodexArtwork", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "补充图集空格超出边界"])
                }
                let bytes = try rgba(unused)
                try require(!hasAlpha(bytes), "补充表情每行最后两格必须透明")
            }
        }

        let merged = clips(atlas: atlas, extraAtlas: extraAtlas)
        let allExpressions = Set(["smile", "smile-closed", "typing", "notes", "knock", "confetti",
                                  "panic", "guilty", "stone", "confident", "crying"])
        try require(Set(merged.keys) == allExpressions && merged.values.allSatisfy { $0.frames.count > 1 },
                    "Codex默认风格必须为全部11种表情提供逐帧动画")
        let classic = clips(atlas: atlas)
        for (name, clip) in classic {
            guard let combined = merged[name] else { continue }
            try require(combined.durations == clip.durations && combined.frames.count == clip.frames.count,
                        "扩展图集不得改写原有7组动画")
            for index in clip.frames.indices {
                let before = try rgba(clip.frames[index])
                let after = try rgba(combined.frames[index])
                try require(before == after, "扩展图集不得改写原有7组像素：\(name)")
            }
        }
        try require(extraClips(atlas: atlas).isEmpty && clips(atlas: extraAtlas).isEmpty,
                    "主图集和补充图集尺寸不得互相误识别")
    }
}
