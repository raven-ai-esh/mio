import AppKit
import SwiftUI
import MioCore

struct GraphSpaceEmphasis {
    let focusedSpaceIDs: Set<String>
    private let spaceByNode: [String:String]
    init(nodes: [MemoryGraphNode], focusedSpaceIDs: Set<String>) {
        self.focusedSpaceIDs = focusedSpaceIDs
        spaceByNode = Dictionary(uniqueKeysWithValues:nodes.map{($0.id,$0.spaceID)})
    }
    func nodeOpacity(_ id: String) -> Double {
        focusedSpaceIDs.isEmpty || focusedSpaceIDs.contains(spaceByNode[id] ?? "") ? 1 : 0.06
    }
    func edgeOpacity(_ from: String, _ to: String) -> Double {
        let a = nodeOpacity(from) == 1, b = nodeOpacity(to) == 1
        return a && b ? 1 : a || b ? 0.22 : 0.06
    }
}

struct GraphCanvas: NSViewRepresentable {
    var localizer: MioLocalizer = .init(language: .system)
    var nodes: [MemoryGraphNode]
    var edges: [MemoryGraphEdge]
    var positions: [String:GraphPoint]
    var colors: [String:NSColor]
    var selected: String
    var history: Bool
    var highlights: GraphReplayHighlights
    var focusedSpaceIDs: Set<String>
    var fitToken: Int
    var zoomCommand: Int
    var select: (String) -> Void
    func makeNSView(context: Context) -> MemoryGraphCanvasView { MemoryGraphCanvasView() }
    func updateNSView(_ view: MemoryGraphCanvasView, context: Context) {
        view.localizer = localizer
        view.setAccessibilityLabel(localizer.text("Граф памяти"))
        view.setAccessibilityHelp(localizer.text("Выберите узел мышью или найдите его по названию. Перемещение: перетаскивание и прокрутка. Масштаб: жест увеличения или кнопки панели."))
        view.nodes = nodes; view.edges = edges; view.positions = positions; view.colors = colors
        view.selected = selected; view.history = history; view.highlights = highlights; view.onSelect = select
        view.focusedSpaceIDs = focusedSpaceIDs
        if !positions.isEmpty && view.lastFitToken != fitToken { view.fit(); view.lastFitToken = fitToken }
        if view.lastZoomCommand != zoomCommand { view.zoom(by:zoomCommand > view.lastZoomCommand ? 1.25:0.8,at:CGPoint(x:view.bounds.midX,y:view.bounds.midY)); view.lastZoomCommand = zoomCommand }
        view.needsDisplay = true
    }
}

// One native drawing surface, not one SwiftUI button/view per memory node.
// Reading content is entirely outside this renderer. Layout is supplied once.
final class MemoryGraphCanvasView: NSView {
    var localizer = MioLocalizer(language: .system)
    var nodes = [MemoryGraphNode]()
    var edges = [MemoryGraphEdge]()
    var positions = [String:GraphPoint]()
    var colors = [String:NSColor]()
    var selected = ""
    var history = false
    var highlights = GraphReplayHighlights()
    var focusedSpaceIDs = Set<String>()
    var onSelect: ((String)->Void)?
    var lastFitToken = -1
    var lastZoomCommand = 0
    private(set) var renderedNodes = 0
    private(set) var renderedEdges = 0
    private(set) var lastDrawSeconds = 0.0
    private var scale = 1.0
    private var pan = CGPoint.zero
    private var hovered = ""
    private var down = CGPoint.zero
    private var originalPan = CGPoint.zero
    private var tracking: NSTrackingArea?
    private var fittedInitialFrame = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Граф памяти")
        setAccessibilityHelp("Выберите узел мышью или найдите его по названию. Перемещение: перетаскивание и прокрутка. Масштаб: жест увеличения или кнопки панели.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); if !fittedInitialFrame && !positions.isEmpty { fit() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking!)
    }
    func fit() {
        guard !positions.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let minX = positions.values.map(\.x).min() ?? 0, maxX = positions.values.map(\.x).max() ?? 0
        let minY = positions.values.map(\.y).min() ?? 0, maxY = positions.values.map(\.y).max() ?? 0
        scale = min(4,max(0.01,min(Double(bounds.width-80)/max(100,maxX-minX),Double(bounds.height-80)/max(100,maxY-minY))))
        pan = CGPoint(x:-(minX+maxX)/2*scale,y:-(minY+maxY)/2*scale)
        fittedInitialFrame = true
        needsDisplay = true
    }
    func screen(_ id: String) -> CGPoint? {
        guard let p = positions[id] else { return nil }
        return CGPoint(x:Double(bounds.midX)+pan.x+p.x*scale,y:Double(bounds.midY)+pan.y+p.y*scale)
    }
    func zoom(by factor: Double, at point: CGPoint) {
        let next = max(0.01,min(20,scale*factor)), multiplier = next/scale
        pan.x = point.x-bounds.midX-(point.x-bounds.midX-pan.x)*multiplier
        pan.y = point.y-bounds.midY-(point.y-bounds.midY-pan.y)*multiplier
        scale = next; needsDisplay = true
    }
    private func nearest(to point: CGPoint) -> String {
        var nearest = "", best = 13.0
        for node in nodes {
            guard let p = screen(node.id) else { continue }
            let distance = hypot(p.x-point.x,p.y-point.y)
            if distance < best { best = distance; nearest = node.id }
        }
        return nearest
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); down = convert(event.locationInWindow,from:nil); originalPan = pan }
    override func mouseDragged(with event: NSEvent) { let point = convert(event.locationInWindow,from:nil); pan = CGPoint(x:originalPan.x+point.x-down.x,y:originalPan.y+point.y-down.y); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard hypot(point.x-down.x,point.y-down.y) < 5 else { return }
        let id = nearest(to:point); if !id.isEmpty { onSelect?(id) }
    }
    override func mouseMoved(with event: NSEvent) {
        let next = nearest(to:convert(event.locationInWindow,from:nil))
        if next != hovered { hovered = next; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = ""; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) { zoom(by:exp(Double(event.scrollingDeltaY)*0.015),at:convert(event.locationInWindow,from:nil)) }
        else { pan.x += event.scrollingDeltaX; pan.y += event.scrollingDeltaY; needsDisplay = true }
    }
    override func magnify(with event: NSEvent) { zoom(by:1+Double(event.magnification),at:convert(event.locationInWindow,from:nil)) }
    override func keyDown(with event: NSEvent) {
        guard [123,124,125,126].contains(event.keyCode) else { super.keyDown(with:event); return }
        guard let origin = screen(selected), !selected.isEmpty else { if let first = nodes.first { onSelect?(first.id) }; return }
        let direction: CGPoint = event.keyCode == 123 ? CGPoint(x:-1,y:0) : event.keyCode == 124 ? CGPoint(x:1,y:0) : event.keyCode == 125 ? CGPoint(x:0,y:1) : CGPoint(x:0,y:-1)
        var nearestID = "", best = Double.infinity
        for node in nodes where node.id != selected {
            guard let point = screen(node.id) else { continue }
            let dx = Double(point.x-origin.x), dy = Double(point.y-origin.y)
            let forward = dx*Double(direction.x)+dy*Double(direction.y)
            guard forward > 0 else { continue }
            let score = hypot(dx,dy)+abs(dx*Double(direction.y)-dy*Double(direction.x))*2
            if score < best { best = score; nearestID = node.id }
        }
        if !nearestID.isEmpty { onSelect?(nearestID) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let started = Date()
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        renderedNodes = 0; renderedEdges = 0
        let emphasis = GraphSpaceEmphasis(nodes:nodes,focusedSpaceIDs:focusedSpaceIDs)
        renderedEdges = stroke(edges,context:context,color:NSColor.labelColor.withAlphaComponent(history ? 0.07:0.14),width:0.6,dashed:false,emphasis:emphasis)
        if !selected.isEmpty {
            _ = stroke(edges.filter { $0.from == selected || $0.to == selected },context:context,color:NSColor.controlAccentColor.withAlphaComponent(0.8),width:1.1,dashed:false,emphasis:emphasis)
        }
        _ = stroke(highlights.issuedEdges,context:context,color:NSColor.systemTeal.withAlphaComponent(0.8),width:1.6,dashed:false,emphasis:emphasis)
        context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.85).cgColor); context.setLineWidth(1.5); context.setLineDash(phase:0,lengths:[5,4])
        for (from,to,index) in highlights.transitions {
            guard let a = screen(from), let b = screen(to) else { continue }
            context.setAlpha(emphasis.edgeOpacity(from,to))
            if from == to { context.strokeEllipse(in:CGRect(x:a.x-15,y:a.y-20,width:30,height:30)); continue }
            context.move(to:a); context.addLine(to:b); context.strokePath()
            context.setLineDash(phase:0,lengths:[])
            let angle = atan2(b.y-a.y,b.x-a.x), end = CGPoint(x:b.x-cos(angle)*8,y:b.y-sin(angle)*8)
            context.move(to:CGPoint(x:end.x-cos(angle-0.6)*8,y:end.y-sin(angle-0.6)*8)); context.addLine(to:end); context.addLine(to:CGPoint(x:end.x-cos(angle+0.6)*8,y:end.y-sin(angle+0.6)*8)); context.strokePath()
            label("\(index)",at:CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2),color:.systemOrange)
            context.setLineDash(phase:0,lengths:[5,4])
        }
        context.setLineDash(phase:0,lengths:[]); context.setAlpha(1)
        for node in nodes {
            guard let point = screen(node.id) else { continue }
            let radius = node.id == selected || node.id == hovered ? 6.0 : min(4,max(2.2,scale*4))
            guard bounds.insetBy(dx:-20,dy:-20).contains(point) else { continue }
            let circle = CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)
            let opacity = emphasis.nodeOpacity(node.id)
            // A crossing edge must not brighten the centre of a dimmed node.
            if opacity < 1 { context.setFillColor(NSColor.textBackgroundColor.cgColor); context.fillEllipse(in:circle) }
            context.saveGState(); context.setAlpha(opacity)
            var color = colors[node.spaceID] ?? .systemBlue
            let candidates = highlights.candidates.contains(node.id), read = highlights.reads.contains(node.id), mutation = highlights.mutations.contains(node.id), failed = highlights.failures.contains(node.id)
            if history { color = failed ? .systemRed : mutation ? .systemGreen : read ? .systemBlue : candidates ? .systemBlue : color.withAlphaComponent(0.18) }
            if history && candidates && !read && !mutation && !failed { context.setStrokeColor(color.withAlphaComponent(0.55).cgColor); context.setLineWidth(1.3); context.strokeEllipse(in:circle) }
            else { context.setFillColor(color.cgColor); context.fillEllipse(in:circle) }
            if node.id == selected || highlights.current.contains(node.id) { context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5); context.strokeEllipse(in:circle.insetBy(dx:-3,dy:-3)) }
            if failed { context.setStrokeColor(NSColor.systemRed.cgColor); context.move(to:CGPoint(x:point.x-5,y:point.y-5)); context.addLine(to:CGPoint(x:point.x+5,y:point.y+5)); context.strokePath() }
            if node.id == selected || node.id == hovered || nodes.count <= 24 { label(String(node.title.prefix(80)),at:CGPoint(x:point.x+9,y:point.y+7),color:.labelColor) }
            context.restoreGState()
            renderedNodes += 1
        }
        lastDrawSeconds = Date().timeIntervalSince(started)
        let focused = nodes.filter{emphasis.nodeOpacity($0.id)==1}.count
        let filter = focusedSpaceIDs.isEmpty ? "" : localizer.text(" Выделено %@ узлов, приглушено %@ узлов.",[String(focused),String(nodes.count-focused)])
        setAccessibilityValue(localizer.text("%@ узлов, %@ связей; отрисовано %@ узлов и %@ связей.%@ %@",[String(nodes.count),String(edges.count),String(renderedNodes),String(renderedEdges),filter,selected.isEmpty ? "":nodes.first{$0.id==selected}?.title ?? ""]))
    }
    private func stroke(_ edges: [MemoryGraphEdge], context: CGContext, color: NSColor, width: Double, dashed: Bool, emphasis: GraphSpaceEmphasis) -> Int {
        var paths = [Double:CGMutablePath](), count = 0
        for edge in edges {
            guard let a = screen(edge.from), let b = screen(edge.to) else { continue }
            let opacity = emphasis.edgeOpacity(edge.from,edge.to), path = paths[opacity] ?? CGMutablePath()
            paths[opacity] = path
            if edge.from == edge.to { path.addEllipse(in:CGRect(x:a.x-9,y:a.y-18,width:18,height:18)) }
            else { path.move(to:a); path.addLine(to:b) }
            count += 1
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor); context.setLineWidth(width); context.setLineDash(phase:0,lengths:dashed ? [4,4]:[])
        for opacity in paths.keys.sorted() { context.setAlpha(opacity); context.addPath(paths[opacity]!); context.strokePath() }
        context.restoreGState()
        return count
    }
    private func label(_ text: String, at point: CGPoint, color: NSColor) {
        let string = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:color])
        let size = string.size(), box = CGRect(x:min(max(3,point.x),max(3,bounds.width-size.width-7)),y:min(max(3,point.y),max(3,bounds.height-20)),width:size.width+8,height:size.height+4)
        NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill(); NSBezierPath(roundedRect:box,xRadius:4,yRadius:4).fill()
        string.draw(at:CGPoint(x:box.minX+4,y:box.minY+2))
    }
}
