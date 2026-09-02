// Downloads the Reports PDF with a visible busy state.
//
// A plain `<a download>` gives no feedback while Chrome renders the report
// (several seconds), so we fetch it ourselves, flip `aria-busy` on the link
// while waiting, then hand the blob to the browser's download flow. The
// template styles the busy state with Tailwind's `aria-busy:` variants, and
// `updated()` re-applies it after LiveView patches (the page re-renders on a
// timer). Failures are reported back to the LiveView as a flash.
function filenameFrom(response, fallback) {
  const header = response.headers.get("content-disposition") || ""
  const match = header.match(/filename\*?=(?:utf-8'')?"?([^";]+)"?/i)
  if (!match) return fallback
  try {
    return decodeURIComponent(match[1])
  } catch (_e) {
    return match[1]
  }
}

const DownloadPdf = {
  mounted() {
    this.busy = false

    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      if (this.busy) return
      this.download()
    })
  },

  updated() {
    this.sync()
  },

  sync() {
    this.el.setAttribute("aria-busy", this.busy ? "true" : "false")
  },

  async download() {
    this.busy = true
    this.sync()

    const href = this.el.getAttribute("href")

    try {
      const response = await fetch(href, {
        credentials: "same-origin",
        headers: {accept: "application/pdf"},
      })

      const type = response.headers.get("content-type") || ""
      if (!response.ok || !type.includes("application/pdf")) {
        throw new Error(`unexpected response ${response.status} ${type}`)
      }

      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const link = document.createElement("a")
      link.href = url
      link.download = filenameFrom(response, this.el.getAttribute("download") || "report.pdf")
      document.body.appendChild(link)
      link.click()
      link.remove()
      // Give the browser time to start the download before releasing the blob.
      setTimeout(() => URL.revokeObjectURL(url), 60_000)
    } catch (_e) {
      this.pushEvent("pdf_failed", {})
    } finally {
      this.busy = false
      this.sync()
    }
  },
}

export default DownloadPdf
