// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import UIKit
final class HEVCDisplayView: UIView {
    var hasCurrentImage = true
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError() }
}
