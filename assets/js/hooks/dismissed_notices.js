// Remembers which Home alerts/banners a caregiver dismissed.
//
// The server owns the visible state (it filters dismissed notices out of the
// render); this hook only persists it. Storage is per device, per child and per
// local day (`data-day`), so a dismissed notice stays gone for the day but
// returns tomorrow if it still applies. On mount the stored keys are pushed
// back to the server; on each dismissal the server sends the full set to save.
function read(storageKey, day) {
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey) || "null")
    return stored && stored.day === day && Array.isArray(stored.keys) ? stored.keys : []
  } catch (_e) {
    return []
  }
}

function write(storageKey, day, keys) {
  try {
    localStorage.setItem(storageKey, JSON.stringify({day, keys}))
  } catch (_e) {
    // private mode; worst case the notices reappear on the next visit
  }
}

const DismissedNotices = {
  mounted() {
    const {storageKey, day} = this.el.dataset
    const keys = read(storageKey, day)
    if (keys.length > 0) this.pushEvent("restore_notices", {keys})

    this.handleEvent("notices:save", ({keys}) => {
      write(this.el.dataset.storageKey, this.el.dataset.day, keys)
    })
  },
}

export default DismissedNotices
