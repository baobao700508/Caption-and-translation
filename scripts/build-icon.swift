import AppKit
import Foundation

// Render the editable SVG into every macOS icon size using native tools.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/build-icon.swift source.svg output.icns\n", stderr)
    exit(1)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Cannot render icon SVG: \(source.path)\n", stderr)
    exit(1)
}
let files = FileManager.default
let iconset = files.temporaryDirectory.appendingPathComponent("LiveCaption-\(UUID().uuidString).iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: iconset) }
let master = iconset.appendingPathComponent("master.png")
try png.write(to: master)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        let target = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let resize = Process()
        resize.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        resize.arguments = ["--resampleHeightWidth", "\(pixels)", "\(pixels)", master.path, "--out", target.path]
        resize.standardOutput = FileHandle.nullDevice
        try resize.run()
        resize.waitUntilExit()
        guard resize.terminationStatus == 0 else { exit(resize.terminationStatus) }
    }
}
try files.removeItem(at: master)
try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { exit(converter.terminationStatus) }
print("App icon: \(output.path)")
