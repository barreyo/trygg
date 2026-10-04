// Keeps the login page's "enter your code" step alive across an app switch.
//
// On iOS the login email is read in another app, and the installed PWA is
// frequently reloaded or its socket reconnected on return. The code step is
// otherwise carried by a flash, which LiveView only honours for 60 seconds on
// reconnect and which is gone entirely after a reload, so the user lands back
// on the "email me a link" form with no way to type the code.
//
// While the code step is showing we remember the address locally; when the
// page comes up on the email step and a fresh entry exists, ask the server to
// show the code step again. The server still verifies everything: this only
// restores which form is visible. Entries expire with the emailed code.
const KEY = "trygg:login-pending"
const TTL_MS = 15 * 60 * 1000

function read() {
  try {
    const {email, at} = JSON.parse(localStorage.getItem(KEY)) || {}
    return email && Date.now() - at < TTL_MS ? email : null
  } catch (_e) {
    return null
  }
}

function write(email) {
  try {
    localStorage.setItem(KEY, JSON.stringify({email, at: Date.now()}))
  } catch (_e) {}
}

function clear() {
  try {
    localStorage.removeItem(KEY)
  } catch (_e) {}
}

const LoginResume = {
  mounted() {
    // "Send a new one" dispatches this client-side, ahead of the server round
    // trip, so the re-render below doesn't mistake it for a lost state.
    this.onClear = () => clear()
    this.el.addEventListener("trygg:login-clear", this.onClear)

    // Submitting a code ends the flow; a wrong code comes back with the email
    // in the flash and the code step re-stores it on mount.
    this.onSubmit = (e) => {
      if (e.target && e.target.id === "login_form_code") clear()
    }
    document.addEventListener("submit", this.onSubmit, true)

    this.sync()
  },

  updated() {
    this.sync()
  },

  reconnected() {
    this.sync()
  },

  destroyed() {
    this.el.removeEventListener("trygg:login-clear", this.onClear)
    document.removeEventListener("submit", this.onSubmit, true)
  },

  sync() {
    const sentTo = this.el.dataset.sentTo

    if (sentTo) {
      if (read() !== sentTo) write(sentTo)
      return
    }

    const email = read()
    if (email) this.pushEvent("resume", {email})
  },
}

export default LoginResume
