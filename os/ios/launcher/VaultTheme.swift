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
    static let edgeDark = Color.black.opacity(0.62)
    static let hazard = Color(red: 0.941, green: 0.639, blue: 0.165)
    static let hazardInk = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let amber = Color(red: 0.898, green: 0.663, blue: 0.208)
    static let teal = Color(red: 0.373, green: 0.702, blue: 0.659)

    static func display(_ size: CGFloat) -> Font {
        if UIFont(name: VaultUI.displayName, size: size) != nil {
            return Font.custom(VaultUI.displayName, size: size)
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

struct VaultChamfer: Shape {
    var corner: CGFloat = 5
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let radius = min(corner, min(rect.width, rect.height) / 2)
        let notch = min(cut, min(rect.width, rect.height) / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notch))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct VaultHazard: Shape {
    var pitch: CGFloat = 9
    var bar: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let span = max(1, pitch)
        let width = max(0.5, min(bar, span - 0.5))
        var x = -rect.height - width

        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + x + rect.height + width, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + x + width, y: rect.maxY))
            path.closeSubpath()
            x += span + width
        }

        return path
    }
}

struct VaultTopEdge: Shape {
    var corner: CGFloat = 5
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let notch = min(cut, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + min(corner, rect.width / 2), y: rect.minY + 0.5))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY + 0.5))
        return path
    }
}

extension View {
    func vaultPlate(corner: CGFloat = 5, cut: CGFloat = 10, fill: Color? = nil) -> some View {
        let shape = VaultChamfer(corner: corner, cut: cut)
        return self
            .background(shape.fill(fill ?? Vault.plate))
            .overlay(shape.stroke(Vault.hairline, lineWidth: 1))
            .overlay(VaultTopEdge(corner: corner, cut: cut).stroke(Vault.edgeLight, lineWidth: 1))
    }
}

enum VaultUI {
    static let displayName = "BlackOpsOne-Regular"

    static let hull = UIColor(red: 0.039, green: 0.043, blue: 0.047, alpha: 1)
    static let plate = UIColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1)
    static let text = UIColor(red: 0.914, green: 0.929, blue: 0.945, alpha: 1)
    static let dim = UIColor(red: 0.604, green: 0.631, blue: 0.663, alpha: 1)
    static let faint = UIColor(red: 0.420, green: 0.447, blue: 0.478, alpha: 1)
    static let hazard = UIColor(red: 0.941, green: 0.639, blue: 0.165, alpha: 1)
    static let hazardInk = UIColor(red: 0.043, green: 0.043, blue: 0.047, alpha: 1)
    static let edgeLight = UIColor(white: 1, alpha: 0.16)
    static let edgeDark = UIColor(white: 0, alpha: 0.62)

    static func display(_ size: CGFloat) -> UIFont {
        return UIFont(name: displayName, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .heavy)
    }

    static func label(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func chamfer(in rect: CGRect, corner: CGFloat, cut: CGFloat) -> UIBezierPath {
        let radius = min(corner, min(rect.width, rect.height) / 2)
        let notch = min(cut, min(rect.width, rect.height) / 2)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notch))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          controlPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          controlPoint: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          controlPoint: CGPoint(x: rect.minX, y: rect.minY))
        path.close()
        return path
    }
}

final class VaultPanelView: UIView {
    private let fillLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let topLayer = CAShapeLayer()

    var corner: CGFloat = 5 {
        didSet { setNeedsLayout() }
    }

    var cut: CGFloat = 10 {
        didSet { setNeedsLayout() }
    }

    var fill: UIColor = VaultUI.plate {
        didSet { fillLayer.fillColor = fill.cgColor }
    }

    var edge: UIColor = UIColor(white: 1, alpha: 0.14) {
        didSet { edgeLayer.strokeColor = edge.cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isUserInteractionEnabled = false

        fillLayer.fillColor = fill.cgColor
        layer.addSublayer(fillLayer)

        edgeLayer.fillColor = UIColor.clear.cgColor
        edgeLayer.strokeColor = edge.cgColor
        edgeLayer.lineWidth = 1
        layer.addSublayer(edgeLayer)

        topLayer.fillColor = UIColor.clear.cgColor
        topLayer.strokeColor = VaultUI.edgeLight.cgColor
        topLayer.lineWidth = 1
        layer.addSublayer(topLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let shape = VaultUI.chamfer(in: bounds, corner: corner, cut: cut)
        fillLayer.frame = bounds
        fillLayer.path = shape.cgPath

        edgeLayer.frame = bounds
        edgeLayer.path = shape.cgPath

        let top = UIBezierPath()
        top.move(to: CGPoint(x: min(corner, bounds.width / 2), y: 0.5))
        top.addLine(to: CGPoint(x: max(0, bounds.maxX - min(cut, bounds.width / 2)), y: 0.5))
        topLayer.frame = bounds
        topLayer.path = top.cgPath
    }
}

final class HazardStripView: UIView {
    var pitch: CGFloat = 10
    var bar: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = VaultUI.hazardInk
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        VaultUI.hazardInk.setFill()
        context.fill(rect)
        context.saveGState()
        context.clip(to: rect)
        VaultUI.hazard.setFill()

        var x = -rect.height
        while x < rect.width + rect.height {
            let stripe = UIBezierPath()
            stripe.move(to: CGPoint(x: x, y: rect.maxY))
            stripe.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            stripe.addLine(to: CGPoint(x: x + rect.height + bar, y: rect.minY))
            stripe.addLine(to: CGPoint(x: x + bar, y: rect.maxY))
            stripe.close()
            stripe.fill()
            x += pitch + bar
        }

        context.restoreGState()
    }
}
