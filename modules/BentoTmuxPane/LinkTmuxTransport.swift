import BentoLink
import BentoWorkbench
import Foundation
import os

// Stage 2 of the byte-pipe seam: TmuxByteTransport over the daemon's real
// wire, riding the same BentoLink machinery every ACP pane rides. One
// virtual instance = one acphost stream (a stream binds to at most one
// instance, daemon-side), so each attach opens its own connection:
// ensure (`spawn` kind=tmux — idempotent, binds nothing) → `attach` with
// the caller's catch-up cursor → stdio units both ways. Credit is the
// transport's business (AcpHostTransport grants it per delivered unit —
// the flushStdio policy); exit arrives as the ordinary `exit` control.

public final class LinkTmuxTransport: TmuxByteTransport, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.bento.tmuxpane", category: "link")

    /// Builds one CONNECTED-mode transport per attach. Injected so the
    /// class is bearer-agnostic: the Mac shell hands in the local unix
    /// socket, iOS the sealed relay path — nothing here is macOS-only.
    public typealias TransportFactory = @Sendable () -> AcpHostTransport

    private let instanceID: TmuxVirtualInstanceID
    private let sessionName: String
    private let makeTransport: TransportFactory

    private let lock = NSLock()
    private var transport: AcpHostTransport?
    private var continuation: AsyncStream<TmuxPaneEvent>.Continuation?
    /// A resize that arrived before any live attach (surfaces size their
    /// grid ahead of the stream); replayed once attached.
    private var pendingResize: (cols: Int, rows: Int)?
    /// Serializes resize ops: acks are matched FIFO on the stream, and the
    /// LAST size sent must be the last size the pane holds.
    private var resizeChain: Task<Void, Never>?

    public init(instanceID: TmuxVirtualInstanceID, sessionName: String = "",
                makeTransport: @escaping TransportFactory) {
        self.instanceID = instanceID
        self.sessionName = sessionName
        self.makeTransport = makeTransport
    }

    #if os(macOS)
    /// Local-daemon convenience: plaintext units over the daemon's unix
    /// socket, resolved the way DaemonAgentLauncher resolves it ($BENTO_HOME,
    /// else ~/.bento-acp) so this transport reaches the SAME daemon the Mac
    /// app launched.
    public convenience init(instanceID: TmuxVirtualInstanceID, sessionName: String = "",
                            socketPath: String? = nil) {
        let path = socketPath ?? DaemonAgentLauncher().socketPath
        self.init(instanceID: instanceID, sessionName: sessionName) {
            AcpHostTransportFactory.local(socketPath: path)
        }
    }
    #endif

    // MARK: - TmuxByteTransport

    public func attach(haveSeq: UInt64) async throws -> TmuxAttachment {
        teardown()   // supersede any previous stream

        let t = makeTransport()
        try await t.connect()
        // Ensure the target's tmux session exists before touching a pane in
        // it. Idempotent (the daemon adopts a live control client), and it
        // publishes the structure mirror before acking — so by the time the
        // attach below runs, the pane's id namespace is real.
        _ = try await t.ensureTmux(target: instanceID.target, sessionName: sessionName)

        var newCont: AsyncStream<TmuxPaneEvent>.Continuation!
        let events = AsyncStream<TmuxPaneEvent>(bufferingPolicy: .unbounded) { newCont = $0 }
        let cont = newCont!
        // Handlers bind to THIS attach's continuation (not self's slot):
        // stdio starts the instant the daemon answers, and a late unit from
        // a superseded connection must never leak into the new stream.
        t.onStdioUnit = { unit in
            cont.yield(.output(unit))
        }
        t.onEvent = { event in
            switch event {
            case .agentExited(let code, let message):
                cont.yield(.exit(code: code, message: message))
                cont.finish()
            case .stderrLine(let line):
                Self.log.warning("tmux pane stderr: \(line, privacy: .public)")
            default:
                break
            }
        }

        let info: AttachInfo
        do {
            info = try await t.attach(agentID: instanceID.raw, haveSeq: haveSeq)
        } catch {
            cont.finish()
            t.close()
            throw error
        }

        let resume: (cols: Int, rows: Int)?
        lock.lock()
        transport = t
        continuation = cont
        resume = pendingResize
        pendingResize = nil
        lock.unlock()
        if let resume {
            enqueueResize(t, cols: resume.cols, rows: resume.rows)
        }

        return TmuxAttachment(
            details: TmuxAttachDetails(running: info.running, headSeq: info.headSeq,
                                       startSeq: info.startSeq, replay: info.replay),
            events: events)
    }

    public func detach() {
        teardown()
    }

    public func write(_ data: Data) {
        lock.lock()
        let t = transport
        lock.unlock()
        // Synchronous enqueue — no Task hop, so keystroke order is call
        // order. Bytes with no live stream are dropped, same as typing at a
        // disconnected terminal.
        t?.enqueueStdio(data)
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        guard let t = transport else {
            pendingResize = (cols, rows)
            lock.unlock()
            return
        }
        lock.unlock()
        enqueueResize(t, cols: cols, rows: rows)
    }

    // MARK: - Internals

    private func enqueueResize(_ t: AcpHostTransport, cols: Int, rows: Int) {
        let id = instanceID.raw
        lock.lock()
        let previous = resizeChain
        resizeChain = Task {
            await previous?.value
            do {
                _ = try await t.resizeTmuxPane(agentID: id, cols: cols, rows: rows)
            } catch {
                // The ack is logging surface only — the mirror's next
                // snapshot is the truth of what size the pane holds.
                Self.log.error("tmux resize \(cols)x\(rows) failed: \(String(describing: error))")
            }
        }
        lock.unlock()
    }

    private func teardown() {
        lock.lock()
        let t = transport
        let cont = continuation
        transport = nil
        continuation = nil
        lock.unlock()
        // Polite detach first (the daemon unbinds either way when the
        // stream closes); then drop the connection and end the event stream.
        t?.detach()
        t?.close()
        cont?.finish()
    }
}

// MARK: - Authority wiring (the statechanged subscription)

extension DaemonAuthority {
    /// Build an authority wired to a live control transport: verbs go out
    /// as acked structure frames, and the statekv change stream for
    /// `tmux/<target>/structure` routes back into `ingest` — the exact
    /// mechanism the workspace mirror rides today (statechanged → re-pull
    /// via getstate; see AgentWorkspaceStore.syncWithDaemon), no parallel
    /// channel. The transport's `onEvent` slot becomes this authority's,
    /// so hand it a DEDICATED control connection.
    ///
    /// Ends with an initial pull: when the target was already ensured, the
    /// authority holds a projection before this returns.
    @MainActor
    public static func linked(to transport: AcpHostTransport,
                              target: String = "local",
                              entryID: Int = 0) async -> DaemonAuthority {
        let authority = DaemonAuthority(
            encoding: DaemonStructureVerbEncoding(target: target),
            entryID: entryID
        ) { frame in
            try await transport.sendStructureFrame(frame)
        }
        let key = TmuxStructureDecoding.statekvKey(target: target)
        transport.onEvent = { [weak authority] event in
            guard case .stateChanged(let changed) = event, changed == key else { return }
            Task { @MainActor in
                guard let authority,
                      let data = try? await transport.getState(key: key) else { return }
                authority.ingest(stateValue: data)
            }
        }
        if let data = try? await transport.getState(key: key) {
            authority.ingest(stateValue: data)
        }
        return authority
    }
}
