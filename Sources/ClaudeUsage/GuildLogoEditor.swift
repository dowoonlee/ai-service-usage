import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 길드 로고 편집 시트 — 샘플 10종 중 고르거나, 이미지를 올려 3:2로 잘라 픽셀 로고로 굽는다.
///
/// 결과는 `GuildLogo` 저장 문자열("s:N" / "p:<base64>")로 `onCommit`에 넘긴다.
/// 서버 호출·RP 차감은 호출측(`GuildView`)이 맡는다 — 이 뷰는 순수하게 "무엇을 적용할지"만 정한다.
@MainActor
struct GuildLogoEditorView: View {
    let currentLogo: String?
    let guildID: String
    let costRP: Int
    let availableRP: Int
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    private enum Mode: String, CaseIterable {
        case sample = "샘플"
        case upload = "이미지 업로드"
    }

    @State private var mode: Mode = .sample
    @State private var selectedSample: Int
    /// 업로드 원본. nil이면 업로드 탭은 파일 선택 안내만 보여준다.
    @State private var source: NSImage?
    /// 크롭 박스 — 원본 폭 대비 비율(0.1~1.0)과 중심(정규화 0~1 좌표).
    @State private var cropScale: CGFloat = 1.0
    @State private var cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// 확정 전 픽셀화 결과(66×44 PNG). 크롭이 바뀔 때만 다시 굽는다.
    @State private var bakedPNG: Data?
    @State private var loadError: String?
    /// 드래그 시작 시점의 크롭 중심. `DragGesture.translation`이 **누적값**이라
    /// onChanged마다 더하면 이동이 가속된다 — 매번 시작점 기준으로 다시 계산해야 한다.
    @State private var dragStartCenter: CGPoint?

    init(currentLogo: String?, guildID: String, costRP: Int, availableRP: Int,
         onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.currentLogo = currentLogo
        self.guildID = guildID
        self.costRP = costRP
        self.availableRP = availableRP
        self.onCommit = onCommit
        self.onCancel = onCancel
        // 현재 값이 샘플이면 그 샘플을 선택 상태로 열어 준다.
        if case .sample(let i) = GuildLogo.parse(currentLogo, guildID: guildID) {
            _selectedSample = State(initialValue: i)
        } else {
            _selectedSample = State(initialValue: GuildLogo.fallbackIndex(for: guildID))
            _mode = State(initialValue: .upload)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("길드 로고 변경")
                .font(.system(size: 14, weight: .bold))

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .sample: sampleGrid
            case .upload: uploadPane
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: - 샘플 선택

    private var sampleGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("길드 생성 시 무작위로 받은 로고입니다. 다른 샘플로 바꿀 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                      spacing: 8) {
                ForEach(0..<GuildLogo.sampleCount, id: \.self) { i in
                    Button { selectedSample = i } label: {
                        logoThumb(GuildLogo.sampleImage(i), width: 76)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.sm)
                                    .strokeBorder(i == selectedSample ? Color.accentColor : .clear,
                                                  lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 업로드 + 크롭

    private var uploadPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("이미지 선택…") { pickFile() }
                    .font(.system(size: 12))
                if source != nil {
                    Button("다시 고르기") { source = nil; bakedPNG = nil }
                        .font(.system(size: 11))
                }
                Spacer()
            }
            if let err = loadError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }

            if let src = source {
                cropCanvas(src)
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 10))
                    Slider(value: $cropScale, in: 0.15...1.0)
                        .onChange(of: cropScale) { _, _ in clampCenter(); bake() }
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 10))
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("결과 미리보기 (\(GuildLogo.pixelWidth)×\(GuildLogo.pixelHeight))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let png = bakedPNG, let img = GuildLogo.previewImage(fromPNG: png) {
                            logoThumb(img, width: 192)
                        } else {
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 192, height: 108)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("드래그해서 위치를, 슬라이더로 크기를 맞추세요.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let png = bakedPNG {
                            Text("\(png.count / 1024 > 0 ? "\(png.count / 1024)KB" : "\(png.count)B")")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 150)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22)).foregroundStyle(.secondary)
                            Text("PNG · JPG 등 이미지를 선택하면 3:2로 자를 수 있습니다")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    )
            }
        }
    }

    /// 원본을 fit으로 깔고 그 위에 3:2 크롭 창을 겹쳐 보여준다.
    /// 크롭 창 밖은 어둡게 덮어 잘려나갈 영역을 눈으로 알 수 있게 한다.
    private func cropCanvas(_ src: NSImage) -> some View {
        GeometryReader { geo in
            let fitted = fittedRect(imageSize: src.size, in: geo.size)
            let box = cropBoxRect(in: fitted)
            ZStack(alignment: .topLeading) {
                Image(nsImage: src)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                Color.black.opacity(0.45)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(
                        // 크롭 창만 뚫린 마스크 (even-odd로 구멍)
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: geo.size))
                            p.addRect(box)
                        }.fill(style: FillStyle(eoFill: true))
                    )
                    .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { g in
                        guard fitted.width > 0, fitted.height > 0 else { return }
                        let start = dragStartCenter ?? cropCenter
                        if dragStartCenter == nil { dragStartCenter = start }
                        cropCenter.x = start.x + g.translation.width / fitted.width
                        cropCenter.y = start.y + g.translation.height / fitted.height
                        clampCenter()
                    }
                    // 미리보기는 드래그가 끝날 때만 다시 굽는다 — 큰 원본에서 매 프레임
                    // CGContext를 새로 만드는 비용을 피하려고 의도적으로 미룬다.
                    .onEnded { _ in dragStartCenter = nil; bake() }
            )
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.black.opacity(0.15)))
    }

    // MARK: - 하단

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.cyan)
                Text("보유 RP \(availableRP) · 변경에 \(costRP) RP")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if availableRP < costRP {
                Text("RP 부족").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            Button("취소") { onCancel() }.font(.system(size: 12))
            Button("적용 · \(costRP) RP") {
                if let value = pendingValue { onCommit(value) }
            }
            .font(.system(size: 12, weight: .semibold))
            .disabled(pendingValue == nil || availableRP < costRP)
        }
    }

    /// 지금 적용될 저장 문자열. 업로드 탭인데 아직 굽지 않았으면 nil(=적용 불가).
    private var pendingValue: String? {
        switch mode {
        case .sample:
            return GuildLogo.encode(sample: selectedSample)
        case .upload:
            guard let png = bakedPNG else { return nil }
            guard png.count <= GuildLogo.maxCustomBytes else { return nil }
            return GuildLogo.encode(customPNG: png)
        }
    }

    // MARK: - 동작

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let img = NSImage(contentsOf: url), img.size.width >= 1, img.size.height >= 1 else {
            loadError = "이미지를 읽지 못했습니다."
            DebugLog.log("guild logo: 이미지 로드 실패 \(url.lastPathComponent)")
            return
        }
        loadError = nil
        source = img
        // 처음엔 3:2로 꽉 차게 — 원본이 3:2보다 세로로 길면 폭 기준, 아니면 높이 기준.
        cropScale = 1.0
        cropCenter = CGPoint(x: 0.5, y: 0.5)
        clampCenter()
        bake()
    }

    /// 크롭 창을 원본 픽셀 좌표로 환산.
    private func cropRectInImage(_ src: NSImage) -> CGRect {
        let iw = src.size.width, ih = src.size.height
        let ratio = CGFloat(GuildLogo.pixelWidth) / CGFloat(GuildLogo.pixelHeight)
        // 폭 기준으로 잡되 높이가 넘치면 높이 기준으로 줄인다 (세로로 긴 원본 대응).
        var w = iw * cropScale
        var h = w / ratio
        if h > ih { h = ih; w = h * ratio }
        let cx = cropCenter.x * iw, cy = cropCenter.y * ih
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 크롭 창이 원본 밖으로 나가지 않도록 중심을 가둔다.
    private func clampCenter() {
        guard let src = source else { return }
        let r = cropRectInImage(src)
        let halfW = r.width / 2 / src.size.width
        let halfH = r.height / 2 / src.size.height
        cropCenter.x = min(max(cropCenter.x, halfW), 1 - halfW)
        cropCenter.y = min(max(cropCenter.y, halfH), 1 - halfH)
    }

    /// 크롭 → 66×44 PNG. 실패하면 미리보기를 비워 적용 버튼이 잠긴다.
    private func bake() {
        guard let src = source else { bakedPNG = nil; return }
        bakedPNG = GuildLogo.pixelate(src, crop: cropRectInImage(src))
        if bakedPNG == nil { DebugLog.log("guild logo: 픽셀화 실패") }
    }

    // MARK: - 표시 헬퍼

    /// 이미지를 컨테이너에 fit 시킨 사각형(화면 좌표).
    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// 원본 좌표계 크롭 창을 화면 좌표로.
    private func cropBoxRect(in fitted: CGRect) -> CGRect {
        guard let src = source else { return fitted }
        let r = cropRectInImage(src)
        let sx = fitted.width / src.size.width, sy = fitted.height / src.size.height
        return CGRect(x: fitted.minX + r.minX * sx, y: fitted.minY + r.minY * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    private func logoThumb(_ img: NSImage, width: CGFloat) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.none)          // 도트 확대는 nearest
            .frame(width: width, height: width * CGFloat(GuildLogo.pixelHeight)
                                              / CGFloat(GuildLogo.pixelWidth))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}

/// 길드 로고 배너 — 표시 전용 공용 뷰. 리더보드 행/오피스 상단/길드 목록이 함께 쓴다.
/// `GuildLogo.image(for:)`가 MainActor 격리 캐시를 읽으므로 뷰도 같은 격리에 둔다.
@MainActor
struct GuildLogoBanner: View {
    let logo: String?
    let guildID: String
    var width: CGFloat

    var body: some View {
        Image(nsImage: GuildLogo.image(for: logo, guildID: guildID))
            .resizable()
            .interpolation(.none)
            .frame(width: width,
                   height: (width * CGFloat(GuildLogo.pixelHeight)
                            / CGFloat(GuildLogo.pixelWidth)).rounded())
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}
