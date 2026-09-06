// A tiny promise wrapper over IndexedDB for the offline log queue.
//
// The repo keeps `assets/` free of `node_modules` (esbuild bundles straight
// from `deps/` and `vendor/`), so rather than pull in Dexie we hand-roll the
// handful of calls this feature needs against one database with two stores:
//
//   * `queue`    — entries captured offline, keyed by their client-generated
//                  `clientId`. Drained by `sync.js` once back online.
//   * `context`  — a single row per child mirrored from the live LiveView
//                  (`OfflineContext` hook) so the offline screen knows which
//                  child it is logging for and in which units.
//   * `snapshot` — a small read cache per child (last few entries + any
//                  running sleep timer), pushed from the dashboard, so the
//                  offline screen isn't logging blind.
//
// Everything degrades to a no-op rejection if IndexedDB is unavailable
// (private windows, storage disabled); callers surface that to the user.

const DB_NAME = "trygg-offline"
const DB_VERSION = 2

let dbPromise

function openDb() {
  if (dbPromise) return dbPromise

  dbPromise = new Promise((resolve, reject) => {
    if (!("indexedDB" in globalThis)) {
      reject(new Error("IndexedDB unavailable"))
      return
    }

    const req = indexedDB.open(DB_NAME, DB_VERSION)

    req.onupgradeneeded = () => {
      const db = req.result
      if (!db.objectStoreNames.contains("queue")) {
        db.createObjectStore("queue", {keyPath: "clientId"})
      }
      if (!db.objectStoreNames.contains("context")) {
        db.createObjectStore("context", {keyPath: "childId"})
      }
      if (!db.objectStoreNames.contains("snapshot")) {
        db.createObjectStore("snapshot", {keyPath: "childId"})
      }
    }

    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  }).catch((err) => {
    // Let a later call retry rather than caching the failure forever.
    dbPromise = null
    throw err
  })

  return dbPromise
}

function tx(storeName, mode, run) {
  return openDb().then(
    (db) =>
      new Promise((resolve, reject) => {
        const transaction = db.transaction(storeName, mode)
        const store = transaction.objectStore(storeName)
        let result
        Promise.resolve(run(store))
          .then((value) => {
            result = value
          })
          .catch(reject)
        transaction.oncomplete = () => resolve(result)
        transaction.onerror = () => reject(transaction.error)
        transaction.onabort = () => reject(transaction.error)
      })
  )
}

function request(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

// --- queue ---------------------------------------------------------------

export function queueAdd(row) {
  return tx("queue", "readwrite", (store) => request(store.add(row)))
}

export function queuePut(row) {
  return tx("queue", "readwrite", (store) => request(store.put(row)))
}

export function queueAll() {
  return tx("queue", "readonly", (store) => request(store.getAll())).then((rows) =>
    (rows || []).sort((a, b) => a.createdAt - b.createdAt)
  )
}

export function queueGet(clientId) {
  return tx("queue", "readonly", (store) => request(store.get(clientId)))
}

export function queueDelete(clientId) {
  return tx("queue", "readwrite", (store) => request(store.delete(clientId)))
}

// --- context ------------------------------------------------------------

export function contextPut(row) {
  return tx("context", "readwrite", (store) => request(store.put(row)))
}

export function contextAll() {
  return tx("context", "readonly", (store) => request(store.getAll())).then(
    (rows) => rows || []
  )
}

// --- snapshot ---------------------------------------------------------

export function snapshotPut(row) {
  return tx("snapshot", "readwrite", (store) => request(store.put(row)))
}

export function snapshotAll() {
  return tx("snapshot", "readonly", (store) => request(store.getAll())).then(
    (rows) => rows || []
  )
}
