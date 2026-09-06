// Makes the phone/browser Back button close an open modal instead of leaving
// the page.
//
// The edit/create modals are pure LiveView socket state — opening one doesn't
// change the URL, so without this the Android system Back button (wired to
// `history.back()` in an installed PWA) navigates the page away mid-edit. If
// the entry behind that history step resolves to a different child, it looks
// like Back "switched child".
//
// On mount we push a bookmark history entry (same URL, tagged state). Back then
// pops that instead of navigating: `popstate` fires with the URL unchanged, so
// LiveView ignores it, and we send the close event. When the modal is closed
// any other way (Cancel, Save, Escape) we pop our own bookmark so history stays
// clean.
const ModalBack = {
  mounted() {
    this.closeEvent = this.el.dataset.closeEvent || "cancel_edit"
    this.bookmarked = false

    try {
      history.pushState({tryggModal: true}, "")
      this.bookmarked = true
    } catch (_e) {
      // pushState can throw in locked-down webviews; the modal still works,
      // Back just isn't intercepted.
    }

    this.onPop = () => {
      // Our bookmark was popped (or a real navigation is underway). Either way
      // the modal should not stay open on a page the user is leaving.
      this.bookmarked = false
      this.pushEvent(this.closeEvent, {})
    }
    window.addEventListener("popstate", this.onPop)
  },

  destroyed() {
    window.removeEventListener("popstate", this.onPop)

    // Closed by a button or Escape rather than by Back: our bookmark is still
    // on top of the stack, so drop it.
    if (this.bookmarked && history.state && history.state.tryggModal) {
      history.back()
    }
  },
}

export default ModalBack
