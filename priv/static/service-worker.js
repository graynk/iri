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

const CACHE = "iri-static-v6"
const STATIC = [
  "/apple-touch-icon.png",
  "/images/iri-icon-180.png",
  "/images/iri-icon-192.png",
  "/images/iri-icon-512.png",
  "/images/iri-icon.svg"
]

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(STATIC)))
  self.skipWaiting()
})

self.addEventListener("activate", event => {
  event.waitUntil(
    caches
      .keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", event => {
  const url = new URL(event.request.url)
  if (event.request.method !== "GET" || url.origin !== self.location.origin || !STATIC.includes(url.pathname)) return
  event.respondWith(caches.match(event.request).then(cached => cached || fetch(event.request)))
})
