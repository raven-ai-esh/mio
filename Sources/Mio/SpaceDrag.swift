import SwiftUI
import UniformTypeIdentifiers
import MioCore
import OSLog

enum MioSpaceDragLog {
    private static let logger=Logger(subsystem:"app.mio.memory",category:"space-drag")
    // Phase names only: never log memory text, names, IDs or drag payloads.
    static func phase(_ value: String) { logger.debug("\(value,privacy:.public)") }
}

struct MioSpaceDrag: Codable {
    static let typeID="app.mio.space"
    static let contentType=UTType(exportedAs:typeID,conformingTo:.data)
    let sessionID: String
    let spaceID: String
    let parentID: String?
}

enum SpaceDropPlacement { case before, inside, after }

extension AppModel {
    func makeSpaceDrag(_ id: String) -> MioSpaceDrag {
        .init(sessionID:dragSessionID,spaceID:id,parentID:spaceTree.parent(of:id))
    }
    func dropSpace(_ drag: MioSpaceDrag, target: String?, placement: SpaceDropPlacement) async {
        MioSpaceDragLog.phase("space move dispatched")
        guard !busy,drag.sessionID==dragSessionID else { return }
        // Dropping a row back onto itself is a no-op, including its edge zones.
        guard target != drag.spaceID else { return }
        busy=true;defer { busy=false }
        do {
            let tree=spaceTree
            var parent=target,before: String?
            if let target,placement != .inside {
                guard spaces.contains(where:{$0.id==target}) else { throw MioError("space_changed",l("Положение пространства изменилось. Повторите перетаскивание.")) }
                parent=tree.parent(of:target)
                if placement == .before { before=target }
                else {
                    let siblings=tree.siblingIDs(parent:parent).filter{$0 != drag.spaceID}
                    if let index=siblings.firstIndex(of:target),index+1<siblings.count { before=siblings[index+1] }
                }
            }
            _=try await execute("space.move",["space_id":.string(drag.spaceID),"parent_id":parent.map(JSONValue.string) ?? .null,"before_space_id":before.map(JSONValue.string) ?? .null,"expected_parent_id":drag.parentID.map(JSONValue.string) ?? .null])
            await refresh();notice="Пространство перемещено"
        } catch { failure=error.localizedDescription;await refresh() }
    }
}
