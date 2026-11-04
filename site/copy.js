// Copy buttons for the command and config blocks. Plain JavaScript: it writes to the clipboard only when someone
// presses a button, and makes no requests.
'use strict';

(() => {
  const blocks = document.querySelectorAll('pre[data-copy]');
  if (!blocks.length || !navigator.clipboard) {
    return;
  }

  const status = document.createElement('p');
  status.className = 'sr-only';
  status.setAttribute('role', 'status');
  document.body.append(status);

  const svgNS = 'http://www.w3.org/2000/svg';
  const icon = (paths) => {
    const svg = document.createElementNS(svgNS, 'svg');
    for (const [name, value] of Object.entries({
      viewBox: '0 0 24 24', width: '16', height: '16', fill: 'none', stroke: 'currentColor',
      'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true',
    })) {
      svg.setAttribute(name, value);
    }
    for (const d of paths) {
      const path = document.createElementNS(svgNS, 'path');
      path.setAttribute('d', d);
      svg.append(path);
    }
    return svg;
  };
  const copyIcon = [
    'M9 9h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V10a1 1 0 0 1 1-1z',
    'M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1',
  ];
  const doneIcon = ['M5 12l5 5L19 7'];

  // Each command on its own line, without the phone-only line continuation.
  const textOf = (pre) => {
    const code = pre.querySelector('code');
    const lines = code.querySelectorAll('.line');
    if (!lines.length) {
      return code.textContent.trim();
    }
    return Array.from(lines, (line) => {
      const copy = line.cloneNode(true);
      copy.querySelectorAll('.cont').forEach((node) => node.remove());
      return copy.textContent.trim();
    }).join('\n');
  };

  for (const pre of blocks) {
    const label = pre.dataset.copy || 'Copy';
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'copy-button';
    button.title = label;
    button.setAttribute('aria-label', label);
    button.append(icon(copyIcon));
    let reset = 0;
    button.addEventListener('click', async () => {
      clearTimeout(reset);
      try {
        await navigator.clipboard.writeText(textOf(pre));
      } catch {
        // Without clipboard access, select the text so it can be copied by hand.
        window.getSelection().selectAllChildren(pre.querySelector('code'));
        status.textContent = 'Selected. Press Command-C to copy.';
        return;
      }
      button.replaceChildren(icon(doneIcon));
      button.classList.add('is-done');
      status.textContent = 'Copied';
      reset = setTimeout(() => {
        button.replaceChildren(icon(copyIcon));
        button.classList.remove('is-done');
        status.textContent = '';
      }, 1600);
    });
    pre.classList.add('has-copy');
    pre.append(button);
  }
})();
