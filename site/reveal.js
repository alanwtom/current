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
//
// Headlines are the exception: they arrive a word at a time rather than as a
// block. That is done here rather than in a file of its own because the two
// have to agree about *when* — a word's delay is the delay this file would
// have given the whole heading, plus its own place in the line — and two files
// that must agree about ordering are one file with a race in it.
(function () {
  'use strict';

  // Set before anything else can throw. The head is watching for exactly this,
  // and it is the only way to notice this file never arriving at all.
  window.__revealOK = true;

  var STEP = 130;   // ms between items in a cascade
  var CAP = 2200;   // the deep end of the load batch stops waiting its turn

  var groups = [].slice.call(document.querySelectorAll('.fade'));
  if (!groups.length) return;

  function show(group) {
    group.classList.add('in');
  }

  /* Each word becomes its own inline-block so it can be moved — `transform`
     does nothing to an inline box — and the spaces stay as real text nodes,
     which is what lets the line wrap where it always did.
   *
   * The lot is then hidden from screen readers and the original string put
   * back as a label: read aloud, a heading chopped into eleven spans is
   * eleven separate things.
   *
   * Anything that throws here leaves the heading exactly as it was, because
   * `te-ready` — the class the CSS hides words under — is only added once the
   * split has finished. */
  function splitWords(el) {
    var text = el.textContent;
    if (!text.trim()) return;

    var holder = document.createElement('span');
    holder.setAttribute('aria-hidden', 'true');

    var i = 0;
    text.split(/(\s+)/).forEach(function (chunk) {
      if (!chunk) return;
      if (/^\s+$/.test(chunk)) {
        holder.appendChild(document.createTextNode(chunk));
        return;
      }
      var seg = document.createElement('span');
      seg.className = 'te-seg';
      seg.style.setProperty('--te-i', i++);
      seg.textContent = chunk;
      holder.appendChild(seg);
    });

    el.setAttribute('aria-label', text.trim());
    el.textContent = '';
    el.appendChild(holder);
    el.classList.add('te-ready');
  }

  try {
    [].forEach.call(document.querySelectorAll('.te'), splitWords);
  } catch (e) {
    document.documentElement.className += ' motion-off';
    return;
  }

  /* A heading is handed the moment its slot comes up rather than a transition
     delay of its own; the CSS adds each word's place in the line to it. */
  function schedule(item, ms) {
    if (item.classList.contains('te')) {
      item.style.setProperty('--te-base-ms', ms + 'ms');
    } else {
      item.style.transitionDelay = ms + 'ms';
    }
  }

  /* A nested group does its own children, so the outer one must not also move
     it as a block — it would be two rises at different speeds over the same
     pixels. Skipping it here keeps the global counter honest: document order
     puts the outer group first, so the inner one carries on from where the
     outer stopped rather than restarting at zero and racing it. */
  function ownItems(group) {
    return [].slice.call(group.children).filter(function (k) {
      return !k.classList.contains('fade');
    });
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
    var kids = ownItems(group);
    if (!kids.length) return;

    var onScreen = kids.some(function (k) {
      return k.getBoundingClientRect().top < vh;
    });

    if (onScreen) {
      // Part of the opening view: one cascade across all visible blocks.
      kids.forEach(function (k) {
        schedule(k, Math.min(next++ * STEP, CAP));
      });
      loadBatch.push(group);
    } else {
      // Below the fold: stagger the group's own items as it scrolls in.
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          kids.forEach(function (k, j) {
            schedule(k, Math.min(j * STEP, CAP));
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
