import Foundation
import Testing
import UnabletonCore
@testable import Unableton

private func dragGeometry(zoom: Double = 24, horizontal: CGFloat = 0, vertical: CGFloat = 0,
                          width: CGFloat = 1_200, height: CGFloat = 600) -> ClipDragGeometry {
    ClipDragGeometry(headerWidth: 212, rulerHeight: 38, rowHeight: 84,
                     viewportWidth: width, viewportHeight: height,
                     horizontalOffset: horizontal, verticalOffset: vertical, zoom: zoom)
}

private func geometrySong() -> Song {
    var song = Song()
    song.tracks = [
        Track(name: "Lead", instrumentID: "synth.lead", clips: [
            Clip(startBeat: 8, lengthBeats: 8, notes: [NoteEvent(pitch: 72)])
        ]),
        Track(name: "Pad", instrumentID: "synth.pad"),
        Track(name: "Bass guitar", instrumentID: "sampled.bass"),
        Track(name: "Audio", kind: .audio)
    ]
    return song
}

struct ClipDragGeometryTests {
    @Test func middleAndRightGrabsKeepTheLeadingEdgeUnderThePreview() throws {
        let geometry = dragGeometry(), song = geometrySong(), clip = song.tracks[0].clips[0]
        for grabX in [0.0, 95, 189] {
            let start = CGPoint(x: 212 + clip.startBeat * 24 + 1 + grabX, y: 80)
            let offset = try #require(geometry.grabOffsetX(for: clip, pointer: start))
            #expect(offset == grabX)
            let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: song.tracks[0].id,
                                                      grabOffsetX: offset, zoom: 24))
            #expect(geometry.target(for: start, context: context, in: song)?.startBeat == 8)
            let moved = CGPoint(x: start.x + 96, y: start.y)
            #expect(geometry.target(for: moved, context: context, in: song)?.startBeat == 12)
        }
    }

    @Test func zoomAndBothScrollOffsetsAreAppliedOnce() throws {
        for zoom in [8.0, 24, 60] {
            var song = geometrySong()
            // Source is the third row, with two rows scrolled out of sight.
            let source = song.tracks.removeFirst()
            song.tracks.insert(source, at: 2)
            song.tracks[2].clips[0].startBeat = 32
            let clip = song.tracks[2].clips[0]
            let geometry = dragGeometry(zoom: zoom, horizontal: 28 * zoom, vertical: 170)
            let grabX = 2 * zoom - 1
            let start = CGPoint(x: 212 + 32 * zoom + 1 + grabX - 28 * zoom, y: 80)
            let offset = try #require(geometry.grabOffsetX(for: clip, pointer: start))
            #expect(offset == grabX)
            let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: source.id,
                                                      grabOffsetX: offset, zoom: zoom))
            let unchanged = try #require(geometry.target(for: start, context: context, in: song))
            #expect(unchanged.trackID == source.id && unchanged.startBeat == 32)
            let moved = CGPoint(x: start.x + 4 * zoom, y: start.y - 85)
            // The pointer's row is above the pinned ruler and cannot accept a drop.
            #expect(geometry.target(for: moved, context: context, in: song) == nil)
            let sameRow = CGPoint(x: start.x + 4 * zoom, y: start.y)
            #expect(geometry.target(for: sameRow, context: context, in: song)?.startBeat == 36)
        }
    }

    @Test func stationaryPointerFollowsContentDuringAutoScroll() throws {
        let song = geometrySong(), clip = song.tracks[0].clips[0]
        let before = dragGeometry(), pointer = CGPoint(x: 500, y: 80)
        let offset = try #require(before.grabOffsetX(for: clip, pointer: pointer))
        let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: song.tracks[0].id,
                                                  grabOffsetX: offset, zoom: 24))
        #expect(before.target(for: pointer, context: context, in: song)?.startBeat == 8)
        let after = dragGeometry(horizontal: 12, vertical: 85)
        let target = try #require(after.target(for: pointer, context: context, in: song))
        #expect(target.startBeat == 8.5 && target.trackID == song.tracks[1].id)
    }

    @Test func targetRowsRejectDividersAndIncompatibleTracks() throws {
        let geometry = dragGeometry(), song = geometrySong(), clip = song.tracks[0].clips[0]
        let pointer = CGPoint(x: 500, y: 80)
        let offset = try #require(geometry.grabOffsetX(for: clip, pointer: pointer))
        let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: song.tracks[0].id,
                                                  grabOffsetX: offset, zoom: 24))
        #expect(geometry.target(for: CGPoint(x: 500, y: 143), context: context, in: song)?.trackID == song.tracks[1].id)
        #expect(geometry.target(for: CGPoint(x: 500, y: 228), context: context, in: song) == nil)
        #expect(geometry.target(for: CGPoint(x: 500, y: 313), context: context, in: song) == nil)
        #expect(geometry.target(for: CGPoint(x: 500, y: 122.5), context: context, in: song) == nil)
        #expect(geometry.target(for: CGPoint(x: 500, y: 123), context: context, in: song)?.trackID == song.tracks[1].id)
        #expect(geometry.target(for: CGPoint(x: 500, y: 500), context: context, in: song) == nil)
    }

    @Test func headerRulerAndOutsidePointersCannotGrabOrDrop() throws {
        let geometry = dragGeometry(), song = geometrySong(), clip = song.tracks[0].clips[0]
        let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: song.tracks[0].id,
                                                  grabOffsetX: 95, zoom: 24))
        for pointer in [CGPoint(x: 211, y: 80), CGPoint(x: 500, y: 37), CGPoint(x: 1_200, y: 80),
                        CGPoint(x: 500, y: 600), CGPoint(x: -1, y: 80), CGPoint(x: 500, y: -1),
                        CGPoint(x: CGFloat.nan, y: 80), CGPoint(x: 500, y: CGFloat.infinity)] {
            #expect(geometry.grabOffsetX(for: clip, pointer: pointer) == nil)
            #expect(geometry.target(for: pointer, context: context, in: song) == nil)
            #expect(geometry.scrollDelta(for: pointer) == .zero)
        }
        #expect(geometry.grabOffsetX(for: clip, pointer: CGPoint(x: 400, y: 80)) == nil)
        #expect(geometry.grabOffsetX(for: clip, pointer: CGPoint(x: 600, y: 80)) == nil)
    }

    @Test func edgeScrollingIsBoundedAndStopsOutsideTheCanvas() {
        let geometry = dragGeometry()
        #expect(geometry.scrollDelta(for: CGPoint(x: 500, y: 300)) == .zero)
        #expect(geometry.scrollDelta(for: CGPoint(x: 224, y: 50)) == CGSize(width: -6, height: -6))
        #expect(geometry.scrollDelta(for: CGPoint(x: 1_188, y: 588)) == CGSize(width: 6, height: 6))
        #expect(geometry.scrollDelta(for: CGPoint(x: 236, y: 62)) == .zero)
        #expect(geometry.scrollDelta(for: CGPoint(x: 212, y: 38)) == CGSize(width: -12, height: -12))
        let nearBottom = geometry.scrollDelta(for: CGPoint(x: 1_199, y: 599))
        #expect(nearBottom.width > 0 && nearBottom.width <= 12 && nearBottom.height > 0 && nearBottom.height <= 12)
        #expect(geometry.scrollDelta(for: CGPoint(x: 1_201, y: 599)) == .zero)
        #expect(geometry.scrollDelta(for: CGPoint(x: 211, y: 39)) == .zero)
    }

    @Test func malformedGeometryProducesNoTargetsOrScrolling() throws {
        let song = geometrySong(), clip = song.tracks[0].clips[0]
        let context = try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: song.tracks[0].id,
                                                  grabOffsetX: 95, zoom: 24))
        for geometry in [dragGeometry(zoom: 0), dragGeometry(zoom: .nan), dragGeometry(horizontal: .infinity),
                         dragGeometry(vertical: .nan), dragGeometry(width: 200), dragGeometry(height: 30)] {
            let point = CGPoint(x: 500, y: 80)
            #expect(geometry.grabOffsetX(for: clip, pointer: point) == nil)
            #expect(geometry.target(for: point, context: context, in: song) == nil)
            #expect(geometry.scrollDelta(for: point) == .zero)
        }
    }
}
