/*
 The surfaces carousel.

 The markup is a plain horizontally scrolling list, and stays one if this never runs: every
 card is still reachable by trackpad, shift-wheel, or keyboard. What this adds is the dots,
 a drag for people on a mouse, and an advance that starts on its own once the section is
 actually on screen — and gets out of the way the moment the reader touches it.
*/
(() => {
  const carousel = document.querySelector("[data-surfaces-carousel]");
  const track = carousel?.querySelector(".surfaces");
  const slides = track ? Array.from(track.children) : [];
  if (slides.length < 2) return;

  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  const BEFORE_FIRST = 3000;
  const BETWEEN = 5000;
  const AFTER_TOUCHING = 8000;

  const dots = document.createElement("div");
  dots.className = "surfaces-dots";
  const buttons = slides.map((slide, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "surfaces-dot";
    button.setAttribute(
      "aria-label",
      slide.querySelector("h3")?.textContent.trim() ?? `Card ${index + 1}`
    );
    button.addEventListener("click", () => {
      hold();
      show(index);
    });
    dots.append(button);
    return button;
  });
  carousel.append(dots);

  let current = -1;
  const mark = (index) => {
    if (index === current) return;
    current = index;
    buttons.forEach((button, n) =>
      button.setAttribute("aria-current", n === index ? "true" : "false")
    );
  };

  const offsetOf = (slide) => slide.offsetLeft - track.offsetLeft;
  const nearest = () =>
    slides.reduce(
      (best, slide, index) =>
        Math.abs(offsetOf(slide) - track.scrollLeft) <
        Math.abs(offsetOf(slides[best]) - track.scrollLeft)
          ? index
          : best,
      0
    );
  const show = (index) =>
    track.scrollTo({
      left: offsetOf(slides[index]),
      behavior: still.matches ? "auto" : "smooth"
    });

  let onScreen = false;
  let hovered = false;
  let held = false;
  let ticker = null;
  let release = null;

  const wanted = () =>
    onScreen && !hovered && !held && !document.hidden && !still.matches;
  const stop = () => {
    clearInterval(ticker);
    ticker = null;
  };
  const play = () => {
    stop();
    if (!wanted()) return;
    ticker = setInterval(() => show((current + 1) % slides.length), BETWEEN);
  };
  // The reader did something deliberate: leave it alone for a while afterwards.
  const hold = () => {
    held = true;
    stop();
    clearTimeout(release);
    release = setTimeout(() => {
      held = false;
      play();
    }, AFTER_TOUCHING);
  };

  let settle = null;
  track.addEventListener(
    "scroll",
    () => {
      clearTimeout(settle);
      settle = setTimeout(() => mark(nearest()), 80);
    },
    { passive: true }
  );

  carousel.addEventListener("pointerenter", () => {
    hovered = true;
    stop();
  });
  carousel.addEventListener("pointerleave", () => {
    hovered = false;
    play();
  });
  carousel.addEventListener("focusin", () => {
    hovered = true;
    stop();
  });
  carousel.addEventListener("focusout", () => {
    hovered = false;
    play();
  });
  track.addEventListener("wheel", hold, { passive: true });
  document.addEventListener("visibilitychange", play);

  track.addEventListener("keydown", (event) => {
    const step =
      event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    hold();
    show(Math.min(slides.length - 1, Math.max(0, current + step)));
  });

  // Dragging, for a mouse. Touch and trackpad already scroll this themselves, and taking
  // their events over would only take the momentum away.
  let from = 0;
  let scrolledTo = 0;
  let dragging = false;
  track.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "mouse" || event.button !== 0) return;
    dragging = true;
    from = event.clientX;
    scrolledTo = track.scrollLeft;
    track.classList.add("is-dragging");
    track.setPointerCapture(event.pointerId);
    hold();
  });
  track.addEventListener("pointermove", (event) => {
    if (dragging) track.scrollLeft = scrolledTo - (event.clientX - from);
  });
  const drop = (event) => {
    if (!dragging) return;
    dragging = false;
    track.classList.remove("is-dragging");
    if (track.hasPointerCapture(event.pointerId)) {
      track.releasePointerCapture(event.pointerId);
    }
    show(nearest());
  };
  track.addEventListener("pointerup", drop);
  track.addEventListener("pointercancel", drop);

  let started = false;
  new IntersectionObserver(
    ([entry]) => {
      onScreen = entry.isIntersecting;
      if (!onScreen) return stop();
      if (started) return play();
      started = true;
      setTimeout(play, BEFORE_FIRST);
    },
    { threshold: 0.4 }
  ).observe(carousel);

  mark(0);
})();
