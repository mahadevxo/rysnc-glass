import Foundation

@Observable
final class TransferManager {
    let state = TransferState()
    private var runningProcesses: [Process] = []
    private var isCancelled = false
    // Set synchronously on Start, unlike state.phase which only flips to
    // .running once the job's Task actually starts running — guards against
    // a rapid double-click spawning two overlapping jobs in that gap.
    private var jobInFlight = false
    // Bumped for every job start and every cancel. A job's Task carries the
    // generation it began under and checks it before writing terminal state,
    // so a cancelled job that's still unwinding in the background can't
    // stomp on a job the user has already started since.
    private var jobGeneration = 0
    /// The running job's Task. Internal so a test can wait for a cancelled
    /// job to finish tearing its processes down before inspecting disk state —
    /// isTransferActive is released by cancel() immediately and so says
    /// nothing about whether rsync has actually exited yet.
    private(set) var jobTask: Task<Void, Never>?
    /// Whether rsync's byte counts are running totals for the whole process
    /// (--info=progress2) or per file (--progress). Depends on which rsync
    /// is doing the sending, which for a direct server-to-server job is the
    /// one on the source server, not this Mac's.
    private var progressIsCumulative = RsyncCapabilities.supportsInfoProgress2

    /// Builds the rsync process for a set of item names (nil: the whole
    /// source path), so the same planning and queueing drives rsync run
    /// here or on a remote server.
    typealias ProcessFactory = (_ itemNames: [String]?, _ sourceIsDirectory: Bool) throws -> Process

    var isTransferActive: Bool { jobInFlight }

    /// Every live manager — one per window — so quitting can check and stop
    /// all of them, not just whichever window happens to be frontmost.
    private static let all = NSHashTable<TransferManager>.weakObjects()
    static var active: [TransferManager] {
        all.allObjects.filter { $0.isTransferActive }
    }

    init() {
        Self.all.add(self)
    }

    func start(source: Endpoint, target: Endpoint, options: RsyncOptions) {
        guard !jobInFlight else { return }
        jobInFlight = true
        beginJob(source: source, target: target, options: options)
    }

    private func beginJob(source: Endpoint, target: Endpoint, options: RsyncOptions) {
        state.reset()
        jobGeneration += 1
        let generation = jobGeneration
        guard source.isValid, target.isValid else {
            state.statusMessage = "Fill in all required fields for both source and target."
            state.phase = .finished(success: false)
            jobInFlight = false
            return
        }
        state.startedAt = Date()
        startSampler(generation: generation)
        // Chain onto the previous job rather than running alongside it. After a
        // cancel its Task may still be unwinding, and the two share isCancelled
        // and runningProcesses — starting the new job on top of that would
        // clear the flag the old one is still watching and let it resume. This
        // also means isCancelled stays true for the old job's whole life, so it
        // reliably stops instead of continuing into its next item.
        let previous = jobTask
        jobTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard generation == self.jobGeneration else { return }
            self.isCancelled = false
            await self.runJob(source: source, target: target, options: options, generation: generation)
        }
    }

    func clearLog() {
        state.logLines.removeAll()
    }

    func cancel() {
        isCancelled = true
        for process in runningProcesses where process.isRunning {
            process.terminate()
        }
        runningProcesses = []
        // Release the start guard here rather than waiting for the job's Task
        // to unwind. The UI offers Start again as soon as the phase flips, but
        // the Task only gets there after its processes actually die, and until
        // it called finalize() the guard in start() silently swallowed the
        // next Start — Cancel followed by Start did nothing at all. Bumping
        // the generation makes whatever that Task does when it finally lands
        // a no-op, so releasing early is safe.
        jobInFlight = false
        jobGeneration += 1
        state.phase = .cancelled
        state.statusMessage = "Cancelled."
        settleMetrics()
    }

    /// Once a second while the job runs: measures speed from how fast the
    /// byte counts climb, and time remaining from how fast overall progress
    /// climbs. The two are deliberately separate — progress is weighted by
    /// file count as well as bytes, so a byte rate alone would promise a
    /// small-file tail finishes far sooner than it will.
    private func startSampler(generation: Int) {
        Task { @MainActor [weak self] in
            var bytesWindow = RateWindow(span: 5)
            var progressWindow = RateWindow(span: 30)
            var streamWindows: [ObjectIdentifier: RateWindow] = [:]
            let origin = Date()
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self, generation == self.jobGeneration, self.jobInFlight else { return }
                let state = self.state
                let now = Date()
                let t = now.timeIntervalSince(origin)
                state.now = now

                bytesWindow.add(Double(state.bytesTransferred), at: t)
                state.bytesPerSecond = bytesWindow.rate ?? 0
                for stream in state.streams {
                    var window = streamWindows[ObjectIdentifier(stream)] ?? RateWindow(span: 5)
                    window.add(Double(stream.bytesTransferred), at: t)
                    stream.bytesPerSecond = stream.isRunning ? (window.rate ?? 0) : 0
                    streamWindows[ObjectIdentifier(stream)] = window
                }

                // Only once transferring: indexing moves nothing, and folding
                // that pause into the window would inflate the estimate.
                guard state.phase == .running else { continue }
                let progress = state.overallProgress
                progressWindow.add(progress, at: t)
                if let rate = progressWindow.rate, rate > 0 {
                    state.secondsRemaining = (1 - progress) / rate
                } else {
                    state.secondsRemaining = nil
                }
            }
        }
    }

    /// Freezes the clock and replaces the live speed with the job's average,
    /// which is the more useful number once nothing is moving.
    private func settleMetrics() {
        let now = Date()
        state.finishedAt = now
        state.now = now
        state.secondsRemaining = nil
        for stream in state.streams { stream.bytesPerSecond = 0 }
        if let elapsed = state.elapsed, elapsed > 0 {
            state.bytesPerSecond = Double(state.bytesTransferred) / elapsed
        }
    }

    enum LegOutcome: Equatable {
        case success
        case failure(String? = nil)
        case cancelled
    }

    private func runJob(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int) async {
        state.phase = .planning
        state.statusMessage = "Checking dependencies…"

        if (source.isRemote || target.isRemote) && CommandLocator.ssh == nil {
            fail("ssh not found on this Mac.", generation: generation)
            return
        }
        if [source, target].contains(where: { $0.isRemote && $0.authMethod == .password }) && CommandLocator.sshpass == nil {
            fail("Password auth needs sshpass. Install it with: brew install hudochenkov/sshpass/sshpass", generation: generation)
            return
        }

        if source.isCloud || target.isCloud {
            state.appendLog("Cloud storage: transferring with rclone.")
            finalize(outcome: await runRclone(source: source, target: target, options: options), generation: generation)
            return
        }

        if CommandLocator.rsync == nil {
            fail("rsync not found on this Mac. Install it with: brew install rsync", generation: generation)
            return
        }
        progressIsCumulative = RsyncCapabilities.supportsInfoProgress2

        if source.isRemote && target.isRemote {
            if options.directServerToServer, await runDirect(source: source, target: target, options: options, generation: generation) {
                return
            }
            if isCancelled { return }
            if options.remoteFallback == .rcloneStream {
                if CommandLocator.rclone != nil {
                    state.appendLog("Streaming server-to-server with rclone through this Mac's memory, so nothing is staged on its disk. rclone sends changed files whole and doesn't carry over permissions or ownership.")
                    finalize(outcome: await runRclone(source: source, target: target, options: options), generation: generation)
                    return
                }
                state.appendLog("rclone isn't available, so relaying with rsync through local staging instead.")
            }
            logNetworkTuning(options, hosts: [source.host, target.host])
            await runRelay(source: source, target: target, options: options, generation: generation)
        } else {
            if let streams = await parallelDownloadStreams(source: source, target: target, options: options) {
                state.appendLog("Large single file: downloading it as \(streams) parallel pieces with rclone. rsync can only fetch a file as one stream.")
                finalize(outcome: await runRclone(source: source, target: target, options: options, multiThreadStreams: streams), generation: generation)
                return
            }
            if isCancelled { return }
            logNetworkTuning(options, hosts: [source, target].filter(\.isRemote).map(\.host))
            let outcome = await runLeg(source: source, target: target, options: options, generation: generation)
            finalize(outcome: outcome, generation: generation)
        }
    }

    /// Files at least this big are worth downloading as parallel pieces.
    static let parallelDownloadThreshold: Int64 = 1 << 30

    /// How many pieces to download the source in, or nil to leave it to
    /// rsync. Only for one large file coming down from a server, and only
    /// when there's no copy of it on this Mac yet: a partial copy means an
    /// interrupted download that rsync --partial can resume, where rclone
    /// would start the file over.
    private func parallelDownloadStreams(source: Endpoint, target: Endpoint, options: RsyncOptions) async -> Int? {
        guard source.isRemote, target.kind == .local, options.streamCount > 1, !options.dryRun,
              CommandLocator.rclone != nil else { return nil }
        state.statusMessage = "Inspecting source…"
        guard let size = try? await EndpointInspector.fileSize(source), size >= Self.parallelDownloadThreshold else { return nil }
        let landing = PathUtilities.join(target.localPath, (source.remotePath as NSString).lastPathComponent)
        guard !FileManager.default.fileExists(atPath: landing) else {
            state.appendLog("A copy of this file is already on this Mac, so rsync will resume it rather than download it again in parallel pieces.")
            return nil
        }
        return options.streamCount
    }

    /// Runs the whole transfer as one rclone process, which does its own
    /// parallelism (--transfers, --multi-thread-streams).
    private func runRclone(source: Endpoint, target: Endpoint, options: RsyncOptions, multiThreadStreams: Int? = nil) async -> LegOutcome {
        guard CommandLocator.rclone != nil else { return .failure(RcloneEngine.EngineError.missing.localizedDescription) }

        // Log in to each server with ssh first. It fails fast with ssh's own
        // error message if the login doesn't work, and it records a new
        // server's host key (accept-new), which rclone then checks against.
        let agent = PrivateAgent()
        defer { agent.stop() }
        var useLoginAgent = false
        for endpoint in [source, target] where endpoint.isRemote {
            state.statusMessage = "Connecting to \(endpoint.host)…"
            do {
                let check = try SSHConnectionBuilder.makeProcess(for: endpoint, remoteCommand: "true")
                let result = try await ProcessRunner.run(check, onStart: registerProcess)
                if isCancelled { return .cancelled }
                guard result.exitCode == 0 else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .failure("Couldn't connect to \(endpoint.host)\(detail.isEmpty ? "" : ": \(detail)")")
                }
            } catch {
                return .failure("Couldn't connect to \(endpoint.host): \(error.localizedDescription)")
            }
            guard endpoint.authMethod == .key, !useLoginAgent else { continue }
            do {
                try await agent.start()
                try await agent.addKey(for: endpoint)
            } catch {
                // ssh logged in, so the key is somewhere ssh can find it —
                // most likely already in the login agent, which rclone can
                // use directly.
                useLoginAgent = true
            }
        }

        let sourceIsDirectory: Bool
        if source.isCloud {
            sourceIsDirectory = true  // only decides copy vs sync; rclone handles a file either way
        } else {
            do {
                sourceIsDirectory = try await EndpointInspector.isDirectory(source)
            } catch {
                return .failure("Couldn't inspect source path: \(error.localizedDescription)")
            }
        }
        if isCancelled { return .cancelled }

        let process: Process
        do {
            process = try await RcloneEngine.buildProcess(
                source: source, target: target, sourceIsDirectory: sourceIsDirectory, options: options,
                agentSocket: useLoginAgent ? nil : agent.socket, multiThreadStreams: multiThreadStreams
            )
        } catch {
            return .failure(error.localizedDescription)
        }

        let streamState = StreamState(id: 0)
        state.streams = [streamState]
        state.totalCostKB = 1  // rclone reports its own overall fraction
        state.phase = .running
        state.statusMessage = "Transferring with rclone…"
        guard await register(process) else { return .cancelled }
        await runStream(process: process, streamState: streamState, legCostKB: nil)
        runningProcesses = []
        if isCancelled { return .cancelled }
        return streamState.exitCode == 0 ? .success : .failure(nil)
    }

    /// Tries a direct server-to-server transfer. Returns false, having
    /// logged why, if the path isn't available — the caller then routes the
    /// data through this Mac instead.
    private func runDirect(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int) async -> Bool {
        state.statusMessage = "Checking whether \(source.host) can reach \(target.host) directly…"
        let direct = ServerToServer(source: source, target: target)
        defer { direct.stop() }
        do {
            try await direct.prepare(onStart: registerProcess)
        } catch {
            if !isCancelled {
                state.appendLog("Can't transfer server-to-server directly: \(error.localizedDescription). Routing the data through this Mac instead.")
            }
            return false
        }
        if isCancelled { return true }

        state.appendLog("Direct server-to-server: \(source.host) sends straight to \(target.host), so the data never passes through this Mac. \(source.host) logs in to \(target.host) using your key through a temporary forwarded agent, for this transfer only.")
        logNetworkTuning(options, hosts: [target.host])
        progressIsCumulative = direct.capabilities?.supportsInfoProgress2 ?? false
        let outcome = await runLeg(source: source, target: target, options: options, generation: generation) { itemNames, sourceIsDirectory in
            try direct.buildProcess(itemNames: itemNames, sourceIsDirectory: sourceIsDirectory, options: options)
        }
        finalize(outcome: outcome, generation: generation)
        return true
    }

    private func logNetworkTuning(_ options: RsyncOptions, hosts: [String]) {
        for host in hosts {
            let local = options.isLocalNetwork(host: host)
            let reason = options.network == .automatic
                ? (local ? "\(host) is on the local network" : "\(host) looks to be over the internet")
                : "Network set to \(options.network.rawValue.lowercased())"
            state.appendLog("\(reason) — compression \(local ? "off" : "on").")
        }
    }

    /// rsync can't go remote-to-remote directly, so relay through a local
    /// staging folder. Rather than downloading everything and only then
    /// uploading everything (which needs enough free local disk to hold the
    /// whole transfer at once), this relays item by item: each top-level
    /// item is downloaded, uploaded, and then deleted from staging before
    /// moving on — so the amount of data moved can exceed what fits on this
    /// Mac at any one time. The staging path is stable per source/target
    /// pair, and a small on-disk manifest (see markItemRelayed) tracks which
    /// items already finished, so an interrupted relay resumes on the next
    /// run without re-downloading items that already landed on the target
    /// — a partially-downloaded item in progress still resumes via --partial.
    private func runRelay(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int) async {
        let stagingPath = RelayStaging.path(source: source, target: target)
        do {
            try FileManager.default.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't create a local staging folder for the remote-to-remote relay: \(error.localizedDescription)", generation: generation)
            return
        }

        let staging = Endpoint(label: "Staging")
        staging.kind = .local
        staging.localPath = stagingPath

        let mode = options.pipelineRelayLegs ? "overlapping each item's upload with the next item's download" : "one item at a time"
        state.appendLog("Remote-to-remote transfer: relaying through a local staging folder at \(stagingPath), \(mode). Each item is deleted from staging once it's confirmed on the target, so this can move more data than fits on this Mac at once.")

        state.statusMessage = "Inspecting source…"
        let sourceIsDirectory: Bool
        do {
            sourceIsDirectory = try await EndpointInspector.isDirectory(source)
        } catch {
            fail("Couldn't inspect source path: \(error.localizedDescription)", generation: generation)
            return
        }

        if options.dryRun {
            state.appendLog("Note: dry run through a remote-to-remote relay only previews the download leg — the staged files won't exist yet for the upload leg to preview.")
        }

        let outcome: LegOutcome
        if sourceIsDirectory {
            outcome = await runRelayDirectory(source: source, staging: staging, target: target, options: options)
        } else {
            outcome = await runRelaySingleFile(source: source, staging: staging, target: target, options: options)
        }

        if outcome == .success {
            try? FileManager.default.removeItem(atPath: stagingPath)
        }
        finalize(outcome: outcome, generation: generation)
    }

    /// Single-file relay: there's only one item, so there's nothing to bound
    /// disk usage further than "the file has to exist in staging once" —
    /// rsync itself needs a full local copy before it can push it onward.
    func runRelaySingleFile(source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions) async -> LegOutcome {
        let streamState = StreamState(id: 0)
        streamState.itemsTotal = 1
        // Not indexed, so each leg counts as one unit of rsync's own percentage.
        state.totalCostKB = options.dryRun ? 1 : 2
        state.streams = [streamState]
        state.phase = .running

        streamState.currentFile = "Downloading…"
        state.statusMessage = "Downloading \(source.path)…"
        let downloadProcess: Process
        do {
            downloadProcess = try RsyncCommandBuilder.buildProcess(source: source, target: staging, itemNames: nil, sourceIsDirectory: false, options: options)
        } catch {
            let message = "Couldn't build rsync command: \(error.localizedDescription)"
            state.appendLog(message)
            return .failure(message)
        }
        runningProcesses = [downloadProcess]
        await runStream(process: downloadProcess, streamState: streamState, legCostKB: nil)
        runningProcesses = []
        if isCancelled { return .cancelled }
        guard streamState.exitCode == 0 else { return .failure(nil) }

        // A dry run only ever previews the download leg — nothing was
        // actually written to staging, so there's no real file to preview
        // an upload of. Stop here rather than running rsync against a path
        // that doesn't exist.
        if options.dryRun {
            streamState.itemsCompleted = 1
            return .success
        }

        // The download leg copied the single source file into the staging
        // directory under its own basename — the upload leg needs to point
        // at that specific file, not the staging directory itself (which,
        // being a real directory on disk, would otherwise get nested a
        // level deep on the target instead of copied as the one file).
        let fileName = (source.path as NSString).lastPathComponent
        let stagedFile = Endpoint(label: "Staging")
        stagedFile.kind = .local
        stagedFile.localPath = PathUtilities.join(staging.localPath, fileName)

        streamState.currentFile = "Uploading…"
        state.statusMessage = "Uploading to \(target.host)…"
        let uploadProcess: Process
        do {
            uploadProcess = try RsyncCommandBuilder.buildProcess(source: stagedFile, target: target, itemNames: nil, sourceIsDirectory: false, options: options)
        } catch {
            let message = "Couldn't build rsync command: \(error.localizedDescription)"
            state.appendLog(message)
            return .failure(message)
        }
        runningProcesses = [uploadProcess]
        await runStream(process: uploadProcess, streamState: streamState, legCostKB: nil)
        runningProcesses = []
        if isCancelled { return .cancelled }
        guard streamState.exitCode == 0 else { return .failure(nil) }
        streamState.itemsCompleted = 1
        return .success
    }

    /// Directory relay: packs items into chunks (same planning as local/remote
    /// parallel streams), and each stream takes the next chunk from a shared
    /// queue as it frees up, relaying it sequentially or pipelined
    /// (overlapping the upload of one chunk with the download of the next)
    /// depending on options.pipelineRelayLegs.
    func runRelayDirectory(source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions) async -> LegOutcome {
        state.statusMessage = "Indexing source…"
        let indexed: [SizedItem]
        do {
            indexed = try await SizeLister.list(for: source, onStart: registerProcess)
        } catch {
            let message = "Couldn't list source directory: \(error.localizedDescription)"
            state.appendLog(message)
            return .failure(message)
        }
        guard !indexed.isEmpty else {
            state.appendLog("Source directory is empty — nothing to relay.")
            return .success
        }
        // Refine before consulting the manifest, so the names compared against
        // it are the same shape as the ones a previous refined run recorded.
        let allItems = await refineForBalance(items: indexed, in: source, options: options)
        state.statusMessage = "Planning \(options.streamCount) parallel stream\(options.streamCount == 1 ? "" : "s")…"

        // Items already fully relayed in an earlier run are deleted from
        // staging as they complete (that's how this stays disk-bounded), so
        // there's nothing local left for rsync to skip via its own
        // comparison. A small on-disk manifest fills that gap so a resumed
        // run doesn't re-download items that already landed on the target.
        let alreadyRelayed = loadRelayedItems(staging: staging)
        let items = allItems.filter { !isRelayed($0.name, in: alreadyRelayed) }
        guard !items.isEmpty else {
            state.appendLog("Every item was already relayed in an earlier run — nothing left to do.")
            return .success
        }
        if !alreadyRelayed.isEmpty {
            state.appendLog("Skipping \(allItems.count - items.count) item(s) already relayed in an earlier run.")
        }

        // Same window as runLeg: a cancel kills the scan, so an empty result
        // here means "cancelled", not "nothing to do". Check before we set a
        // running phase the cancelled job would then be stuck in.
        if isCancelled { return .cancelled }

        // Equal, fine-grained chunks rather than shrinking ones: a relayed
        // chunk sits in local staging until it's uploaded, so its size is
        // what bounds disk use.
        let chunks = SplitPlanner.chunks(items: items, streamCount: options.streamCount, shrinking: false)
        let queue = ChunkQueue(chunks)
        logChunkPlan(chunks, streamCount: options.streamCount)
        // Each chunk goes down and then up again, except under a dry run,
        // which only previews the download.
        let legsPerChunk: Double = options.dryRun ? 1 : 2
        state.totalCostKB = Double(chunks.reduce(0) { $0 + $1.cost }) * legsPerChunk

        let streams = (0..<min(options.streamCount, chunks.count)).map { index -> StreamState in
            let streamState = StreamState(id: index)
            streamState.itemsTotal = items.count
            return streamState
        }
        state.streams = streams
        state.phase = .running
        state.statusMessage = "Relaying \(items.count) item\(items.count == 1 ? "" : "s") through local staging…"

        let pipelined = options.pipelineRelayLegs
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for streamState in streams {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    await MainActor.run { streamState.isRunning = true }
                    let ok = pipelined
                        ? await self.relayPipelined(queue: queue, source: source, staging: staging, target: target, options: options, streamState: streamState)
                        : await self.relaySequential(queue: queue, source: source, staging: staging, target: target, options: options, streamState: streamState)
                    await MainActor.run { streamState.isRunning = false }
                    return ok
                }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Every stream is done, so nothing is writing to staging any more.
        pruneEmptyDirectories(in: staging)

        if isCancelled { return .cancelled }
        return results.allSatisfy { $0 } ? .success : .failure(nil)
    }

    /// One chunk fully through the pipe before taking the next — lowest peak
    /// disk usage (roughly one chunk's worth per stream at a time).
    ///
    /// A stream stops at its first failure rather than moving on: a failed
    /// upload leaves its chunk in staging, and carrying on would let those
    /// pile up past the disk bound. The other streams keep draining the queue.
    private func relaySequential(queue: ChunkQueue, source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions, streamState: StreamState) async -> Bool {
        while !isCancelled, let (index, chunk) = queue.take() {
            await MainActor.run { streamState.itemNames += chunk.itemNames }
            guard await relayChunkLeg(chunk, index: index, of: queue.count, from: source, to: staging, options: options, verb: "Downloading", streamState: streamState) else { return false }
            if options.dryRun {
                // Nothing was really staged under -n, so there's nothing to
                // preview an upload of — a dry run only previews downloads.
                await markItemsCompleted(chunk.itemNames.count, streamState)
                continue
            }
            if isCancelled { return false }
            guard await relayChunkLeg(chunk, index: index, of: queue.count, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState) else { return false }
            await finishRelayedChunk(chunk, staging: staging, streamState: streamState)
        }
        return !isCancelled
    }

    /// Overlaps uploading one chunk with downloading the next — faster (uses
    /// both connections at once instead of one idling while the other
    /// works), at the cost of roughly double the peak local disk per stream.
    private func relayPipelined(queue: ChunkQueue, source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions, streamState: StreamState) async -> Bool {
        if options.dryRun {
            // Nothing is actually uploaded under a dry run, so there's
            // nothing for pipelining to overlap — fall back to previewing
            // each chunk's download in turn.
            return await relaySequential(queue: queue, source: source, staging: staging, target: target, options: options, streamState: streamState)
        }
        var pending: (index: Int, chunk: WorkChunk)?
        while !isCancelled, let (index, chunk) = queue.take() {
            await MainActor.run { streamState.itemNames += chunk.itemNames }
            async let downloadOK = relayChunkLeg(chunk, index: index, of: queue.count, from: source, to: staging, options: options, verb: "Downloading", streamState: streamState)

            if let pending {
                let uploadOK = await relayChunkLeg(pending.chunk, index: pending.index, of: queue.count, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState)
                guard uploadOK else {
                    _ = await downloadOK
                    return false
                }
                await finishRelayedChunk(pending.chunk, staging: staging, streamState: streamState)
            }

            guard await downloadOK else { return false }
            pending = (index, chunk)
        }
        if let pending, !isCancelled {
            guard await relayChunkLeg(pending.chunk, index: pending.index, of: queue.count, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState) else { return false }
            await finishRelayedChunk(pending.chunk, staging: staging, streamState: streamState)
        }
        return !isCancelled
    }

    /// A chunk is on the target: free its staging space and record it so a
    /// resumed run skips it.
    private func finishRelayedChunk(_ chunk: WorkChunk, staging: Endpoint, streamState: StreamState) async {
        for name in chunk.itemNames {
            deleteLocalItem(name: name, staging: staging)
            await markItemRelayed(name: name, staging: staging)
        }
        await markItemsCompleted(chunk.itemNames.count, streamState)
    }

    /// Runs one chunk through one leg of the relay (download: source→staging,
    /// or upload: staging→target) as its own rsync process.
    private func relayChunkLeg(_ chunk: WorkChunk, index: Int, of total: Int, from source: Endpoint, to target: Endpoint, options: RsyncOptions, verb: String, streamState: StreamState) async -> Bool {
        let label = chunk.itemNames.count == 1 ? chunk.itemNames[0] : "\(chunk.itemNames.count) items"
        await MainActor.run { streamState.currentFile = "[chunk \(index)/\(total)] \(verb) \(label)…" }
        let process: Process
        do {
            process = try RsyncCommandBuilder.buildProcess(source: source, target: target, itemNames: chunk.itemNames, sourceIsDirectory: true, options: options)
        } catch {
            state.appendLog("Couldn't build \(verb.lowercased()) command for \(label): \(error.localizedDescription)")
            return false
        }
        guard await register(process) else { return false }
        let exitCode = await runProcessCapturingOutput(process, streamState: streamState, legCostKB: Double(chunk.cost))
        await MainActor.run { runningProcesses.removeAll { $0 === process } }
        return exitCode == 0
    }

    /// Adds a process to the set cancel() terminates — unless a cancel has
    /// already landed, in which case the caller shouldn't start it at all.
    private func register(_ process: Process) async -> Bool {
        await MainActor.run {
            guard !isCancelled else { return false }
            runningProcesses.append(process)
            return true
        }
    }

    /// True if this item, or a directory containing it, was already relayed.
    /// The ancestor check matters when an earlier run recorded a whole folder
    /// and this run split that same folder into subfolders — without it, a
    /// resume would re-transfer everything under it.
    ///
    /// The reverse isn't covered: how finely a run splits depends on its
    /// stream count, so lowering the stream count between runs can leave this
    /// run asking about "photos" when the manifest only holds "photos/2019"
    /// and its siblings. That resume re-relays the folder — rsync still skips
    /// the files already on the target, so it costs a rescan, not a recopy.
    private func isRelayed(_ name: String, in relayed: Set<String>) -> Bool {
        if relayed.contains(name) { return true }
        var prefix = ""
        for component in name.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if relayed.contains(prefix) { return true }
        }
        return false
    }

    private func deleteLocalItem(name: String, staging: Endpoint) {
        try? FileManager.default.removeItem(atPath: PathUtilities.join(staging.localPath, name))
    }

    /// Clears out the empty parent directories nested items leave behind
    /// ("photos/" once every "photos/<year>" has been relayed). Deliberately
    /// not done as each item completes: sibling items of the same parent run
    /// on different streams, and deleting a directory that merely looks empty
    /// could take out one a sibling's rsync had just created and was about to
    /// write into. Empty directories cost no disk, so this waits until every
    /// stream has finished and nothing else is writing.
    private func pruneEmptyDirectories(in staging: Endpoint) {
        let root = staging.localPath
        let all = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
        // Deepest first, so emptying a child lets its parent go too.
        for relative in all.sorted(by: { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }) {
            // rmdir removes a directory only if it's empty, as one atomic
            // operation — unlike removeItem, which deletes recursively.
            _ = rmdir(PathUtilities.join(root, relative))
        }
    }

    private static let relayedItemsFileName = ".rsyncglass-relayed-items"

    /// Items already fully relayed (downloaded, uploaded, and deleted from
    /// staging) in an earlier run of this same source/target pair, tracked
    /// in a small manifest file since the items themselves no longer linger
    /// in staging for rsync to skip on its own — without this, a resumed
    /// run would re-download items that already landed on the target.
    private func loadRelayedItems(staging: Endpoint) -> Set<String> {
        let path = PathUtilities.join(staging.localPath, Self.relayedItemsFileName)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(contents.split(separator: "\n").map(String.init))
    }

    /// Advances a stream's finished-item count. Wrapped in MainActor.run
    /// since streams run as concurrent tasks off the main actor, and the UI
    /// reads it live. Progress itself comes from each leg's rsync output,
    /// weighted by the chunk's indexed cost.
    private func markItemsCompleted(_ count: Int, _ streamState: StreamState) async {
        await MainActor.run {
            streamState.itemsCompleted += count
        }
    }

    private func markItemRelayed(name: String, staging: Endpoint) async {
        await MainActor.run {
            let path = PathUtilities.join(staging.localPath, Self.relayedItemsFileName)
            let line = name + "\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Runs one source→target rsync leg (splitting into parallel streams if
    /// requested) and reports how it ended. Does not set a terminal phase —
    /// callers decide that, since a relay has a second leg to run after this one.
    private func runLeg(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int, makeProcess: ProcessFactory? = nil) async -> LegOutcome {
        let makeProcess = makeProcess ?? { itemNames, sourceIsDirectory in
            try RsyncCommandBuilder.buildProcess(source: source, target: target, itemNames: itemNames, sourceIsDirectory: sourceIsDirectory, options: options)
        }
        state.statusMessage = "Inspecting source…"
        let sourceIsDirectory: Bool
        do {
            sourceIsDirectory = try await EndpointInspector.isDirectory(source)
        } catch {
            fail("Couldn't inspect source path: \(error.localizedDescription)", generation: generation)
            return .failure(nil)
        }

        var chunks: [WorkChunk] = []
        // Indexed even for a single stream: rsync's own percentage counts
        // bytes only, so it sits near 100% through a long tail of small files.
        // Knowing the entry count lets progress weigh those files properly.
        var indexedCostKB: Double?
        if sourceIsDirectory {
            state.statusMessage = "Indexing source…"
            do {
                // Registered so Cancel can terminate the scan: indexing walks
                // the whole tree, which on a large remote source is long
                // enough that an uninterruptible one would leave Cancel
                // looking like it did nothing.
                let items = try await SizeLister.list(for: source, onStart: registerProcess)
                indexedCostKB = Double(items.reduce(0) { $0 + SplitPlanner.cost(of: $1) })
                if items.isEmpty {
                    if options.streamCount > 1 {
                        state.appendLog("Source directory has nothing to split — running as a single stream.")
                    }
                } else {
                    let totalEntries = items.reduce(0) { $0 + $1.entryCount }
                    let totalKB = items.reduce(0) { $0 + $1.sizeKB }
                    state.appendLog("Indexed \(items.count) top-level item(s): \(Self.formatKB(totalKB)) across \(totalEntries) entries.")
                }
                if options.streamCount > 1 && !items.isEmpty {
                    let refined = await refineForBalance(items: items, in: source, options: options)
                    state.statusMessage = "Planning \(options.streamCount) parallel streams…"
                    chunks = SplitPlanner.chunks(items: refined, streamCount: options.streamCount)
                    logChunkPlan(chunks, streamCount: options.streamCount)
                }
            } catch {
                state.appendLog(options.streamCount > 1
                    ? "Couldn't split source for parallel streams (\(error.localizedDescription)) — falling back to a single stream."
                    : "Couldn't index source (\(error.localizedDescription)) — progress will follow rsync's byte count only.")
            }
        }

        // Cancelling kills the scan, which makes it come back empty — exactly
        // what an unsplittable source looks like. Without this check the job
        // would "fall back to a single stream" and transfer the whole source
        // the user just cancelled.
        if isCancelled { return .cancelled }

        if chunks.isEmpty {
            let streamState = StreamState(id: 0)
            // An empty directory indexes as zero work; count the one process
            // as a unit then, so finishing it still reads as 100%.
            let costKB = (indexedCostKB ?? 0) > 0 ? indexedCostKB : nil
            state.totalCostKB = costKB ?? 1
            let process: Process
            do {
                process = try makeProcess(nil, sourceIsDirectory)
            } catch {
                fail("Couldn't build rsync command: \(error.localizedDescription)", generation: generation)
                return .failure(nil)
            }
            state.streams = [streamState]
            runningProcesses = [process]
            state.phase = .running
            state.statusMessage = "Transferring…"
            await runStream(process: process, streamState: streamState, legCostKB: costKB)
            runningProcesses = []
            if isCancelled { return .cancelled }
            return streamState.exitCode == 0 ? .success : .failure(nil)
        }

        let queue = ChunkQueue(chunks)
        state.totalCostKB = Double(chunks.reduce(0) { $0 + $1.cost })
        let streams = (0..<min(options.streamCount, chunks.count)).map { StreamState(id: $0) }
        state.streams = streams
        state.phase = .running
        state.statusMessage = "Transferring…"

        await withTaskGroup(of: Void.self) { group in
            for streamState in streams {
                group.addTask { [weak self] in
                    await self?.runChunks(from: queue, streamState: streamState, sourceIsDirectory: sourceIsDirectory, makeProcess: makeProcess)
                }
            }
        }

        runningProcesses = []
        if isCancelled { return .cancelled }
        return streams.allSatisfy { $0.exitCode == 0 } ? .success : .failure(nil)
    }

    /// One stream's loop: take the next chunk, transfer it, repeat until the
    /// queue is empty. Whichever stream is free takes the next chunk, so they
    /// all finish within about one chunk of each other however far off the
    /// cost estimates turn out to be.
    ///
    /// Stops at the first failed chunk and leaves the rest to the other
    /// streams — a failure that's about this source or target, like a full
    /// disk, would only fail every remaining chunk the same way.
    private func runChunks(from queue: ChunkQueue, streamState: StreamState, sourceIsDirectory: Bool, makeProcess: ProcessFactory) async {
        await MainActor.run {
            streamState.isRunning = true
            streamState.exitCode = 0
        }
        while !isCancelled, let (index, chunk) = queue.take() {
            await MainActor.run {
                streamState.itemNames += chunk.itemNames
                streamState.currentFile = "Chunk \(index) of \(queue.count)"
            }
            let process: Process
            do {
                process = try makeProcess(chunk.itemNames, sourceIsDirectory)
            } catch {
                state.appendLog("Couldn't build rsync command for chunk \(index): \(error.localizedDescription)")
                await MainActor.run { streamState.exitCode = -1 }
                break
            }
            guard await register(process) else { break }
            let exitCode = await runProcessCapturingOutput(process, streamState: streamState, legCostKB: Double(chunk.cost))
            await MainActor.run {
                runningProcesses.removeAll { $0 === process }
                streamState.exitCode = exitCode
                if exitCode == 0 { streamState.itemsCompleted += chunk.itemNames.count }
            }
            if exitCode != 0 { break }
        }
        await MainActor.run { streamState.isRunning = false }
    }

    private func logChunkPlan(_ chunks: [WorkChunk], streamCount: Int) {
        guard let largest = chunks.first else { return }
        let totalKB = chunks.reduce(0) { $0 + $1.totalKB }
        state.appendLog("Split into \(chunks.count) chunk\(chunks.count == 1 ? "" : "s") for \(min(streamCount, chunks.count)) stream\(streamCount == 1 ? "" : "s"), \(Self.formatKB(totalKB)) in all. Streams take the next chunk as they free up, largest first; the largest is \(Self.formatKB(largest.totalKB)).")
    }

    /// Applies a job's terminal state, unless the user has cancelled or
    /// started another job since — a stale job's outcome must not overwrite
    /// the current one's phase or re-enable a guard the new job owns.
    private func finalize(outcome: LegOutcome, generation: Int) {
        guard generation == jobGeneration else { return }
        runningProcesses = []
        jobInFlight = false
        settleMetrics()
        switch outcome {
        case .success:
            state.phase = .finished(success: true)
            state.statusMessage = "Done."
        case .failure(let message):
            state.phase = .finished(success: false)
            state.statusMessage = message ?? "Finished with errors — check the log below."
        case .cancelled:
            state.phase = .cancelled
            state.statusMessage = "Cancelled."
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == jobGeneration else { return }
        state.statusMessage = message
        state.appendLog(message)
        state.phase = .finished(success: false)
        jobInFlight = false
        settleMetrics()
    }

    private func runStream(process: Process, streamState: StreamState, legCostKB: Double?) async {
        await MainActor.run { streamState.isRunning = true }
        let exitCode = await runProcessCapturingOutput(process, streamState: streamState, legCostKB: legCostKB)
        await MainActor.run {
            streamState.isRunning = false
            streamState.exitCode = exitCode
            if exitCode == 0 {
                streamState.progressFraction = 1
            }
        }
    }

    /// Runs a process to completion, piping its stdout/stderr into the shared
    /// log (tagged with the stream's number) and returning its exit code
    /// directly rather than through shared mutable state — safe to call
    /// concurrently for the same stream (e.g. a pipelined relay's
    /// overlapping download/upload).
    ///
    /// - legCostKB: the indexed work this process covers (see LegProgress),
    ///   nil if unknown.
    private func runProcessCapturingOutput(_ process: Process, streamState: StreamState, legCostKB: Double?) async -> Int32 {
        let streamID = streamState.id
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let leg = await MainActor.run { streamState.beginLeg(costKB: legCostKB) }

        let onLine: (String) -> Void = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.handleOutputLine(line, for: streamState, leg: leg)
            }
        }

        // Split on isNewline rather than "\n" or "\r": it covers both (rsync
        // redraws progress with a bare "\r"), and also "\r\n", which ssh ends
        // its warnings with and Swift treats as a single Character matching
        // neither — so a warning would otherwise swallow the line after it.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                onLine(String(line))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                onLine("⚠︎ " + line)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
            do {
                try process.run()
                // cancel() only terminates processes that are already
                // running, so one registered just before a cancel and
                // launched just after would otherwise transfer a whole
                // chunk the user has cancelled.
                if self.isCancelled { process.terminate() }
            } catch {
                let message = "Stream \(streamID + 1) failed to start: \(error.localizedDescription)"
                Task { @MainActor in
                    self.state.appendLog(message)
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume()
            }
        }

        let exitCode = process.isRunning ? -1 : process.terminationStatus
        await MainActor.run { streamState.endLeg(leg, succeeded: exitCode == 0) }
        return exitCode
    }

    @MainActor
    private func handleOutputLine(_ line: String, for streamState: StreamState, leg: LegProgress) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A cancelled job's processes keep draining output while they wind
        // down. Once its streams have been replaced, they're no longer part of
        // the displayed state, so drop their output rather than logging it
        // against — or worse, writing progress into — whatever runs now.
        guard state.streams.contains(where: { $0 === streamState }) else { return }

        // rclone logs JSON to stderr, which arrives here marked as a warning.
        let unmarked = trimmed.hasPrefix("⚠︎") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
        if let rclone = RcloneLogLine.parse(unmarked) {
            switch rclone {
            case .stats(let bytes, let fraction):
                leg.apply(fraction: fraction, bytes: bytes)
                streamState.recompute()
            case .message(let level, let text, let object):
                if let object { streamState.currentFile = object }
                if !text.isEmpty {
                    let marker = level == "error" || level == "critical" ? "⚠︎ " : ""
                    state.appendLog("[rclone] \(marker)\(object.map { "\($0): " } ?? "")\(text)")
                }
            }
            return
        }

        state.appendLog("[Stream \(streamState.id + 1)] \(trimmed)")

        // Progress goes to this process's own leg, not straight into the
        // stream: a relay stream runs one process per item (and two at once
        // when pipelined), each restarting near 0%, and the stream's figure
        // is the cost-weighted sum over all of them.
        if let update = RsyncProgressParser.parse(trimmed) {
            leg.apply(update, cumulativeBytes: progressIsCumulative)
            streamState.recompute()
            return
        }

        // relayItemLeg sets currentFile itself for multi-item streams, so raw
        // output only needs to reach the log for those.
        guard streamState.itemsTotal <= 1 else { return }
        if !trimmed.contains("%") && !trimmed.hasPrefix("⚠︎") {
            streamState.currentFile = trimmed
        }
    }

    /// Registers a planning-phase process so Cancel can terminate it — those
    /// scans walk the whole tree and would otherwise ignore a cancel.
    private func registerProcess(_ process: Process) {
        Task { @MainActor in
            // Registering happens after the process is already running, so a
            // cancel can land in between. Terminating it here rather than
            // adding it to a list nobody will revisit stops a scan that would
            // otherwise keep walking a large tree unsupervised.
            guard !self.isCancelled else {
                process.terminate()
                return
            }
            // Left in the list once finished rather than cleared via
            // terminationHandler — ProcessRunner owns that handler to resume
            // its continuation, and overwriting it would hang the scan.
            // cancel() skips processes that aren't running, and the list is
            // replaced wholesale once the transfer starts, so the few
            // finished scans sitting in it are harmless.
            self.runningProcesses.append(process)
        }
    }

    /// Breaks up any item too big for one stream, reporting what it did.
    /// Falls back silently to the unrefined items if the extra scan fails —
    /// a worse split is much better than a failed transfer.
    private func refineForBalance(items: [SizedItem], in source: Endpoint, options: RsyncOptions) async -> [SizedItem] {
        let refined = await SplitPlanner.refine(items: items, streamCount: options.streamCount) { [weak self] parents in
            guard let self else { return [] }
            await MainActor.run { self.state.statusMessage = "Indexing inside \(parents.count) large item(s)…" }
            return await SizeLister.listChildren(of: parents, in: source, onStart: self.registerProcess)
        }
        if refined.count != items.count {
            state.appendLog("Split \(items.count) top-level item(s) into \(refined.count) for balance — a directory too big for one stream is transferred as several of its subfolders.")
        }
        return refined
    }

    private static func formatKB(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file)
    }
}

/// Hands chunks out, largest first, to whichever stream asks next. Streams
/// run as concurrent tasks, hence the lock.
final class ChunkQueue {
    private let chunks: [WorkChunk]
    private var nextIndex = 0
    private let lock = NSLock()

    init(_ chunks: [WorkChunk]) {
        self.chunks = chunks
    }

    var count: Int { chunks.count }

    /// The next chunk and its 1-based position, or nil once all are taken.
    func take() -> (index: Int, chunk: WorkChunk)? {
        lock.withLock {
            guard nextIndex < chunks.count else { return nil }
            defer { nextIndex += 1 }
            return (nextIndex + 1, chunks[nextIndex])
        }
    }
}
