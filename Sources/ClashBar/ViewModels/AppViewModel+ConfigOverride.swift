import AppKit
import Foundation

@MainActor
extension AppViewModel {
    static let configOverrideTemplate = """
    # ClashBar 配置覆写文件 (Config Override)
    #
    # 本文件与订阅配置放在同一目录；保存后 ClashBar 会自动重新加载内核。
    # 支持（仅顶层键）：
    #   +rules:  将下列规则插入订阅 rules 列表最前面（优先匹配，可用于添加直连/绕过规则）
    #   其他键（如 ipv6）会覆盖订阅配置中的同名键
    #
    # 示例（去掉行首 # 即生效）：
    #
    # ipv6: false
    #
    # +rules:
    #   - "DOMAIN-SUFFIX,example.com,DIRECT"
    #   - "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
    """

    var configOverrideFileExists: Bool {
        self.existingConfigOverrideFileURL() != nil
    }

    var configOverrideFileDisplayName: String? {
        self.existingConfigOverrideFileURL()?.lastPathComponent
    }

    func existingConfigOverrideFileURL() -> URL? {
        guard let configDirectory = self.configService.configDirectory else { return nil }
        let fileManager = FileManager.default
        for fileName in [ConfigOverrideMerger.preferredFileName, "override.yml"] {
            let candidate = configDirectory.appendingPathComponent(fileName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Feeds the core the merged config when an override file exists; otherwise the source config.
    func resolveRuntimeConfigPath(sourceConfigPath: String) -> String {
        guard self.isConfigOverrideEnabled, let overrideURL = self.existingConfigOverrideFileURL() else {
            return sourceConfigPath
        }

        do {
            let sourceText = try String(contentsOfFile: sourceConfigPath, encoding: .utf8)
            let overrideText = try String(contentsOf: overrideURL, encoding: .utf8)
            guard let outcome = ConfigOverrideMerger.mergedText(sourceText: sourceText, overrideText: overrideText)
            else {
                return sourceConfigPath
            }

            // Written next to the source config so the core keeps resolving its working
            // directory (and geo databases) exactly like it does for a regular profile.
            let outputURL = URL(fileURLWithPath: sourceConfigPath)
                .deletingLastPathComponent()
                .appendingPathComponent(ConfigOverrideMerger.runtimeMergedFileName, isDirectory: false)
            try outcome.text.write(to: outputURL, atomically: true, encoding: .utf8)
            self.appendLog(
                level: "info",
                message: tr(
                    "log.config.override.applied",
                    overrideURL.lastPathComponent,
                    outcome.appliedKeys.joined(separator: ", ")))
            return outputURL.path
        } catch {
            self.appendLog(
                level: "error",
                message: tr("log.config.override.merge_failed", error.localizedDescription))
            return sourceConfigPath
        }
    }

    func applyConfigOverrideEnabled(_ enabled: Bool) {
        guard self.isConfigOverrideEnabled != enabled else { return }
        self.isConfigOverrideEnabled = enabled
        self.defaults.set(enabled, forKey: self.configOverrideEnabledKey)

        guard !self.isRemoteTarget, self.isRuntimeRunning, !self.isCoreActionProcessing else { return }
        Task { [weak self] in
            await self?.restartCore(trigger: .configSwitch)
        }
    }

    func openConfigOverrideFile() {
        guard let configDirectory = self.ensureConfigDirectoryAvailable() else { return }

        let targetURL = configDirectory.appendingPathComponent(
            ConfigOverrideMerger.preferredFileName,
            isDirectory: false)
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            do {
                try Self.configOverrideTemplate.write(
                    to: targetURL,
                    atomically: true,
                    encoding: .utf8)
                self.syncConfigSignatureSnapshotToMonitorBaseline()
            } catch {
                self.appendLog(
                    level: "error",
                    message: tr("log.config.override.create_failed", error.localizedDescription))
                return
            }
        }

        NSWorkspace.shared.open(targetURL)
    }

    func loadPersistedConfigOverrideEnabled() -> Bool {
        guard self.defaults.object(forKey: self.configOverrideEnabledKey) != nil else { return true }
        return self.defaults.bool(forKey: self.configOverrideEnabledKey)
    }
}
