/* The header bar: whether the page has moved, and where the highlight is.
 *
 * The first job is the small one: add a class past a few pixels of scroll,
 * remove it at the top. Everything the bar then does — drawing its glass in,
 * pulling in from both sides — is CSS, so it stays in one place and degrades
 * to nothing if this file never loads.
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

/* The travelling highlight.
 *
 * motion-primitives calls this AnimatedBackground and gets it from Motion's
 * shared-layout animation. The same effect without the library is one
 * absolutely positioned element that is told where to be — because a highlight
 * that moves is a highlight that was never two highlights.
 *
 * It rests on whatever carries `.on`, follows the pointer or the focus ring,
 * and returns when both leave. Reduce Motion skips the whole thing rather than
 * building a highlight that teleports: the CSS hover state underneath is a
 * better answer than a jumping box.
 */
(function () {
  'use strict';

  if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  [].forEach.call(document.querySelectorAll('[data-ab]'), function (host) {
    var items = [].slice.call(host.querySelectorAll('[data-ab-item]'));
    if (items.length < 2) return;

    var thumb = document.createElement('span');
    thumb.className = 'ab-thumb';
    thumb.setAttribute('aria-hidden', 'true');
    host.insertBefore(thumb, host.firstChild);

    function home() {
      return host.querySelector('[data-ab-item].on') || items[0];
    }

    function moveTo(el, instant) {
      // A link hidden at this width has no box to sit on, and asking for one
      // would park the highlight at 0,0 with no size.
      if (!el || !el.offsetWidth) return;
      if (instant) thumb.style.transition = 'none';
      thumb.style.width = el.offsetWidth + 'px';
      thumb.style.height = el.offsetHeight + 'px';
      thumb.style.transform = 'translate(' + el.offsetLeft + 'px,' + el.offsetTop + 'px)';
      if (instant) {
        void thumb.offsetWidth;   // land before the transition comes back
        thumb.style.transition = '';
      }
    }

    // Pointer only where there is one. On a touch screen `mouseenter` fires on
    // tap, and the highlight would stick to the last thing touched.
    if (!window.matchMedia || matchMedia('(hover: hover)').matches) {
      items.forEach(function (item) {
        item.addEventListener('mouseenter', function () { moveTo(item); });
      });
      host.addEventListener('mouseleave', function () { moveTo(home()); });
    }

    // The keyboard gets it always: tabbing through the nav should show where
    // you are the same way hovering does.
    items.forEach(function (item) {
      item.addEventListener('focus', function () { moveTo(item); });
    });
    host.addEventListener('focusout', function (e) {
      if (host.contains(e.relatedTarget)) return;
      moveTo(home());
    });

    moveTo(home(), true);
    host.classList.add('ab-on');

    // Both of these move the links underneath it. The font one is not
    // optional: the page's faces are `font-display: swap`, so every label is
    // measured in the fallback first and changes width when the real one lands.
    var queued = false;
    window.addEventListener('resize', function () {
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () {
        queued = false;
        moveTo(host.querySelector('[data-ab-item]:hover') || home(), true);
      });
    }, { passive: true });

    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(function () { moveTo(home(), true); });
    }
  });
})();
