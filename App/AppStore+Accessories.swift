import Foundation
import StowCore
import StowExtensionSDK

extension AppStore {
    func sampleEnabled(noteID: UUID? = nil) -> Bool {
        base.extensionInstances.contains { $0.moduleID == sampleID && $0.noteID == noteID && $0.isEnabled }
    }

    func toggleSample(noteID: UUID? = nil) {
        if let index = base.extensionInstances.firstIndex(where: { $0.moduleID == sampleID && $0.noteID == noteID }) {
            base.extensionInstances[index].isEnabled.toggle()
            let instance = base.extensionInstances[index]
            if !instance.isEnabled {
                accessoryRuns.removeValue(forKey: instance.id)?.cancel()
                accessoryTokens[instance.id] = nil
                accessoryResults[instance.id] = nil
                Task { await accessoryHost.cancel(instanceID: instance.id, moduleID: instance.moduleID) }
            }
        } else {
            base.extensionInstances.append(
                .init(
                    moduleID: sampleID, slot: noteID == nil ? .boardAccessory : .noteAccessory,
                    noteID: noteID, isEnabled: true))
        }
        changed()
        runOwned { await $0.refreshAccessories() }
    }

    func refreshAccessories() async {
        guard !isRestoringBackup, !isPaused else { return }
        // A refresh that began while the store ran ends once it stops, so a closing profile starts no more
        // accessories. One asked of an already stopped store still runs: tests that silence a store's timers by
        // stopping it, then refresh its accessories by hand.
        let beganRunning = !isStopped
        for id in base.extensionInstances.map(\.id) {
            guard !Task.isCancelled, !isRestoringBackup, !isPaused, !(beganRunning && isStopped) else { return }
            guard let instance = base.extensionInstances.first(where: { $0.id == id && $0.isEnabled }) else {
                continue
            }
            if let existing = accessoryRuns[id] {
                await existing.value
                continue
            }
            let token = UUID()
            accessoryTokens[id] = token
            let task = Task { [weak self] in
                guard let self, !Task.isCancelled,
                    base.extensionInstances.contains(where: { $0.id == id && $0.isEnabled })
                else { return }
                defer {
                    if accessoryTokens[id] == token {
                        accessoryRuns[id] = nil
                        accessoryTokens[id] = nil
                    }
                }
                let request = AccessoryRequest(
                    instanceID: id, slot: instance.slot,
                    configurationVersion: instance.configurationVersion, configuration: instance.configuration)
                let result = await accessoryHost.run(request, moduleID: instance.moduleID, enabled: true)
                guard !Task.isCancelled,
                    base.extensionInstances.contains(where: { $0.id == id && $0.isEnabled })
                else { return }
                accessoryResults[id] = result
            }
            accessoryRuns[id] = task
            await task.value
        }
    }
}
