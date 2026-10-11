// Tells CSS how much of the bottom of the screen the on-screen keyboard covers
// (`--kb`), so a bottom sheet can lift its panel clear of it.
//
// On iOS, and on Android with the default viewport behaviour, the keyboard
// overlays the page without resizing the layout viewport: `100dvh` and
// `fixed inset-0` stay put and a focused field can end up underneath. The
// Visual Viewport API reports what's actually visible, so the covered strip is
// the layout height minus the visible height and its offset.

const vv = window.visualViewport

if (vv) {
  const root = document.documentElement
  const update = () => {
    const covered = Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop))
    // Ignore small differences (browser chrome sliding in and out): a keyboard is 200px+.
    root.style.setProperty("--kb", covered > 120 ? `${covered}px` : "0px")
  }
  vv.addEventListener("resize", update)
  vv.addEventListener("scroll", update)
  update()
}
