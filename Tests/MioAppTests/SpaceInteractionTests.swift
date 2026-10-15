import XCTest
import AppKit
import Combine
import SwiftUI
import MioCore
@testable import Mio

@MainActor final class SpaceInteractionTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-space-interaction-"+UUID().uuidString)
        setenv("MIO_DATA_DIRECTORY",directory.path,1);model=AppModel(startIndexing:false);await model.refresh()
    }
    override func tearDown() async throws { model.shutdown();model=nil;unsetenv("MIO_DATA_DIRECTORY");try? FileManager.default.removeItem(at:directory) }
    private func drag(_ id: String) -> MioSpaceDrag { .init(sessionID:model.dragSessionID,spaceID:id,parentID:model.spaceTree.parent(of:id)) }
    func testSpaceDropBeforeAfterInsideRootAndCancelledOrStaleDrag() async throws {
        let a=try await model.execute("space.create",["name":.string("Alpha")]).id
        let b=try await model.execute("space.create",["name":.string("Beta")]).id
        let c=try await model.execute("space.create",["name":.string("Gamma")]).id
        await model.refresh()
        // Creating a provider (including a cancelled native drag) is read-only.
        _=model.makeSpaceDrag(a);XCTAssertEqual(model.spaceEntries.map(\.id),[a,b,c])
        await model.dropSpace(drag(c),target:a,placement:.before)
        XCTAssertEqual(model.spaceEntries.map(\.id),[c,a,b])
        await model.dropSpace(drag(c),target:b,placement:.after)
        XCTAssertEqual(model.spaceEntries.map(\.id),[a,b,c])
        let oldDrag=drag(b)
        await model.dropSpace(drag(b),target:a,placement:.inside)
        XCTAssertEqual(model.spaceTree.parent(of:b),a)
        await model.dropSpace(oldDrag,target:nil,placement:.inside)
        XCTAssertEqual(model.spaceTree.parent(of:b),a);XCTAssertFalse(model.failure.isEmpty)
        model.failure=""
        await model.dropSpace(drag(a),target:b,placement:.inside)
        XCTAssertNil(model.spaceTree.parent(of:a));XCTAssertFalse(model.failure.isEmpty)
        await model.dropSpace(drag(b),target:nil,placement:.inside)
        XCTAssertNil(model.spaceTree.parent(of:b));XCTAssertEqual(model.spaceEntries.map(\.id),[a,c,b])
        let before=model.snapshot["spaces"]
        await model.dropSpace(drag(b),target:b,placement:.inside)
        await model.dropSpace(.init(sessionID:"foreign",spaceID:c,parentID:nil),target:a,placement:.inside)
        XCTAssertEqual(model.snapshot["spaces"],before)
    }
    func testCustomRGBIsRenderedExactlyAndInvalidHexIsRejected() throws {
        let color=try XCTUnwrap(NSColor(MioFormat.color("#8F36D9")).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent,143.0/255,accuracy:0.00001)
        XCTAssertEqual(color.greenComponent,54.0/255,accuracy:0.00001)
        XCTAssertEqual(color.blueComponent,217.0/255,accuracy:0.00001)
        XCTAssertEqual(MioSpaceRGB(hex:"#8f36d9")?.hex,"#8F36D9")
        for invalid in ["8F36D9","#GGGGGG","#123","#1234567","#+12345",""] { XCTAssertNil(MioSpaceRGB(hex:invalid)) }
        XCTAssertEqual(MioSpaceRGB(red:2,green:-1,blue:0.5).hex,"#FF0080")
    }
    func testEmptyOrPartialCustomColorCannotSubmitNewOrExistingSheet() {
        for original: String? in [nil,"","blue","#8F36D9"] {
            XCTAssertFalse(MioSpacePalette.isValid("",original:original))
            XCTAssertFalse(MioSpacePalette.isValid("#8F",original:original))
            XCTAssertTrue(MioSpacePalette.isValid("#8F36D9",original:original))
            XCTAssertTrue(MioSpacePalette.isValid("teal",original:original))
        }
        XCTAssertTrue(MioSpacePalette.isValid("legacy",original:"legacy"))
        XCTAssertFalse(MioSpacePalette.isValid("legacy",original:nil))
    }
    func testNativeSpaceRowProvidesAppKitDragImageComponents() async throws {
        _=try await model.execute("space.create",["name":.string("Draggable")]);await model.refresh()
        let view=SpaceOutlineView(frame:NSRect(x:0,y:0,width:220,height:100)),column=NSTableColumn(identifier:.init("space"))
        view.addTableColumn(column);view.outlineTableColumn=column
        let coordinator=SpacesOutline.Coordinator(model:model,height:.constant(100));view.dataSource=coordinator;view.delegate=coordinator;coordinator.update(view)
        let item=coordinator.outlineView(view,child:1,ofItem:nil)
        let cell=try XCTUnwrap(coordinator.outlineView(view,viewFor:column,item:item) as? NSTableCellView)
        cell.frame=NSRect(x:0,y:0,width:220,height:32);cell.layoutSubtreeIfNeeded()
        XCTAssertNotNil(cell.imageView);XCTAssertNotNil(cell.textField)
        XCTAssertFalse(cell.draggingImageComponents.isEmpty,"Native row must supply a real drag preview")
    }
    func testUnchangedIndexerStatusDoesNotInvalidateNativeWorkspace() async throws {
        await model.refreshIndexing()
        var notifications=0
        let observer=model.$indexingStatus.dropFirst().sink { _ in notifications+=1 }
        await model.refreshIndexing();await model.refreshIndexing()
        XCTAssertEqual(notifications,0);withExtendedLifetime(observer) {}
    }
}
