import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Native vector artwork matching Data, Retriever and Orchestrator's icon family.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
let navy = CGColor(srgbRed: 3.0/255, green: 36.0/255, blue: 87.0/255, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let iconset = root.appendingPathComponent("RemoteAgent.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func glyph(_ context: CGContext) {
    context.setStrokeColor(navy); context.setLineWidth(32)
    context.setLineCap(.round); context.setLineJoin(.round)
    for y: CGFloat in [338, 512, 685] {
        context.move(to: CGPoint(x: 140, y: y)); context.addLine(to: CGPoint(x: 238, y: y))
        context.move(to: CGPoint(x: 786, y: y)); context.addLine(to: CGPoint(x: 884, y: y))
    }
    context.strokePath()
    context.addPath(CGPath(roundedRect: CGRect(x: 238, y: 234, width: 548, height: 552), cornerWidth: 92, cornerHeight: 92, transform: nil))
    context.strokePath()
    let center = CGPoint(x: 512, y: 512)
    let outer = [CGPoint(x: 355, y: 635), CGPoint(x: 355, y: 385), CGPoint(x: 670, y: 610), CGPoint(x: 670, y: 405)]
    context.setLineWidth(28)
    for point in outer { context.move(to: center); context.addLine(to: point) }
    context.strokePath()
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for point in outer + [center] {
        context.addEllipse(in: CGRect(x: point.x - 45, y: point.y - 45, width: 90, height: 90))
        context.drawPath(using: .fillStroke)
    }
}
func render(_ pixels: Int, framed: Bool = true) -> CGImage {
    let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if !framed {
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        bitmap.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        glyph(bitmap); return bitmap.makeImage()!
    }
    let grid: (CGFloat, CGFloat)
    switch pixels {
    case 16: grid = (1, 2.785)
    case 32: grid = (2, 5.75)
    case 64: grid = (6, 11.5)
    case 128: grid = (12, 23)
    case 256: grid = (25, 46)
    case 512: grid = (50, 92)
    default: grid = (100, 184)
    }
    let edge = CGFloat(pixels), tile = CGRect(x: grid.0, y: grid.0, width: edge - 2*grid.0, height: edge - 2*grid.0)
    bitmap.saveGState()
    bitmap.setShadow(offset: CGSize(width: 0, height: -edge*10/1024), blur: edge*10/1024, color: CGColor(gray: 0, alpha: 0.18))
    bitmap.addPath(CGPath(roundedRect: tile, cornerWidth: grid.1, cornerHeight: grid.1, transform: nil))
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fillPath(); bitmap.restoreGState()
    bitmap.translateBy(x: tile.minX, y: tile.minY); bitmap.scaleBy(x: tile.width/1024, y: tile.height/1024)
    glyph(bitmap)
    return bitmap.makeImage()!
}
func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(encoder, image, nil); precondition(CGImageDestinationFinalize(encoder))
    return data as Data
}
func chunk(_ name: String, _ payload: Data) -> Data {
    var result = Data(name.utf8), size = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }; result.append(payload); return result
}
var payload = Data(), images: [Int: Data] = [:]
for (kind, size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
    let data = png(render(size)); images[size] = data
    try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    payload.append(chunk(kind, data))
}
try chunk("icns", payload).write(to: root.appendingPathComponent("RemoteAgent.icns"))
try images[1024]!.write(to: root.appendingPathComponent("RemoteAgent-macOS.png"))
try png(render(1024, framed: false)).write(to: root.appendingPathComponent("RemoteAgent.png"))
let catalog = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
let slots = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String: Any]
for slot in slots["images"] as! [[String: String]] {
    let size = Int(slot["size"]!.components(separatedBy: "x")[0])!
    let scale = Int(slot["scale"]!.replacingOccurrences(of: "x", with: ""))!
    try images[size*scale]!.write(to: catalog.appendingPathComponent(slot["filename"]!))
}
print("Exported RemoteAgent navy-and-white artwork, seven ICNS sizes and native asset catalog")
