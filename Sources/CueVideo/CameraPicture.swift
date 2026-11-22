import SwiftUI
import Combine
import CueATEM

/// Where a camera's live picture comes from: a Canon's own HTTP preview, or, for any other
/// camera, the NDI picture set for its switcher input (the camera's own NDI stream, say).
/// Auto tracking, snapshots and the camera's tile all read whichever one this gives.
enum CameraPicture {
    case canon(PTZCamera)
    case ndi(String)

    static func of(_ c: PTZCamera, _ store: ConfigStore = Booth.shared.store) -> CameraPicture? {
        if c.proto == .canonXC { return c.host.isEmpty ? nil : .canon(c) }
        return store.ndi(c.atemInput).map { .ndi($0) }
    }

    /// Every new frame, on the main thread.
    var frames: AnyPublisher<CGImage, Never> {
        switch self {
        case .canon(let c): return CanonFeedHub.shared.feed(for: c).$image.compactMap { $0 }.eraseToAnyPublisher()
        case .ndi(let n): return NDIFeedHub.shared.feed(n).$image.compactMap { $0 }.eraseToAnyPublisher()
        }
    }

    /// The latest frame, only while the picture is really coming in.
    var liveImage: CGImage? {
        switch self {
        case .canon(let c): let f = CanonFeedHub.shared.feed(for: c); return f.live ? f.image : nil
        case .ndi(let n): let f = NDIFeedHub.shared.feed(n); return f.live ? f.image : nil
        }
    }

    /// Keeps the picture running while something other than a view needs it. Pair with release.
    func retain() {
        switch self {
        case .canon(let c): CanonFeedHub.shared.retain(c)
        case .ndi(let n): NDIFeedHub.shared.retain(n)
        }
    }

    func release() {
        switch self {
        case .canon(let c): CanonFeedHub.shared.release(c)
        case .ndi(let n): NDIFeedHub.shared.release(n)
        }
    }
}

extension PTZController {
    /// The camera on this switcher input that CueVideo has a live picture for.
    func pictured(on input: Int?, _ store: ConfigStore) -> PTZCamera? {
        guard let input else { return nil }
        return cameras.first { $0.atemInput == input && CameraPicture.of($0, store) != nil }
    }
}

/// A camera's live picture, fitted to its frame, whichever way it arrives. While the camera
/// is auto tracking, the person it follows is outlined. With `onPick`, clicking the picture
/// reports where (0 to 1 across and down the picture).
struct CameraVideo: View {
    let camera: PTZCamera
    var onPick: ((CGPoint) -> Void)? = nil
    @ObservedObject private var store = Booth.shared.store

    var body: some View {
        switch CameraPicture.of(camera, store) {
        case .canon: CanonCameraVideo(camera: camera, onPick: onPick)
        case .ndi(let n): NDICameraVideo(camera: camera, source: n, onPick: onPick).id(n)
        case nil: Color.black
        }
    }
}

private struct CanonCameraVideo: View {
    let camera: PTZCamera
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var feed: CanonFeed

    init(camera: PTZCamera, onPick: ((CGPoint) -> Void)?) {
        self.camera = camera
        self.onPick = onPick
        feed = CanonFeedHub.shared.feed(for: camera)
    }

    var body: some View {
        TrackedPicture(camera: camera, image: feed.image, live: feed.live, waiting: "Connecting", onPick: onPick)
            .onAppear { CanonFeedHub.shared.retain(camera) }
            .onDisappear { CanonFeedHub.shared.release(camera) }
    }
}

private struct NDICameraVideo: View {
    let camera: PTZCamera
    let source: String
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var feed: NDIFeed

    init(camera: PTZCamera, source: String, onPick: ((CGPoint) -> Void)?) {
        self.camera = camera
        self.source = source
        self.onPick = onPick
        feed = NDIFeedHub.shared.feed(source)
    }

    var body: some View {
        TrackedPicture(camera: camera, image: feed.image, live: feed.live,
                       waiting: "Waiting for \(NDIMonitor.shortName(source))", onPick: onPick)
            .onAppear { NDIFeedHub.shared.retain(source) }
            .onDisappear { NDIFeedHub.shared.release(source) }
    }
}

/// The picture itself, with the tracking outline and the click-to-pick layer.
private struct TrackedPicture: View {
    let camera: PTZCamera
    let image: CGImage?
    let live: Bool
    let waiting: String
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var tracker = AutoTracker.shared

    var body: some View {
        GeometryReader { g in
            let box = fitted(g.size)
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                // Their head and body, what the camera follows: arms reaching out don't stretch it.
                if let s = tracker.sessions[camera.id], let t = s.target?.core {
                    let r = CGRect(x: box.minX + t.minX * box.width, y: box.minY + t.minY * box.height,
                                   width: t.width * box.width, height: t.height * box.height)
                    let color = s.phase == .following ? T.accent : T.warning
                    RoundedRectangle(cornerRadius: 4).stroke(color, style: StrokeStyle(lineWidth: 2, dash: s.phase == .following ? [] : [5, 4]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .animation(.linear(duration: 0.1), value: t)
                }
                if !live {
                    VStack(spacing: T.s1) {
                        ProgressView().controlSize(.small)
                        Text(image == nil ? waiting : "Picture stopped").font(.sans(11)).foregroundStyle(T.inkMuted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(T.s2)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                guard let onPick, box.width > 0, box.contains(p) else { return }
                onPick(CGPoint(x: (p.x - box.minX) / box.width, y: (p.y - box.minY) / box.height))
            }
            .allowsHitTesting(onPick != nil)
        }
    }

    /// Where the picture sits inside a frame of this size.
    private func fitted(_ size: CGSize) -> CGRect {
        let iw = CGFloat(image?.width ?? 16), ih = CGFloat(image?.height ?? 9)
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
