/* The checksum control: shorten a long value on screen, hand over all of it on
 * click.
 *
 * A file rather than an inline <script>, and that is not a style preference.
 * `vercel.json` sends `script-src 'self'` with no 'unsafe-inline' and no
 * nonce, so an inline block is refused outright in production while working
 * perfectly against a local server — the worst shape a bug can have. Every
 * script this page runs has to be a real file.
 *
 * Its own file, like the rest, so a fault here cannot take the page's words
 * with it. This is the least important of the five and the easiest to lose:
 * if it never runs, the page shows the whole checksum and no button, which is
 * what the page did before there was a button.
 */
(function () {
  'use strict';

  /* Shorten the value on screen, hand over all of it on click.
     The element holds the real thing so there is one place to update it when
     a release goes out; what is displayed is trimmed from that. */
  document.querySelectorAll('[data-copy-from]').forEach(function (btn) {
    var src = document.getElementById(btn.getAttribute('data-copy-from'));
    if (!src) return;

    var full = (src.textContent || '').trim();
    if (!full) return;

    var clip = parseInt(btn.getAttribute('data-clip'), 10);
    if (clip > 0 && full.length > clip) {
      src.title = full;                              // hovering still gives all of it
      src.textContent = full.slice(0, clip) + '…';
    }
    btn.hidden = false;   // a button that cannot copy should never be on screen

    function write(text) {
      /* Two routes, and both are needed. `navigator.clipboard` is the real one
         and only exists in a secure context — the live site is HTTPS, but this
         page is also opened straight off the disk while it is worked on, where
         it is missing. `execCommand` is deprecated and still works everywhere;
         it needs a real selection, so it gets a textarea for one frame.

         Catching the rejection matters as much as checking it exists:
         `writeText` refuses on a document that doesn't have focus — any window
         the user has clicked away from — and the older path has no such rule. */
      function legacy() {
        return new Promise(function (resolve, reject) {
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.setAttribute('readonly', '');
          ta.style.cssText = 'position:fixed; top:-9999px; opacity:0';
          document.body.appendChild(ta);
          ta.select();
          var ok = false;
          try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
          ta.remove();
          ok ? resolve() : reject();
        });
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        return navigator.clipboard.writeText(text).catch(legacy);
      }
      return legacy();
    }

    btn.addEventListener('click', function () {
      write(full).then(function () {
        btn.classList.add('copied');
        setTimeout(function () { btn.classList.remove('copied'); }, 1500);
      }, function () {
        /* Nothing was copied, so don't tick as though it was — that was the
           old behaviour here, and a control that reports success it didn't
           have is worse than one that visibly fails. Give back the thing it
           was going to copy instead: the value in full, selected. */
        src.textContent = full;
        src.style.wordBreak = 'break-all';
        try {
          var r = document.createRange();
          r.selectNodeContents(src);
          var s = window.getSelection();
          s.removeAllRanges();
          s.addRange(r);
        } catch (e) { /* it is on screen either way, which is the point */ }
      });
    });
  });
})();
