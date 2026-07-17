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

    private enum LegOutcome: Equatable {
        case success
        case failure
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
    /// staging folder: download source → staging, then upload staging → target.
    /// The staging path is stable per source/target pair, so an interrupted
    /// relay resumes both legs (via --partial) on the next run instead of
    /// starting over.
    private func runRelay(source: Endpoint, target: Endpoint, options: RsyncOptions) async {
        if options.dryRun {
            state.appendLog("Note: dry run through a remote-to-remote relay only previews the download leg — the staged files won't exist yet for the upload leg to preview.")
        }

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

        state.appendLog("Remote-to-remote transfer: relaying through a local staging folder at \(stagingPath).")
        state.statusMessage = "Stage 1 of 2 — downloading from \(source.host)…"
        let downloadOutcome = await runLeg(source: source, target: staging, options: options)

        guard downloadOutcome == .success else {
            finalize(outcome: downloadOutcome)
            return
        }

        state.appendLog("— Stage 1 complete. Uploading staged files to \(target.host). —")
        state.statusMessage = "Stage 2 of 2 — uploading to \(target.host)…"
        state.streams = []
        let uploadOutcome = await runLeg(source: staging, target: target, options: options)

        if uploadOutcome == .success {
            try? FileManager.default.removeItem(atPath: stagingPath)
        }
        finalize(outcome: uploadOutcome)
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
            return .failure
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
            return .failure
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
        return state.streams.allSatisfy { $0.exitCode == 0 } ? .success : .failure
    }

    private func finalize(outcome: LegOutcome) {
        runningProcesses = []
        jobInFlight = false
        switch outcome {
        case .success:
            state.phase = .finished(success: true)
            state.statusMessage = "Done."
        case .failure:
            state.phase = .finished(success: false)
            state.statusMessage = "Finished with errors — check the log below."
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let streamID = streamState.id
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

        let exitCode = process.isRunning ? -1 : process.terminationStatus
        await MainActor.run {
            streamState.isRunning = false
            streamState.exitCode = exitCode
            if exitCode == 0 {
                streamState.progressFraction = 1
            }
        }
    }

    @MainActor
    private func handleOutputLine(_ line: String, streamID: Int) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.appendLog("[Stream \(streamID + 1)] \(trimmed)")
        guard let streamState = state.streams.first(where: { $0.id == streamID }) else { return }

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
