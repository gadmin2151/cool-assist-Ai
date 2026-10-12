import AppKit

// Same normalized C / conversation / check symbol as BrandMark.swift.
func symbolPath(in rect: CGRect) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 91, y: 32))
  path.addCurve(
    to: CGPoint(x: 50, y: 7), control1: CGPoint(x: 85, y: 15), control2: CGPoint(x: 71, y: 7))
  path.addCurve(
    to: CGPoint(x: 7, y: 50), control1: CGPoint(x: 25, y: 7), control2: CGPoint(x: 7, y: 26))
  path.addCurve(
    to: CGPoint(x: 14, y: 73), control1: CGPoint(x: 7, y: 59), control2: CGPoint(x: 9, y: 66))
  path.addLine(to: CGPoint(x: 6, y: 94))
  path.addLine(to: CGPoint(x: 25, y: 86))
  path.addCurve(
    to: CGPoint(x: 50, y: 93), control1: CGPoint(x: 33, y: 91), control2: CGPoint(x: 41, y: 93))
  path.addCurve(
    to: CGPoint(x: 91, y: 67), control1: CGPoint(x: 70, y: 93), control2: CGPoint(x: 85, y: 82))
  path.addLine(to: CGPoint(x: 71, y: 67))
  path.addCurve(
    to: CGPoint(x: 50, y: 76), control1: CGPoint(x: 66, y: 73), control2: CGPoint(x: 60, y: 76))
  path.addCurve(
    to: CGPoint(x: 25, y: 50), control1: CGPoint(x: 35, y: 76), control2: CGPoint(x: 25, y: 65))
  path.addCurve(
    to: CGPoint(x: 50, y: 24), control1: CGPoint(x: 25, y: 35), control2: CGPoint(x: 35, y: 24))
  path.addCurve(
    to: CGPoint(x: 71, y: 32), control1: CGPoint(x: 60, y: 24), control2: CGPoint(x: 66, y: 26))
  path.closeSubpath()
  path.move(to: CGPoint(x: 34, y: 49))
  path.addLine(to: CGPoint(x: 41, y: 42))
  path.addLine(to: CGPoint(x: 50, y: 51))
  path.addLine(to: CGPoint(x: 67, y: 34))
  path.addLine(to: CGPoint(x: 76, y: 43))
  path.addLine(to: CGPoint(x: 50, y: 69))
  path.closeSubpath()
  var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
    .scaledBy(x: rect.width / 100, y: rect.height / 100)
  return path.copy(using: &transform) ?? path
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8,
      bytesPerRow: size * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("Missing icon context") }
  let scale = CGFloat(size) / 1024
  context.scaleBy(x: scale, y: scale)
  context.setFillColor(CGColor(srgbRed: 214 / 255, green: 0, blue: 0, alpha: 1))
  context.addPath(
    CGPath(
      roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928),
      cornerWidth: 220, cornerHeight: 220, transform: nil))
  context.fillPath()
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  context.addPath(symbolPath(in: CGRect(x: 190, y: 190, width: 644, height: 644)))
  context.setFillColor(CGColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1))
  context.fillPath()
  guard let image = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  else { fatalError("Icon rendering failed") }
  if size <= 512 { try png.write(to: output.appendingPathComponent("icon_\(size)x\(size).png")) }
  if size >= 32 {
    try png.write(to: output.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
  }
}
