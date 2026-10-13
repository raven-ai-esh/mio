import Foundation

public struct MemoryGraphNode: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let spaceID: String
    public let revisionID: String
    public let status: String
    public init(id: String, title: String = "", spaceID: String = "", revisionID: String = "", status: String = "") {
        self.id = id; self.title = title; self.spaceID = spaceID; self.revisionID = revisionID; self.status = status
    }
    public init(_ value: JSONValue) {
        self.init(id: value["id"].stringValue ?? "", title: value["title"].stringValue ?? "", spaceID: value["space_id"].stringValue ?? "", revisionID: value["revision_id"].stringValue ?? "", status: value["status"].stringValue ?? "")
    }
}

public struct MemoryGraphEdge: Hashable, Sendable, Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let kind: String
    public init(id: String, from: String, to: String, kind: String = "related") { self.id = id; self.from = from; self.to = to; self.kind = kind }
    public init(_ value: JSONValue) { self.init(id: value["id"].stringValue ?? "", from: value["from_note_id"].stringValue ?? "", to: value["to_note_id"].stringValue ?? "", kind: value["kind"].stringValue ?? "related") }
}

public struct GraphPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public func distance(to other: GraphPoint) -> Double { hypot(x - other.x, y - other.y) }
}

public struct GraphLayoutResult: Sendable {
    public let positions: [String: GraphPoint]
    public let componentCount: Int
    public let elapsed: Double
    public init(positions: [String: GraphPoint], componentCount: Int, elapsed: Double = 0) { self.positions = positions; self.componentCount = componentCount; self.elapsed = elapsed }
}

// Connected components are packed separately. Within each component a cooled
// Fruchterman–Reingold layout uses Barnes–Hut repulsion, not an all-pairs loop.
// Stable input order makes recomputation deterministic; UI selections don't
// change the topology and therefore don't restart the calculation.
public enum MemoryGraphLayout {
    public static func signature(nodes: [MemoryGraphNode], edges: [MemoryGraphEdge]) -> String {
        nodes.map(\.id).sorted().joined(separator: "\n") + "\u{0}" + edges.map { $0.id + ":" + $0.from + ":" + $0.to }.sorted().joined(separator: "\n")
    }
    public static func calculate(nodes: [MemoryGraphNode], edges: [MemoryGraphEdge], iterations: Int = 220) throws -> GraphLayoutResult {
        let started = Date()
        let ids = Array(Set(nodes.map(\.id).filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return .init(positions: [:], componentCount: 0) }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var adjacency = [[Int]](repeating: [], count: ids.count), pairs = [(Int, Int)](), seen = Set<String>()
        for edge in edges.sorted(by: { $0.id < $1.id }) {
            guard let a = index[edge.from], let b = index[edge.to], a != b else { continue }
            let key = "\(min(a,b)):\(max(a,b))"
            guard seen.insert(key).inserted else { continue }
            adjacency[a].append(b); adjacency[b].append(a); pairs.append((a,b))
        }
        var visited = Set<Int>(), components = [[Int]]()
        for root in ids.indices where !visited.contains(root) {
            var queue = [root], cursor = 0; visited.insert(root)
            while cursor < queue.count {
                let current = queue[cursor]; cursor += 1
                for neighbor in adjacency[current].sorted() where visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
            components.append(queue.sorted())
        }
        components.sort { $0.count == $1.count ? $0[0] < $1[0] : $0.count > $1.count }
        struct Piece { var ids: [Int]; var points: [GraphPoint]; var width: Double; var height: Double }
        var pieces = [Piece]()
        for component in components {
            try Task.checkCancellation()
            let local = Dictionary(uniqueKeysWithValues: component.enumerated().map { ($0.element,$0.offset) })
            let componentPairs = pairs.compactMap { pair -> (Int,Int)? in
                guard let a = local[pair.0], let b = local[pair.1] else { return nil }; return (a,b)
            }
            var points = try forceLayout(count: component.count, pairs: componentPairs, iterations: iterations)
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
            for i in points.indices { points[i].x -= minX; points[i].y -= minY }
            pieces.append(Piece(ids: component, points: points, width: max(36,maxX-minX), height: max(36,maxY-minY)))
        }
        let padding = 90.0
        let totalArea = pieces.reduce(0.0) { $0 + ($1.width+padding)*($1.height+padding) }
        let rowWidth = max((pieces.map(\.width).max() ?? 0)+padding, sqrt(totalArea)*1.4)
        var x = 0.0, y = 0.0, rowHeight = 0.0, result = [String:GraphPoint]()
        for piece in pieces {
            if x > 0 && x+piece.width+padding > rowWidth { x = 0; y += rowHeight+padding; rowHeight = 0 }
            for (i,id) in piece.ids.enumerated() { result[ids[id]] = GraphPoint(x+piece.points[i].x,y+piece.points[i].y) }
            x += piece.width+padding; rowHeight = max(rowHeight,piece.height)
        }
        let centerX = ((result.values.map(\.x).min() ?? 0)+(result.values.map(\.x).max() ?? 0))/2
        let centerY = ((result.values.map(\.y).min() ?? 0)+(result.values.map(\.y).max() ?? 0))/2
        for id in ids { if let p = result[id] { result[id] = GraphPoint(p.x-centerX,p.y-centerY) } }
        return .init(positions: result, componentCount: components.count, elapsed: Date().timeIntervalSince(started))
    }
    private static func forceLayout(count: Int, pairs: [(Int,Int)], iterations: Int) throws -> [GraphPoint] {
        if count == 1 { return [GraphPoint(0,0)] }
        let k = 64.0
        var points = (0..<count).map { i -> GraphPoint in
            let angle = Double(i)*2.399963229728653, r = k*sqrt(Double(i)+0.5)*0.65
            return GraphPoint(cos(angle)*r,sin(angle)*r)
        }
        let rounds = max(1,iterations)
        for round in 0..<rounds {
            if round % 8 == 0 { try Task.checkCancellation() }
            let tree = QuadTree(points: points)
            var force = points.indices.map { tree.repulsion(index: $0, point: points[$0], k: k) }
            for (a,b) in pairs {
                let dx = points[a].x-points[b].x, dy = points[a].y-points[b].y, d = max(0.1,hypot(dx,dy))
                let multiplier = d/k
                force[a].x -= dx*multiplier; force[a].y -= dy*multiplier
                force[b].x += dx*multiplier; force[b].y += dy*multiplier
            }
            let temperature = k*(1.8*pow(1-Double(round)/Double(rounds),1.5)+0.04)
            for i in points.indices {
                force[i].x -= points[i].x*0.035; force[i].y -= points[i].y*0.035
                let length = max(0.001,hypot(force[i].x,force[i].y)), step = min(length,temperature)/length
                points[i].x += force[i].x*step; points[i].y += force[i].y*step
            }
        }
        return points
    }
    private final class QuadTree {
        struct Cell { var x: Double; var y: Double; var half: Double; var center: GraphPoint; var mass: Int; var children: [Int]; var members: [Int] }
        var cells = [Cell]()
        let points: [GraphPoint]
        init(points: [GraphPoint]) {
            self.points = points
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0, minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
            _ = build(Array(points.indices),x:(minX+maxX)/2,y:(minY+maxY)/2,half:max(1,max(maxX-minX,maxY-minY)/2+1),depth:0)
        }
        @discardableResult private func build(_ members: [Int], x: Double, y: Double, half: Double, depth: Int) -> Int {
            let center = GraphPoint(members.reduce(0) { $0+points[$1].x }/Double(members.count),members.reduce(0) { $0+points[$1].y }/Double(members.count))
            let id = cells.count
            cells.append(Cell(x:x,y:y,half:half,center:center,mass:members.count,children:[],members:[]))
            if members.count <= 1 || depth >= 18 { cells[id].members = members; return id }
            var groups = [[Int]](repeating:[],count:4)
            for i in members { groups[(points[i].x>=x ? 1:0)+(points[i].y>=y ? 2:0)].append(i) }
            for q in 0..<4 where !groups[q].isEmpty {
                let child = build(groups[q],x:x+(q%2==1 ? half/2:-half/2),y:y+(q>=2 ? half/2:-half/2),half:half/2,depth:depth+1)
                cells[id].children.append(child)
            }
            return id
        }
        func repulsion(index: Int, point: GraphPoint, k: Double) -> GraphPoint {
            var result = GraphPoint(0,0), stack = [0]
            while let id = stack.popLast() {
                let cell = cells[id]
                if !cell.members.isEmpty {
                    for other in cell.members where other != index {
                        let dx = point.x-points[other].x, dy = point.y-points[other].y, square = max(0.01,dx*dx+dy*dy)
                        result.x += dx*k*k/square; result.y += dy*k*k/square
                    }
                } else {
                    let dx = point.x-cell.center.x, dy = point.y-cell.center.y, square = max(0.01,dx*dx+dy*dy)
                    let contains = abs(point.x-cell.x)<=cell.half && abs(point.y-cell.y)<=cell.half
                    if !contains && cell.half*2/sqrt(square) < 0.85 {
                        let multiplier = k*k*Double(cell.mass)/square
                        result.x += dx*multiplier; result.y += dy*multiplier
                    } else { stack.append(contentsOf:cell.children) }
                }
            }
            return result
        }
    }
}
