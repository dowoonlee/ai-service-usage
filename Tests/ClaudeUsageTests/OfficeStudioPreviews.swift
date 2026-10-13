import XCTest
import SwiftUI
@testable import ClaudeUsage

@MainActor
final class OfficeStudioPreviews: SandboxedTestCase {
    func testWorkbenchTabs() throws {
        _ = try PreviewRenderer.requireOutputDir()
        var state = OfficeStudioState(legacyLayout: "0:35:0;1:250:1;9:160:3:40:%ED%99%98%EC%98%81;8:220:3:40;6:120:2")
        try state.savePreset(name: "모두 모인 사무실")
        try state.store("legacy-0")
        try state.store("legacy-2")
        try state.savePreset(name: "작은 휴게실")
        for (theme, appearance) in [("라이트", NSAppearance.Name.aqua), ("다크", .darkAqua)] {
            for tab in OfficeStudioPanel.Tab.allCases {
                let panel = OfficeStudioPanel(state: state, canUndo: true, canRedo: false,
                    tab: .constant(tab), onAction: { _ in }).padding(12)
                try PreviewRenderer.renderInWindow(panel, size: CGSize(width: 520, height: 330),
                    section: "길드 꾸미기", title: "\(tab.rawValue)-\(theme)", appearance: appearance)
            }
        }
    }
}

@MainActor
final class OfficeStudioPhotoTests: SandboxedTestCase {
    func testPhotoExportHasExactCanvasSize() throws {
        let info = PreviewDemoState.guildInfo()
        let sim = OfficeSimulation()
        sim.configure(members: info.members,
            assignments: OfficeLayout.autoAssignments(memberIds: info.members.map(\.nickname), seed: info.guild.id),
            placements: OfficeLayout.sanitizedPlacements(info.guild.officeFurniture))
        defer { sim.stop() }
        let view = GuildOfficeView(info: info, rearrangeMode: .constant(true),
            previewFloorTheme: .constant(nil), previewWallTheme: .constant(nil),
            onSaveStudio: { _ in }, onSetLogoPos: { _, _ in }, onPlaceDecor: { _, _ in },
            onRemoveDecor: { _ in }, onApplyTheme: {}, purchaseSheetOpen: .constant(false))
        let data = try XCTUnwrap(view.photoPNG(pets: sim.pets))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 1120)
        XCTAssertEqual(bitmap.pixelsHigh, 600)
        if PreviewRenderer.outputRoot != nil {
            try PreviewRenderer.writeImage(try XCTUnwrap(NSImage(data: data)), section: "길드 꾸미기", title: "사진-내보내기")
        }
    }
}
