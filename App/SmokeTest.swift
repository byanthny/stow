#if DEBUG
    import AppKit
    import StowCore

    extension AppDelegate {
        /// Exercises only synthetic state in a caller-selected directory; never touches the normal data folder.
        func runSmokeTest() async {
            var checks: [String: Bool] = [:]
            let directory = store.stateURL.deletingLastPathComponent()
            try? await Task.sleep(for: .milliseconds(500))
            // README captures use this same fresh synthetic state, before any acceptance mutations.
            store.toggleSection(AttentionSection.waiting.rawValue)
            try? await Task.sleep(for: .milliseconds(250))
            capture(board.contentView, to: directory.appendingPathComponent("board.png"))
            showSettings()
            try? await Task.sleep(for: .milliseconds(250))
            let settings = NSApp.windows.first { $0.title == "Stow settings" }
            capture(settings?.contentView, to: directory.appendingPathComponent("appearance.png"))
            settings?.close()
            store.toggleSection(AttentionSection.waiting.rawValue)
            let noteID = store.addNote("# Smoke note\n\n- **bold**\n- `code`\n\n[link](https://example.com)")
            store.editNote(noteID, markdown: "# Last keystroke\n\n**Saved before quit.**")
            checks["lastEditFlushed"] = await store.flush()
            store.detachNote(noteID)
            checks["detachedWindowCreated"] = noteWindows[noteID] != nil && store.note(noteID)?.isDetached == true
            noteWindows[noteID]?.performClose(nil)
            checks["closePreservesNote"] = store.note(noteID) != nil && store.note(noteID)?.isDetached == false
            store.detachNote(noteID)
            store.toggleAlwaysOnTop(noteID)
            checks["independentWindowLevel"] = noteWindows[noteID]?.level == .normal
            board.orderOut(nil)
            checks["notesRemainWhenBoardHidden"] = noteWindows[noteID]?.isVisible == true
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            checks["dockReopenShowsBoard"] = board.isVisible
            let count = store.state.notes.count
            store.pasteOutsideEditor("https://github.com/example/project/pull/42\nremember to check restoration")
            checks["pastePinsAndAddsNote"] =
                store.state.pins.contains { $0.number == 42 } && store.state.notes.count == count + 1
            store.toggleSample(noteID: noteID)
            await store.refreshAccessories()
            checks["optionalAccessory"] = !store.accessoryResults.isEmpty
            store.setGitHubEnabled(false)
            checks["notesOnly"] = !store.state.githubEnabled && store.note(noteID) != nil
            checks["persistedDetachedState"] = await store.flush()
            do {
                let saved = try await StateRepository(url: store.stateURL).load()
                checks["restartDataRestored"] =
                    saved.notes.first { $0.id == noteID }?.isDetached == true && saved.pins.contains { $0.number == 42 }
            } catch { checks["restartDataRestored"] = false }
            let temporary = store.addNote("delete this note")
            store.detachNote(temporary)
            store.deleteNote(temporary)
            checks["explicitDelete"] = store.note(temporary) == nil && noteWindows[temporary] == nil
            store.expandedPRs.insert("github.com/example/desktop/27")
            try? await Task.sleep(for: .milliseconds(800))
            if let content = board.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("notes-only.png"))
            }
            if let content = noteWindows[noteID]?.contentView,
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("note.png"))
            }
            _ = await store.flush()
            let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appendingPathComponent("smoke-results.json"))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }

        private func capture(_ content: NSView?, to url: URL) {
            guard let content, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
