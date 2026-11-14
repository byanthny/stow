import StowCore

extension AppStore {
    @discardableResult
    func applyAppearance(_ settings: AppearanceSettings) -> Bool {
        guard let valid = try? settings.validated() else { return false }
        state.appearance = valid
        theme.apply(valid)
        onAppearanceChange?()
        changed()
        return true
    }

    func toggleBoardAlwaysOnTop() {
        state.boardAlwaysOnTop.toggle()
        onBoardLevelChange?()
        changed()
    }

    func toggleSection(_ section: String) {
        if section == Self.mergedGroupID {
            mergedGroupIsExpanded.toggle()
            return
        }
        if state.collapsedSections.contains(section) {
            state.collapsedSections.removeAll { $0 == section }
        } else {
            state.collapsedSections.append(section)
        }
        changed()
    }

    func sectionIsCollapsed(_ section: String) -> Bool {
        section == Self.mergedGroupID ? !mergedGroupIsExpanded : state.collapsedSections.contains(section)
    }

    func moveBoardSection(_ section: BoardLayout.Section, by offset: Int) {
        state.boardLayout.move(section, by: offset)
        changed()
    }

    func setVisiblePullRequests(_ count: Int) {
        guard BoardLayout.visiblePullRequestRange.contains(count) else { return }
        state.boardLayout.visiblePullRequests = count
        changed()
    }

    func resetBoardLayout() {
        state.boardLayout = BoardLayout()
        state.collapsedSections.removeAll { $0 == BoardLayout.Section.notes.rawValue }
        changed()
    }

    func setShowsBoardTitle(_ shown: Bool) {
        state.boardLayout.showsTitle = shown
        changed()
    }

    func setGroupByOwner(_ grouped: Bool) {
        state.boardLayout.groupByOwner = grouped
        changed()
    }

    func setOwnerOrder(_ order: BoardLayout.OwnerOrder) {
        state.boardLayout.ownerOrder = order
        changed()
    }

    func setAlwaysShowOwnerControl(_ shown: Bool) {
        state.boardLayout.alwaysShowOwnerControl = shown
        changed()
    }

    func setHidesNotesForHiddenOwners(_ hides: Bool) {
        state.boardLayout.hidesNotesForHiddenOwners = hides
        changed()
    }

    /// Settings → Board → Keep always-on-top notes visible when hiding, read when this profile hides.
    func setHideKeepsAlwaysOnTopNotes(_ keeps: Bool) {
        state.hideKeepsAlwaysOnTopNotes = keeps
        changed()
    }

    /// Settings → Profiles → Hide when switching away, read from this profile when a switch leaves it.
    func setHidesWhenSwitchingAway(_ hides: Bool) {
        state.hidesWhenSwitchingAway = hides
        changed()
    }

    func setNotesStartCollapsed(_ collapsed: Bool) {
        state.boardLayout.notesStartCollapsed = collapsed
        changed()
    }
}
