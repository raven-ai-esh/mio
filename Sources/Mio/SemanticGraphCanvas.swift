import AppKit
import MetalKit
import SwiftUI
import MioCore
import simd

struct SemanticGraphCanvas: NSViewRepresentable {
    let localizer: MioLocalizer
    let nodes: [MemoryGraphNode]
    let edges: [MemoryGraphEdge]
    let positions: [String: SemanticGraphPoint]
    let colors: [String: NSColor]
    let selected: String
    let focusedSpaceIDs: Set<String>
    let fitToken: Int
    let zoomCommand: Int
    let select: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        if let view = SemanticGraphMetalView(metalDevice: MTLCreateSystemDefaultDevice()) { return view }
        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        return label
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let canvas = view as? SemanticGraphMetalView else {
            (view as? NSTextField)?.stringValue = localizer.text("3D-граф недоступен на этом Mac")
            return
        }
        canvas.setAccessibilityLabel(localizer.text("3D-граф памяти"))
        canvas.setAccessibilityHelp(localizer.text("Перетащите, чтобы повернуть карту. Shift и перетаскивание — перемещение. Прокрутка или щипок — масштаб."))
        canvas.onSelect = select
        canvas.update(nodes: nodes, edges: edges, positions: positions, colors: colors, focusedSpaceIDs: focusedSpaceIDs)
        canvas.select(selected)
        canvas.setAccessibilityValue(localizer.text("%@ точек · %@ связей", [String(canvas.pointCount), String(canvas.linkCount)]))
        if canvas.lastFitToken != fitToken { canvas.fit(); canvas.lastFitToken = fitToken }
        if let previous = canvas.lastZoomCommand, previous != zoomCommand {
            canvas.zoom(by: pow(1.25, Float(zoomCommand - previous)))
        }
        canvas.lastZoomCommand = zoomCommand
    }
}

struct SemanticGraphCamera {
    var yaw: Float = 0.32
    var pitch: Float = -0.22
    var zoom: Float = 1
    var pan = SIMD2<Float>.zero
    var center = SIMD3<Float>.zero
    var radius: Float = 1

    mutating func fit(_ points: [SIMD3<Float>]) {
        self = Self()
        guard let first = points.first else { return }
        var lower = first, upper = first
        for point in points {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        center = (lower + upper) / 2
        radius = max(0.035, points.map { simd_distance($0, center) }.max() ?? 0)
    }

    func transform(size: CGSize) -> simd_float4x4 {
        let aspect = max(0.001, Float(size.width / max(size.height, 1)))
        let cosYaw = cos(yaw), sinYaw = sin(yaw)
        let cosPitch = cos(pitch), sinPitch = sin(pitch)
        let right = SIMD3(cosYaw, 0, sinYaw) / radius
        let up = SIMD3(sinYaw * sinPitch, cosPitch, -cosYaw * sinPitch) / radius
        let forward = SIMD3(-sinYaw * cosPitch, sinPitch, cosYaw * cosPitch) / radius
        let depth = SIMD4(forward, 3.25 - simd_dot(forward, center))
        let focal: Float = 2.55 * zoom
        let x = SIMD4(right, -simd_dot(right, center)) * (focal / max(aspect, 1)) + depth * pan.x
        let y = SIMD4(up, -simd_dot(up, center)) * (focal * min(aspect, 1)) + depth * pan.y
        return simd_float4x4(rows: [x, y, depth - SIMD4(0, 0, 0, 0.1), depth])
    }

    static func screen(_ point: SIMD3<Float>, transform: simd_float4x4, size: CGSize) -> (point: CGPoint, depth: Float)? {
        let projected = transform * SIMD4(point, 1)
        guard projected.w > 0.1 else { return nil }
        let x = CGFloat(projected.x / projected.w), y = CGFloat(projected.y / projected.w)
        return (CGPoint(x: (x + 1) * size.width / 2, y: (y + 1) * size.height / 2), projected.w)
    }
}

@MainActor final class SemanticGraphMetalView: MTKView, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct Uniforms {
        var transform: simd_float4x4
        var linkColor: SIMD4<Float>
        var diameter: Float
        var selectedIndex: UInt32
    }

    private struct Input: Equatable {
        let nodes: [MemoryGraphNode]
        let edges: [MemoryGraphEdge]
        let positions: [String: SemanticGraphPoint]
        let colors: [String: NSColor]
        let focus: Set<String>
    }

    private let commandQueue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let linkPipeline: MTLRenderPipelineState
    private let pointDepth: MTLDepthStencilState
    private let linkDepth: MTLDepthStencilState
    private var input: Input?
    private var points: [MemoryGraphNode] = []
    private var vertices: MTLBuffer?
    private var links: MTLBuffer?
    private var normalLinkCount = 0
    private var linkedToSelf = Set<String>()
    private var selectedIndex = UInt32.max
    private var selected = ""
    private var camera = SemanticGraphCamera()
    private var mouseOrigin: CGPoint?
    private var previousMouse: CGPoint?
    private var dragged = false
    private var linkColor = SIMD4<Float>(0.5, 0.5, 0.5, 0.15)

    var onSelect: (String) -> Void = { _ in }
    var lastFitToken: Int?
    var lastZoomCommand: Int?
    var pointCount: Int { points.count }
    private(set) var linkCount = 0

    init?(metalDevice: MTLDevice?) {
        guard let device = metalDevice, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let pointPipeline = try? Self.pipeline(device, library: library, fragment: "pointFragment"),
              let linkPipeline = try? Self.pipeline(device, library: library, fragment: "linkFragment"),
              let pointDepth = Self.depthState(device, writes: true),
              let linkDepth = Self.depthState(device, writes: false) else { return nil }
        self.commandQueue = queue
        self.pointPipeline = pointPipeline
        self.linkPipeline = linkPipeline
        self.pointDepth = pointDepth
        self.linkDepth = linkDepth
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        setAccessibilityElement(true)
        setAccessibilityIdentifier("graph.semantic.canvas")
        setAccessibilityRole(.image)
        updateAppearance()
    }

    required init(coder: NSCoder) { fatalError("Use init(metalDevice:) to create the semantic graph view.") }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = Self.rgb(.textBackgroundColor)
            clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
            linkColor = SIMD4(Self.rgb(.labelColor), 0.15)
        }
        needsDisplay = true
    }

    func update(nodes: [MemoryGraphNode], edges: [MemoryGraphEdge], positions: [String: SemanticGraphPoint],
                colors: [String: NSColor], focusedSpaceIDs: Set<String>) {
        let input = Input(nodes: nodes, edges: edges, positions: positions, colors: colors, focus: focusedSpaceIDs)
        guard self.input != input else { return }
        let previouslyEmpty = points.isEmpty
        self.input = input
        points = nodes.filter { positions[$0.id] != nil }
        let byID = Dictionary(uniqueKeysWithValues: points.enumerated().map { ($0.element.id, UInt32($0.offset)) })
        linkedToSelf = Set(edges.lazy.filter { $0.from == $0.to && byID[$0.from] != nil }.map(\.from))
        let emphasis = GraphSpaceEmphasis(nodes: nodes, focusedSpaceIDs: focusedSpaceIDs)
        let palette = colors.mapValues { Self.rgb($0) }
        let vertexData = points.compactMap { node -> Vertex? in
            guard let point = positions[node.id] else { return nil }
            let color = palette[node.spaceID] ?? Self.rgb(.systemBlue)
            return Vertex(position: SIMD4(point.position, linkedToSelf.contains(node.id) ? 1 : 0),
                          color: SIMD4(color, Float(emphasis.nodeOpacity(node.id))))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(edges.count * 2)
        var selfLinks = 0
        for edge in edges {
            guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
            if from == to { selfLinks += 1 }
            else { indices.append(from); indices.append(to) }
        }
        vertices = vertexData.isEmpty ? nil : vertexData.withUnsafeBytes {
            device?.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        links = indices.isEmpty ? nil : indices.withUnsafeBytes {
            device?.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        normalLinkCount = links == nil ? 0 : indices.count / 2
        linkCount = vertices == nil ? 0 : normalLinkCount + selfLinks
        selectedIndex = byID[selected] ?? .max
        if previouslyEmpty && !points.isEmpty { fit() }
        needsDisplay = true
    }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        selectedIndex = points.firstIndex(where: { $0.id == id }).map(UInt32.init) ?? .max
        if let position = input?.positions[id]?.position {
            let screen = SemanticGraphCamera.screen(position, transform: camera.transform(size: bounds.size), size: bounds.size)
            if screen.map({ bounds.contains($0.point) }) != true { camera.center = position; camera.pan = .zero }
        }
        needsDisplay = true
    }

    func fit() {
        camera.fit(points.compactMap { input?.positions[$0.id]?.position })
        needsDisplay = true
    }

    func zoom(by factor: Float) {
        camera.zoom = max(0.24, min(12, camera.zoom * factor))
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let vertices {
            var uniforms = Uniforms(transform: camera.transform(size: bounds.size), linkColor: linkColor,
                                    diameter: pointDiameter * Float(drawableSize.width / max(1, bounds.width)),
                                    selectedIndex: selectedIndex)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setDepthStencilState(pointDepth)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
            if let links {
                encoder.setRenderPipelineState(linkPipeline)
                encoder.setDepthStencilState(linkDepth)
                encoder.drawIndexedPrimitives(type: .line, indexCount: normalLinkCount * 2,
                                              indexType: .uint32, indexBuffer: links, indexBufferOffset: 0)
            }
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseOrigin = convert(event.locationInWindow, from: nil)
        previousMouse = mouseOrigin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let start = mouseOrigin, let previous = previousMouse else { return }
        if !dragged && hypot(location.x - start.x, location.y - start.y) < 3 { return }
        dragged = true
        let dx = Float(location.x - previous.x), dy = Float(location.y - previous.y)
        if event.modifierFlags.contains(.shift) {
            camera.pan += SIMD2(2 * dx / max(1, Float(bounds.width)), 2 * dy / max(1, Float(bounds.height)))
        } else {
            rotate(dx: dx * 0.009, dy: dy * 0.009)
        }
        previousMouse = location
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseOrigin = nil; previousMouse = nil }
        guard !dragged, let node = hit(convert(event.locationInWindow, from: nil)) else { return }
        onSelect(node.id)
    }

    override func scrollWheel(with event: NSEvent) {
        zoom(by: exp(max(-0.7, min(0.7, Float(event.scrollingDeltaY) * 0.014))))
    }

    override func magnify(with event: NSEvent) { zoom(by: Float(max(0.1, 1 + event.magnification))) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: rotate(dx: -0.16, dy: 0)
        case 124: rotate(dx: 0.16, dy: 0)
        case 125: rotate(dx: 0, dy: -0.16)
        case 126: rotate(dx: 0, dy: 0.16)
        default: super.keyDown(with: event)
        }
    }

    private func rotate(dx: Float, dy: Float) {
        camera.yaw = (camera.yaw + dx).truncatingRemainder(dividingBy: 2 * .pi)
        camera.pitch = max(-1.52, min(1.52, camera.pitch + dy))
        needsDisplay = true
    }

    private var pointDiameter: Float { max(3.2, min(8, 4.5 * sqrt(camera.zoom))) }

    private func hit(_ location: CGPoint) -> MemoryGraphNode? {
        let transform = camera.transform(size: bounds.size)
        var best: (node: MemoryGraphNode, visibleHit: Bool, depth: Float, distance: CGFloat)?
        for node in points {
            guard let position = input?.positions[node.id]?.position,
                  let projected = SemanticGraphCamera.screen(position, transform: transform, size: bounds.size) else { continue }
            let distance = hypot(projected.point.x - location.x, projected.point.y - location.y)
            let diameter = node.id == selected ? pointDiameter * 2.2 : linkedToSelf.contains(node.id) ? pointDiameter * 1.7 : pointDiameter
            let visibleHit = distance <= CGFloat(diameter / 2)
            guard visibleHit || distance <= 8 else { continue }
            if let best {
                if best.visibleHit && !visibleHit { continue }
                if best.visibleHit == visibleHit {
                    if visibleHit && best.depth < projected.depth { continue }
                    if !visibleHit && best.distance < distance { continue }
                }
            }
            best = (node, visibleHit, projected.depth, distance)
        }
        return best?.node
    }

    private static func rgb(_ color: NSColor) -> SIMD3<Float> {
        guard let color = color.usingColorSpace(.sRGB) else { return SIMD3(0.25, 0.5, 0.9) }
        return SIMD3(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
    }

    private static func pipeline(_ device: MTLDevice, library: MTLLibrary, fragment: String) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "project")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.depthAttachmentPixelFormat = .depth32Float
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func depthState(_ device: MTLDevice, writes: Bool) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.isDepthWriteEnabled = writes
        descriptor.depthCompareFunction = .lessEqual
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position; float4 color; };
    struct Uniforms { float4x4 transform; float4 linkColor; float diameter; uint selectedIndex; };
    struct Projected {
        float4 position [[position]];
        float4 color;
        float size [[point_size]];
        float ring;
    };
    vertex Projected project(uint i [[vertex_id]], device const Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]]) {
        Vertex v = vertices[i];
        bool selected = i == uniforms.selectedIndex;
        float ring = selected ? 2.0 : v.position.w;
        float size = uniforms.diameter * (selected ? 2.2 : (ring > 0.0 ? 1.7 : 1.0));
        return {uniforms.transform * float4(v.position.xyz, 1.0), v.color, size, ring};
    }
    fragment float4 pointFragment(Projected in [[stage_in]], float2 uv [[point_coord]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
        float radius = length(uv * 2.0 - 1.0);
        if (radius >= 1.0 || (in.ring > 0.0 && radius > 0.48 && radius < 0.70)) discard_fragment();
        float3 color = in.ring > 1.0 && radius >= 0.70 ? uniforms.linkColor.rgb : in.color.rgb;
        float alpha = in.ring > 1.0 ? 1.0 : in.color.a;
        return float4(color, alpha * (1.0 - smoothstep(0.82, 1.0, radius)));
    }
    fragment float4 linkFragment(Projected in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
        return float4(uniforms.linkColor.rgb, uniforms.linkColor.a * in.color.a);
    }
    """
}
