import Foundation
import Combine
import Vision
import CueATEM

/// The three follow shots a broadcast camera operator works with, and how each is framed.
///
/// Framing follows standard broadcast practice:
/// - Eyes sit on or near the upper third line, with modest headroom (more room above the
///   head on wide shots, less on close ones), never the head in the middle of the frame.
/// - Frame edges cut between joints, not at them: a shoulders-up shot ends at mid-chest,
///   a waist-up shot just below the waist, a full-length shot leaves a little room under
///   the feet. Never at the neck, elbows, knees or ankles.
/// - Lead room (looking or walking room): a person facing or moving to one side gets more
///   space on that side, so they aren't walking into the edge of the frame.
/// - The camera doesn't chase every small move. It lets the person move a little inside the
///   frame, eases into and out of each move, and settles rather than hunting.
/// - Shot size stays consistent as people walk nearer or farther, with slow zooms.
///
/// Sizes are measured by the head: the drop from the eyes to the shoulders as a share of the
/// frame height. That stays visible in every shot size, and grows as the shot gets tighter.
enum ShotSize: String, CaseIterable, Identifiable {
    case shoulders, waist, full
    var id: String { rawValue }

    var name: String {
        switch self {
        case .shoulders: return "Shoulders up"
        case .waist: return "Waist up"
        case .full: return "Full length"
        }
    }
    var short: String {
        switch self { case .shoulders: return "Close"; case .waist: return "Waist"; case .full: return "Full" }
    }

    /// The built-in rule for this size. The setup file's "framing" can change any part of it
    /// while CueVideo runs (Setup, the config file, or Claude's set_framing).
    var standard: FramingRule {
        switch self {
        case .shoulders: return FramingRule(eyeLine: 0.29, scale: 0.36, leadRoom: 0.09, deadX: 0.12, deadY: 0.08)
        case .waist: return FramingRule(eyeLine: 0.29, scale: 0.21, leadRoom: 0.11, deadX: 0.13, deadY: 0.08)
        // Less room up and down: the eyes sit near the top, and more would risk the top of their head.
        case .full: return FramingRule(eyeLine: 0.12, scale: 0.097, leadRoom: 0.13, deadX: 0.15, deadY: 0.06)
        }
    }
    /// The rule in use now: the standard with any changes from the setup file.
    var rule: FramingRule { standard.merged(Booth.shared.store.config.framing[rawValue]) }

    /// Where the eyes sit, down from the top of the frame (0 to 1).
    var eyeLine: Double { rule.eyeLine ?? 0.3 }
    /// Eyes to shoulders as a share of frame height, the standard for this size.
    var scale: Double { rule.scale ?? 0.2 }
    /// How far off center a person facing or walking one way sits, giving lead room.
    var leadRoom: Double { rule.leadRoom ?? 0.1 }
    /// How far they can drift across or up and down before the camera moves.
    var deadX: Double { rule.deadX ?? 0.13 }
    var deadY: Double { rule.deadY ?? 0.08 }

    /// The size a framing is closest to, from its head scale and what's in shot.
    static func classify(scale: Double?, anklesInShot: Bool, hipsInShot: Bool) -> ShotSize? {
        if let s = scale {
            if s < 0.145 { return .full }      // between the full and waist standards
            if s < 0.275 { return anklesInShot ? .full : .waist }
            return hipsInShot ? .waist : .shoulders
        }
        if anklesInShot { return .full }
        return hipsInShot ? .waist : nil
    }
}

/// One person found in a frame. Coordinates are normalized with the origin top left.
struct TrackedPerson {
    /// Everything of them in view, arms and legs included (for the outline and their look).
    var box: CGRect
    /// Head and torso only: where they are, however their arms move.
    var core: CGRect
    /// Between the eyes (or the nose, or the ears).
    var eye: CGPoint
    /// The middle of their body, across: between the shoulders and between the hips. Nil when
    /// neither pair shows. Arms never move it, and nor does a nod or a lean of the head.
    var trunkX: CGFloat?
    /// Eyes to shoulders, as a share of frame height. Nil when the body landmarks aren't clear.
    var scale: Double?
    var hipsInShot = false
    var anklesInShot = false
    /// -1 facing left in the picture, 1 facing right, 0 toward the camera or unclear.
    var facing = 0
    /// Shoulder to shoulder against the eyes-to-shoulders drop, both in frame heights. Narrower
    /// than usual for them means the whole body has turned, not just the head.
    var shoulderSpan: Double?
    /// What they look like, for telling people apart. Nil when they're too small to tell.
    var appearance: Appearance?
    /// Found by outline alone, with no landmarks: the eye point is a guess from the outline.
    var outline = false

    var size: ShotSize? { ShotSize.classify(scale: scale, anklesInShot: anklesInShot, hipsInShot: hipsInShot) }
    /// Where the camera aims across: the middle of their body, or their head when that's all there is.
    var aimX: CGFloat { trunkX ?? eye.x }
}

/// Auto tracking: a camera follows one person around the stage.
///
/// It watches the same preview picture the volunteer sees (CameraPicture), finds people and their
/// body landmarks in each frame with Apple's Vision framework, keeps hold of the one it was
/// told to follow, works out whether the shot is shoulders up, waist up or full length, and
/// pans, tilts and (gently) zooms to frame them the way a broadcast operator would (see
/// ShotSize). Any manual move of that camera (joystick, shot, preset, home) ends tracking at
/// once. Zooming by hand keeps tracking going and makes that zoom the size to hold.
final class AutoTracker: ObservableObject {
    static let shared = AutoTracker()

    enum Phase: String { case starting, following, searching, lost }

    struct Session {
        let camera: UUID
        var phase: Phase = .starting
        var target: TrackedPerson?
        /// The shot it's framing to, and the head scale to hold (the standard for the size,
        /// or whatever the volunteer zoomed to).
        var size: ShotSize = .waist
        var holdScale: Double?
        /// What the person asked for; nil means work it out from the shot when tracking starts.
        var asked: ShotSize?
        /// What the picture is right now.
        var seen: ShotSize?
        var pick: CGPoint?
        var people: [TrackedPerson] = []
        /// Smoothed: x is the middle of their body (aimX), y their eyes.
        var eye: CGPoint?
        var scale: Double?         // smoothed
        var lead = 0.0             // smoothed lead-room offset
        var lastSeen = Date()
        var started = Date()
        var lastFrame = Date()
        var manualZoomAt: Date?
        var panning = false, tilting = false, zooming = false
        /// Zoom last sent. Pan and tilt are in `motion`, eased between frames.
        var sentZoom = 0.0

        // Motion, measured. The camera reports its angle of view, so moves are worked out in
        // real angles: how fast the person is really going, and how fast the camera really
        // turns for the speed it was asked (some Canon modes slow panning when zoomed in).
        var fov = 40.0                       // horizontal angle of view now, degrees
        var lastPos: (pan: Double, tilt: Double, at: Date)?
        var gainPan = 1.0, gainTilt = 1.0    // how fast it really turns ÷ how fast it was asked
        var lastEye: (p: CGPoint, at: Date)?
        var imgVX = 0.0, imgVY = 0.0         // the person's motion in the picture, frames a second
        var moveX = 0.0, moveY = 0.0         // their real motion (right and up), frames a second
        var polling = false
        /// Recent measured positions (degrees), for how fast the camera really moved.
        var polls: [(at: Date, pan: Double, tilt: Double)] = []
        /// Zoom hold, kept calm: when the size first looked wrong, and the last zoom's end and direction.
        var zoomWrongSince: Date?
        var zoomEnded = Date.distantPast
        var zoomDir = 0
        /// For the first moments, the size to hold follows the (smoothed) size they're at.
        var holdLearnUntil = Date.distantPast
        /// Walking: the direction they've been clearly moving, and since when.
        /// Walking: how sure we are they're walking each way (-1 to 1; the sign is the direction),
        /// and their steady walking speed in frames a second, held through a moment's dip.
        var walkW = 0.0, walkSpeed = 0.0, walkWY = 0.0, walkSpeedY = 0.0
        /// Their shoulder span squared up to the camera (the widest lately), and which way their
        /// whole body has been turned (-1 left, 1 right, 0 square on) and since when.
        var squareSpan: Double?, turn = 0, turnSince = Date()

        // Who it's following. A few pictures of what they look like (the first `anchors` are
        // kept for good: the ones from the stage scan, or the first sight of them; the rest
        // are the most recent), so the camera stays with them when people cross and waits
        // for them, not the nearest person, after losing sight.
        /// Their name from the stage scan, when following someone by name.
        var person: String?
        var gallery: [Appearance] = []
        var anchors = 1
        var galleryAt = Date.distantPast
        /// How much their own look varies, and how different the people near them look.
        var ownLook: Double?, otherLook: Double?
        /// Since when they've been the only person around (then it's safe to learn their look).
        var aloneSince: Date?
        /// While only their outline shows, the outline last frame, to tell the body moving from arms reaching.
        var outlineRef: CGRect?
    }

    /// Pan and tilt on their way to what tracking last asked for. Each picture sets a new speed
    /// to aim for; twenty times a second the camera's speed eases toward it (see glide), so it
    /// gathers speed and slows down smoothly instead of jumping to each new speed. Kept out of
    /// `sessions`, which the screen watches, since it changes so often.
    struct Motion {
        /// Speeds asked for, in frames a second, right and up.
        var wantX = 0.0, wantY = 0.0
        var urgent = false, panning = false, tilting = false
        /// Speeds now, and how fast they're changing.
        var x = 0.0, y = 0.0, ax = 0.0, ay = 0.0
        /// Pan and tilt last sent, in the camera's units (hundredths of a degree a second).
        var sentPan = 0.0, sentTilt = 0.0
        var sentLog: [(at: Date, pan: Double, tilt: Double)] = []
        var at = Date()
    }

    @Published private(set) var sessions: [UUID: Session] = [:]
    private var motion: [UUID: Motion] = [:]
    private var ticks = 0

    private var feeds: [UUID: AnyCancellable] = [:]
    private var cameras: [UUID: PTZCamera] = [:]
    private var pictures: [UUID: CameraPicture] = [:]
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [(String?) -> Void]] = [:]
    private var timer: Timer?
    // Concurrent, so cameras tracking at once each get their own frames looked at; `busy` keeps
    // one frame per camera in flight.
    private let vision = DispatchQueue(label: "cuevideo.tracker", qos: .userInitiated, attributes: .concurrent)

    private var ptz: PTZController { Booth.shared.ptz }
    private var config: CueConfig { Booth.shared.store.config }

    private init() {}

    /// Hooks the tracker to the camera controls. Called once at launch.
    func attach() {
        ptz.onManualMove = { [weak self] id in self?.stop(id) }
        ptz.onManualZoom = { [weak self] id in self?.manualZoom(id) }
    }

    func isTracking(_ id: UUID) -> Bool { sessions[id] != nil }

    /// Start following someone on a camera. `point` (0 to 1, top left) picks the person
    /// nearest it; without one, the person nearest the middle. `size` frames them as that
    /// shot; without one, as whichever shot the camera is closest to now. `done` gets nil
    /// once someone is found, or the reason no one was.
    /// `person` follows someone labelled in the last stage scan, by name, wherever they are in the shot.
    func start(_ camera: PTZCamera, at point: CGPoint? = nil, size: ShotSize? = nil, person: String? = nil, done: ((String?) -> Void)? = nil) {
        stop(camera.id)
        guard let picture = CameraPicture.of(camera) else {
            done?("Auto tracking needs the camera's picture: a Canon camera, or an NDI picture set for its switcher input in Setup.")
            return
        }
        var s = Session(camera: camera.id)
        if let person {
            guard let cast = StageCast.shared.look(person) else {
                let names = StageCast.shared.names
                done?(names.isEmpty ? "No one has been labelled yet. Run a stage scan first."
                                    : "No one called \(person) in the last stage scan. It has: \(names.joined(separator: ", ")).")
                return
            }
            s.person = cast.name
            s.gallery = Array(cast.looks.prefix(4))
            s.anchors = s.gallery.count
        }
        s.pick = point
        s.asked = size
        if let a = s.asked { s.size = a }
        sessions[camera.id] = s
        cameras[camera.id] = camera
        if let done { waiters[camera.id, default: []].append(done) }
        pictures[camera.id] = picture
        picture.retain()
        motion[camera.id] = Motion()
        feeds[camera.id] = picture.frames.sink { [weak self] img in self?.frame(img, camera.id) }
        if timer == nil {
            // Twenty times a second, in every run loop mode so it keeps going while a slider is dragged.
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Reframe a tracking camera as a different shot size.
    func setSize(_ id: UUID, _ size: ShotSize) {
        guard var s = sessions[id] else { return }
        s.asked = size
        s.size = size
        s.holdScale = size.scale
        s.manualZoomAt = nil
        // A size picked on purpose reframes now, without the usual wait.
        s.zoomWrongSince = .distantPast
        s.zoomEnded = .distantPast
        s.zoomDir = 0
        sessions[id] = s
    }

    func stop(_ id: UUID) {
        guard let s = sessions[id] else { return }
        sessions[id] = nil
        feeds[id] = nil
        busy.remove(id)
        cameras[id] = nil
        pictures.removeValue(forKey: id)?.release()
        if let m = motion.removeValue(forKey: id), m.sentPan != 0 || m.sentTilt != 0 { ptz.trackDrive(pan: 0, tilt: 0, camera: id) }
        if s.sentZoom != 0 { ptz.trackZoom(0, camera: id) }
        finish(id, "Tracking was stopped.")
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stopAll() { for id in sessions.keys { stop(id) } }

    /// The volunteer (or Claude) zoomed: stop holding the old size for a moment, then hold the new one.
    private func manualZoom(_ id: UUID) {
        guard var s = sessions[id] else { return }
        s.manualZoomAt = Date()
        s.zooming = false
        s.sentZoom = 0
        sessions[id] = s
    }

    // MARK: Frames

    private func frame(_ img: CGImage, _ id: UUID) {
        guard sessions[id] != nil, !busy.contains(id) else { return }  // still working on the last frame: skip
        busy.insert(id)
        vision.async { [weak self] in
            let people = Self.detect(img)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy.remove(id)
                self.update(id, people)
            }
        }
    }

    /// People in a frame, with their landmarks where Vision can see them.
    static func detect(_ img: CGImage) -> [TrackedPerson] {
        let pose = VNDetectHumanBodyPoseRequest()
        let rects = VNDetectHumanRectanglesRequest()
        rects.upperBodyOnly = true
        do { try VNImageRequestHandler(cgImage: img).perform([pose, rects]) } catch { return [] }

        var found: [TrackedPerson] = []
        for o in pose.results ?? [] {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            func at(_ j: VNHumanBodyPoseObservation.JointName, _ min: Float = 0.3) -> CGPoint? {
                guard let p = pts[j], p.confidence >= min else { return nil }
                return CGPoint(x: p.location.x, y: 1 - p.location.y)
            }
            func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
                switch (a, b) {
                case let (a?, b?): return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                default: return a ?? b
                }
            }
            let eyes = mid(at(.leftEye), at(.rightEye))
            let ears = mid(at(.leftEar), at(.rightEar))
            guard let eye = eyes ?? at(.nose) ?? ears else { continue }
            let ls = at(.leftShoulder), rs = at(.rightShoulder)
            let shoulders = mid(ls, rs) ?? at(.neck)
            let all = pts.values.filter { $0.confidence >= 0.3 }.map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let maxY = all.map(\.y).max() else { continue }
            // Shot size in one unit (the eyes-to-shoulders drop), measured from the longest span in
            // view, since a small span is only a few pixels on a wide shot: eyes to ankles (about
            // 7.8 times eyes to shoulders on a standing adult), eyes to hips (about 3.7 times;
            // both measured on the stage cameras with Vision's own joints),
            // else eyes to shoulders. Taking the larger of the long spans keeps someone sitting
            // down (whose eyes-to-ankles is shorter) from looking far away.
            let hip = mid(at(.leftHip), at(.rightHip)) ?? at(.root)
            let ankle = mid(at(.leftAnkle), at(.rightAnkle))
            var long: [Double] = []
            if let a = ankle, a.y - eye.y > 0.05 { long.append(Double(a.y - eye.y) / 7.8) }
            if let h = hip, h.y - eye.y > 0.03 { long.append(Double(h.y - eye.y) / 3.7) }
            let short = shoulders.map { Double($0.y - eye.y) }.flatMap { $0 > 0.01 ? $0 : nil }
            let scale: Double? = long.max() ?? short
            // Top of the head is about half the eyes-to-shoulders drop above the eyes.
            let top = eye.y - CGFloat(scale ?? 0.05) * 0.6
            // Head and torso, without the arms or legs: a raised or reaching arm widens the whole
            // body's box but leaves this where it is, so a gesture never reads as moving.
            let trunk = [eye, shoulders, ls, rs, hip, at(.leftHip), at(.rightHip), at(.nose), at(.leftEar), at(.rightEar)].compactMap { $0 }
            let tMinX = trunk.map(\.x).min() ?? eye.x, tMaxX = trunk.map(\.x).max() ?? eye.x
            let tMaxY = trunk.map(\.y).max() ?? eye.y
            // With only the head in view, allow for the shoulders (about the eyes-to-shoulders drop each side).
            let pad = CGFloat(shoulders == nil ? (scale ?? 0.05) : 0)
            let core = CGRect(x: tMinX - pad, y: top, width: max(0.02, tMaxX - tMinX + pad * 2), height: max(0.02, tMaxY - top))
            var p = TrackedPerson(box: CGRect(x: minX, y: top, width: max(0.02, maxX - minX), height: max(0.02, maxY - top)),
                                  core: core, eye: eye, scale: scale)
            // The body's middle, across. Only from a full pair: one shoulder or hip alone sits half a
            // body off the middle, and swapping between one and both made the aim jump.
            let lh = at(.leftHip), rh = at(.rightHip)
            let mids: [CGFloat] = [ls.flatMap { l in rs.map { (l.x + $0.x) / 2 } }, lh.flatMap { l in rh.map { (l.x + $0.x) / 2 } } ?? at(.root)?.x]
                .compactMap { $0 }
            p.trunkX = mids.isEmpty ? at(.neck)?.x : mids.reduce(0, +) / CGFloat(mids.count)
            p.hipsInShot = at(.root) != nil || at(.leftHip) != nil || at(.rightHip) != nil
            p.anklesInShot = at(.leftAnkle) != nil || at(.rightAnkle) != nil
            // Facing: the nose sits off the line between the shoulders on the side they face.
            if let nose = at(.nose), let l = ls, let r = rs {
                let w = abs(l.x - r.x)
                let off = (nose.x - (l.x + r.x) / 2) / max(w, 0.01)
                if w > 0.02, abs(off) > 0.3 { p.facing = off > 0 ? 1 : -1 }
            } else if at(.leftEar) != nil, at(.rightEar) == nil, let n = at(.nose), let e = at(.leftEar) {
                p.facing = n.x > e.x ? 1 : -1  // profile: only one ear shows
            } else if at(.rightEar) != nil, at(.leftEar) == nil, let n = at(.nose), let e = at(.rightEar) {
                p.facing = n.x > e.x ? 1 : -1
            }
            // Frame x is in widths; a 16:9 width is 16/9 heights.
            if let l = ls, let r = rs, let sc = scale, sc > 0.005 { p.shoulderSpan = Double(abs(l.x - r.x)) * 16 / 9 / sc }
            found.append(p)
        }
        // People too small or turned away for landmarks still show as a body: follow them by
        // their outline (no shot size or zoom from these).
        for r in rects.results ?? [] where r.confidence > 0.3 {
            let b = r.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            if found.contains(where: { $0.box.intersects(box) && box.contains($0.eye) }) { continue }
            found.append(TrackedPerson(box: box, core: box, eye: CGPoint(x: box.midX, y: box.minY + box.height * 0.12), scale: nil, outline: true))
        }
        // What each person looks like (the biggest few in the shot), to tell them apart.
        let biggest = found.indices.sorted { found[$0].box.width * found[$0].box.height > found[$1].box.width * found[$1].box.height }
        for i in biggest.prefix(6) { found[i].appearance = Appearance.of(img, box: found[i].box) }
        return found
    }

    private func update(_ id: UUID, _ people: [TrackedPerson]) {
        guard var s = sessions[id] else { return }
        let now = Date()
        s.people = people
        s.lastFrame = now

        if s.target == nil {
            let pick: TrackedPerson?
            if s.person != nil {
                // Someone named in the stage scan: whoever looks like them, wherever they stand.
                pick = IdentityMatch.find(people.map { $0.appearance?.distance(to: s.gallery) }).map { people[$0] }
            } else {
                // First sight: take the person under the click, or nearest it (the middle by default).
                let p = s.pick ?? CGPoint(x: 0.5, y: 0.5)
                pick = people.first { $0.box.contains(p) } ?? people.min { dist($0.core.center, p) < dist($1.core.center, p) }
            }
            if let pick {
                s.target = pick
                s.eye = CGPoint(x: pick.aimX, y: pick.eye.y)
                s.scale = pick.scale
                s.seen = pick.size
                // Frame as asked; otherwise keep the shot the volunteer set up: its size class for
                // headroom and lead room, and its exact size to hold (no zoom at the start).
                s.size = s.asked ?? pick.size ?? .waist
                s.holdScale = s.asked != nil ? s.size.scale : pick.scale
                s.holdLearnUntil = now.addingTimeInterval(1.5)
                s.lastSeen = now
                s.phase = .following
                if s.gallery.isEmpty, let look = pick.appearance { s.gallery = [look]; s.anchors = 1; s.galleryAt = now }
                sessions[id] = s
                finish(id, nil)
                return
            }
            sessions[id] = s
            if now.timeIntervalSince(s.started) > 4 { finish(id, notFound(s)) }
            return
        }

        // Keep hold of the same person: by where they were and by what they look like.
        let last = s.target!
        let gone = now.timeIntervalSince(s.lastSeen)
        let reach = min(0.5, 0.2 + max(last.core.width, last.core.height) * 0.6 + gone * 0.15)
        let candidates = people.map { p in
            IdentityMatch.Candidate(position: dist(p.core.center, last.core.center),
                                    appearance: s.gallery.isEmpty ? nil : p.appearance?.distance(to: s.gallery))
        }
        let choice = IdentityMatch.choose(candidates, reach: reach, gone: gone, model: .init(own: s.ownLook, others: s.otherLook))
        if case let .take(i, sure) = choice {
            var next = people[i]
            // Arms up or across the body can hide the landmarks, leaving only an outline that
            // grows and shifts with the arms. Then move only by what both sides of the outline do
            // together: the whole body moving. One side reaching out is an arm, and moves nothing.
            if next.outline {
                let shift = s.outlineRef.map { Self.bodyShift(from: $0, to: next.box) } ?? .zero
                s.outlineRef = next.box
                let moved = last.core.offsetBy(dx: shift.x, dy: shift.y)
                // Unless it's lost them altogether (the outline is somewhere else): then the outline.
                if moved.intersects(next.box) {
                    next.eye = CGPoint(x: last.eye.x + shift.x, y: last.eye.y + shift.y)
                    next.trunkX = last.aimX + shift.x
                    next.core = moved
                }
            } else { s.outlineRef = nil }
            learn(&s, next, candidates, i, sure: sure, reach: reach, gone: gone, now: now)
            s.target = next
            s.lastSeen = now
            s.phase = .following
            let o = s.eye ?? next.eye
            s.eye = CGPoint(x: o.x + (next.aimX - o.x) * 0.5, y: o.y + (next.eye.y - o.y) * 0.4)
            if let n = next.scale { s.scale = s.scale.map { $0 + (n - $0) * 0.08 } ?? n }
            if let z = next.size { s.seen = z }
            steer(&s, next)
        } else {
            if gone > 0.6 { hold(&s) }
            s.phase = gone > 5 ? .lost : .searching
        }
        sessions[id] = s
    }

    /// Learns what the followed person looks like, only from frames where it's certain who
    /// they are: their look confirmed it, or they've been the only person around for a second.
    /// Two people crossing never teaches it the wrong one.
    private func learn(_ s: inout Session, _ next: TrackedPerson, _ candidates: [IdentityMatch.Candidate], _ i: Int,
                       sure: Bool, reach: Double, gone: Double, now: Date) {
        let alone = candidates.filter { $0.position < reach * 1.5 }.count == 1
        if !alone { s.aloneSince = nil } else if s.aloneSince == nil { s.aloneSince = now }
        let settled = gone < 0.7 && (s.aloneSince.map { now.timeIntervalSince($0) > 1 } ?? false)
        guard sure || settled, let look = next.appearance else { return }
        if let d = candidates[i].appearance { s.ownLook = s.ownLook.map { $0 + (d - $0) * 0.2 } ?? d }
        if sure {
            for (j, c) in candidates.enumerated() where j != i && c.position < reach * 1.5 {
                if let d = c.appearance { s.otherLook = s.otherLook.map { $0 + (d - $0) * 0.2 } ?? d }
            }
        }
        guard now.timeIntervalSince(s.galleryAt) > 0.7 else { return }
        s.galleryAt = now
        if s.gallery.count >= 6, s.gallery.count > s.anchors { s.gallery.remove(at: s.anchors) }
        if s.gallery.count < 6 { s.gallery.append(look) }
    }

    private func notFound(_ s: Session) -> String {
        s.person.map { "Can't see \($0) in the picture." } ?? "No one is in the picture."
    }

    /// Pan, tilt and zoom toward the framing for this shot size.
    private func steer(_ s: inout Session, _ person: TrackedPerson) {
        guard let eye = s.eye else { return }
        let now = Date()

        // After a manual zoom settles, hold whatever size the volunteer chose.
        if let m = s.manualZoomAt {
            if now.timeIntervalSince(m) > 0.8 {
                s.manualZoomAt = nil
                if let sc = s.scale {
                    s.holdScale = sc
                    s.size = ShotSize.classify(scale: sc, anklesInShot: person.anklesInShot, hipsInShot: person.hipsInShot) ?? s.size
                }
            }
        }
        let size = s.size
        if s.asked == nil, now < s.holdLearnUntil, let sc = s.scale { s.holdScale = sc }

        let ey = size.eyeLine - eye.y          // eyes above the line: tilt up
        let k = config.trackSpeed
        let fovX = s.fov, fovY = s.fov * 9 / 16
        let tune = config.trackTuning
        let latency = tune.latency ?? 0.45     // the preview picture (and Vision) run about this far behind

        // How fast they're really moving: their motion in the picture plus the camera's own
        // motion at the time that picture was taken. In frames a second, right and up.
        let dtFrame = min(0.3, max(0.03, s.lastEye.map { now.timeIntervalSince($0.at) } ?? 0.07))
        let here = CGPoint(x: person.aimX, y: person.eye.y)
        if let last = s.lastEye {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0.02, dt < 0.6 {
                let vx = (here.x - last.p.x) / dt, vy = (here.y - last.p.y) / dt
                s.imgVX += (vx - s.imgVX) * 0.35
                s.imgVY += (vy - s.imgVY) * 0.35
            } else { s.imgVX = 0; s.imgVY = 0 }
        }
        s.lastEye = (here, now)
        // How fast the person is really moving (frames a second, right and up): their drift in
        // the picture plus how fast the camera was really turning when that picture was taken,
        // measured from its position reads, never assumed from what it was told.
        let ta = now.addingTimeInterval(-latency + 0.05)
        let before = s.polls.filter { $0.at <= ta }
        var camRX = 0.0, camRY = 0.0
        if before.count >= 2 {
            // Over the last three reads (about half a second), so the camera's own starts and
            // stops don't look like the person moving.
            let a = before[max(0, before.count - 3)], b = before[before.count - 1]
            let dt = b.at.timeIntervalSince(a.at)
            if dt > 0.05, dt < 1 { camRX = (b.pan - a.pan) / dt / fovX; camRY = (b.tilt - a.tilt) / dt / fovY }
        }
        s.moveX += ((s.imgVX + camRX) - s.moveX) * 0.2
        s.moveY += ((camRY - s.imgVY) - s.moveY) * 0.2
        // Which way their whole body is turned: shoulders narrower than usual for them, and the
        // head pointing the same way, held a moment. A head turn alone (looking to one side of
        // the room from a music stand) leaves the shoulders square, so it doesn't count.
        if let span = person.shoulderSpan {
            // The widest lately, slowly forgotten (about halving in ten seconds) as zoom and pose drift.
            s.squareSpan = max(span, (s.squareSpan ?? span) * 0.995)
        }
        let turnNow = Self.bodyTurn(facing: person.facing, span: person.shoulderSpan, square: s.squareSpan)
        if turnNow != s.turn { s.turn = turnNow; s.turnSince = now }
        let bodyDir = now.timeIntervalSince(s.turnSince) > 0.3 ? s.turn : 0

        // Walking, as a steady speed the camera keeps up, not an on-off switch. Clear movement
        // one way builds up the sureness that they're walking (fully sure in half a second, or a
        // quarter the way their body is turned); anything else lets it fade over 0.6 s. The camera
        // is given their walking speed, smoothed and held through a moment's dip, in proportion
        // to that sureness. An on-off switch here sent the camera fast, then slow, then fast
        // again, as their measured speed wobbled either side of the line.
        func walking(_ v: Double, _ w: inout Double, _ speed: inout Double, _ min: Double, toward: Int) -> Double {
            let d = v > min ? 1 : (v < -min ? -1 : 0)
            w = Self.walkWeight(w, moving: d, dt: dtFrame, rise: Self.walkConfirm(direction: d, bodyTurn: toward))
            if w == 0 { speed = 0; return 0 }
            if d != 0, (d > 0) == (w > 0) { speed += (v - speed) * 0.15 }
            guard (speed > 0) == (w > 0) else { return 0 }
            let a = abs(w)
            return speed * a * a * (3 - 2 * a)   // eased in and out
        }
        let walkMin = tune.walkThreshold ?? 0.12
        let walkVX = walking(s.moveX, &s.walkW, &s.walkSpeed, walkMin, toward: bodyDir)
        let walkVY = walking(s.moveY, &s.walkWY, &s.walkSpeedY, walkMin * 1.25, toward: 0)
        let walkingX = abs(s.walkW) > 0.3, walkingY = abs(s.walkWY) > 0.3
        let relX = s.imgVX, relY = -s.imgVY

        // Lead room: only when they're really walking does the full lead go ahead of them.
        // Never from which way the camera is panning: that fed on itself, the lead pushing the
        // camera on, the move reading as a walk, and the shot swinging past someone standing
        // still. Standing, which way they face (turning to each side of the room) only nudges it.
        // Eased so the frame doesn't jump when they turn.
        s.lead += (Self.leadTarget(walkVX: abs(s.walkW) > 0.5 ? walkVX : 0, facing: bodyDir, leadRoom: size.leadRoom) - s.lead) * 0.06
        let ex = eye.x - (0.5 + s.lead)        // right of the mark: pan right

        // Edge alarm: how close their body is to the side of the frame they're heading for,
        // 0 (comfortable) to 1 (touching it). Near the edge the camera corrects harder.
        // Their head and torso's edge (never an arm: gestures don't move the camera), or on a
        // tight shot (torso wider than half the frame) their head.
        let box = person.core
        let urgency = Self.edgeUrgency(core: box, eyeX: eye.x, right: ex > 0)

        // A still zone around the mark (see shouldMove): the camera only moves once they leave it.
        // The camera outrunning them: they slide back in the picture, against their walk (the
        // picture's y runs down, their walk's up).
        let outrunX = s.walkW * s.imgVX < 0 && abs(s.imgVX) > walkMin
        let outrunY = s.walkWY * s.imgVY > 0 && abs(s.imgVY) > walkMin * 1.25
        s.panning = Self.shouldMove(s.panning, off: ex, zone: size.deadX, walking: walkingX, outrunning: outrunX, edge: urgency)
        s.tilting = config.trackTilt
            && Self.shouldMove(s.tilting, off: ey, zone: size.deadY, walking: walkingY, outrunning: outrunY, edge: 0)
        _ = (relX, relY)

        // The camera speed to aim for, in frames a second: their own speed, plus a gentle pull
        // toward the mark (stronger near the edge). Tested in simulation against a camera that
        // turns faster or slower than expected and a picture delay of 0.3 to 0.65 s: it keeps
        // up with walking and settles without hunting. The camera doesn't jump to it: the motion
        // loop eases into it (see glide), so it gathers speed and slows down smoothly.
        func rate(_ e: Double, _ move: Double, _ on: Bool) -> Double {
            let kp = min(2.5, min(1.6, (tune.correction ?? 1.2) * k) * (1 + 1.5 * urgency))
            return on ? move + kp * e : 0
        }
        let rx = rate(ex, walkVX, s.panning)
        let ry = rate(ey, walkVY, s.tilting)
        let camX = camRX
        var m = motion[s.camera] ?? Motion()
        m.wantX = rx; m.wantY = ry
        m.urgent = urgency > 0.3
        m.panning = s.panning; m.tilting = s.tilting
        motion[s.camera] = m
        let pan = m.sentPan, tilt = m.sentTilt
        TrackLog.shared.write(String(format: "%.3f,%@,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.0f,%.0f,%.2f,%d,%.3f,%.3f,%d,%.2f,%.2f",
            now.timeIntervalSince1970, cameras[s.camera]?.name ?? "?", eye.x, ex, ey, s.imgVX, s.moveX, camX, rx,
            s.fov, s.gainPan, pan, tilt, urgency, s.panning ? 1 : 0, box.minX, box.maxX,
            bodyDir, person.shoulderSpan.flatMap { sp in s.squareSpan.map { sp / max($0, 0.001) } } ?? -1, s.walkW))

        // Hold the shot size as they come nearer or move away, calmly: only when the size has
        // been clearly wrong (over about a third) for 1.5 s, slowly, with a rest of 2 s after
        // each zoom and no reversing within 5 s, so turning, bending or nodding never sets it
        // hunting in and out.
        var zoom = 0.0
        if config.trackZoom, s.manualZoomAt == nil, let hold = s.holdScale, let sc = s.scale, person.scale != nil {
            let r = log(hold / sc)             // positive: they look too small, zoom in
            let dir = r > 0 ? 1 : -1
            if s.zooming {
                if abs(r) < 0.08 || (dir != s.zoomDir) {
                    s.zooming = false; s.zoomEnded = now; s.zoomWrongSince = nil
                }
            } else if abs(r) > (tune.zoomThreshold ?? 0.3) {
                if s.zoomWrongSince == nil { s.zoomWrongSince = now }
                let settled = now.timeIntervalSince(s.zoomEnded) > 2
                let reversing = dir != s.zoomDir && now.timeIntervalSince(s.zoomEnded) < 5
                if now.timeIntervalSince(s.zoomWrongSince!) > (tune.zoomWait ?? 1.5), settled, !reversing {
                    s.zooming = true; s.zoomDir = dir
                }
            } else {
                s.zoomWrongSince = nil
            }
            if s.zooming {
                let v = min(0.45, max(0.04, abs(r) * 0.3))  // faster when far off, gentle near the size
                zoom = ((r > 0 ? v : -v) * 50).rounded() / 50
            }
        } else if s.zooming {
            s.zooming = false; s.zoomEnded = now
        }
        sendZoom(&s, zoom)
    }

    /// Where the lead room puts the mark, off the middle (negative: left of it, leaving room on
    /// the right). The full lead ahead of someone walking; a little toward where someone
    /// standing faces.
    static func leadTarget(walkVX: Double, facing: Int, leadRoom: Double) -> Double {
        if walkVX != 0 { return walkVX > 0 ? -leadRoom : leadRoom }
        return Double(-facing) * leadRoom * 0.35
    }

    /// Whether the camera should be panning (or tilting). Someone `off` the mark by less than
    /// `zone` (a share of the frame) is left alone, even if they seem to be moving: the camera's
    /// own moves can look like walking, and letting that start it set the shot swinging back and
    /// forth around someone standing still. Leaving the zone, or nearing the edge, starts it. Then
    /// it follows a walk, and settles once they're back near the mark and not walking, or the
    /// camera is outrunning them (which is how a walk that wasn't really one shows).
    static func shouldMove(_ on: Bool, off e: Double, zone: Double, walking: Bool, outrunning: Bool, edge: Double) -> Bool {
        if abs(e) > zone || edge > 0 { return true }
        guard on else { return false }
        return !(abs(e) < zone * 0.5 && (!walking || outrunning))
    }

    /// Which way someone's whole body is turned: their head's way, when their shoulders show
    /// under 70% of their squared-up width. 0 when square on or unclear.
    static func bodyTurn(facing: Int, span: Double?, square: Double?) -> Int {
        guard facing != 0, let span, let square, square > 0 else { return 0 }
        return span < square * 0.7 ? facing : 0
    }

    /// How sure we are someone is walking, -1 to 1 (the sign is the direction), after one
    /// frame: clear movement one way (`moving`) builds it to full in `rise` seconds; no clear
    /// movement, or movement the other way, lets it fade to nothing over `fall` seconds first.
    static func walkWeight(_ w: Double, moving: Int, dt: Double, rise: Double, fall: Double = 0.6) -> Double {
        let dir = w > 0 ? 1 : (w < 0 ? -1 : 0)
        if moving != 0, dir == 0 || dir == moving { return max(-1, min(1, w + Double(moving) * dt / rise)) }
        let faded = w - Double(dir) * dt / fall
        return dir > 0 ? max(0, faded) : min(0, faded)
    }

    /// One step of the camera's speed `v` (frames a second) toward `want`, the way an operator
    /// moves a fluid head: the push builds up gradually, so the camera gathers speed and then
    /// eases into the new speed, and it lets off the same way as it arrives. `a` is how fast the
    /// speed is changing now. `ramp` is about how long, in seconds, a change of speed takes.
    /// Slowing down goes a little quicker than speeding up, so it doesn't coast past someone
    /// stopping; near the edge of frame (`urgent`) it may push twice as hard.
    static func glide(_ v: inout Double, _ a: inout Double, toward want: Double, dt: Double, ramp: Double,
                      speed k: Double, urgent: Bool) {
        let r = max(0.15, ramp)
        let slowing = abs(want) < abs(v) || want * v < 0
        let f = (slowing ? 1.6 : 1.0) * (urgent ? 2.0 : 1.0)
        let tau = r / 3 / f                          // eases the last of the way in, without overshooting
        let maxA = 1.2 / r * max(1, k) * f           // the hardest push, frames a second each second
        let maxJerk = 2.5 / (r * r) * f                // how quickly the push itself can build or let off
        let wantA = max(-maxA, min(maxA, (want - v) / tau))
        a += max(-maxJerk * dt, min(maxJerk * dt, wantA - a))
        let next = v + a * dt
        if (want - v) * (want - next) < 0 { v = want; a = 0 } else { v = next }
    }

    /// A speed for the camera, in its units (hundredths of a degree a second; 20 is its
    /// slowest). Settled, anything under 15 is no move, so it doesn't twitch. Correcting (they're
    /// outside the dead zone), anything that isn't nothing is at least the slowest speed: zoomed
    /// in tight, a correction can work out under 15, and rounding it to nothing left the camera
    /// never fixing it (a head held against the top of the frame, the tilt never moving).
    static func cameraSpeed(raw: Double, correcting: Bool) -> Double {
        if abs(raw) < (correcting ? 1 : 15) { return 0 }
        return (min(10000, max(20, abs(raw))) / 10).rounded() * 10 * (raw < 0 ? -1 : 1)
    }

    /// Seconds of steady movement before it counts as a walk: sooner the way they're turned.
    static func walkConfirm(direction: Int, bodyTurn: Int) -> Double {
        direction != 0 && direction == bodyTurn ? 0.25 : 0.5
    }

    /// How close someone is to the side of the frame they're heading for: 0 comfortable, 1 touching.
    static func edgeUrgency(core: CGRect, eyeX: CGFloat, right: Bool) -> Double {
        let gap = core.width < 0.5 ? (right ? 1 - core.maxX : core.minX)
                                   : (right ? 1 - eyeX : eyeX) - 0.1
        return min(1, max(0, (0.2 - Double(gap)) / 0.2))
    }

    /// How far someone seen only by their outline really moved between two outlines: what both
    /// sides did together. Walking moves both sides one way; an arm reaching out or going up moves
    /// one side only, and that's no move at all. Walking while reaching counts the smaller.
    static func bodyShift(from a: CGRect, to b: CGRect) -> CGPoint {
        func together(_ d1: CGFloat, _ d2: CGFloat) -> CGFloat { d1 * d2 <= 0 ? 0 : (abs(d1) < abs(d2) ? d1 : d2) }
        return CGPoint(x: together(b.minX - a.minX, b.maxX - a.maxX), y: together(b.minY - a.minY, b.maxY - a.maxY))
    }

    /// Brings the camera to a stop (quickly, but still eased) and stops any zoom.
    private func hold(_ s: inout Session) {
        s.panning = false; s.tilting = false; s.zooming = false
        if var m = motion[s.camera] {
            m.wantX = 0; m.wantY = 0; m.urgent = true; m.panning = false; m.tilting = false
            motion[s.camera] = m
        }
        sendZoom(&s, 0)
    }

    private func sendZoom(_ s: inout Session, _ zoom: Double) {
        if zoom != s.sentZoom {
            s.sentZoom = zoom
            ptz.trackZoom(zoom, camera: s.camera)
        }
    }

    /// Eases each tracking camera's pan and tilt toward what it was last asked for, and sends
    /// the speed when it changes.
    private func glideAll() {
        let now = Date()
        let ramp = config.trackTuning.ramp ?? 0.7, k = config.trackSpeed
        for (id, var m) in motion {
            guard let s = sessions[id] else { continue }
            let dt = min(0.1, max(0.01, now.timeIntervalSince(m.at)))
            m.at = now
            Self.glide(&m.x, &m.ax, toward: m.wantX, dt: dt, ramp: ramp, speed: k, urgent: m.urgent)
            Self.glide(&m.y, &m.ay, toward: m.wantY, dt: dt, ramp: ramp, speed: k, urgent: m.urgent)
            // Into the camera's units: degrees a second (× 100), allowing for how it really turns.
            let pan = Self.cameraSpeed(raw: m.x * s.fov * 100 / max(0.05, s.gainPan), correcting: m.panning)
            let tilt = Self.cameraSpeed(raw: m.y * s.fov * 9 / 16 * 100 / max(0.05, s.gainTilt), correcting: m.tilting)
            if pan != m.sentPan || tilt != m.sentTilt {
                m.sentPan = pan; m.sentTilt = tilt
                m.sentLog.append((now, pan, tilt))
                if m.sentLog.count > 120 { m.sentLog.removeFirst(m.sentLog.count - 120) }
                ptz.trackDriveRaw(pan: Int(pan), tilt: Int(tilt), camera: id)
            }
            motion[id] = m
        }
    }

    /// Twenty times a second: the camera's motion. Four times a second: where the cameras
    /// really are, and stopping a camera whose picture has stopped coming in, so it never
    /// drifts on old frames.
    private func tick() {
        glideAll()
        ticks += 1
        guard ticks % 5 == 0 else { return }
        let now = Date()
        for id in sessions.keys { poll(id) }
        for (id, var s) in sessions where now.timeIntervalSince(s.lastFrame) > 0.6 {
            let m = motion[id]
            guard s.sentZoom != 0 || (m.map { $0.wantX != 0 || $0.wantY != 0 } ?? false) else { continue }
            hold(&s)
            s.phase = .searching
            sessions[id] = s
        }
        for (id, s) in sessions where s.target == nil && now.timeIntervalSince(s.started) > 4 {
            finish(id, s.person.map { "Can't see \($0) in the picture, or the picture isn't coming in." } ?? "No one is in the picture, or the picture isn't coming in.")
        }
    }

    /// Reads where the camera really is: its angle of view, and how fast it's really turning
    /// compared with the speed it was asked for.
    private func poll(_ id: UUID) {
        guard var s = sessions[id], !s.polling else { return }
        s.polling = true
        sessions[id] = s
        ptz.readPosition(camera: id) { [weak self] pos in
            guard let self, var s = self.sessions[id] else { return }
            s.polling = false
            if let pos {
                let now = Date()
                if pos.zoom > 50 { s.fov = Double(pos.zoom) / 100 }
                let pan = Double(pos.pan) / 100, tilt = Double(pos.tilt) / 100
                if let last = s.lastPos {
                    let dt = now.timeIntervalSince(last.at)
                    // Learn only from a steady speed held long enough for the camera to reach it.
                    if dt > 0.1 {
                        // Degrees it was asked to turn over that time (the camera reacts about
                        // 0.15 s late), against how far it really turned. Learn only from
                        // clear moves in one direction.
                        func asked(_ axis: (Double, Double) -> Double) -> Double {
                            let from = last.at.addingTimeInterval(-0.15), to = now.addingTimeInterval(-0.15)
                            var total = 0.0
                            let log = self.motion[id]?.sentLog ?? []
                            for (i, e) in log.enumerated() {
                                let start = max(from, e.at)
                                let end = min(to, i + 1 < log.count ? log[i + 1].at : to)
                                if end > start { total += axis(e.pan, e.tilt) / 100 * end.timeIntervalSince(start) }
                            }
                            return total
                        }
                        func learn(_ g: inout Double, _ moved: Double, _ want: Double) {
                            guard abs(want) > 0.3, moved * want > 0 else { return }
                            let seen = abs(moved) / abs(want)
                            if seen.isFinite { g += (min(1.5, max(0.05, seen)) - g) * 0.35 }
                        }
                        learn(&s.gainPan, pan - last.pan, asked { p, _ in p })
                        learn(&s.gainTilt, tilt - last.tilt, asked { _, t in t })
                    }
                }
                s.lastPos = (pan, tilt, now)
                s.polls.append((now, pan, tilt))
                if s.polls.count > 16 { s.polls.removeFirst(s.polls.count - 16) }
            }
            self.sessions[id] = s
        }
    }

    private func finish(_ id: UUID, _ why: String?) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        for f in w { f(why) }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// A frame-by-frame record of what tracking saw and did, for tuning:
/// ~/Library/Logs/CueVideo/tracking.csv (the last few minutes of tracking).
final class TrackLog {
    static let shared = TrackLog()
    private let url: URL
    private var handle: FileHandle?
    private var lines = 0

    init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/CueVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tracking.csv")
    }

    func write(_ line: String) {
        if handle == nil || lines > 20000 {
            try? handle?.close()
            let head = "time,camera,eye_x,err_x,err_y,picture_vx,person_vx,camera_vx_then,want_vx,fov_deg,pan_gain,pan_sent,tilt_sent,edge_urgency,panning,box_min_x,box_max_x,body_turn,shoulder_share,walk_sure\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(head.utf8))
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            lines = 0
        }
        handle?.write(Data((line + "\n").utf8))
        lines += 1
    }
}
