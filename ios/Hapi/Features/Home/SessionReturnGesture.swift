import SwiftUI
import UIKit

/// A list-edge gesture for reopening the last chat after navigating back.
/// Attaching to the navigation view leaves row swipe actions and vertical
/// scrolling alone; it never creates a second ChatView behind the list.
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
        lazy var recognizer: UIScreenEdgePanGestureRecognizer = {
            let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan))
            gesture.edges = .left
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

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, navigationController?.viewControllers.count == 1,
                  navigationController?.presentedViewController == nil else { return false }
            let velocity = recognizer.velocity(in: recognizer.view)
            return velocity.x > abs(velocity.y)
        }

        @objc private func handlePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            complete(translation: gesture.translation(in: gesture.view))
        }

        func complete(translation: CGPoint) {
            guard isEnabled, translation.x >= 60, translation.x > abs(translation.y) else { return }
            onReturn()
        }
    }
}
