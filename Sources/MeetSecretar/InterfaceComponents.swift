import SwiftUI

struct IconTile: View {
  let symbol: String
  var color: Color = Palette.highlight
  var size: CGFloat = 36

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.43, weight: .medium))
      .foregroundStyle(color).frame(width: size, height: size)
      .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
      .accessibilityHidden(true)
  }
}

/// A static illustration: it never implies that recording is already running.
struct MeetingWaveform: View {
  private let heights: [CGFloat] = [14, 26, 40, 23, 55, 36, 64, 44, 22, 39, 16]
  var body: some View {
    HStack(spacing: 5) {
      ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
        Capsule().fill(Palette.accent.gradient)
          .frame(width: 5, height: height).opacity(index == 0 || index == 10 ? 0.3 : 0.65)
      }
    }.accessibilityHidden(true).allowsHitTesting(false)
  }
}

struct StatusBadge: View {
  let text: String
  var symbol: String? = nil
  var color: Color = Palette.highlight

  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol) }
      Text(text).lineLimit(1)
    }.font(.system(size: 10, weight: .medium)).foregroundStyle(color)
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(color.opacity(0.10), in: Capsule())
  }
}

extension View {
  func panelSurface(tint: Color = Palette.accent, cornerRadius: CGFloat = 16) -> some View {
    background {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Palette.card)
    }
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius)
        .strokeBorder(Palette.border, lineWidth: 1).allowsHitTesting(false)
    }
  }
}

/// The complete label bounds take clicks, including padding and spacers.
struct SurfaceButtonStyle: ButtonStyle {
  var selected = false
  var prominent = false
  var bordered = true

  func makeBody(configuration: Configuration) -> some View {
    Surface(
      configuration: configuration, selected: selected, prominent: prominent, bordered: bordered)
  }

  private struct Surface: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let prominent: Bool
    let bordered: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .contentShape(Rectangle())
        .foregroundStyle(prominent ? Color.white : Palette.text)
        .background {
          RoundedRectangle(cornerRadius: 11).fill(
            LinearGradient(
              colors: prominent
                ? [Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), Palette.accent]
                : selected
                  ? [Palette.accent.opacity(0.07), Palette.accent.opacity(0.025)]
                  : [
                    Palette.raised.opacity(configuration.isPressed ? 1 : hovered ? 0.9 : 0.55),
                    Palette.raised.opacity(0.35),
                  ],
              startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 11).strokeBorder(
            selected
              ? Palette.accent.opacity(0.14)
              : Palette.border.opacity(bordered ? (hovered ? 1 : 0.8) : 0), lineWidth: 1
          )
          .allowsHitTesting(false)
        }
        .shadow(
          color: prominent && enabled && hovered ? Palette.accent.opacity(0.06) : .clear,
          radius: 6, y: 2
        )
        .opacity(enabled ? 1 : 0.45)
        .overlay(alignment: .leading) {
          if selected && !prominent {
            RoundedRectangle(cornerRadius: 2).fill(Palette.accent)
              .frame(width: 2).padding(.vertical, 10).allowsHitTesting(false)
          }
        }
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        .onHover { hovered = $0 }
    }
  }
}

/// Document navigation keeps all sections visible without competing with the record action.
struct DocumentTabs<Value: Hashable>: View {
  let choices: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      ForEach(choices, id: \.self) { choice in
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selection = choice }
        } label: {
          Text(title(choice)).font(
            .system(size: 12, weight: selection == choice ? .semibold : .regular)
          )
          .foregroundStyle(selection == choice ? Palette.text : Palette.muted)
          .padding(.horizontal, 12).frame(minHeight: 40)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .overlay(alignment: .bottom) {
            Capsule().fill(selection == choice ? Palette.accent : .clear).frame(height: 3)
          }
        }.buttonStyle(.plain)
          .accessibilityAddTraits(selection == choice ? .isSelected : [])
      }
    }.overlay(alignment: .bottom) { Divider().offset(y: 2) }
      .accessibilityElement(children: .contain).accessibilityLabel("Раздел встречи")
  }
}

/// Heights derive solely from captured audio levels, never from a simulated listening loop.
struct LiveWaveform: View {
  let level: Double
  let paused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let weights: [CGFloat] = [
    0.23, 0.4, 0.65, 0.45, 0.84, 0.58, 1, 0.72, 0.93, 0.54, 0.8, 0.44, 0.68, 0.35, 0.52, 0.3, 0.18,
  ]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
        Capsule().fill(paused ? Palette.muted : Palette.accent)
          .frame(width: 3, height: 3 + weight * CGFloat(paused ? 0 : min(1, max(0, level))) * 28)
      }
    }.frame(height: 32)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
      .accessibilityLabel(paused ? "На паузе" : "Уровень записываемого звука")
      .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) процентов")
      .allowsHitTesting(false)
  }
}

struct SelectionTabs<Value: Hashable>: View {
  let label: String
  let choices: [Value]
  @Binding var selection: Value
  let title: (Value) -> String

  var body: some View {
    HStack(spacing: 4) {
      ForEach(choices, id: \.self) { choice in
        Button {
          selection = choice
        } label: {
          Text(title(choice)).font(.system(size: 12, weight: .medium))
            .lineLimit(1).frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(
          SurfaceButtonStyle(
            selected: selection == choice, bordered: false)
        )
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
      }
    }.padding(4).background(Palette.sidebar.opacity(0.7))
      .clipShape(RoundedRectangle(cornerRadius: 13))
      .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}
