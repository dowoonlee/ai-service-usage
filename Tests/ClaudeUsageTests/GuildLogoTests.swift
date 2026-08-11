import AppKit
import XCTest
@testable import ClaudeUsage

final class GuildLogoTests: XCTestCase {
    private let guildID = "5f2c9a10-1111-4222-8333-444455556666"

    // MARK: - 저장 값 파싱

    func testSampleRoundTrip() {
        for i in 0..<GuildLogo.sampleCount {
            let raw = GuildLogo.encode(sample: i)
            XCTAssertEqual(raw, "s:\(i)")
            XCTAssertEqual(GuildLogo.parse(raw, guildID: guildID), .sample(i))
        }
    }

    func testCustomRoundTrip() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD])
        let raw = GuildLogo.encode(customPNG: png)
        XCTAssertTrue(raw.hasPrefix("p:"))
        XCTAssertEqual(GuildLogo.parse(raw, guildID: guildID), .custom(png))
    }

    // 서버가 값을 안 내려주거나(구버전) 깨진 값이 와도 길드마다 일관된 샘플이 나와야 한다.
    func testFallbackIsDeterministicAndInRange() {
        let broken: [String?] = [nil, "", "s:", "s:99", "s:-1", "x:1", "p:@@@not-base64@@@"]
        for raw in broken {
            let a = GuildLogo.parse(raw, guildID: guildID)
            let b = GuildLogo.parse(raw, guildID: guildID)
            XCTAssertEqual(a, b, "같은 입력은 항상 같은 폴백이어야 한다: \(raw ?? "nil")")
            guard case .sample(let i) = a else {
                return XCTFail("폴백은 항상 샘플이어야 한다: \(raw ?? "nil")")
            }
            XCTAssertTrue((0..<GuildLogo.sampleCount).contains(i))
        }
    }

    // 길드가 다르면 대체로 다른 로고가 나와야 한다(해시가 한 값으로 쏠리지 않는지).
    func testFallbackSpreadsAcrossGuilds() {
        let indices = Set((0..<200).map { GuildLogo.fallbackIndex(for: "guild-\($0)") })
        XCTAssertEqual(indices.count, GuildLogo.sampleCount,
                       "200개 길드면 10종이 모두 나와야 한다")
    }

    // MARK: - 샘플 렌더

    func testSampleImagesHaveExactPixelSize() {
        for i in 0..<GuildLogo.sampleCount {
            let img = GuildLogo.sampleImage(i)
            XCTAssertEqual(Int(img.size.width), GuildLogo.pixelWidth, "sample \(i) width")
            XCTAssertEqual(Int(img.size.height), GuildLogo.pixelHeight, "sample \(i) height")
        }
    }

    // 문양이 실제로 그려졌는지 — 배경 한 가지 색으로만 채워진 로고가 없어야 한다.
    func testSampleImagesAreNotBlank() {
        for i in 0..<GuildLogo.sampleCount {
            guard let cg = GuildLogo.cgImage(from: GuildLogo.sampleImage(i)),
                  let data = cg.dataProvider?.data as Data? else {
                return XCTFail("sample \(i): 픽셀을 읽지 못함")
            }
            var distinct = Set<UInt32>()
            var offset = 0
            while offset + 3 < data.count {
                let b = UInt32(data[offset])
                let g = UInt32(data[offset + 1])
                let r = UInt32(data[offset + 2])
                distinct.insert((r << 16) | (g << 8) | b)
                offset += 4
            }
            XCTAssertGreaterThan(distinct.count, 2, "sample \(i): 색이 사실상 단색")
        }
    }

    // 인덱스가 범위를 벗어나도 크래시 없이 클램프.
    func testSampleImageClampsOutOfRangeIndex() {
        XCTAssertEqual(Int(GuildLogo.sampleImage(-5).size.width), GuildLogo.pixelWidth)
        XCTAssertEqual(Int(GuildLogo.sampleImage(999).size.width), GuildLogo.pixelWidth)
    }

    // MARK: - 픽셀화

    /// 위 절반 빨강 / 아래 절반 파랑 원본. 방향(상하 반전) 회귀 감시용.
    private func makeTestImage(w: Int, h: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: w * 4, bitsPerPixel: 32)!
        for y in 0..<h {
            for x in 0..<w {
                var px: [Int] = y < h / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
                rep.setPixel(&px, atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }

    func testPixelateProducesExactSize() throws {
        let src = makeTestImage(w: 400, h: 300)
        let png = try XCTUnwrap(GuildLogo.pixelate(src, crop: CGRect(x: 0, y: 0, width: 400, height: 225)))
        let out = try XCTUnwrap(NSImage(data: png))
        XCTAssertEqual(Int(out.size.width), GuildLogo.pixelWidth)
        XCTAssertEqual(Int(out.size.height), GuildLogo.pixelHeight)
        XCTAssertLessThanOrEqual(png.count, GuildLogo.maxCustomBytes)
    }

    // 크롭 좌표계는 좌상단 원점 — 위쪽을 자르면 빨강만 남아야 한다.
    // (CGContext는 좌하단 원점이라 구현이 바뀌면 조용히 뒤집힐 수 있어 고정해 둔다.)
    func testPixelateKeepsVerticalOrientation() throws {
        let src = makeTestImage(w: 320, h: 180)
        let topHalf = CGRect(x: 0, y: 0, width: 320, height: 80)
        let png = try XCTUnwrap(GuildLogo.pixelate(src, crop: topHalf))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let center = try XCTUnwrap(rep.colorAt(x: GuildLogo.pixelWidth / 2,
                                               y: GuildLogo.pixelHeight / 2))
        XCTAssertGreaterThan(center.redComponent, 0.8, "위쪽 크롭이면 빨강이어야 함")
        XCTAssertLessThan(center.blueComponent, 0.2)
    }

    // 크롭이 원본 경계를 걸쳐도 교집합으로 잘라내고 크래시하지 않는다.
    func testPixelateClampsPartiallyOutOfBoundsCrop() {
        let src = makeTestImage(w: 100, h: 100)
        let straddling = CGRect(x: -50, y: -30, width: 200, height: 112)
        XCTAssertNotNil(GuildLogo.pixelate(src, crop: straddling))
    }

    func testPixelateRejectsEmptyCrop() {
        let src = makeTestImage(w: 100, h: 100)
        XCTAssertNil(GuildLogo.pixelate(src, crop: CGRect(x: 400, y: 400, width: 50, height: 28)),
                     "원본과 겹치지 않는 크롭은 nil")
    }

    // MARK: - 서버 계약

    // guild_policy.ts의 GUILD_LOGO_SAMPLE_COUNT / GUILD_LOGO_MAX_BYTES와 같이 움직여야 한다.
    // 서버만 고치고 클라를 잊으면 유효한 로고가 400으로 거부되므로 값을 못 박아 둔다.
    func testServerContractConstants() {
        XCTAssertEqual(GuildLogo.sampleCount, 10)
        XCTAssertEqual(GuildLogo.maxCustomBytes, 8 * 1024)
        XCTAssertEqual(GuildLogo.pixelWidth, 66)
        XCTAssertEqual(GuildLogo.pixelHeight, 44)
        // 3:2 유지(국기 표준) — 크롭 UI와 표시 뷰가 공유하는 전제.
        XCTAssertEqual(GuildLogo.pixelWidth * 2, GuildLogo.pixelHeight * 3)
    }
}
