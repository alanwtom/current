// Sections rise into place as they scroll in, the way the hero does on load.
//
// The animation is a nicety. Being able to read the page is not — so this is
// written so that every way it can fail leaves the text visible:
//
//   * no IntersectionObserver, or Reduce Motion  -> everything shown at once
//   * the observer never fires                   -> a timer shows everything
//   * no JavaScript at all                       -> a <noscript> rule in the
//                                                   page overrides the CSS
//
// That last case is not hypothetical for the middle one either: an observer
// only reports intersections while the page is actually being rendered, so a
// tab that loads in the background can sit there with nothing revealed. The
// failsafe below is what stops that being a blank page.
(function () {
  var els = [].slice.call(document.querySelectorAll('.reveal'));
  if (!els.length) return;

  function showAll() {
    els.forEach(function (el) { el.classList.add('seen'); });
  }

  if (!('IntersectionObserver' in window) ||
      !window.matchMedia ||
      matchMedia('(prefers-reduced-motion: reduce)').matches) {
    showAll();
    return;
  }

  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (!e.isIntersecting) return;
      e.target.classList.add('seen');
      io.unobserve(e.target);   // one-way: nothing re-animates on the way back up
    });
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

  els.forEach(function (el) { io.observe(el); });

  // Failsafe. If the observer has told us nothing after three seconds — a
  // background tab, a browser that throttles it, anything — stop being clever
  // and show the page.
  window.setTimeout(function () {
    if (document.querySelectorAll('.reveal.seen').length) return;
    io.disconnect();
    showAll();
  }, 3000);
})();
