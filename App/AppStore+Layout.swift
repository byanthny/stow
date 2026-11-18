import StowCore

extension AppStore {
    @discardableResult
    func applyAppearance(_ settings: AppearanceSettings) -> Bool {
        guard let valid = try? settings.validated() else { return false }
        base.appearance = valid
        theme.apply(valid)
        onAppearanceChange?()
        changed()
        return true
    }

    func toggleBoardAlwaysOnTop() {
        base.boardAlwaysOnTop.toggle()
        onBoardLevelChange?()
        changed()
    }

    func toggleSection(_ section: String) {
        if section == Self.mergedGroupID {
            mergedGroupIsExpanded.toggle()
            return
        }
        if base.collapsedSections.contains(section) {
            base.collapsedSections.removeAll { $0 == section }
        } else {
            base.collapsedSections.append(section)
        }
        changed()
    }

    func sectionIsCollapsed(_ section: String) -> Bool {
        section == Self.mergedGroupID ? !mergedGroupIsExpanded : base.collapsedSections.contains(section)
    }

    func moveBoardSection(_ section: BoardLayout.Section, by offset: Int) {
        base.boardLayout.move(section, by: offset)
        changed()
    }

    func setVisiblePullRequests(_ count: Int) {
        guard BoardLayout.visiblePullRequestRange.contains(count) else { return }
        base.boardLayout.visiblePullRequests = count
        changed()
    }

    func resetBoardLayout() {
        base.boardLayout = BoardLayout()
        base.collapsedSections.removeAll { $0 == BoardLayout.Section.notes.rawValue }
        changed()
    }

    func setShowsBoardTitle(_ shown: Bool) {
        base.boardLayout.showsTitle = shown
        changed()
    }

    func setGroupByOwner(_ grouped: Bool) {
        base.boardLayout.groupByOwner = grouped
        changed()
    }

    func setOwnerOrder(_ order: BoardLayout.OwnerOrder) {
        base.boardLayout.ownerOrder = order
        changed()
    }

    func setAlwaysShowOwnerControl(_ shown: Bool) {
        base.boardLayout.alwaysShowOwnerControl = shown
        changed()
    }

    func setHidesNotesForHiddenOwners(_ hides: Bool) {
        base.boardLayout.hidesNotesForHiddenOwners = hides
        changed()
    }

    /// Settings → Board → Keep always-on-top notes visible when hiding, read when this profile hides.
    func setHideKeepsAlwaysOnTopNotes(_ keeps: Bool) {
        base.hideKeepsAlwaysOnTopNotes = keeps
        changed()
    }

    /// Settings → Profiles → Hide when switching away, read from this profile when a switch leaves it.
    func setHidesWhenSwitchingAway(_ hides: Bool) {
        base.hidesWhenSwitchingAway = hides
        changed()
    }

    func setNotesStartCollapsed(_ collapsed: Bool) {
        base.boardLayout.notesStartCollapsed = collapsed
        changed()
    }
}
