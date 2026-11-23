import SwiftUI
import UIKit

enum Vault {
    static let hull = Color(red: 0.039, green: 0.043, blue: 0.047)
    static let plate = Color(red: 0.078, green: 0.086, blue: 0.102)
    static let inset = Color(red: 0.055, green: 0.063, blue: 0.075)
    static let text = Color(red: 0.914, green: 0.929, blue: 0.945)
    static let dim = Color(red: 0.604, green: 0.631, blue: 0.663)
    static let faint = Color(red: 0.420, green: 0.447, blue: 0.478)
    static let panel = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.09)
    static let edgeLight = Color.white.opacity(0.16)
    static let ink = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let amber = Color(red: 0.898, green: 0.663, blue: 0.208)
    static let teal = Color(red: 0.373, green: 0.702, blue: 0.659)

    /// The touch HUD: near-black plates, one neutral outline, white glyphs.
    static let controlFill = Color(white: 0.063)
    static let controlBorder = Color(white: 0.333)
    static let controlContent = Color(white: 0.949)

    static func display(_ size: CGFloat) -> Font {
        if UIFont(name: VaultUI.displayName, size: size) != nil {
            return Font.custom(VaultUI.displayName, fixedSize: size)
        }
        return .system(size: size * 0.86, weight: .heavy, design: .monospaced)
    }

    static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight)
    }
}

extension View {
    func vaultPlate(corner: CGFloat = 8, fill: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return self
            .background(shape.fill(fill ?? Vault.plate))
            .overlay(shape.stroke(Vault.hairline, lineWidth: 1))
            .overlay(
                Rectangle()
                    .fill(Vault.edgeLight)
                    .frame(height: 1)
                    .padding(.horizontal, corner),
                alignment: .top
            )
    }
}

enum VaultUI {
    static let displayName = "Anton-Regular"

    static let hull = UIColor(red: 0.039, green: 0.043, blue: 0.047, alpha: 1)
    static let plate = UIColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1)
    static let text = UIColor(red: 0.914, green: 0.929, blue: 0.945, alpha: 1)
    static let dim = UIColor(red: 0.604, green: 0.631, blue: 0.663, alpha: 1)
    static let faint = UIColor(red: 0.420, green: 0.447, blue: 0.478, alpha: 1)
    static let ink = UIColor(red: 0.043, green: 0.043, blue: 0.047, alpha: 1)
    static let edgeLight = UIColor(white: 1, alpha: 0.16)

    static let controlFill = UIColor(white: 0.063, alpha: 1)
    static let controlBorder = UIColor(white: 0.333, alpha: 1)
    static let controlContent = UIColor(white: 0.949, alpha: 1)
    static let controlPressed = UIColor(white: 0.161, alpha: 1)
    static let controlKnob = UIColor(white: 0.22, alpha: 1)

    static func display(_ size: CGFloat) -> UIFont {
        return UIFont(name: displayName, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .heavy)
    }

    static func label(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

final class VaultPanelView: UIView {
    private let fillLayer = CAShapeLayer()
    private let shadeLayer = CAGradientLayer()
    private let shadeMask = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let innerLayer = CAShapeLayer()

    var corner: CGFloat = 10 {
        didSet { setNeedsLayout() }
    }

    var fill: UIColor = VaultUI.plate {
        didSet { fillLayer.fillColor = fill.cgColor }
    }

    var edge: UIColor = UIColor(white: 1, alpha: 0.14) {
        didSet { edgeLayer.strokeColor = edge.cgColor }
    }

    var lineWidth: CGFloat = 1 {
        didSet {
            edgeLayer.lineWidth = lineWidth
            setNeedsLayout()
        }
    }

    var innerEdge: UIColor = .clear {
        didSet {
            innerLayer.strokeColor = innerEdge.cgColor
            innerLayer.isHidden = innerEdge.cgColor.alpha <= 0
        }
    }

    var innerInset: CGFloat = 2 {
        didSet { setNeedsLayout() }
    }

    var shadowOpacity: Float = 0 {
        didSet { fillLayer.shadowOpacity = shadowOpacity }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isUserInteractionEnabled = false

        fillLayer.fillColor = fill.cgColor
        fillLayer.shadowColor = UIColor.black.cgColor
        fillLayer.shadowOffset = CGSize(width: 0, height: 2)
        fillLayer.shadowRadius = 5
        fillLayer.shadowOpacity = 0
        layer.addSublayer(fillLayer)

        shadeLayer.colors = [UIColor(white: 1, alpha: 0.045).cgColor,
                             UIColor(white: 0, alpha: 0.10).cgColor]
        shadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        shadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        shadeLayer.mask = shadeMask
        layer.addSublayer(shadeLayer)

        edgeLayer.fillColor = UIColor.clear.cgColor
        edgeLayer.strokeColor = edge.cgColor
        edgeLayer.lineWidth = lineWidth
        layer.addSublayer(edgeLayer)

        innerLayer.fillColor = UIColor.clear.cgColor
        innerLayer.strokeColor = UIColor.clear.cgColor
        innerLayer.lineWidth = 1
        innerLayer.lineCap = .round
        innerLayer.isHidden = true
        layer.addSublayer(innerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: corner)
        fillLayer.frame = bounds
        fillLayer.path = shape.cgPath
        fillLayer.shadowPath = shape.cgPath

        shadeLayer.frame = bounds
        shadeMask.frame = bounds
        shadeMask.path = shape.cgPath

        edgeLayer.frame = bounds
        edgeLayer.path = shape.cgPath

        let topY = max(1, innerInset - 0.5)
        let highlight = UIBezierPath()
        highlight.move(to: CGPoint(x: min(bounds.midX, corner + 2), y: topY))
        highlight.addLine(to: CGPoint(x: max(bounds.midX, bounds.width - corner - 2), y: topY))
        innerLayer.frame = bounds
        innerLayer.path = highlight.cgPath
    }
}
