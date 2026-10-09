// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/trygg"
import topbar from "../vendor/topbar"
import Timer from "./hooks/timer"
import InstallPrompt from "./hooks/install_prompt"
import DownloadPdf from "./hooks/download_pdf"
import Theme from "./hooks/theme"
import PushNotifications from "./hooks/push_notifications"
import PushPrompt from "./hooks/push_prompt"
import ModalBack from "./hooks/modal_back"
import PullToRefresh from "./hooks/pull_to_refresh"
import ChildSwipe from "./hooks/child_swipe"
import OfflineContext from "./hooks/offline_context"
import ChartScrub from "./hooks/chart_scrub"
import LoginResume from "./hooks/login_resume"
import LoginScene from "./hooks/login_scene"
import {installOfflinePanel} from "./offline/panel_toggle"
import {startAutoSync} from "./offline/auto_sync"
import "./remote_flash"
import "./log_splash"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    Timer,
    InstallPrompt,
    DownloadPdf,
    Theme,
    PushNotifications,
    PushPrompt,
    ModalBack,
    PullToRefresh,
    ChildSwipe,
    OfflineContext,
    ChartScrub,
    LoginResume,
    LoginScene,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})

// While a live navigation or patch is in flight, `data-navigating` dims the
// outgoing page (see app.css) — the incoming one renders its skeleton as soon
// as it mounts, then its data.
const root = document.documentElement
window.addEventListener("phx:page-loading-start", ({detail}) => {
  if (detail.kind === "redirect" || detail.kind === "patch") root.dataset.navigating = detail.kind
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => {
  delete root.dataset.navigating
  document.querySelectorAll("[data-nav-tab][data-pending]").forEach(el => el.removeAttribute("data-pending"))
  topbar.hide()
})

// Tabs answer a tap immediately: mark the tapped tab as the one being opened
// before the server has replied. The next render replaces the tab bar, which
// drops the mark.
document.addEventListener("click", e => {
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  const tab = e.target.closest && e.target.closest("[data-nav-tab]")
  if (!tab || tab.getAttribute("aria-current") === "page") return
  tab.closest("nav").querySelectorAll("[data-pending]").forEach(el => el.removeAttribute("data-pending"))
  tab.setAttribute("data-pending", "")
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// Reveal the offline quick-logger if the connection drops while the app is open,
// and drain any queued offline entries once we're connected.
installOfflinePanel(liveSocket)
startAutoSync({liveSocket})

// Register the service worker for installable-PWA / offline app shell.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {})
  })
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

