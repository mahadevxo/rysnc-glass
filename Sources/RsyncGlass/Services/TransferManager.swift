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

    var isTransferActive: Bool { jobInFlight }

    func start(source: Endpoint, target: Endpoint, options: RsyncOptions) {
        guard !jobInFlight else { return }
        jobInFlight = true
        beginJob(source: source, target: target, options: options)
    }

    private func beginJob(source: Endpoint, target: Endpoint, options: RsyncOptions) {
        state.reset()
        guard source.isValid, target.isValid else {
            state.statusMessage = "Fill in all required fields for both source and target."
            state.phase = .finished(success: false)
            jobInFlight = false
            return
        }
        isCancelled = false
        Task {
            await runJob(source: source, target: target, options: options)
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
        state.phase = .cancelled
        state.statusMessage = "Cancelled."
    }

    enum LegOutcome: Equatable {
        case success
        case failure(String? = nil)
        case cancelled
    }

    private func runJob(source: Endpoint, target: Endpoint, options: RsyncOptions) async {
        state.phase = .planning
        state.statusMessage = "Checking dependencies…"

        if CommandLocator.rsync == nil {
            fail("rsync not found on this Mac. Install it with: brew install rsync")
            return
        }
        if (source.isRemote || target.isRemote) && CommandLocator.ssh == nil {
            fail("ssh not found on this Mac.")
            return
        }
        if [source, target].contains(where: { $0.isRemote && $0.authMethod == .password }) && CommandLocator.sshpass == nil {
            fail("Password auth needs sshpass. Install it with: brew install hudochenkov/sshpass/sshpass")
            return
        }

        if source.isRemote && target.isRemote {
            await runRelay(source: source, target: target, options: options)
        } else {
            let outcome = await runLeg(source: source, target: target, options: options)
            finalize(outcome: outcome)
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
    private func runRelay(source: Endpoint, target: Endpoint, options: RsyncOptions) async {
        let stagingPath = RelayStaging.path(source: source, target: target)
        do {
            try FileManager.default.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't create a local staging folder for the remote-to-remote relay: \(error.localizedDescription)")
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
            fail("Couldn't inspect source path: \(error.localizedDescription)")
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
        finalize(outcome: outcome)
    }

    /// Single-file relay: there's only one item, so there's nothing to bound
    /// disk usage further than "the file has to exist in staging once" —
    /// rsync itself needs a full local copy before it can push it onward.
    func runRelaySingleFile(source: Endpoint, staging: Endpoint, target: Endpoint, options: RsyncOptions) async -> LegOutcome {
        let streamState = StreamState(id: 0)
        streamState.byteShare = 1
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
        state.statusMessage = "Planning \(options.streamCount) parallel stream\(options.streamCount == 1 ? "" : "s")…"
        let allItems: [SizedItem]
        do {
            allItems = try await SizeLister.list(for: source)
        } catch {
            let message = "Couldn't list source directory: \(error.localizedDescription)"
            state.appendLog(message)
            return .failure(message)
        }
        guard !allItems.isEmpty else {
            state.appendLog("Source directory is empty — nothing to relay.")
            return .success
        }

        // Items already fully relayed in an earlier run are deleted from
        // staging as they complete (that's how this stays disk-bounded), so
        // there's nothing local left for rsync to skip via its own
        // comparison. A small on-disk manifest fills that gap so a resumed
        // run doesn't re-download items that already landed on the target.
        let alreadyRelayed = loadRelayedItems(staging: staging)
        let items = allItems.filter { !alreadyRelayed.contains($0.name) }
        guard !items.isEmpty else {
            state.appendLog("Every item was already relayed in an earlier run — nothing left to do.")
            return .success
        }
        if !alreadyRelayed.isEmpty {
            state.appendLog("Skipping \(allItems.count - items.count) item(s) already relayed in an earlier run.")
        }

        let plans = SplitPlanner.plan(items: items, streamCount: options.streamCount)
        let grandTotal = max(plans.reduce(0) { $0 + $1.totalKB }, 1)

        var groups: [(streamState: StreamState, itemNames: [String])] = []
        for (index, plan) in plans.enumerated() {
            let streamState = StreamState(id: index)
            streamState.itemNames = plan.itemNames
            streamState.itemsTotal = plan.itemNames.count
            streamState.byteShare = Double(plan.totalKB) / Double(grandTotal)
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
        let exitCode = await runProcessCapturingOutput(process, streamID: streamState.id)
        await MainActor.run { runningProcesses.removeAll { $0 === process } }
        return exitCode == 0
    }

    private func deleteLocalItem(name: String, staging: Endpoint) {
        try? FileManager.default.removeItem(atPath: PathUtilities.join(staging.localPath, name))
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
    private func runLeg(source: Endpoint, target: Endpoint, options: RsyncOptions) async -> LegOutcome {
        state.statusMessage = "Inspecting source…"
        let sourceIsDirectory: Bool
        do {
            sourceIsDirectory = try await EndpointInspector.isDirectory(source)
        } catch {
            fail("Couldn't inspect source path: \(error.localizedDescription)")
            return .failure(nil)
        }

        var plans: [StreamPlan] = []
        if options.streamCount > 1 && sourceIsDirectory {
            state.statusMessage = "Planning \(options.streamCount) parallel streams…"
            do {
                let items = try await SizeLister.list(for: source)
                if items.isEmpty {
                    state.appendLog("Source directory has nothing to split — running as a single stream.")
                } else {
                    plans = SplitPlanner.plan(items: items, streamCount: options.streamCount)
                }
            } catch {
                state.appendLog("Couldn't split source for parallel streams (\(error.localizedDescription)) — falling back to a single stream.")
            }
        }

        var jobs: [(process: Process, streamState: StreamState)] = []
        do {
            if plans.isEmpty {
                let streamState = StreamState(id: 0)
                streamState.byteShare = 1
                let process = try RsyncCommandBuilder.buildProcess(
                    source: source, target: target, itemNames: nil,
                    sourceIsDirectory: sourceIsDirectory, options: options
                )
                jobs.append((process, streamState))
            } else {
                let grandTotal = max(plans.reduce(0) { $0 + $1.totalKB }, 1)
                for (index, plan) in plans.enumerated() {
                    let streamState = StreamState(id: index)
                    streamState.itemNames = plan.itemNames
                    streamState.byteShare = Double(plan.totalKB) / Double(grandTotal)
                    let process = try RsyncCommandBuilder.buildProcess(
                        source: source, target: target, itemNames: plan.itemNames,
                        sourceIsDirectory: sourceIsDirectory, options: options
                    )
                    jobs.append((process, streamState))
                }
            }
        } catch {
            fail("Couldn't build rsync command: \(error.localizedDescription)")
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

    private func finalize(outcome: LegOutcome) {
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

    private func fail(_ message: String) {
        state.statusMessage = message
        state.appendLog(message)
        state.phase = .finished(success: false)
        jobInFlight = false
    }

    private func runStream(process: Process, streamState: StreamState) async {
        await MainActor.run { streamState.isRunning = true }
        let exitCode = await runProcessCapturingOutput(process, streamID: streamState.id)
        await MainActor.run {
            streamState.isRunning = false
            streamState.exitCode = exitCode
            if exitCode == 0 {
                streamState.progressFraction = 1
            }
        }
    }

    /// Runs a process to completion, piping its stdout/stderr into the shared
    /// log (tagged with streamID) and returning its exit code directly rather
    /// than through shared mutable state — safe to call concurrently for the
    /// same streamID (e.g. a pipelined relay's overlapping download/upload).
    private func runProcessCapturingOutput(_ process: Process, streamID: Int) async -> Int32 {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let onLine: (String) -> Void = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.handleOutputLine(line, streamID: streamID)
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
    private func handleOutputLine(_ line: String, streamID: Int) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.appendLog("[Stream \(streamID + 1)] \(trimmed)")
        guard let streamState = state.streams.first(where: { $0.id == streamID }) else { return }

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
