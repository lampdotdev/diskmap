import SwiftUI
import AppKit

/// One slice of the sunburst: a ring (depth 1 is the folder's own items), and where around the circle it runs,
/// in radians clockwise from the top.
struct Arc {
    let node: Node
    /// The item of the shown folder this slice sits in, for the selection and the table.
    let outer: Node
    let depth: Int
    let start: Double
    let end: Double
    let color: Color
    let measuring: Bool
}

struct SunburstContent {
    var arcs: [Arc] = []
    /// The share still being measured, drawn as a dashed slice in the first ring.
    var gap: (start: Double, end: Double)?
    /// The disk's free space, when Free space is on: one pale slice through every ring.
    var free: (start: Double, end: Double)?
    var freeSize: Int64 = 0
}

enum SunburstLayout {
    static let rings = 3
    /// Slices thinner than this (radians) aren't drawn, nor what's inside them.
    static let minSpan = 0.004

    static func build(_ folder: Node, pending: Int64, free: Int64 = 0) -> SunburstContent {
        var content = SunburstContent()
        let total = Double(folder.size + max(0, pending) + max(0, free))
        guard total > 0 else { return content }
        let full = 2 * Double.pi
        var angle = 0.0
        for child in folder.sortedChildren where child.size > 0 {
            let span = full * Double(child.size) / total
            if span >= minSpan {
                add(child, outer: child, depth: 1, start: angle, span: span, hueAt: nil, into: &content.arcs)
            }
            angle += span
        }
        if pending > 0 {
            let span = full * Double(pending) / total
            content.gap = (angle, angle + span)
            angle += span
        }
        if free > 0 {
            content.free = (angle, full)
            content.freeSize = free
        }
        return content
    }

    private static func add(_ node: Node, outer: Node, depth: Int, start: Double, span: Double, hueAt: Double?,
                            into arcs: inout [Arc]) {
        // Each slice of the first ring takes its hue from where it sits, from cool blue round to warm pink;
        // what's inside keeps it, lighter with each ring.
        let hue = hueAt ?? (0.55 + 0.42 * (start + span / 2) / (2 * Double.pi)).truncatingRemainder(dividingBy: 1)
        arcs.append(Arc(node: node, outer: outer, depth: depth, start: start, end: start + span,
                        color: color(node, hue: hue, depth: depth),
                        measuring: node.kind == .folder && !node.isComplete))
        guard depth < rings, node.kind == .folder, node.size > 0 else { return }
        var angle = start
        for child in node.sortedChildren where child.size > 0 {
            let s = span * Double(child.size) / Double(node.size)
            if s < minSpan { break }
            add(child, outer: outer, depth: depth + 1, start: angle, span: s, hueAt: hue, into: &arcs)
            angle += s
        }
    }

    static func color(_ node: Node, hue: Double, depth: Int) -> Color {
        let d = Double(depth - 1)
        switch node.kind {
        case .folder:
            return Color(hue: hue, saturation: max(0.25, 0.78 - d * 0.14), brightness: min(0.98, 0.80 + d * 0.05))
        case .file:
            return Color(hue: hue, saturation: 0.14, brightness: 0.78 + d * 0.04)
        case .smallFiles:
            return Color(hue: hue, saturation: 0.08, brightness: 0.86)
        case .hidden:
            return Color(nsColor: .systemGray)
        }
    }
}

struct SunburstView: View, Animatable {
    let folder: Node
    let revision: Int
    let pending: Int64
    /// Free space on the disk to show beside the folder's items; 0 leaves it out.
    var free: Int64 = 0
    /// How much of `free` is shown, 0...1, eased by SwiftUI when Free space is switched.
    var freeAmount: Double = 1
    var animatableData: Double {
        get { freeAmount }
        set { freeAmount = newValue }
    }
    @Binding var selection: Set<Node.ID>
    @Binding var hovered: (outer: Node, inner: Node?)?
    /// A click on a folder's slice opens it.
    var onOpen: (Node) -> Void
    /// A click in the middle: back out to the enclosing folder.
    var onUp: () -> Void

    @State private var hoveredArc: Node?
    @State private var hoveringFree = false

    var body: some View {
        GeometryReader { geo in
            let content = SunburstLayout.build(folder, pending: pending, free: Int64(Double(free) * freeAmount))
            let g = Geometry(size: geo.size)
            ZStack {
                Canvas { context, _ in
                    draw(content, g, in: &context)
                }
                centerLabel(g)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let arc = hit(p, content, g)
                    hoveredArc = arc?.node
                    hoveringFree = arc == nil && isInFree(p, content, g)
                    hovered = arc.map { ($0.outer, $0.depth == 1 ? nil : $0.node) }
                case .ended:
                    hoveredArc = nil
                    hoveringFree = false
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let arc = hit(p, content, g)
                if arc == nil, g.distance(p) < g.inner {
                    onUp()
                    return
                }
                // ⌘-click adds or takes away one item, ⇧-click adds; a plain click opens a folder, or picks a file.
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if let id = arc?.outer.id, flags.contains(.command) {
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                } else if let id = arc?.outer.id, flags.contains(.shift) {
                    selection.insert(id)
                } else if let arc, arc.node.kind == .folder, !arc.node.children.isEmpty {
                    onOpen(arc.node)
                } else {
                    selection = Set([arc?.outer.id].compactMap { $0 })
                }
            }
        }
    }

    struct Geometry {
        let center: CGPoint
        let inner: CGFloat
        let ring: CGFloat

        init(size: CGSize) {
            let radius = max(10, min(size.width, size.height) / 2 - 4)
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            inner = radius * 0.36
            ring = (radius - inner) / CGFloat(SunburstLayout.rings)
        }

        func radii(_ depth: Int) -> (CGFloat, CGFloat) {
            (inner + CGFloat(depth - 1) * ring, inner + CGFloat(depth) * ring)
        }

        func distance(_ p: CGPoint) -> CGFloat { hypot(p.x - center.x, p.y - center.y) }

        /// Radians clockwise from the top.
        func angle(_ p: CGPoint) -> Double {
            let a = atan2(Double(p.y - center.y), Double(p.x - center.x)) + Double.pi / 2
            return a < 0 ? a + 2 * Double.pi : a
        }

        func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: center.x + r * CGFloat(cos(angle - Double.pi / 2)), y: center.y + r * CGFloat(sin(angle - Double.pi / 2)))
        }

        func slice(_ start: Double, _ end: Double, depth: Int) -> Path {
            let (r0, r1) = radii(depth)
            var p = Path()
            p.addArc(center: center, radius: r1 - 0.5, startAngle: .radians(start - Double.pi / 2),
                     endAngle: .radians(end - Double.pi / 2), clockwise: false)
            p.addArc(center: center, radius: r0 + 0.5, startAngle: .radians(end - Double.pi / 2),
                     endAngle: .radians(start - Double.pi / 2), clockwise: true)
            p.closeSubpath()
            return p
        }
    }

    private func hit(_ p: CGPoint, _ content: SunburstContent, _ g: Geometry) -> Arc? {
        let d = g.distance(p)
        guard d >= g.inner else { return nil }
        let depth = Int((d - g.inner) / g.ring) + 1
        guard depth <= SunburstLayout.rings else { return nil }
        let a = g.angle(p)
        return content.arcs.first { $0.depth == depth && a >= $0.start && a < $0.end }
    }

    private func isInFree(_ p: CGPoint, _ content: SunburstContent, _ g: Geometry) -> Bool {
        guard let free = content.free else { return false }
        let d = g.distance(p)
        let a = g.angle(p)
        return d >= g.inner && d <= g.radii(SunburstLayout.rings).1 && a >= free.start && a < free.end
    }

    private func draw(_ content: SunburstContent, _ g: Geometry, in context: inout GraphicsContext) {
        if let free = content.free, free.end - free.start > 0.005 {
            var path = Path()
            let outer = g.radii(SunburstLayout.rings).1 - 0.5
            path.addArc(center: g.center, radius: outer, startAngle: .radians(free.start - Double.pi / 2),
                        endAngle: .radians(free.end - Double.pi / 2), clockwise: false)
            path.addArc(center: g.center, radius: g.inner + 0.5, startAngle: .radians(free.end - Double.pi / 2),
                        endAngle: .radians(free.start - Double.pi / 2), clockwise: true)
            path.closeSubpath()
            context.fill(path, with: .color(Color.green.opacity(hoveringFree ? 0.22 : 0.12)))
            context.stroke(path, with: .color(Color.green.opacity(0.45)), lineWidth: 1)
            let mid = (free.start + free.end) / 2
            let r = (g.inner + outer) / 2
            let chord = 2 * r * CGFloat(sin(min(Double.pi / 2, (free.end - free.start) / 2)))
            let text = context.resolve(Text("Free").font(.caption.weight(.semibold)).foregroundColor(.green))
            if text.measure(in: CGSize(width: 200, height: 40)).width < chord * 0.8 {
                context.draw(text, at: g.point(mid, r), anchor: .center)
            }
        }
        let lit = hoveredArc.map { ObjectIdentifier($0) }
        let litOuter = hovered?.outer.id
        for arc in content.arcs {
            let path = g.slice(arc.start, arc.end, depth: arc.depth)
            context.fill(path, with: .color(arc.measuring ? arc.color.opacity(0.55) : arc.color))
            let isLit = ObjectIdentifier(arc.node) == lit || (lit == nil && arc.depth == 1 && arc.outer.id == litOuter)
            if isLit {
                context.fill(path, with: .color(.white.opacity(0.3)))
            }
            context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
            if arc.depth == 1 && selection.contains(arc.outer.id) {
                context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
            }
        }
        if let gap = content.gap, gap.end - gap.start > 0.01 {
            let path = g.slice(gap.start, gap.end, depth: 1)
            context.fill(path, with: .color(.primary.opacity(0.04)))
            context.stroke(path, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        // Names on every ring where there's room: along the ring when it fits, else pointing outward across a
        // narrow slice; turned so they never read upside down.
        for arc in content.arcs {
            let (r0, r1) = g.radii(arc.depth)
            let mid = (r0 + r1) / 2
            let span = arc.end - arc.start
            let chord = 2 * mid * CGFloat(sin(min(Double.pi / 2, span / 2)))
            guard chord > 14 else { continue }
            let text = context.resolve(Text(arc.node.title)
                .font(arc.depth == 1 ? .caption.weight(.semibold) : .caption2.weight(.medium))
                .foregroundColor(.white))
            let size = text.measure(in: CGSize(width: 400, height: 40))
            let midAngle = (arc.start + arc.end) / 2
            var turn: Double
            if size.width < chord * 0.8, size.height < (r1 - r0) * 0.8 {
                turn = midAngle
                if midAngle > Double.pi / 2 && midAngle < 3 * Double.pi / 2 { turn -= Double.pi }
            } else if size.width < (r1 - r0) * 0.85, size.height < chord * 0.8 {
                turn = midAngle - Double.pi / 2
                if midAngle > Double.pi { turn += Double.pi }
            } else {
                continue
            }
            let p = g.point(midAngle, mid)
            var c = context
            c.translateBy(x: p.x, y: p.y)
            c.rotate(by: .radians(turn))
            c.addFilter(.shadow(color: .black.opacity(0.25), radius: 1, y: 0.5))
            c.draw(text, at: .zero, anchor: .center)
        }
    }

    private func centerLabel(_ g: Geometry) -> some View {
        let node = hoveredArc ?? folder
        return VStack(spacing: 2) {
            Text(hoveringFree ? "Free space" : node.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(formatBytes(hoveringFree ? free : node.size))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if hoveredArc == nil && !hoveringFree && folder.parent != nil {
                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(width: g.inner * 1.7)
        .position(g.center)
        .allowsHitTesting(false)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
