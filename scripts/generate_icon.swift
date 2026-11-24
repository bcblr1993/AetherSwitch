import AppKit
import CoreGraphics
import Foundation

// Usage:
//   swift generate_icon.swift --master <input-image> --png-out <1024-png> --icns-out <AppIcon.icns>
// When --master is an opaque raster master (e.g. Concept A JPEG on light background), it extracts the
// squircle via corner flood-fill matte + anti-aliased edge feathering and places it inside the HIG
// 824x824 frame (origin 100,100) on a transparent 1024x1024 sRGB canvas with soft macOS Dock shadow.
// When --master is already a transparent 1024x1024 PNG (like website_content/.../icon.png), it preserves
// it verbatim and regenerates all .iconset resolutions + AppIcon.icns.

struct IconOptions {
    var masterPath: String?
    var pngOutPath: String?
    var icnsOutPath: String?
}

func parseArgs() -> IconOptions {
    var opts = IconOptions()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--master" where i + 1 < args.count:
            opts.masterPath = args[i + 1]; i += 2
        case "--png-out" where i + 1 < args.count:
            opts.pngOutPath = args[i + 1]; i += 2
        case "--icns-out" where i + 1 < args.count:
            opts.icnsOutPath = args[i + 1]; i += 2
        default:
            if opts.pngOutPath == nil && !args[i].hasPrefix("-") {
                opts.pngOutPath = args[i]
            }
            i += 1
        }
    }
    return opts
}

func makeBitmapContext(pixels: Int) -> (CGContext, CGColorSpace) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: space,
        bitmapInfo: bitmapInfo
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return (ctx, space)
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func extractSquircleMasterPNG(from rep: NSBitmapImageRep) -> CGImage {
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    var visited = [Bool](repeating: false, count: w * h)
    var isBG = [Bool](repeating: false, count: w * h)
    var lum = [Double](repeating: 1.0, count: w * h)
    var colors = [(Double, Double, Double)](repeating: (0, 0, 0), count: w * h)

    for y in 0..<h {
        for x in 0..<w {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .white
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            let idx = y * w + x
            colors[idx] = (r, g, b)
            lum[idx] = 0.299 * r + 0.587 * g + 0.114 * b
        }
    }

    var queue = [(Int, Int)]()
    queue.reserveCapacity(w * h / 2)
    for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
        let idx = seed.1 * w + seed.0
        if !visited[idx] {
            visited[idx] = true
            isBG[idx] = true
            queue.append(seed)
        }
    }

    var head = 0
    let cardinal = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    let diagonals = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    while head < queue.count {
        let (x, y) = queue[head]; head += 1
        for (dx, dy) in cardinal {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            let idx = ny * w + nx
            if visited[idx] { continue }
            // Stop at the unbroken dark outer obsidian groove (lum <= 0.42) surrounding the bevel.
            if lum[idx] > 0.42 {
                visited[idx] = true
                isBG[idx] = true
                queue.append((nx, ny))
            }
        }
    }

    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w where !isBG[y * w + x] {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }

    let (matteCtx, space) = makeBitmapContext(pixels: w)
    let raw = matteCtx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            let p = idx * 4
            if isBG[idx] {
                raw[p] = 0; raw[p + 1] = 0; raw[p + 2] = 0; raw[p + 3] = 0
                continue
            }
            let (r, g, b) = colors[idx]
            var bgCardinal = 0
            for (dx, dy) in cardinal {
                let nx = x + dx, ny = y + dy
                if nx < 0 || nx >= w || ny < 0 || ny >= h || isBG[ny * w + nx] { bgCardinal += 1 }
            }
            var bgDiag = 0
            for (dx, dy) in diagonals {
                let nx = x + dx, ny = y + dy
                if nx < 0 || nx >= w || ny < 0 || ny >= h || isBG[ny * w + nx] { bgDiag += 1 }
            }
            var alpha = 1.0
            if bgCardinal >= 2 {
                alpha = 0.35
            } else if bgCardinal == 1 {
                alpha = min(1.0, max(0.40, (0.45 - lum[idx]) / 0.25))
            } else if bgDiag >= 1 && lum[idx] > 0.28 {
                alpha = 0.85
            }
            raw[p] = UInt8(min(255, max(0, Int(round(r * alpha * 255)))))
            raw[p + 1] = UInt8(min(255, max(0, Int(round(g * alpha * 255)))))
            raw[p + 2] = UInt8(min(255, max(0, Int(round(b * alpha * 255)))))
            raw[p + 3] = UInt8(min(255, max(0, Int(round(alpha * 255)))))
        }
    }

    let cropped = matteCtx.makeImage()!.cropping(
        to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    )!
    let (canvas, _) = makeBitmapContext(pixels: 1024)
    let shadowColor = CGColor(colorSpace: space, components: [0.0, 0.02, 0.06, 0.30])!
    canvas.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: shadowColor)
    canvas.draw(cropped, in: CGRect(x: 100, y: 100, width: 824, height: 824))
    return canvas.makeImage()!
}

func buildIconsetAndICNS(master1024: CGImage, icnsOutPath: String) throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aetherswitch-iconset-\(UUID().uuidString)")
    let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let entries: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for entry in entries {
        let (ctx, _) = makeBitmapContext(pixels: entry.px)
        ctx.draw(master1024, in: CGRect(x: 0, y: 0, width: entry.px, height: entry.px))
        guard let scaled = ctx.makeImage() else {
            throw NSError(domain: "GenerateIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to scale icon to \(entry.px)"])
        }
        try writePNG(scaled, to: iconsetDir.appendingPathComponent(entry.name).path)
    }

    let outURL = URL(fileURLWithPath: icnsOutPath)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outURL.path]
    let pipe = Pipe()
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
        throw NSError(domain: "GenerateIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "iconutil failed: \(err)"])
    }
}

let opts = parseArgs()
guard let masterPath = opts.masterPath else {
    fputs("Usage: generate_icon.swift --master <input-image> [--png-out <1024.png>] [--icns-out <AppIcon.icns>]\n", stderr)
    exit(1)
}
let masterURL = URL(fileURLWithPath: masterPath)
guard let rep = NSBitmapImageRep(data: try Data(contentsOf: masterURL)),
      let inputCG = rep.cgImage else {
    fputs("Failed to load master image at \(masterPath)\n", stderr)
    exit(1)
}

let isAlreadyTransparent1024: Bool = {
    guard rep.hasAlpha, rep.pixelsWide == 1024, rep.pixelsHigh == 1024,
          let corner = rep.colorAt(x: 0, y: 0) else { return false }
    return corner.alphaComponent < 0.01
}()

let master1024 = isAlreadyTransparent1024 ? inputCG : extractSquircleMasterPNG(from: rep)

if let pngOutPath = opts.pngOutPath {
    try writePNG(master1024, to: pngOutPath)
    print("wrote PNG: \(pngOutPath)")
}
if let icnsOutPath = opts.icnsOutPath {
    try buildIconsetAndICNS(master1024: master1024, icnsOutPath: icnsOutPath)
    print("wrote ICNS: \(icnsOutPath)")
}
