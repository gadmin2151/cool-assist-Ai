import AppKit
import SwiftUI

/// The approved C / conversation / check symbol, drawn independently of display resolution.
enum CoolAssistSymbol {
  static func path(in rect: CGRect) -> CGPath {
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

  static func menuBarImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.addPath(path(in: rect.insetBy(dx: 1, dy: 1)))
      context.setFillColor(NSColor.black.cgColor)
      context.fillPath()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Cool Assist Ai"
    return image
  }
}

struct BrandMark: View {
  var size: CGFloat = 40
  var body: some View {
    Canvas { context, canvas in
      let inset = canvas.width * 0.16
      context.fill(
        Path(
          CoolAssistSymbol.path(
            in: CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset))),
        with: .color(Palette.text))
    }
    .frame(width: size, height: size)
    .background(Palette.accent, in: RoundedRectangle(cornerRadius: size * 0.27))
    .accessibilityHidden(true)
  }
}
