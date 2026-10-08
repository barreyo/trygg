// Tapping the login illustration sets the cradle wobbling and pops a few
// hearts. The animation itself is pure CSS (`.is-popping` in app.css); this
// only restarts it on every tap, which a class that stays put can't do.
//
// The scene is rendered with `phx-update="ignore"`, so the class this hook
// adds is never reset by a LiveView patch.
export default {
  mounted() {
    this.onTap = () => {
      this.el.classList.remove("is-popping")
      // Force a reflow so removing and re-adding the class restarts the animation.
      void this.el.getBoundingClientRect()
      this.el.classList.add("is-popping")
      if (navigator.vibrate) navigator.vibrate(8)
    }
    this.el.addEventListener("click", this.onTap)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onTap)
  }
}
