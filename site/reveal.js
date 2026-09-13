// The page fades in top to bottom: blocks in the first viewport assemble as
// one continuous cascade on load; blocks below the fold wait and stagger
// through their own items when they scroll into view.
//
// The animation is a nicety. Being able to read the page is not:
//
//   * no IntersectionObserver, or Reduce Motion  -> everything shown at once
//   * the observer never fires                   -> a timer shows everything
//   * no JavaScript at all                       -> a <noscript> rule in the
//                                                   page overrides the CSS
(function () {
  var STEP = 130;   // ms between items in a cascade
  var CAP = 2200;   // the deep end of the load batch stops waiting its turn

  var groups = [].slice.call(document.querySelectorAll('.fade'));
  if (!groups.length) return;

  function show(group) {
    group.classList.add('in');
  }

  if (!('IntersectionObserver' in window) ||
      !window.matchMedia ||
      matchMedia('(prefers-reduced-motion: reduce)').matches) {
    groups.forEach(show);
    return;
  }

  var vh = window.innerHeight;
  var loadBatch = [];
  var next = 0;   // global item counter, so the load batch runs top down

  groups.forEach(function (group) {
    var kids = [].slice.call(group.children);
    var onScreen = kids.some(function (k) {
      return k.getBoundingClientRect().top < vh;
    });

    if (onScreen) {
      // Part of the opening view: one cascade across all visible blocks.
      kids.forEach(function (k) {
        k.style.transitionDelay = Math.min(next++ * STEP, CAP) + 'ms';
      });
      loadBatch.push(group);
    } else {
      // Below the fold: stagger the group's own items as it scrolls in.
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          kids.forEach(function (k, j) {
            k.style.transitionDelay = Math.min(j * STEP, CAP) + 'ms';
          });
          show(group);
          io.disconnect();   // one-way: nothing re-animates on the way back up
        });
      }, { rootMargin: '0px 0px -10% 0px', threshold: 0.08 });
      io.observe(group);
    }
  });

  // Two frames so the hidden state is committed before the class flips,
  // otherwise the transition can be skipped and items just appear.
  requestAnimationFrame(function () {
    requestAnimationFrame(function () {
      loadBatch.forEach(show);
    });
  });

  // Failsafe. If nothing has started after three seconds — a background tab,
  // a browser that throttles observers — stop being clever and show the page.
  window.setTimeout(function () {
    if (document.querySelector('.fade.in')) return;
    groups.forEach(show);
  }, 3000);
})();
