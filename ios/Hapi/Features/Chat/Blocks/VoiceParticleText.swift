import HapiUI
import SwiftUI
import UIKit

/// The transcript remains accessible as text; only a changed voice draft gets a transient canvas.
struct VoiceParticleText: View {
  let text: String
  @Environment(\.hapiTypography) private var typography
  @Environment(\.hapiTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var previous: String?
  @State private var revision = UUID()

  var body: some View {
    ZStack(alignment: .topLeading) {
      Text(verbatim: text).font(typography.bodyFont).lineSpacing(typography.bodyLineSpacing)
        .opacity(previous == nil ? 1 : 0)
      if let previous {
        Text(verbatim: previous).font(typography.bodyFont).lineSpacing(typography.bodyLineSpacing).hidden()
      }
    }
    .overlay(alignment: .topLeading) {
      if let previous {
        ParticleTextCanvas(old: previous, new: text,
          font: .systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .semibold : .regular),
          lineSpacing: typography.bodyLineSpacing, color: UIColor(theme.textPrimary)) {
          self.previous = nil
        }
        .id(revision)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .onChange(of: text) { old, new in
      revision = UUID()
      previous = Self.animationSource(from: old, to: new, reduceMotion: reduceMotion)
    }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced { previous = nil }
    }
    .onDisappear { previous = nil }
  }
  nonisolated static func animationSource(from old: String, to new: String, reduceMotion: Bool) -> String? {
    !reduceMotion && !old.isEmpty && old != new && max(old.count, new.count) <= 4000 ? old : nil
  }
}

private struct ParticleTextCanvas: UIViewRepresentable {
  let old: String
  let new: String
  let font: UIFont
  let lineSpacing: CGFloat
  let color: UIColor
  let completion: () -> Void
  func makeUIView(context: Context) -> ParticleTextView {
    let view = ParticleTextView()
    view.accessibilityIdentifier = "voice-particle-canvas"
    return view
  }
  func updateUIView(_ view: ParticleTextView, context: Context) {
    view.configure(old: old, new: new, font: font, lineSpacing: lineSpacing, color: color, completion: completion)
  }
  static func dismantleUIView(_ view: ParticleTextView, coordinator: ()) { view.stop() }
}

private final class ParticleTextView: UIView {
  private struct Dot { let point: CGPoint; let alpha: CGFloat }
  private var oldText = ""
  private var newText = ""
  private var oldImage: UIImage?
  private var newImage: UIImage?
  private var source: [Dot] = []
  private var destination: [Dot] = []
  private var displayLink: CADisplayLink?
  private var start: CFTimeInterval = 0
  private var progress: CGFloat = 0
  private var renderedSize = CGSize.zero
  private var completion: (() -> Void)?
  private var font = UIFont.systemFont(ofSize: 16)
  private var lineSpacing: CGFloat = 3
  private var color = UIColor.label
  private let duration: CFTimeInterval = 0.72

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    clipsToBounds = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(old: String, new: String, font: UIFont, lineSpacing: CGFloat, color: UIColor, completion: @escaping () -> Void) {
    self.completion = completion
    guard oldText != old || newText != new || self.font != font || self.lineSpacing != lineSpacing || self.color != color else { return }
    self.font = font
    self.lineSpacing = lineSpacing
    self.color = color
    stop()
    oldText = old
    newText = new
    renderedSize = .zero
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard window != nil, bounds.width > 0, bounds.height > 0, renderedSize != bounds.size else { return }
    renderedSize = bounds.size
    stop()
    guard bounds.height <= 1600 else { finish(); return }
    oldImage = raster(oldText)
    newImage = raster(newText)
    source = sample(oldImage)
    destination = sample(newImage)
    guard !source.isEmpty, !destination.isEmpty else { finish(); return }
    progress = 0
    start = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() { displayLink?.invalidate(); displayLink = nil }
  private func finish() {
    stop()
    // SwiftUI state must not be mutated during a UIKit layout/update pass.
    let callback = completion
    completion = nil
    DispatchQueue.main.async { callback?() }
  }
  @objc private func tick() {
    progress = min(1, (CACurrentMediaTime() - start) / duration)
    setNeedsDisplay()
    if progress >= 1 { finish() }
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stop()
      renderedSize = .zero
    } else {
      setNeedsLayout()
    }
  }

  private func raster(_ text: String) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    return UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
      (text as NSString).draw(in: bounds, withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
    }
  }

  private func sample(_ image: UIImage?) -> [Dot] {
    guard let cg = image?.cgImage else { return [] }
    let width = cg.width, height = cg.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    return rgba.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
      context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
      let data = bytes.bindMemory(to: UInt8.self)
      var dots: [Dot] = []
      for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
          let alpha = CGFloat(data[(y * width + x) * 4 + 3]) / 255
          if alpha > 0.18 { dots.append(Dot(point: CGPoint(x: x, y: y), alpha: alpha)) }
        }
      }
      // Bounded drawing work, including long dictation and large accessibility layouts.
      let step = max(1, Int(ceil(Double(dots.count) / 2400)))
      return stride(from: 0, to: dots.count, by: step).map { dots[$0] }
    }
  }

  private func smooth(_ value: CGFloat) -> CGFloat {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
  }
  private func noise(_ i: Int) -> CGFloat {
    let value = sin(Double(i) * 127.1 + 311.7) * 43758.5453
    return CGFloat(value - floor(value))
  }
  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    let p = progress
    oldImage?.draw(at: .zero, blendMode: .normal, alpha: 1 - smooth(p / 0.22))
    newImage?.draw(at: .zero, blendMode: .normal, alpha: smooth((p - 0.76) / 0.24))
    let count = max(source.count, destination.count)
    guard count > 0, !source.isEmpty, !destination.isEmpty else { return }
    let t = smooth(p), spread = sin(.pi * t)
    let envelope = min(smooth(p / 0.18), 1 - smooth((p - 0.8) / 0.2))
    for i in 0..<count {
      let a = source[i * source.count / count]
      let b = destination[i * destination.count / count]
      let x = a.point.x + (b.point.x - a.point.x) * t + (noise(i) - 0.5) * 14 * spread
      let y = a.point.y + (b.point.y - a.point.y) * t + (noise(i + 712) - 0.5) * 14 * spread
      let radius = 0.4 + 0.35 * noise(i + 17)
      context.setFillColor(color.withAlphaComponent(envelope * (0.6 + 0.4 * noise(i + 29))).cgColor)
      context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
  }
}
