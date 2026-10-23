import Foundation

@MainActor
extension AppViewModel {
    func startConfigDirectoryMonitoringIfNeeded() {
        guard self.configDirectoryMonitor == nil else { return }
        guard let directoryURL = self.ensureConfigDirectoryAvailable() else { return }

        _ = self.configService.reloadConfigs()
        self.configFileSignatureSnapshot = Self.configFileSignatureSnapshot(
            for: self.monitoredConfigFileURLs(self.configService.availableConfigs))
        self.configDirectoryMonitor = ConfigDirectoryMonitor(
            directoryURL: directoryURL,
            selectedFileURL: self.configService.selectedConfig)
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleConfigDirectoryRefresh()
            }
        }
    }

    func syncConfigSignatureSnapshotToMonitorBaseline() {
        guard self.configDirectoryMonitor != nil else { return }
        self.configFileSignatureSnapshot = Self.configFileSignatureSnapshot(
            for: self.monitoredConfigFileURLs(self.configService.availableConfigs))
    }

    func stopConfigDirectoryMonitoring() {
        self.configDirectoryMonitor?.cancel()
        self.configDirectoryMonitor = nil
        self.configDirectoryDebounceTask?.cancel()
        self.configDirectoryDebounceTask = nil
        self.configFileSignatureSnapshot = [:]
        self.pendingConfigChangeRestart = false
    }

    private func scheduleConfigDirectoryRefresh(delayNanoseconds: UInt64 = 350_000_000) {
        self.configDirectoryDebounceTask?.cancel()
        self.configDirectoryDebounceTask = Task { [weak self] in
            guard await (try? Task.sleep(nanoseconds: delayNanoseconds)) != nil else { return }
            self?.configDirectoryDebounceTask = nil
            await self?.handleConfigDirectoryChangesIfNeeded()
        }
    }

    private func handleConfigDirectoryChangesIfNeeded() async {
        guard let directoryURL = self.ensureConfigDirectoryAvailable() else { return }

        let previousSelectedPath = self.configService.selectedConfig?.path
        let overrideURL = self.existingConfigOverrideFileURL()
        let scan = await Task.detached(priority: .utility) {
            let files = ConfigDirectoryManager.scanConfigFiles(in: directoryURL)
            let signatures = Self.configFileSignatureSnapshot(
                for: files + (overrideURL.map { [$0] } ?? []))
            return (files, signatures)
        }.value
        guard !Task.isCancelled else { return }

        let changedFileNames = self.changedConfigFileNames(
            previous: self.configFileSignatureSnapshot,
            current: scan.1)
        let overrideChanged = changedFileNames.contains { ConfigOverrideMerger.isReservedFileName($0) }
        var selectedConfigChanged = false
        if !changedFileNames.isEmpty {
            self.configService.applyScannedConfigs(scan.0)
            self.configFileSignatureSnapshot = scan.1
            let nextSelectedPath = self.syncSelectedConfigStateForMonitoring()
            self.syncConfigDisplayState()

            let involvedSelectedFileNames = Set([
                self.configFileName(fromPath: previousSelectedPath),
                self.configFileName(fromPath: nextSelectedPath),
            ].compactMap(\.self))
            selectedConfigChanged = !involvedSelectedFileNames.isDisjoint(with: changedFileNames)
        }

        guard !self.isRemoteTarget else {
            self.pendingConfigChangeRestart = false
            return
        }
        guard self.pendingConfigChangeRestart || selectedConfigChanged || overrideChanged else { return }
        guard self.isRuntimeRunning else {
            self.pendingConfigChangeRestart = false
            return
        }

        if self.isCoreActionProcessing {
            if selectedConfigChanged || overrideChanged, !self.isTunSyncing {
                self.pendingConfigChangeRestart = true
            }
            self.scheduleConfigDirectoryRefresh(delayNanoseconds: 500_000_000)
            return
        }

        self.pendingConfigChangeRestart = false
        self.appendLog(
            level: "info",
            message: overrideChanged && !selectedConfigChanged
                ? tr("log.config.override_changed_restart")
                : tr("log.config.changed_restart"))
        await self.restartCore(trigger: .configSwitch)
    }

    private func monitoredConfigFileURLs(_ files: [URL]) -> [URL] {
        files + [self.existingConfigOverrideFileURL()].compactMap { $0 }
    }

    private nonisolated static func configFileSignatureSnapshot(for files: [URL]) -> [String: String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var snapshot: [String: String] = [:]

        for fileURL in files {
            let resolved = fileURL.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: keys)
            let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? -1
            snapshot[fileURL.lastPathComponent] = "\(modifiedAt)-\(size)"
        }

        return snapshot
    }

    private func changedConfigFileNames(
        previous: [String: String],
        current: [String: String]) -> Set<String>
    {
        let allNames = Set(previous.keys).union(current.keys)
        return Set(allNames.filter { previous[$0] != current[$0] })
    }

    private func configFileName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    @discardableResult
    private func syncSelectedConfigStateForMonitoring() -> String? {
        guard let path = self.syncSelectedConfigSelection(self.configService.selectedConfig) else {
            self.selectedConfigName = "-"
            self.defaults.removeObject(forKey: self.selectedConfigKey)
            return nil
        }
        return path
    }
}
