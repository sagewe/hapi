#if canImport(UIKit)
import SwiftUI
import UIKit

/// Native `UIScrollView`-backed zoomable/pannable full-screen image view.
/// Supports pinch-to-zoom (1×–6×), double-tap to zoom at the tapped point,
/// smooth momentum panning while zoomed, and single-tap dismissal only at 1×.
/// Upgrading `image` from a thumbnail to a full-resolution original preserves
/// the current zoom scale and pan offset when the aspect ratio matches.
public struct ZoomableImageView: UIViewRepresentable {
    public let image: UIImage
    public let maxZoomScale: CGFloat
    public let onSingleTapAtBaseScale: (() -> Void)?

    public init(
        image: UIImage,
        maxZoomScale: CGFloat = 6.0,
        onSingleTapAtBaseScale: (() -> Void)? = nil
    ) {
        self.image = image
        self.maxZoomScale = max(maxZoomScale, 2.0)
        self.onSingleTapAtBaseScale = onSingleTapAtBaseScale
    }

    public func makeUIView(context: Context) -> ZoomableImageContainerView {
        let view = ZoomableImageContainerView()
        view.configure(
            image: image,
            maxZoomScale: maxZoomScale,
            onSingleTapAtBaseScale: onSingleTapAtBaseScale
        )
        return view
    }

    public func updateUIView(_ uiView: ZoomableImageContainerView, context: Context) {
        uiView.configure(
            image: image,
            maxZoomScale: maxZoomScale,
            onSingleTapAtBaseScale: onSingleTapAtBaseScale
        )
    }
}

public final class ZoomableImageContainerView: UIView, UIScrollViewDelegate {
    public let scrollView = UIScrollView()
    public let imageView = UIImageView()

    private var lastBoundsSize: CGSize = .zero
    private var lastAspectRatio: CGFloat = 0
    private var onSingleTapAtBaseScale: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    func configure(
        image: UIImage,
        maxZoomScale: CGFloat,
        onSingleTapAtBaseScale: (() -> Void)?
    ) {
        self.onSingleTapAtBaseScale = onSingleTapAtBaseScale
        scrollView.maximumZoomScale = maxZoomScale

        let newRatio = Self.aspectRatio(of: image)
        let ratioChanged = lastAspectRatio == 0 || abs(newRatio - lastAspectRatio) > 0.02
        imageView.image = image

        if ratioChanged {
            lastAspectRatio = newRatio
            layoutFittedImage(resetZoom: true)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let currentSize = scrollView.bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        if currentSize != lastBoundsSize {
            lastBoundsSize = currentSize
            layoutFittedImage(resetZoom: true)
        } else {
            centerImageView()
        }
    }

    public func toggleZoom(at pointInImageView: CGPoint, animated: Bool = true) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.05 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
            return
        }
        let targetScale = min(scrollView.maximumZoomScale, 3.0)
        let width = scrollView.bounds.width / targetScale
        let height = scrollView.bounds.height / targetScale
        let originX = pointInImageView.x - width / 2
        let originY = pointInImageView.y - height / 2
        let zoomRect = CGRect(x: originX, y: originY, width: width, height: height)
        scrollView.zoom(to: zoomRect, animated: animated)
    }

    private func layoutFittedImage(resetZoom: Bool) {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0, let image = imageView.image else { return }

        let padding: CGFloat = 8
        let availableWidth = max(boundsSize.width - padding * 2, 1)
        let availableHeight = max(boundsSize.height - padding * 2, 1)
        let ratio = Self.aspectRatio(of: image)

        let fitSize: CGSize
        if ratio <= 0 {
            fitSize = CGSize(width: availableWidth, height: availableHeight)
        } else if availableWidth / availableHeight > ratio {
            fitSize = CGSize(width: availableHeight * ratio, height: availableHeight)
        } else {
            fitSize = CGSize(width: availableWidth, height: availableWidth / ratio)
        }

        if resetZoom {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fitSize)
        scrollView.contentSize = fitSize
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let insetX = max((boundsSize.width - contentSize.width) / 2, 0)
        let insetY = max((boundsSize.height - contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    private static func aspectRatio(of image: UIImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 0 }
        return size.width / size.height
    }

    // MARK: - UIScrollViewDelegate

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }

    // MARK: - Gestures

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: imageView)
        toggleZoom(at: point, animated: true)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.05 else { return }
        onSingleTapAtBaseScale?()
    }
}
#endif
