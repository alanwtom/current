/* Tells the bar whether the page has moved.
 *
 * That's the whole job: add a class past a few pixels of scroll, remove it at
 * the top. Everything the bar then does — drawing its glass in, pulling in
 * from both sides — is CSS, so it stays in one place and degrades to nothing
 * if this file never loads.
 *
 * The threshold is deliberately small but not zero. At exactly zero the bar
 * flickers on and off against the elastic overscroll at the top of a trackpad
 * gesture, which is the sort of thing you only see on a Mac and only after
 * shipping it.
 *
 * Its own file, like the others here: each of the page's scripts runs alone,
 * so a fault in one can't take the demo, the reveals or the background with
 * it.
 */
(function () {
  var bar = document.getElementById('bar');
  if (!bar) return;

  var ON_AT = 12;   // px of scroll before the bar draws itself in
  var queued = false;
  var lit = null;

  function apply() {
    queued = false;
    var should = (window.scrollY || window.pageYOffset || 0) > ON_AT;
    if (should === lit) return;      // don't touch the DOM for nothing
    lit = should;
    bar.classList.toggle('is-scrolled', should);
  }

  // One update per frame at most. A scroll listener that writes to the DOM on
  // every event fires far more often than the screen refreshes.
  window.addEventListener('scroll', function () {
    if (!queued) { queued = true; requestAnimationFrame(apply); }
  }, { passive: true });

  // A reload partway down the page starts scrolled, so decide before the
  // first paint rather than waiting for someone to move.
  apply();
})();
