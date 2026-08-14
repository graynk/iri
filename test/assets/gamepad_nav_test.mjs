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

import assert from "node:assert/strict"
import test from "node:test"

import {
  directionForNavigationKey,
  directionForPad,
  shouldNavigateBackForKey,
} from "../../assets/js/gamepad_nav.js"

const pad = ({axes = [], buttons = {}} = {}) => ({
  axes,
  buttons: Array.from({length: 16}, (_, index) => buttons[index] || {pressed: false, value: 0}),
})

test("maps keyboard-style Steam Input directions", () => {
  assert.equal(directionForNavigationKey("ArrowUp"), "up")
  assert.equal(directionForNavigationKey("ArrowDown"), "down")
  assert.equal(directionForNavigationKey("ArrowLeft"), "left")
  assert.equal(directionForNavigationKey("ArrowRight"), "right")
  assert.equal(directionForNavigationKey("Enter"), null)
})

test("reserves escape for dialogs and only maps backspace outside editable controls", () => {
  assert.equal(shouldNavigateBackForKey("Escape", "/games/example", false), false)
  assert.equal(shouldNavigateBackForKey("Backspace", "/games/example", false), true)
  assert.equal(shouldNavigateBackForKey("Backspace", "/games/example", true), false)
  assert.equal(shouldNavigateBackForKey("Backspace", "/library", false), false)
})

test("maps standard d-pad buttons even when only their analog value is set", () => {
  assert.equal(directionForPad(pad({buttons: {12: {pressed: false, value: 1}}})), "up")
  assert.equal(directionForPad(pad({buttons: {15: {pressed: true, value: 1}}})), "right")
})

test("maps primary and alternate Steam Deck stick axes", () => {
  assert.equal(directionForPad(pad({axes: [0, 0.8]})), "down")
  assert.equal(directionForPad(pad({axes: [0, 0, 0, 0, 0, 0, -0.9, 0]})), "left")
  assert.equal(directionForPad(pad({axes: [0, 0, 0, 0, 0, 0, 0, -0.9]})), "up")
  assert.equal(directionForPad(pad()), null)
})
