import SwiftUI
import UnabletonCore

struct TimelineView: View {
    @ObservedObject var session: ProjectSession
    let titlebarInset: CGFloat
    @FocusState private var focused: Bool
    @State private var horizontalOffset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 800
    @State private var viewportHeight: CGFloat = 400
    @State private var scrollPosition = ScrollPosition()
    @State private var clipDrag: ClipDragContext?
    @State private var clipDrop: ClipDropTarget?
    @GestureState private var clipDragActive = false
    @State private var clipDragSuppressed = false
    @State private var clipDragToken = 0
    @State private var clipDragPointer: CGPoint?
    @State private var clipScrollTask: Task<Void, Never>?
    private let headerWidth: CGFloat = 212
    private let rulerHeight: CGFloat = 38
    private let rowHeight: CGFloat = 84
    private var beats: Double { max(64, max(session.file.song.lengthBeats + 8, session.audio.isTranscribingCapture ? session.audio.currentBeat + 8 : 0)) }
    private var laneWidth: CGFloat { CGFloat(beats * session.zoom) }
    var body: some View {
        VStack(spacing: 0) {
            // One scroller keeps rows aligned and both native scrollbars
            // available. The pinned column follows this same vertical offset.
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: headerWidth).accessibilityHidden(true)
                    if session.file.song.tracks.isEmpty {
                        emptyState.frame(width: max(0, viewportWidth - headerWidth), height: viewportHeight)
                    } else {
                        clipLanes.mask {
                            Path(CGRect(x: horizontalOffset - headerWidth, y: verticalOffset + rulerHeight,
                                        width: viewportWidth, height: max(0, viewportHeight - rulerHeight)))
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !session.file.song.tracks.isEmpty {
                        // Cancel only vertical scrolling. Keeping the ruler in
                        // this scroller preserves horizontal alignment and wheel input.
                        pinnedRuler.offset(x: headerWidth, y: verticalOffset)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Keep the column inside the native scroller's responder
                    // chain so scrolling over track names moves both axes.
                    TrackListView(session: session, width: headerWidth, rowHeight: rowHeight, rulerHeight: rulerHeight,
                                  viewportHeight: viewportHeight, verticalOffset: verticalOffset, titlebarInset: titlebarInset)
                        .offset(x: horizontalOffset)
                }
            }
            // The sidebar material reaches the titlebar. Clip lanes and
            // row foregrounds explicitly, rather than clipping that glass.
            .scrollClipDisabled()
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .scrollPosition($scrollPosition)
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                viewportWidth = $0.width
                viewportHeight = $0.height
                updateClipDrop()
            }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(x: geometry.contentOffset.x + geometry.contentInsets.leading,
                        y: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                horizontalOffset = offset.x
                verticalOffset = offset.y
                updateClipDrop()
            }
            .task(id: session.arrangementReveal?.id) {
                guard let request = session.arrangementReveal else { return }
                // Let newly inserted lanes lay out before applying both
                // coordinates to the same scrolling surface.
                await Task.yield()
                guard !Task.isCancelled, session.arrangementReveal?.id == request.id else { return }
                reveal(request)
            }
            .onChange(of: session.audio.currentBeat) { _, beat in
                guard session.transcription.followPlayhead,
                      session.audio.isTranscribingCapture || session.transcription.rehearsing else { return }
                let x = headerWidth + CGFloat(beat * session.zoom)
                if x > horizontalOffset + viewportWidth - 24 || x < horizontalOffset + headerWidth {
                    scrollPosition.scrollTo(x: max(0, CGFloat(beat * session.zoom) - (viewportWidth - headerWidth) * 0.35))
                }
            }
        }
        .background(.background, ignoresSafeAreaEdges: [])
        .background {
            ArrangementBackdropView(tracks: session.file.song.tracks, selection: session.selection,
                                    zoom: session.zoom, horizontalOffset: horizontalOffset, verticalOffset: verticalOffset,
                                    headerWidth: headerWidth, rulerHeight: rulerHeight, rowHeight: rowHeight)
                .backgroundExtensionEffect()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusable().focused($focused).focusEffectDisabled()
        .coordinateSpace(name: "arrangementViewport")
        .onKeyPress(.space) {
            guard focused else { return .ignored }
            session.togglePlayback(); return .handled
        }
        .onKeyPress(.delete) {
            guard session.canEditMusic else { return .ignored }
            session.deleteSelection(); return .handled
        }
        .onKeyPress(.escape) {
            guard clipDragActive || clipDrag != nil else { return .ignored }
            cancelClipDrag(); return .handled
        }
        .onTapGesture { focused = true }
        .onChange(of: session.mode) { _, _ in cancelClipDrag() }
        .onChange(of: session.file.song.revision) { _, _ in cancelClipDrag() }
        .onChange(of: session.zoom) { _, _ in updateClipDrop() }
        .onChange(of: clipDragActive) { _, active in
            guard !active else { return }
            clipScrollTask?.cancel(); clipScrollTask = nil
            let token = clipDragToken
            Task { @MainActor in
                // GestureState can reset before onEnded consumes the context.
                await Task.yield()
                if !clipDragActive, clipDragToken == token { finishClipDrag() }
            }
        }
        .onDisappear { finishClipDrag() }
        .accessibilityElement(children: .contain).accessibilityLabel("Arrangement")
        .overlay(alignment: .bottomTrailing) {
            if !session.file.song.tracks.isEmpty {
                // Keep navigation controls outside the canvas's keyboard and
                // tap handlers so the slider can retain its own focus.
                ArrangementZoomView(zoom: $session.zoom)
                    .padding(.trailing, 16).padding(.bottom, 20)
            }
        }
    }
    private func reveal(_ request: ArrangementRevealRequest) {
        guard request.beat.isFinite, request.beat >= 0,
              let index = session.file.song.tracks.firstIndex(where: { $0.id == request.trackID }) else { return }
        let visibleLaneWidth = max(0, viewportWidth - headerWidth)
        scrollPosition.scrollTo(
            x: max(0, CGFloat(request.beat * session.zoom) - visibleLaneWidth * 0.15),
            y: max(0, CGFloat(index) * (rowHeight + 1))
        )
    }
    private var clipLanes: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight).accessibilityHidden(true)
            ForEach(session.file.song.tracks) { track in
                lane(track).frame(height: rowHeight)
                Divider().frame(height: 1)
            }
            grid.frame(height: 120)
        }
        .frame(width: laneWidth)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Color.accentColor).frame(width: 1.5)
                .offset(x: CGFloat(session.audio.currentBeat * session.zoom))
                .allowsHitTesting(false)
        }
    }
    private var rulerViewport: Path {
        Path(CGRect(x: horizontalOffset, y: 0,
                    width: max(0, viewportWidth - headerWidth), height: rulerHeight))
    }
    private var pinnedRuler: some View {
        ruler
            .frame(width: laneWidth, height: rulerHeight)
            .background(.background, ignoresSafeAreaEdges: [])
            .overlay(alignment: .topLeading) {
                Rectangle().fill(Color.accentColor).frame(width: 1.5)
                    .offset(x: CGFloat(session.audio.currentBeat * session.zoom))
                    .allowsHitTesting(false)
            }
            .mask { rulerViewport }
            .contentShape(rulerViewport)
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Start with an idea").font(.title2)
            Text(session.canEditMusic ? "Describe the music in the chat, or add a track to start editing." : "Describe your music in the chat, record audio, or turn a performance into music with Transcribe.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack { emptyActions }
                VStack { emptyActions }
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    @ViewBuilder private var emptyActions: some View {
        if session.canEditMusic {
            Button("Add Instrument Track") { session.addInstrumentTrack() }
        } else {
            Button(session.audio.isRecording ? "Stop Recording" : "Record Audio") { session.toggleRecording() }
            Button("Transcribe…") { session.showTranscription() }
        }
        Button("Import Audio…") { session.importAudio() }
    }
    private var ruler: some View {
        Canvas { context, size in
            for bar in 0...Int(beats / 4) {
                let x = Double(bar * 4) * session.zoom
                context.draw(Text("\(bar + 1)").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: x + 5, y: rulerHeight / 2 + 4), anchor: .leading)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { session.audio.seek(to: max(0, $0.location.x / session.zoom)) })
        .accessibilityLabel("Timeline ruler. Use the transport to play and seek.")
    }
    private var grid: some View {
        Canvas { context, size in
            for beat in 0...Int(beats) {
                let x = Double(beat) * session.zoom
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.primary.opacity(beat % 4 == 0 ? 0.12 : 0.045)), lineWidth: 0.5)
            }
        }
    }
    @ViewBuilder private func lane(_ track: Track) -> some View {
        if session.canEditMusic {
            laneContents(track)
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    guard session.canEditMusic else { return }
                    session.select(track: track.id)
                    if track.kind == .instrument { session.addNoteClip(at: floor(value.location.x / session.zoom / 4) * 4, trackID: track.id) }
                })
        } else {
            laneContents(track)
        }
    }
    private func laneContents(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            if session.selection.trackID == track.id { Rectangle().fill(.selection.opacity(0.08)) }
            grid
            ForEach(track.clips) { clip in
                clipBlock(track: track, clip: clip)
                    .frame(width: max(12, clip.lengthBeats * session.zoom - 2), height: rowHeight - 12)
                    .opacity(clipDrag?.clipID == clip.id ? 0.3 : 1)
                    .offset(x: clip.startBeat * session.zoom + 1, y: 6)
            }
            if let target = clipDrop, target.trackID == track.id,
               let source = session.file.song.clip(target.clipID) {
                ClipBlockView(session: session, track: track, clip: source)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) }
                    .frame(width: max(12, target.lengthBeats * session.zoom - 2), height: rowHeight - 12)
                    .offset(x: target.startBeat * session.zoom + 1, y: 6)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.select(track: track.id) }
    }
    @ViewBuilder private func clipBlock(track: Track, clip: Clip) -> some View {
        if session.canEditMusic {
            ClipBlockView(session: session, track: track, clip: clip)
                .highPriorityGesture(clipMoveGesture(track: track, clip: clip).exclusively(before:
                    TapGesture().onEnded { session.select(track: track.id, clip: clip.id) }
                ))
        } else {
            ClipBlockView(session: session, track: track, clip: clip)
        }
    }
    private var dragGeometry: ClipDragGeometry {
        ClipDragGeometry(headerWidth: headerWidth, rulerHeight: rulerHeight, rowHeight: rowHeight,
                         viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                         horizontalOffset: horizontalOffset, verticalOffset: verticalOffset, zoom: session.zoom)
    }
    private func clipMoveGesture(track: Track, clip: Clip) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("arrangementViewport"))
            .updating($clipDragActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !clipDragSuppressed else { return }
                guard session.canEditMusic else { cancelClipDrag(); return }
                if clipDrag == nil {
                    guard let offset = dragGeometry.grabOffsetX(for: clip, pointer: value.startLocation),
                          let context = ClipDragContext(song: session.file.song, clipID: clip.id,
                                                        sourceTrackID: track.id, grabOffsetX: offset, zoom: session.zoom) else {
                        clipDragSuppressed = true; return
                    }
                    clipDragToken += 1; clipDrag = context
                    focused = true
                    startClipScrolling()
                }
                clipDragPointer = value.location
                updateClipDrop()
            }
            .onEnded { value in
                defer { finishClipDrag() }
                clipScrollTask?.cancel(); clipScrollTask = nil
                guard !clipDragSuppressed, session.canEditMusic, let context = clipDrag,
                      let target = dragGeometry.target(for: value.location, context: context, in: session.file.song) else { return }
                session.moveClipFromDrag(context, to: target.trackID,
                                         dropX: value.location.x - headerWidth + horizontalOffset, zoom: session.zoom)
            }
    }
    private func updateClipDrop() {
        guard !clipDragSuppressed, session.canEditMusic, let context = clipDrag, let pointer = clipDragPointer else {
            clipDrop = nil; return
        }
        clipDrop = dragGeometry.target(for: pointer, context: context, in: session.file.song)
    }
    private func startClipScrolling() {
        guard clipScrollTask == nil else { return }
        clipScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard !Task.isCancelled, clipDrag != nil, !clipDragSuppressed,
                      session.canEditMusic, let pointer = clipDragPointer else { return }
                let delta = dragGeometry.scrollDelta(for: pointer)
                let x = min(max(0, headerWidth + laneWidth - viewportWidth), max(0, horizontalOffset + delta.width))
                let contentHeight = rulerHeight + CGFloat(session.file.song.tracks.count) * (rowHeight + 1) + 120
                let y = min(max(0, contentHeight - viewportHeight), max(0, verticalOffset + delta.height))
                if x != horizontalOffset || y != verticalOffset { scrollPosition.scrollTo(x: x, y: y) }
            }
        }
    }
    private func cancelClipDrag() {
        if clipDragActive || clipDrag != nil { clipDragSuppressed = true }
        clipDrag = nil; clipDrop = nil; clipDragPointer = nil
        clipScrollTask?.cancel(); clipScrollTask = nil
    }
    private func finishClipDrag() {
        cancelClipDrag()
        clipDragSuppressed = false
    }
}
