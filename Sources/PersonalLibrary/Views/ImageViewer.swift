import AppKit
import SwiftUI

struct ImageViewerRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
}

private struct OpenImageViewerKey: EnvironmentKey {
    static let defaultValue: (ImageViewerRequest) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Set by the reader so pictures inside Markdown can open the same viewer.
    var openImageViewer: (ImageViewerRequest) -> Void {
        get { self[OpenImageViewerKey.self] }
        set { self[OpenImageViewerKey.self] = newValue }
    }
}

struct ImageViewer: View {
    let url: URL
    let title: String
    var onClose: (() -> Void)? = nil
    var minimumHeight: CGFloat = 420

    @State private var image: NSImage?
    @State private var failure: String?
    @State private var details: ImageDetails?
    @State private var scale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var magnificationStart: CGFloat = 1
    @State private var showInfo = false

    private static let scaleRange: ClosedRange<CGFloat> = 0.25...8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        .background(.background)
        .task(id: url) { load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { zoom(to: scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("缩小").keyboardShortcut("-", modifiers: .command)
                .disabled(image == nil)
            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46)
            Button { zoom(to: scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("放大").keyboardShortcut("=", modifiers: .command)
                .disabled(image == nil)
            Divider().frame(height: 16)
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("适应窗口").keyboardShortcut("0", modifiers: .command)
                .disabled(image == nil)
            Button { rotate(by: -90) } label: { Image(systemName: "rotate.left") }
                .help("向左旋转").disabled(image == nil)
            Button { rotate(by: 90) } label: { Image(systemName: "rotate.right") }
                .help("向右旋转").disabled(image == nil)
            Divider().frame(height: 16)
            Button { showInfo.toggle() } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
            }
            .help("图片信息").disabled(details == nil)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("关闭").keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.45)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .scaleEffect(scale)
                        .rotationEffect(rotation)
                        .offset(offset)
                        .gesture(dragGesture)
                        .gesture(magnification)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .help("双击切换缩放，拖动可平移")
                } else if let failure {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 26))
                        Text(failure).font(.system(size: 12)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(24)
                } else {
                    ProgressView("正在读取图片…").controlSize(.small)
                }
                if showInfo, let details {
                    infoPanel(details)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: proxy.size) { _, _ in clampOffset(in: proxy.size) }
        }
        .frame(minHeight: minimumHeight)
    }

    private func infoPanel(_ details: ImageDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            infoLine("尺寸", details.pixelDescription)
            infoLine("格式", details.format.isEmpty ? "—" : details.format)
            infoLine("大小", details.byteDescription)
            if let captured = details.captureDescription { infoLine("拍摄", captured) }
            if let camera = details.camera { infoLine("设备", camera) }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)) }
        .frame(width: 220, alignment: .leading)
    }

    private func infoLine(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Text(value).font(.system(size: 11).monospacedDigit()).lineLimit(1).truncationMode(.middle)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: dragStart.width + value.translation.width,
                                height: dragStart.height + value.translation.height)
            }
            .onEnded { _ in dragStart = offset }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnificationStart == 1, scale != 1 { magnificationStart = scale }
                zoom(to: magnificationStart * value.magnification, clamp: false)
            }
            .onEnded { _ in magnificationStart = 1; clampScale() }
    }

    private func load() {
        image = nil
        failure = nil
        details = nil
        scale = 1
        rotation = .zero
        offset = .zero
        dragStart = .zero
        guard FileManager.default.fileExists(atPath: url.path) else {
            failure = "文件不在原位置，请恢复备份或重新导入。"
            return
        }
        details = ImageInspection.read(url)
        guard let loaded = NSImage(contentsOf: url) else {
            failure = "这个文件无法作为图片打开。"
            return
        }
        image = loaded
    }

    private func zoom(to value: CGFloat, clamp: Bool = true) {
        scale = clamp ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, value))
                      : max(0.05, value)
        if clamp { clampScale() }
    }

    private func clampScale() {
        scale = min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scale))
        if scale <= 1 { offset = .zero; dragStart = .zero }
    }

    private func clampOffset(in size: CGSize) {
        let limitX = max(0, (size.width * scale - size.width) / 2)
        let limitY = max(0, (size.height * scale - size.height) / 2)
        offset = CGSize(width: min(limitX, max(-limitX, offset.width)),
                        height: min(limitY, max(-limitY, offset.height)))
        dragStart = offset
    }

    private func fit() {
        scale = 1
        offset = .zero
        dragStart = .zero
    }

    private func toggleZoom() {
        if scale > 1 { fit() } else { zoom(to: 2) }
    }

    private func rotate(by degrees: Double) {
        rotation += .degrees(degrees)
        offset = .zero
        dragStart = .zero
    }
}
