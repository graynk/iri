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

// Spatial gamepad navigation for couch and Steam Deck browsing.
//
// Standard-mapping controls, active only on the main browsing views
// (library, game details, collections — never settings or forms):
//   d-pad / left stick  move focus between links and buttons
//   A                   activate the focused element
//   B                   go back (except on the library root)
//   LB / RB             scroll a page up / down
const ACTIVE_PATH = /^\/(?:library\/?$|games\/|collections(?:\/|$)?)/

const INITIAL_REPEAT_MS = 320
const REPEAT_MS = 140
const STICK_THRESHOLD = 0.55

const state = {
  focused: null,
  lastRect: null,
  buttons: {},
  directionHeldSince: null,
  lastMoveAt: 0,
  activeDirection: null,
  frame: null,
  idleTimer: null,
  inputMode: null,
}

const editable = element =>
  ["INPUT", "TEXTAREA", "SELECT"].includes(element?.tagName) || element?.isContentEditable

const active = () =>
  ACTIVE_PATH.test(window.location.pathname) &&
  !editable(document.activeElement)

const candidates = () => {
  const scope = document.querySelector('[role="dialog"][aria-modal="true"]') || document

  return [...scope.querySelectorAll("a[href], button:not([disabled]), summary")].filter(element => {
    if (element.getAttribute("aria-hidden") === "true" || element.tabIndex < 0) return false
    const rect = element.getBoundingClientRect()
    if (rect.width < 4 || rect.height < 4) return false
    return element.checkVisibility ? element.checkVisibility() : true
  })
}

const center = rect => ({x: rect.left + rect.width / 2, y: rect.top + rect.height / 2})

const preview = (element, type) => {
  element?.querySelector("[phx-hook], [id^='card-preview-']")?.dispatchEvent(new Event(type))
}

const cardFor = element => element?.closest("[data-gamepad-card]")

const blurFocused = () => {
  if (!state.focused) return
  state.focused.classList.remove("gamepad-focus")
  const card = cardFor(state.focused)
  card?.classList.remove("gamepad-selected")
  if (card) card.dataset.gamepadSelected = "false"
  preview(state.focused, "pointerleave")
  state.focused = null
}

const focusElement = element => {
  if (!element || element === state.focused) return

  blurFocused()
  state.focused = element
  state.lastRect = element.getBoundingClientRect()
  element.classList.add("gamepad-focus")
  const card = cardFor(element)
  card?.classList.add("gamepad-selected")
  if (card) card.dataset.gamepadSelected = "true"
  element.focus({preventScroll: true})
  element.scrollIntoView({block: "center", behavior: "smooth"})
  preview(element, "pointerenter")
}

// Re-anchor after LiveView patches replace the focused node.
const reanchor = () => {
  if (!state.focused || state.focused.isConnected) return

  const anchor = state.lastRect ? center(state.lastRect) : {x: 0, y: 0}
  state.focused = null

  const nearest = candidates()
    .map(element => {
      const point = center(element.getBoundingClientRect())
      return {element, distance: Math.hypot(point.x - anchor.x, point.y - anchor.y)}
    })
    .sort((left, right) => left.distance - right.distance)[0]

  if (nearest) focusElement(nearest.element)
}

const move = direction => {
  const elements = candidates()
  if (elements.length === 0) return

  if (state.focused && !elements.includes(state.focused)) blurFocused()

  if (
    (!state.focused || !state.focused.isConnected) &&
    elements.includes(document.activeElement)
  ) {
    state.focused = document.activeElement
    state.lastRect = document.activeElement.getBoundingClientRect()
  }

  if (!state.focused || !state.focused.isConnected) {
    focusElement(elements.find(element => element.matches("[data-gamepad-item]")) || elements[0])
    return
  }

  const from = center(state.focused.getBoundingClientRect())
  const vertical = direction === "up" || direction === "down"
  const sign = direction === "down" || direction === "right" ? 1 : -1

  let best = null
  for (const element of elements) {
    if (element === state.focused) continue
    const point = center(element.getBoundingClientRect())
    const primary = (vertical ? point.y - from.y : point.x - from.x) * sign
    if (primary < 5) continue
    const orthogonal = Math.abs(vertical ? point.x - from.x : point.y - from.y)
    const score = primary + orthogonal * 2.5
    if (!best || score < best.score) best = {element, score}
  }

  if (best) {
    focusElement(best.element)
  } else if (vertical) {
    // Nothing further in that direction yet; nudge the page so streamed
    // content (load more) can appear.
    window.scrollBy({top: sign * window.innerHeight * 0.6, behavior: "smooth"})
  }
}

const buttonPressed = button => Boolean(button?.pressed || button?.value > 0.5)

export const directionForPad = pad => {
  const verticalAxis = Math.abs(pad.axes[1] || 0) >= Math.abs(pad.axes[7] || 0) ? pad.axes[1] : pad.axes[7]
  const horizontalAxis =
    Math.abs(pad.axes[0] || 0) >= Math.abs(pad.axes[6] || 0) ? pad.axes[0] : pad.axes[6]

  if (buttonPressed(pad.buttons[12]) || verticalAxis < -STICK_THRESHOLD) return "up"
  if (buttonPressed(pad.buttons[13]) || verticalAxis > STICK_THRESHOLD) return "down"
  if (buttonPressed(pad.buttons[14]) || horizontalAxis < -STICK_THRESHOLD) return "left"
  if (buttonPressed(pad.buttons[15]) || horizontalAxis > STICK_THRESHOLD) return "right"
  return null
}

const pressedOnce = (pad, index) => {
  const pressed = buttonPressed(pad.buttons[index])
  const wasPressed = Boolean(state.buttons[index])
  state.buttons[index] = pressed
  return pressed && !wasPressed
}

const closeActiveDialog = () => {
  const dialog = document.querySelector('[role="dialog"][aria-modal="true"]')
  const close = dialog?.querySelector("[data-dialog-close]")

  if (!close) return false

  close.click()
  return true
}

const poll = () => {
  const pad = [...(navigator.getGamepads?.() || [])].find(entry => entry?.connected)

  if (pad && active()) {
    reanchor()

    const direction = directionForPad(pad)
    const now = performance.now()

    if (direction) {
      const held = state.activeDirection === direction
      const dueAt = held
        ? state.lastMoveAt + (now - state.directionHeldSince > INITIAL_REPEAT_MS ? REPEAT_MS : INITIAL_REPEAT_MS)
        : 0

      if (!held || now >= dueAt) {
        if (!held) state.directionHeldSince = now
        state.inputMode = "gamepad"
        state.activeDirection = direction
        state.lastMoveAt = now
        move(direction)
      }
    } else {
      state.activeDirection = null
      state.directionHeldSince = null
    }

    if (pressedOnce(pad, 0) && state.focused?.isConnected) state.focused.click()

    if (
      pressedOnce(pad, 1) &&
      !closeActiveDialog() &&
      window.location.pathname !== "/library"
    ) {
      window.history.back()
    }

    if (pressedOnce(pad, 4)) window.scrollBy({top: -window.innerHeight * 0.8, behavior: "smooth"})
    if (pressedOnce(pad, 5)) window.scrollBy({top: window.innerHeight * 0.8, behavior: "smooth"})
  } else if (state.focused && state.inputMode === "gamepad") {
    blurFocused()
  }

  if (pad) {
    state.frame = window.requestAnimationFrame(poll)
  } else {
    // Do not keep every phone/desktop tab rendering at 60 fps when no
    // controller exists. Poll slowly so an already-connected Steam Deck pad
    // is still discovered even if the browser omits gamepadconnected.
    state.idleTimer = window.setTimeout(poll, 500)
  }
}

// Steam Input commonly exposes the Deck controls to Chromium as keyboard
// events instead of a Gamepad, particularly for non-HTTPS LAN installations.
export const directionForNavigationKey = key =>
  ({
    ArrowUp: "up",
    ArrowDown: "down",
    ArrowLeft: "left",
    ArrowRight: "right",
  })[key] || null

export const shouldNavigateBackForKey = (key, path, editableFocused) =>
  key === "Backspace" && path !== "/library" && !editableFocused

const handleNavigationKey = event => {
  if (!active() || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return

  const direction = directionForNavigationKey(event.key)

  if (direction) {
    event.preventDefault()
    state.inputMode = "keyboard"
    move(direction)
    return
  }

  if (
    (event.key === "Enter" || event.key === " ") &&
    state.focused?.isConnected &&
    document.activeElement === state.focused
  ) {
    event.preventDefault()
    state.inputMode = "keyboard"
    state.focused.click()
    return
  }

  if (
    shouldNavigateBackForKey(
      event.key,
      window.location.pathname,
      editable(event.target) || editable(document.activeElement),
    )
  ) {
    event.preventDefault()
    window.history.back()
    return
  }

  if (event.key === "PageUp" || event.key === "PageDown") {
    event.preventDefault()
    const sign = event.key === "PageDown" ? 1 : -1
    window.scrollBy({top: sign * window.innerHeight * 0.8, behavior: "smooth"})
  }
}

export const initGamepadNav = () => {
  window.addEventListener("keydown", handleNavigationKey)
  window.addEventListener("focusin", event => {
    if (event.target === state.focused) return
    if (state.inputMode !== "keyboard") return

    blurFocused()
    state.inputMode = null
  })
  window.addEventListener("pointerdown", () => {
    if (state.inputMode !== "keyboard") return
    blurFocused()
    state.inputMode = null
  })

  if (!("getGamepads" in navigator)) {
    console.info("Iri: keyboard-style controller navigation active")
    return
  }

  window.addEventListener("gamepadconnected", () => {
    console.info("Iri: gamepad navigation active")
    window.clearTimeout(state.idleTimer)
    window.cancelAnimationFrame(state.frame)
    state.frame = window.requestAnimationFrame(poll)
  })

  window.addEventListener("gamepaddisconnected", () => {
    blurFocused()
  })

  state.frame = window.requestAnimationFrame(poll)
}
