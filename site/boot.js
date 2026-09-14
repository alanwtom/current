/* Two lines, and everything that animates depends on them.
 *
 * The page hides its own headlines in order to animate them in, and hiding
 * text is only honest if something is certain to put it back. This does both
 * halves of that promise.
 *
 * `js` is the class every hiding rule in the stylesheet is written under, so a
 * browser with scripting off never hides anything at all. It has to be set
 * before the first paint or the words show and then vanish, which is why this
 * file is loaded from the head with no `defer` and is deliberately tiny — a
 * render-blocking request for 300 bytes from the same origin costs nothing
 * measurable, and it is the only way to be sure.
 *
 * The timer is the half `<noscript>` cannot do. reveal.js sets __revealOK the
 * moment it runs, so what this catches is that file not arriving or not
 * parsing: a cold cache on a bad connection, or a syntax error shipped on a
 * Friday. Scripting is on in both cases, so the noscript block never applies,
 * and without this the page would sit blank with its own failsafe stranded
 * inside the file that failed to load.
 *
 * It is a file rather than an inline <script> because of the site's own
 * Content-Security-Policy. `vercel.json` sends `script-src 'self'`, with no
 * 'unsafe-inline' and no nonce, so an inline block is refused outright in
 * production while working perfectly on a local server — the worst shape a
 * bug can have. Every script this page runs has to be a real file.
 */
(function () {
  document.documentElement.className += ' js';

  setTimeout(function () {
    if (window.__revealOK) return;
    document.documentElement.className += ' motion-off';
  }, 2500);
})();
