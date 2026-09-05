// Flips the light/dark theme the instant a preference radio changes, without
// waiting on the LiveView round-trip. That round-trip is what made the setting
// feel broken in the installed Android PWA: the socket can be slow to connect
// (or offline on launch), so a server `push_event` never arrived. Here the
// change is applied synchronously on the client; the form's `phx-change` still
// persists the choice for cross-device sync, and on later loads the pre-paint
// script in `root.html.heex` reads the stored value back off `<html>`.

// Keep this in sync with the bootstrap script in root.html.heex.
export function applyTheme(theme) {
  const root = document.documentElement

  if (theme === "system" || !theme) {
    root.removeAttribute("data-theme")
  } else {
    root.setAttribute("data-theme", theme)
  }

  try {
    if (theme === "system" || !theme) {
      localStorage.removeItem("phx:theme")
    } else {
      localStorage.setItem("phx:theme", theme)
    }
  } catch (_e) {
    // Storage blocked (private mode). The attribute above still themes this
    // session; it just won't survive a reload.
  }
}

const Theme = {
  mounted() {
    this.onChange = (e) => {
      const input = e.target.closest('input[name="user[theme]"]')
      if (input && input.checked) applyTheme(input.value)
    }
    this.el.addEventListener("change", this.onChange)
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange)
  },
}

export default Theme
