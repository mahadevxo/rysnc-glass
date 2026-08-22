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

    var isTransferActive: Bool { jobInFlight }

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
    }

    enum LegOutcome: Equatable {
        case success
        case failure(String? = nil)
        case cancelled
    }

    private func runJob(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int) async {
        state.phase = .planning
        state.statusMessage = "Checking dependencies…"

        if CommandLocator.rsync == nil {
            fail("rsync not found on this Mac. Install it with: brew install rsync", generation: generation)
            return
        }
        if (source.isRemote || target.isRemote) && CommandLocator.ssh == nil {
            fail("ssh not found on this Mac.", generation: generation)
            return
        }
        if [source, target].contains(where: { $0.isRemote && $0.authMethod == .password }) && CommandLocator.sshpass == nil {
            fail("Password auth needs sshpass. Install it with: brew install hudochenkov/sshpass/sshpass", generation: generation)
            return
        }

        if source.isRemote && target.isRemote {
            await runRelay(source: source, target: target, options: options, generation: generation)
        } else {
            let outcome = await runLeg(source: source, target: target, options: options, generation: generation)
            finalize(outcome: outcome, generation: generation)
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
        streamState.workShare = 1
        streamState.itemsTotal = 1
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
        await runStream(process: downloadProcess, streamState: streamState)
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
        streamState.progressFraction = 0
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
        await runStream(process: uploadProcess, streamState: streamState)
        runningProcesses = []
        if isCancelled { return .cancelled }
        guard streamState.exitCode == 0 else { return .failure(nil) }
        streamState.itemsCompleted = 1
        return .success
    }

    /// Directory relay: split top-level items across streamCount groups
    /// (same balancing as local/remote parallel streams), then relay each
    /// group's items one at a time — sequentially, or pipelined (overlapping
    /// upload of item N with download of item N+1) depending on
    /// options.pipelineRelayLegs.
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

        let plans = SplitPlanner.plan(items: items, streamCount: options.streamCount)
        let grandTotal = max(plans.reduce(0) { $0 + $1.cost }, 1)

        var groups: [(streamState: StreamState, itemNames: [String])] = []
        for (index, plan) in plans.enumerated() {
            let streamState = StreamState(id: index)
            streamState.itemNames = plan.itemNames
            streamState.itemsTotal = plan.itemNames.count
            streamState.workShare = Double(plan.cost) / Double(grandTotal)
            groups.append((streamState, plan.itemNames))
        }

        state.streams = groups.map { $0.streamState }
        state.phase = .running
        state.statusMessage = "Relaying \(items.count) item\(items.count == 1 ? "" : "s") through local staging…"

        let pipelined = options.pipelineRelayLegs
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for entry in groups {
                let streamState = entry.streamState
                let itemNames = entry.itemNames
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return pipelined
                        ? await self.runGroupPipelined(itemNames: itemNames, source: source, staging: staging, target: target, options: options, streamState: streamState)
                        : await self.runGroupSequential(itemNames: itemNames, source: source, staging: staging, target: target, options: options, streamState: streamState)
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

    /// One item fully through the pipe before starting the next — lowest
    /// peak disk usage (roughly one item's worth per stream at a time).
    private func runGroupSequential(itemNames: [String], source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions, streamState: StreamState) async -> Bool {
        for (index, name) in itemNames.enumerated() {
            if isCancelled { return false }
            guard await relayItemLeg(name: name, itemIndex: index + 1, from: source, to: staging, options: options, verb: "Downloading", streamState: streamState) else { return false }
            if options.dryRun {
                // Nothing was really staged under -n, so there's nothing to
                // preview an upload of — a dry run only previews downloads.
                await markItemCompleted(streamState)
                continue
            }
            if isCancelled { return false }
            guard await relayItemLeg(name: name, itemIndex: index + 1, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState) else { return false }
            deleteLocalItem(name: name, staging: staging)
            await markItemRelayed(name: name, staging: staging)
            await markItemCompleted(streamState)
        }
        return true
    }

    /// Overlaps uploading item N with downloading item N+1 — faster (uses
    /// both connections at once instead of one idling while the other
    /// works), at the cost of roughly double the peak local disk per stream.
    private func runGroupPipelined(itemNames: [String], source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions, streamState: StreamState) async -> Bool {
        if options.dryRun {
            // Nothing is actually uploaded under a dry run, so there's
            // nothing for pipelining to overlap — fall back to previewing
            // each item's download in turn.
            return await runGroupSequential(itemNames: itemNames, source: source, staging: staging, target: target, options: options, streamState: streamState)
        }
        var pending: (name: String, index: Int)?
        for (index, name) in itemNames.enumerated() {
            if isCancelled { return false }
            async let downloadOK = relayItemLeg(name: name, itemIndex: index + 1, from: source, to: staging, options: options, verb: "Downloading", streamState: streamState)

            if let pending {
                let uploadOK = await relayItemLeg(name: pending.name, itemIndex: pending.index, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState)
                guard uploadOK else {
                    _ = await downloadOK
                    return false
                }
                deleteLocalItem(name: pending.name, staging: staging)
                await markItemRelayed(name: pending.name, staging: staging)
                await markItemCompleted(streamState)
            }

            guard await downloadOK else { return false }
            pending = (name, index + 1)
        }
        if let pending {
            guard await relayItemLeg(name: pending.name, itemIndex: pending.index, from: staging, to: target, options: options, verb: "Uploading", streamState: streamState) else { return false }
            deleteLocalItem(name: pending.name, staging: staging)
            await markItemRelayed(name: pending.name, staging: staging)
            await markItemCompleted(streamState)
        }
        return true
    }

    /// Runs one item through one leg of the relay (download: source→staging,
    /// or upload: staging→target) as its own rsync process.
    private func relayItemLeg(name: String, itemIndex: Int, from source: Endpoint, to target: Endpoint, options: RsyncOptions, verb: String, streamState: StreamState) async -> Bool {
        await MainActor.run { streamState.currentFile = "[\(itemIndex)/\(streamState.itemsTotal)] \(verb) \(name)…" }
        let process: Process
        do {
            process = try RsyncCommandBuilder.buildProcess(source: source, target: target, itemNames: [name], sourceIsDirectory: true, options: options)
        } catch {
            state.appendLog("Couldn't build \(verb.lowercased()) command for \(name): \(error.localizedDescription)")
            return false
        }
        await MainActor.run { runningProcesses.append(process) }
        let exitCode = await runProcessCapturingOutput(process, streamState: streamState)
        await MainActor.run { runningProcesses.removeAll { $0 === process } }
        return exitCode == 0
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

    /// Advances a stream's item-count progress. Wrapped in MainActor.run
    /// since runGroupSequential/runGroupPipelined run off the main actor
    /// (each group is its own concurrent task), and this drives the same
    /// progressFraction the UI reads live.
    private func markItemCompleted(_ streamState: StreamState) async {
        await MainActor.run {
            streamState.itemsCompleted += 1
            streamState.progressFraction = Double(streamState.itemsCompleted) / Double(max(streamState.itemsTotal, 1))
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
    private func runLeg(source: Endpoint, target: Endpoint, options: RsyncOptions, generation: Int) async -> LegOutcome {
        state.statusMessage = "Inspecting source…"
        let sourceIsDirectory: Bool
        do {
            sourceIsDirectory = try await EndpointInspector.isDirectory(source)
        } catch {
            fail("Couldn't inspect source path: \(error.localizedDescription)", generation: generation)
            return .failure(nil)
        }

        var plans: [StreamPlan] = []
        if options.streamCount > 1 && sourceIsDirectory {
            state.statusMessage = "Indexing source…"
            do {
                // Registered so Cancel can terminate the scan: indexing walks
                // the whole tree, which on a large remote source is long
                // enough that an uninterruptible one would leave Cancel
                // looking like it did nothing.
                let items = try await SizeLister.list(for: source, onStart: registerProcess)
                if items.isEmpty {
                    state.appendLog("Source directory has nothing to split — running as a single stream.")
                } else {
                    let totalEntries = items.reduce(0) { $0 + $1.entryCount }
                    let totalKB = items.reduce(0) { $0 + $1.sizeKB }
                    state.appendLog("Indexed \(items.count) top-level item(s): \(Self.formatKB(totalKB)) across \(totalEntries) entries.")
                    let refined = await refineForBalance(items: items, in: source, options: options)
                    state.statusMessage = "Planning \(options.streamCount) parallel streams…"
                    plans = SplitPlanner.plan(items: refined, streamCount: options.streamCount)
                    for (index, plan) in plans.enumerated() {
                        state.appendLog("Stream \(index + 1): \(plan.itemNames.count) item(s), \(Self.formatKB(plan.totalKB)).")
                    }
                }
            } catch {
                state.appendLog("Couldn't split source for parallel streams (\(error.localizedDescription)) — falling back to a single stream.")
            }
        }

        // Cancelling kills the scan, which makes it come back empty — exactly
        // what an unsplittable source looks like. Without this check the job
        // would "fall back to a single stream" and transfer the whole source
        // the user just cancelled.
        if isCancelled { return .cancelled }

        var jobs: [(process: Process, streamState: StreamState)] = []
        do {
            if plans.isEmpty {
                let streamState = StreamState(id: 0)
                streamState.workShare = 1
                let process = try RsyncCommandBuilder.buildProcess(
                    source: source, target: target, itemNames: nil,
                    sourceIsDirectory: sourceIsDirectory, options: options
                )
                jobs.append((process, streamState))
            } else {
                let grandTotal = max(plans.reduce(0) { $0 + $1.cost }, 1)
                for (index, plan) in plans.enumerated() {
                    let streamState = StreamState(id: index)
                    streamState.itemNames = plan.itemNames
                    streamState.workShare = Double(plan.cost) / Double(grandTotal)
                    let process = try RsyncCommandBuilder.buildProcess(
                        source: source, target: target, itemNames: plan.itemNames,
                        sourceIsDirectory: sourceIsDirectory, options: options
                    )
                    jobs.append((process, streamState))
                }
            }
        } catch {
            fail("Couldn't build rsync command: \(error.localizedDescription)", generation: generation)
            return .failure(nil)
        }

        state.streams = jobs.map { $0.streamState }
        runningProcesses = jobs.map { $0.process }
        state.phase = .running
        state.statusMessage = "Transferring…"

        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                let process = job.process
                let streamState = job.streamState
                group.addTask { [weak self] in
                    await self?.runStream(process: process, streamState: streamState)
                }
            }
        }

        runningProcesses = []
        if isCancelled { return .cancelled }
        return state.streams.allSatisfy { $0.exitCode == 0 } ? .success : .failure(nil)
    }

    /// Applies a job's terminal state, unless the user has cancelled or
    /// started another job since — a stale job's outcome must not overwrite
    /// the current one's phase or re-enable a guard the new job owns.
    private func finalize(outcome: LegOutcome, generation: Int) {
        guard generation == jobGeneration else { return }
        runningProcesses = []
        jobInFlight = false
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
    }

    private func runStream(process: Process, streamState: StreamState) async {
        await MainActor.run { streamState.isRunning = true }
        let exitCode = await runProcessCapturingOutput(process, streamState: streamState)
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
    private func runProcessCapturingOutput(_ process: Process, streamState: StreamState) async -> Int32 {
        let streamID = streamState.id
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let onLine: (String) -> Void = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.handleOutputLine(line, for: streamState)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                onLine(String(line))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
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

        return process.isRunning ? -1 : process.terminationStatus
    }

    @MainActor
    private func handleOutputLine(_ line: String, for streamState: StreamState) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A cancelled job's processes keep draining output while they wind
        // down. Once its streams have been replaced, they're no longer part of
        // the displayed state, so drop their output rather than logging it
        // against — or worse, writing progress into — whatever runs now.
        guard state.streams.contains(where: { $0 === streamState }) else { return }
        state.appendLog("[Stream \(streamState.id + 1)] \(trimmed)")

        // Streams relaying more than one item (itemsTotal > 1) track progress
        // by item count instead — each item's process restarts near 0%, so
        // feeding its raw per-process percentage into progressFraction would
        // make the bar sawtooth (jump forward as one item finishes, then
        // fall back as the next item's process starts). It would also race
        // against a concurrently-running sibling process in pipelined mode,
        // since both share this same StreamState. relayItemLeg sets
        // currentFile itself for these streams, so raw output only needs to
        // reach the log here.
        guard streamState.itemsTotal <= 1 else { return }

        if let percent = Self.parsePercent(trimmed) {
            streamState.progressFraction = Double(percent) / 100.0
        } else if !trimmed.contains("%") && !trimmed.hasPrefix("⚠︎") {
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

    private static func parsePercent(_ line: String) -> Int? {
        guard let percentRange = line.range(of: "%") else { return nil }
        var digits = ""
        var index = percentRange.lowerBound
        while index > line.startIndex {
            let prev = line.index(before: index)
            let ch = line[prev]
            if ch.isNumber {
                digits = String(ch) + digits
                index = prev
            } else {
                break
            }
        }
        return Int(digits)
    }
}
