// The board demo in the hero. Plain JavaScript over synthetic data: it runs in the page and makes no requests.
'use strict';

(() => {
  const board = document.querySelector('[data-board]');
  if (!board) {
    return;
  }

  const notesList = board.querySelector('[data-notes]');
  const notesCount = board.querySelector('[data-notes-count]');
  const notesToggle = board.querySelector('[aria-controls="notes-body"]');
  const notesSummary = document.getElementById(notesToggle.dataset.summary);
  const hintRegion = board.querySelector('[data-hint]');
  const status = board.querySelector('[data-status]');
  const template = document.getElementById('note-template');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  const maxNotes = 6;
  const newNoteText = 'New note\n\nType anything here. In the app, every note is a plain Markdown file.';
  let nextNote = notesList.children.length + 1;
  let refreshTimer = 0;

  // A note's title is its first non-empty line, without Markdown heading marks.
  const titleOf = (text) => {
    for (const line of text.split('\n')) {
      const title = line.trim().replace(/^#+\s*/, '');
      if (title) {
        return title;
      }
    }
    return 'Untitled note';
  };

  // The hint region stays in the page, so screen readers announce each new hint.
  const setHint = (text) => {
    hintRegion.replaceChildren();
    if (text) {
      const hint = document.createElement('p');
      hint.className = 'hint';
      hint.textContent = text;
      hintRegion.append(hint);
    }
  };

  const setSection = (toggle, expanded) => {
    toggle.setAttribute('aria-expanded', String(expanded));
    document.getElementById(toggle.getAttribute('aria-controls')).hidden = !expanded;
    document.getElementById(toggle.dataset.summary).hidden = expanded;
  };

  // A collapsed Notes section shows the first note's title.
  const updateNotesSummary = () => {
    notesSummary.textContent = notesList.querySelector('.note-title').textContent;
  };

  const setNoteOpen = (note, open) => {
    note.classList.toggle('is-open', open);
    note.querySelector('.note-toggle').setAttribute('aria-expanded', String(open));
    note.querySelector('.note-body').hidden = !open;
  };

  // Each note opens and closes on its own, so several can stay open, like the app's board.
  const toggleNote = (note) => {
    setNoteOpen(note, !note.classList.contains('is-open'));
    setHint('');
  };

  const addNote = () => {
    // A new note opens a collapsed Notes section first, as in the app.
    setSection(notesToggle, true);
    const count = notesList.children.length;
    if (count >= maxNotes) {
      setHint('That is plenty for a demo. The app has no limit.');
      return;
    }

    const note = template.content.firstElementChild.cloneNode(true);
    const id = `note-${nextNote}`;
    nextNote += 1;
    const title = note.querySelector('.note-title');
    const body = note.querySelector('.note-body');
    const input = note.querySelector('.note-input');
    title.id = `${id}-title`;
    title.textContent = titleOf(newNoteText);
    body.id = `${id}-body`;
    note.querySelector('.note-toggle').setAttribute('aria-controls', body.id);
    note.querySelector('[data-action="pop"]').setAttribute('aria-describedby', title.id);
    input.setAttribute('aria-labelledby', title.id);
    input.value = newNoteText;

    notesList.prepend(note);
    notesCount.textContent = String(count + 1);
    updateNotesSummary();
    setNoteOpen(note, true);
    setHint('');
    input.focus({ preventScroll: true });
    input.setSelectionRange(input.value.length, input.value.length);
    note.scrollIntoView({ block: 'nearest', behavior: reducedMotion.matches ? 'auto' : 'smooth' });
  };

  const toggleMore = (button) => {
    const extras = button.closest('.section-body').querySelectorAll('[data-extra]');
    const showing = button.dataset.showing === 'true';
    for (const card of extras) {
      card.hidden = showing;
    }
    button.dataset.showing = String(!showing);
    button.textContent = showing ? `Show ${extras.length} more` : 'Show fewer';
  };

  const togglePin = (button) => {
    button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true'));
  };

  const refresh = (button) => {
    window.clearTimeout(refreshTimer);
    button.classList.add('is-refreshing');
    status.textContent = 'Refreshing…';
    refreshTimer = window.setTimeout(() => {
      button.classList.remove('is-refreshing');
      status.textContent = 'Updated just now';
    }, 700);
  };

  const actions = {
    refresh,
    pin: togglePin,
    add: addNote,
    section: (button) => setSection(button, button.getAttribute('aria-expanded') !== 'true'),
    more: toggleMore,
    note: (button) => toggleNote(button.closest('.note')),
    pop: () => setHint('In the app, this note pops out into its own window.'),
  };

  board.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-action]');
    if (button && board.contains(button)) {
      actions[button.dataset.action]?.(button);
    }
  });

  // Typing keeps the note's one-line title and the Notes summary current.
  notesList.addEventListener('input', (event) => {
    if (event.target.matches('.note-input')) {
      event.target.closest('.note').querySelector('.note-title').textContent = titleOf(event.target.value);
      updateNotesSummary();
    }
  });

  // Escape closes the open note and returns focus to its row.
  notesList.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || event.isComposing || !event.target.matches('.note-input')) {
      return;
    }
    const note = event.target.closest('.note');
    setNoteOpen(note, false);
    note.querySelector('.note-toggle').focus();
  });
})();
