// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

/// A live native loading indicator replaces the idle refresh icon during a query.
struct DiscoveryRefreshButton: UIViewRepresentable {
    let refreshing: Bool
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .label
        button.accessibilityLabel = "重新搜索"
        button.addTarget(context.coordinator, action: #selector(Coordinator.refresh), for: .touchUpInside)
        let icon = context.coordinator.icon
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isUserInteractionEnabled = false
        icon.tintColor = .label
        button.addSubview(icon)
        let spinner = context.coordinator.spinner
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isUserInteractionEnabled = false
        spinner.color = .label
        button.addSubview(spinner)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = enabled
        button.accessibilityValue = refreshing ? "正在刷新" : nil
        context.coordinator.setRefreshing(refreshing)
    }

    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
        coordinator.spinner.stopAnimating()
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        let spinner = UIActivityIndicatorView(style: .medium)
        let icon = UIImageView(image: UIImage(systemName: "arrow.clockwise",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
        private var refreshing: Bool?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func refresh() { action() }

        func setRefreshing(_ value: Bool) {
            guard refreshing != value else { return }
            let animate = refreshing != nil
            refreshing = value
            if value { spinner.startAnimating() }
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let changes = {
                self.icon.alpha = value ? 0 : 1
                self.spinner.alpha = value ? 1 : 0
                self.icon.transform = value && !reduceMotion ? CGAffineTransform(scaleX: 0.82, y: 0.82) : .identity
                self.spinner.transform = !value && !reduceMotion ? CGAffineTransform(scaleX: 0.82, y: 0.82) : .identity
            }
            guard animate else {
                changes()
                if !value { spinner.stopAnimating() }
                return
            }
            UIView.animate(withDuration: reduceMotion ? 0.12 : 0.2, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: changes) { _ in
                if self.refreshing == false { self.spinner.stopAnimating() }
            }
        }
    }
}
