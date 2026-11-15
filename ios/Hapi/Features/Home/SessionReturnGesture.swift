import SwiftUI
import UIKit

/// Swipe left over list whitespace or the title to reopen the last chat.
/// Only a horizontal, single-finger drag is eligible; vertical scrolling stays
/// with the list, and no second ChatView is kept alive behind it.
struct SessionReturnGesture: UIViewControllerRepresentable {
    var isEnabled: Bool
    var onReturn: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onReturn = onReturn
        controller.isEnabled = isEnabled
        controller.installIfVisible()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.recognizer.view?.removeGestureRecognizer(controller.recognizer)
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onReturn: () -> Void = {}
        var isEnabled = false {
            didSet { recognizer.isEnabled = isEnabled }
        }
        lazy var recognizer: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            gesture.maximumNumberOfTouches = 1
            gesture.delegate = self
            gesture.name = "home.return-to-session"
            gesture.isEnabled = isEnabled
            return gesture
        }()

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfVisible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        func installIfVisible() {
            guard isViewLoaded, view.window != nil,
                  let surface = navigationController?.view,
                  recognizer.view !== surface else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            surface.addGestureRecognizer(recognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            Self.allowsStart(in: touch.view)
        }

        /// A row owns its swipe actions, and controls own their editing/tracking.
        /// The navigation pan is only for the surrounding whitespace and title.
        static func allowsStart(in view: UIView?) -> Bool {
            guard let view else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current is UITableViewCell || current is UICollectionViewCell
                    || current is UIControl || current is UITextView {
                    return false
                }
                ancestor = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, navigationController?.viewControllers.count == 1,
                  navigationController?.presentedViewController == nil else { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: recognizer.view)
            return -velocity.x > abs(velocity.y)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            complete(translation: gesture.translation(in: gesture.view))
        }

        func complete(translation: CGPoint) {
            guard isEnabled, translation.x <= -60, -translation.x > abs(translation.y) else { return }
            onReturn()
        }
    }
}
