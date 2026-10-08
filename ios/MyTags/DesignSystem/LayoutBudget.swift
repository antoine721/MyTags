import MyTagsKit
import UIKit

/// Height estimate of the tag panel on a 6.1-inch iPhone (spec 9.2 "Budget de hauteur"):
/// about 479 pt are available under the playback controls.
enum LayoutBudget {
    static let available: CGFloat = 479
    static let rowWidth: CGFloat = 393 - 32 - Theme.labelWidth - Theme.spacing - 8

    enum Fit { case normal, compact, scrolling }

    static func fit(config: TagConfig) -> Fit {
        if height(config: config, compact: false) <= available { return .normal }
        if height(config: config, compact: true) <= available { return .compact }
        return .scrolling
    }

    static func height(config: TagConfig, compact: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        var total: CGFloat = 0
        for field in config.visibleFields {
            switch field.kind {
            case .rating, .text:
                total += Theme.minHitSize
            case .single, .multi:
                let options = config.selectableOptions(forField: field.id)
                let isColor = !options.isEmpty && options.allSatisfy { $0.color != nil }
                var lines = 1
                var x: CGFloat = 0
                for option in options {
                    let width = isColor
                        ? (compact ? 38 : Theme.colorDotSize + 8)
                        : (option.displayLabel as NSString).size(withAttributes: [.font: font]).width + (compact ? 20 : 24)
                    if x > 0 && x + width > rowWidth {
                        lines += 1
                        x = 0
                    }
                    x += width + 6
                }
                total += CGFloat(lines) * Theme.minHitSize
            }
            total += compact ? 2 : 6
        }
        return total
    }
}
