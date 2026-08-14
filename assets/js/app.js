/*
 * This file is part of IRI.
 *
 * Copyright (C) 2026 Nikita Karpukhin
 *
 * IRI is free software: you can redistribute it and/or modify it under the
 * terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 *
 * IRI is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
 * more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with IRI. If not, see <https://www.gnu.org/licenses/>.
 */

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
import {hooks as colocatedHooks} from "phoenix-colocated/iri"
import topbar from "../vendor/topbar"
import {initGamepadNav} from "./gamepad_nav"

const libraryLocationKey = "iri:return-to-library"
const libraryHistoryPositionKey = "iri:library-history-position"

const storedLibraryLocation = () => {
  const location = window.sessionStorage.getItem(libraryLocationKey)
  return location === "/library" || location?.startsWith("/library?") ? location : "/library"
}

const rememberLibraryLocation = () => {
  if (window.location.pathname !== "/library") return
  window.sessionStorage.setItem(libraryLocationKey, `${window.location.pathname}${window.location.search}`)
  window.dispatchEvent(new CustomEvent("iri:library-location"))
}

const ClearableSearch = {
  mounted() {
    this.input = this.el.querySelector("[data-clearable-search-input]")
    this.button = this.el.querySelector("[data-clearable-search-button]")
    this.sync = () => {
      if (this.button && this.input) this.button.disabled = this.input.value.trim() === ""
    }
    this.clear = event => {
      event.preventDefault()
      if (!this.input) return

      this.input.value = ""
      this.input.dispatchEvent(new Event("input", {bubbles: true}))
      this.input.focus()
      this.sync()
    }
    this.dismissOnEnter = event => {
      if (event.key !== "Enter" || !this.input) return

      event.preventDefault()
      this.input.blur()

      const form = this.input.closest("form")
      if (form?.hasAttribute("phx-submit")) form.requestSubmit()
    }
    this.dismissOutside = event => {
      if (document.activeElement !== this.input || this.el.contains(event.target)) return
      this.input.blur()
    }

    this.input?.addEventListener("input", this.sync)
    this.input?.addEventListener("keydown", this.dismissOnEnter)
    this.button?.addEventListener("click", this.clear)
    document.addEventListener("pointerdown", this.dismissOutside, {capture: true, passive: true})
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    this.input?.removeEventListener("input", this.sync)
    this.input?.removeEventListener("keydown", this.dismissOnEnter)
    this.button?.removeEventListener("click", this.clear)
    document.removeEventListener("pointerdown", this.dismissOutside, {capture: true})
  },
}

const LibraryHistory = {
  mounted() {
    this.remember = rememberLibraryLocation
    this.pageNavigationPending = false
    this.startPageAtTop = event => {
      if (!event.target.closest("[data-library-page-link]")) return
      this.pageNavigationPending = true
      window.scrollTo({top: 0, behavior: "auto"})
    }
    this.trackGameNavigation = event => {
      if (!event.target.closest("[data-library-game-link]")) return

      this.remember()
      const position = window.history.state?.position
      if (Number.isInteger(position)) {
        window.sessionStorage.setItem(libraryHistoryPositionKey, position.toString())
      }
    }

    this.remember()
    this.el.addEventListener("click", this.startPageAtTop)
    this.el.addEventListener("click", this.trackGameNavigation)
  },

  updated() {
    this.remember()
    if (!this.pageNavigationPending) return

    this.pageNavigationPending = false
    window.requestAnimationFrame(() => {
      document.getElementById("library-title")?.focus({preventScroll: true})
      window.scrollTo({top: 0, behavior: "auto"})
    })
  },

  destroyed() {
    this.el.removeEventListener("click", this.startPageAtTop)
    this.el.removeEventListener("click", this.trackGameNavigation)
  },
}

const LibraryLink = {
  mounted() {
    this.refresh = () => this.updateDestination()
    window.addEventListener("iri:library-location", this.refresh)
    this.updateDestination()
  },

  updated() {
    this.updateDestination()
  },

  updateDestination() {
    this.el.setAttribute("href", storedLibraryLocation())
  },

  destroyed() {
    window.removeEventListener("iri:library-location", this.refresh)
  },
}

const LibraryBack = {
  mounted() {
    this.updateDestination()
    this.goBack = event => {
      const libraryPosition = Number.parseInt(
        window.sessionStorage.getItem(libraryHistoryPositionKey),
        10,
      )
      const currentPosition = window.history.state?.position

      if (Number.isInteger(currentPosition) && currentPosition === libraryPosition + 1) {
        event.preventDefault()
        window.history.back()
      }
    }
    this.el.addEventListener("click", this.goBack)
  },

  updated() {
    this.updateDestination()
  },

  updateDestination() {
    this.el.setAttribute("href", storedLibraryLocation())
  },

  destroyed() {
    this.el.removeEventListener("click", this.goBack)
  },
}

const JumpToTop = {
  mounted() {
    this.toggle = () => {
      const scrollTop = Math.max(
        window.scrollY || 0,
        document.documentElement.scrollTop || 0,
        document.body.scrollTop || 0,
      )
      const mobile = window.matchMedia(
        "(max-width: 639px), (hover: none) and (pointer: coarse)",
      ).matches
      const visible = scrollTop > (mobile ? 240 : 600)
      this.el.setAttribute("data-jump-visible", visible.toString())
      this.el.setAttribute("aria-hidden", (!visible).toString())
      this.el.setAttribute("tabindex", visible ? "0" : "-1")
    }
    this.jump = () => {
      const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      document.getElementById("main-content")?.focus({preventScroll: true})
      window.scrollTo({top: 0, behavior: reduceMotion ? "auto" : "smooth"})
    }
    this.viewportChanged = () => this.toggle()

    window.addEventListener("scroll", this.toggle, {passive: true})
    window.addEventListener("resize", this.viewportChanged, {passive: true})
    this.el.addEventListener("click", this.jump)
    this.toggle()
  },

  updated() {
    this.toggle()
  },

  destroyed() {
    window.removeEventListener("scroll", this.toggle)
    window.removeEventListener("resize", this.viewportChanged)
    this.el.removeEventListener("click", this.jump)
  },
}

const StatusSelection = {
  mounted() {
    this.select = event => {
      const target = event.target instanceof Element ? event.target : event.target?.parentElement
      if (!target || target.closest("[data-status-selection-ignore]")) return

      const checkbox = this.el.querySelector("[data-status-selection-checkbox]")
      if (!checkbox) return

      const clickedCheckbox = target.closest("[data-status-selection-checkbox]")
      const selected = clickedCheckbox ? checkbox.checked : !checkbox.checked

      if (!clickedCheckbox) checkbox.checked = selected

      this.pushEvent(event.shiftKey ? "select_range" : "toggle_selection", {
        id: this.el.dataset.gameId,
        selected,
      })
    }

    this.el.addEventListener("click", this.select)
  },

  destroyed() {
    this.el.removeEventListener("click", this.select)
  },
}

// Persists the bulk-editor "viewed" set in localStorage so it survives a
// refresh. On mount it replays the stored ids to the server; the server pushes
// the authoritative set back whenever it changes.
const StatusViewedStore = {
  key: "iri:status-viewed",

  mounted() {
    this.handleEvent("status:viewed-store", ({ids}) => {
      try {
        window.localStorage.setItem(this.key, JSON.stringify(ids || []))
      } catch (_error) {
        // Ignore private-mode/quota failures; viewed state stays in-session.
      }
    })

    let stored = []
    try {
      stored = JSON.parse(window.localStorage.getItem(this.key) || "[]")
    } catch (_error) {
      stored = []
    }

    if (Array.isArray(stored) && stored.length > 0) {
      this.pushEvent("sync_viewed", {ids: stored})
    }
  },
}

const CopyToClipboard = {
  mounted() {
    this.copy = async () => {
      const source = document.querySelector(this.el.dataset.copySource)
      if (!source) return

      try {
        await navigator.clipboard.writeText(source.value)
        this.pushEvent("share_link_copied", {})
      } catch (_error) {
        source.focus()
        source.select()
      }
    }

    this.el.addEventListener("click", this.copy)
  },

  destroyed() {
    this.el.removeEventListener("click", this.copy)
  },
}

const CollectionReorder = {
  mounted() {
    this.drag = null
    this.beforeRow = null
    this.autoScrollFrame = null
    this.lastClientY = null

    this.pointerDown = event => {
      const handle = event.target.closest("[data-reorder-handle]")
      const row = handle?.closest("[data-reorder-row]")

      if (!handle || !row || this.el.getAttribute("aria-busy") === "true") return
      if (event.pointerType === "mouse" && event.button !== 0) return

      event.preventDefault()
      this.cancelDrag()

      this.drag = {
        handle,
        row,
        pointerId: event.pointerId,
        movedId: row.dataset.gameId,
        ghost: this.createGhost(row, event),
      }
      this.lastClientY = event.clientY

      handle.setPointerCapture(event.pointerId)
      row.setAttribute("data-reorder-dragging", "")
      this.el.setAttribute("data-reorder-active", "")
      this.updateDropTarget(event.clientY)
      this.startAutoScroll()
    }

    this.pointerMove = event => {
      if (!this.drag || event.pointerId !== this.drag.pointerId) return

      event.preventDefault()
      this.lastClientY = event.clientY
      this.positionGhost(event.clientX, event.clientY)
      this.updateDropTarget(event.clientY)
    }

    this.pointerUp = event => {
      if (!this.drag || event.pointerId !== this.drag.pointerId) return

      event.preventDefault()
      const movedId = this.drag.movedId
      const beforeId = this.beforeRow?.dataset.gameId || null

      this.clearDragState()
      this.el.setAttribute("aria-busy", "true")
      this.el.setAttribute("data-reorder-saving", "")

      this.pushEvent("reorder_game", {moved_id: movedId, before_id: beforeId}, reply => {
        this.el.setAttribute("aria-busy", "false")
        this.el.removeAttribute("data-reorder-saving")

        if (!reply.ok) this.el.setAttribute("data-reorder-error", "")
      })
    }

    this.pointerCancel = event => {
      if (!this.drag || event.pointerId !== this.drag.pointerId) return
      this.cancelDrag()
    }

    this.keyDown = event => {
      if (event.key !== "Escape" || !this.drag) return
      event.preventDefault()
      this.cancelDrag()
      this.drag?.handle?.focus()
    }

    this.el.addEventListener("pointerdown", this.pointerDown)
    this.el.addEventListener("pointermove", this.pointerMove)
    this.el.addEventListener("pointerup", this.pointerUp)
    this.el.addEventListener("pointercancel", this.pointerCancel)
    window.addEventListener("keydown", this.keyDown)
  },

  updated() {
    if (this.drag) this.cancelDrag()
  },

  createGhost(row, event) {
    const rect = row.getBoundingClientRect()
    const ghost = row.cloneNode(true)

    ghost.removeAttribute("id")
    ghost.removeAttribute("data-reorder-row")
    ghost.querySelectorAll("[id]").forEach(element => element.removeAttribute("id"))
    ghost.querySelectorAll("[phx-click]").forEach(element => element.removeAttribute("phx-click"))
    ghost.setAttribute("data-reorder-ghost", "")
    ghost.setAttribute("aria-hidden", "true")
    ghost.style.width = `${rect.width}px`

    document.body.appendChild(ghost)

    this.ghostOffsetX = event.clientX - rect.left
    this.ghostOffsetY = event.clientY - rect.top
    this.positionGhost(event.clientX, event.clientY, ghost)

    return ghost
  },

  positionGhost(clientX, clientY, ghost = this.drag?.ghost) {
    if (!ghost) return

    const maximumLeft = Math.max(8, window.innerWidth - ghost.offsetWidth - 8)
    const left = Math.min(Math.max(8, clientX - this.ghostOffsetX), maximumLeft)
    const top = clientY - this.ghostOffsetY

    ghost.style.transform = `translate3d(${left}px, ${top}px, 0)`
  },

  updateDropTarget(clientY) {
    const rows = [...this.el.querySelectorAll("[data-reorder-row]")]
      .filter(row => row !== this.drag?.row)

    const beforeRow = rows.find(row => clientY < row.getBoundingClientRect().top + row.offsetHeight / 2)

    if (beforeRow === this.beforeRow) return

    this.beforeRow?.removeAttribute("data-reorder-before")
    this.beforeRow = beforeRow || null

    if (this.beforeRow) {
      this.beforeRow.setAttribute("data-reorder-before", "")
      this.el.removeAttribute("data-reorder-at-end")
    } else {
      this.el.setAttribute("data-reorder-at-end", "")
    }
  },

  startAutoScroll() {
    const tick = () => {
      if (!this.drag) return

      const edge = Math.min(96, window.innerHeight * 0.2)
      let movement = 0

      if (this.lastClientY < edge) {
        movement = -Math.ceil((edge - this.lastClientY) / 8)
      } else if (this.lastClientY > window.innerHeight - edge) {
        movement = Math.ceil((this.lastClientY - (window.innerHeight - edge)) / 8)
      }

      if (movement !== 0) {
        window.scrollBy(0, movement)
        this.updateDropTarget(this.lastClientY)
      }

      this.autoScrollFrame = window.requestAnimationFrame(tick)
    }

    this.autoScrollFrame = window.requestAnimationFrame(tick)
  },

  cancelDrag() {
    const handle = this.drag?.handle
    this.clearDragState()
    handle?.focus()
  },

  clearDragState() {
    if (this.autoScrollFrame) window.cancelAnimationFrame(this.autoScrollFrame)
    this.autoScrollFrame = null

    if (this.drag) {
      const {handle, row, pointerId, ghost} = this.drag
      row.removeAttribute("data-reorder-dragging")
      ghost.remove()

      if (handle.hasPointerCapture(pointerId)) handle.releasePointerCapture(pointerId)
    }

    this.beforeRow?.removeAttribute("data-reorder-before")
    this.beforeRow = null
    this.drag = null
    this.lastClientY = null
    this.ghostOffsetX = null
    this.ghostOffsetY = null
    this.el.removeAttribute("data-reorder-active")
    this.el.removeAttribute("data-reorder-at-end")
  },

  destroyed() {
    this.cancelDrag()
    this.el.removeEventListener("pointerdown", this.pointerDown)
    this.el.removeEventListener("pointermove", this.pointerMove)
    this.el.removeEventListener("pointerup", this.pointerUp)
    this.el.removeEventListener("pointercancel", this.pointerCancel)
    window.removeEventListener("keydown", this.keyDown)
  },
}

const ThemeSwitcher = {
  mounted() {
    this.toggle = this.el.querySelector("[data-theme-toggle]")
    this.menu = this.el.querySelector("[data-theme-menu]")
    this.options = Array.from(this.el.querySelectorAll("[data-theme-option]"))
    this.storageKey = this.el.dataset.themeCookie

    this.onToggle = () => (this.menu.hidden ? this.open() : this.close())
    this.onDocumentClick = event => {
      if (!this.menu.hidden && !this.el.contains(event.target)) this.close()
    }
    this.onKeyDown = event => {
      if (event.key === "Escape" && !this.menu.hidden) {
        this.close()
        this.toggle.focus()
      }
    }
    this.onOptionClick = event => {
      this.apply(event.currentTarget.dataset.themeOption)
      this.close()
      this.toggle.focus()
    }

    this.toggle.addEventListener("click", this.onToggle)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onKeyDown)
    this.options.forEach(option => option.addEventListener("click", this.onOptionClick))

    const storedTheme = this.readStoredTheme()
    const initialTheme = this.option(storedTheme) ? storedTheme : document.documentElement.dataset.theme

    if (initialTheme !== document.documentElement.dataset.theme) {
      this.apply(initialTheme)
    } else {
      this.persist(initialTheme)
      this.markActive(initialTheme)
    }
  },

  destroyed() {
    this.toggle.removeEventListener("click", this.onToggle)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onKeyDown)
    this.options.forEach(option => option.removeEventListener("click", this.onOptionClick))
  },

  open() {
    this.menu.hidden = false
    this.toggle.setAttribute("aria-expanded", "true")
    const activeOption = this.options.find(option => option.getAttribute("aria-pressed") === "true")
    const optionToFocus = activeOption || this.options[0]
    optionToFocus?.focus()
  },

  close() {
    this.menu.hidden = true
    this.toggle.setAttribute("aria-expanded", "false")
  },

  apply(theme) {
    const option = this.option(theme)
    if (!option) return

    document.documentElement.setAttribute("data-theme", theme)
    this.persist(theme)
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", option.dataset.themeColor)
    this.markActive(theme)
  },

  option(theme) {
    return this.options.find(option => option.dataset.themeOption === theme)
  },

  readStoredTheme() {
    try {
      return localStorage.getItem(this.storageKey)
    } catch (_error) {
      return null
    }
  },

  persist(theme) {
    try {
      localStorage.setItem(this.storageKey, theme)
    } catch (_error) {
      // The cookie still provides persistence when browser storage is restricted.
    }

    try {
      const secure = window.location.protocol === "https:" ? "; Secure" : ""
      document.cookie =
        `${encodeURIComponent(this.storageKey)}=${encodeURIComponent(theme)}` +
        `; Path=/; Max-Age=31536000; SameSite=Lax${secure}`
    } catch (_error) {
      // The active page still uses the selected theme when cookies are unavailable.
    }
  },

  markActive(theme) {
    this.options.forEach(option => {
      option.setAttribute("aria-pressed", option.dataset.themeOption === theme ? "true" : "false")
    })
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    LibraryHistory,
    LibraryLink,
    LibraryBack,
    JumpToTop,
    StatusSelection,
    StatusViewedStore,
    CopyToClipboard,
    CollectionReorder,
    ClearableSearch,
    ThemeSwitcher,
    ...colocatedHooks,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
let focusMainAfterNavigation = false
window.addEventListener("phx:page-loading-start", event => {
  topbar.show(75)
  focusMainAfterNavigation = event.detail?.kind === "redirect"
})
window.addEventListener("phx:page-loading-stop", _event => {
  topbar.hide()

  if (!focusMainAfterNavigation) return
  focusMainAfterNavigation = false

  window.requestAnimationFrame(() => {
    // Leave focus alone when the destination page already claimed it, e.g.
    // via autofocus or JS.focus().
    if (document.activeElement !== document.body) return
    document.getElementById("main-content")?.focus({preventScroll: true})
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

initGamepadNav()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

if ("serviceWorker" in navigator && process.env.NODE_ENV === "production") {
  window.addEventListener("load", () => navigator.serviceWorker.register("/service-worker.js"))
}

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
    window.addEventListener("keyup", _e => keyDown = null)
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
