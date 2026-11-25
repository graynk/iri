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

/*
 * Iri PlayStation collector v5.
 * Paste this entire file into the Console on library.playstation.com. It
 * walks every page of the Played and Purchased sections by itself; wait for
 * "All pages fetched." in the panel, then press Download for IRI.
 */
(() => {
  if (window.IriPSN?._restore) window.IriPSN._restore()

  const storageKey = "iri-psn-capture-v6"
  const originalFetch = window.fetch.bind(window)
  const OriginalXHR = window.XMLHttpRequest
  const text = value => value == null ? null : String(value).trim() || null
  let storageError = null
  const loadSaved = () => {
    try { return JSON.parse(sessionStorage.getItem(storageKey) || "{}") || {} } catch (_) { return {} }
  }
  const saved = loadSaved()
  const savedCaptures = saved.captures || saved
  const captureKey = item => `${item.concept_id || item.title_id || item.product_id}|${String(item.name || "").toLocaleLowerCase()}`
  const seenKeys = {purchased: new Set(), played: new Set()}
  const captures = {purchased: [], played: []}

  // Every DOM scan used to re-push every visible tile, so the capture arrays
  // (and the sessionStorage copy) grew without bound while scrolling. Keep
  // one entry per game instead.
  const addCaptures = (kind, items) => {
    let added = 0
    items.forEach(item => {
      const key = captureKey(item)
      if (seenKeys[kind].has(key)) return
      seenKeys[kind].add(key)
      captures[kind].push(item)
      added += 1
    })
    return added
  }
  ;["purchased", "played"].forEach(kind => {
    if (Array.isArray(savedCaptures[kind])) addCaptures(kind, savedCaptures[kind])
  })
  const pages = {
    purchased: Number(saved.pages?.purchased || 0),
    played: Number(saved.pages?.played || 0)
  }
  let account = saved.account || null

  const normalize = item => ({
    concept_id: text(item.conceptId || item.concept_id || item.concept?.id),
    title_id: text(item.titleId || item.title_id || item.npTitleId || item.np_communication_id),
    product_id: text(item.productId || item.product_id || item.entitlementId),
    name: text(item.name || item.titleName || item.title || item.localizedName || item.displayName || item.concept?.name),
    platform: item.platform || item.platforms || item.device || item.devices,
    last_played_at: item.lastPlayedDateTime || item.last_played_at || item.lastPlayedAt,
    progress: item.progress,
    membership: item.membership || item.entitlementType || item.serviceName
  })

  // Media products (artbooks, sketchbooks, soundtracks, themes, avatars) and
  // demo builds share the library pages with games but keep a stable trailing
  // marker in their names, even on non-English storefronts.
  const nonGameName = /[\s(\[–—:-](?:demo(?:version)?|trial|testversion|soundtrack|sketchbook|skizzenbuch|art ?book|kunstbuch|theme|thema|avatar|wallpapers?|hintergr(?:und|ünde))[)\]]?$/iu
  const isGameName = name => Boolean(name) && !nonGameName.test(name.trim())

  const looksLikeGame = item => {
    if (!item || typeof item !== "object" || Array.isArray(item)) return false
    const game = normalize(item)
    const gameShape =
      "conceptId" in item || "concept_id" in item || "titleId" in item || "title_id" in item ||
      "productId" in item || "product_id" in item || "entitlementId" in item ||
      "lastPlayedDateTime" in item || "subscriptionService" in item
    return Boolean(gameShape && game.name && (game.concept_id || game.title_id || game.product_id))
  }

  const accountFrom = body => {
    const queue = [{value: body, depth: 0}]
    const seen = new Set()

    while (queue.length) {
      const {value, depth} = queue.shift()
      if (!value || typeof value !== "object" || seen.has(value) || depth > 7) continue
      seen.add(value)

      if (!Array.isArray(value)) {
        const onlineId = text(value.onlineId || value.online_id)
        const accountId = text(value.accountId || value.account_id)
        if (onlineId) return {id: accountId || onlineId.toLocaleLowerCase(), online_id: onlineId}
        Object.values(value).forEach(child => queue.push({value: child, depth: depth + 1}))
      } else {
        value.forEach(child => queue.push({value: child, depth: depth + 1}))
      }
    }

    return null
  }

  const captureAccount = body => {
    const found = accountFrom(body)
    if (found) account = found
    return found
  }

  const captureAccountFromDOM = () => {
    if (account) return account

    const image = [...document.querySelectorAll("header img[alt], nav img[alt], [role='banner'] img[alt]")]
      .find(candidate => {
        const name = text(candidate.getAttribute("alt"))
        const source = String(candidate.currentSrc || candidate.src || "").toLowerCase()
        const rect = candidate.getBoundingClientRect()
        const square = rect.width > 20 && rect.height > 20 && Math.abs(rect.width - rect.height) < 8

        return name && square && !/playstation|sony|logo|loading|laden/i.test(name) &&
          !/logo|wordmark/.test(source)
      })

    const onlineId = text(image?.getAttribute("alt"))
    if (onlineId) account = {id: onlineId.toLocaleLowerCase(), online_id: onlineId}
    return account
  }

  const findItems = body => {
    const apolloRoot = body?.props?.apolloState?.ROOT_QUERY
    const apolloState = body?.props?.apolloState || {}
    const apolloGames = apolloRoot && Object.entries(apolloRoot)
      .find(([key, value]) =>
        /(?:gameLibrary|purchased)TitlesRetrieve/i.test(key) && Array.isArray(value?.games)
      )?.[1]?.games
      ?.map(game => game?.__ref ? apolloState[game.__ref] || game : game)

    if (Array.isArray(apolloGames) && apolloGames.some(looksLikeGame)) return apolloGames

    const known = [
      body?.items,
      body?.titles,
      body?.games,
      body?.data?.items,
      body?.data?.titles,
      body?.data?.games,
      body?.data?.gameLibraryTitlesRetrieve?.games,
      body?.data?.purchasedGameList?.games,
      body?.data?.titleHistory?.titles
    ].find(items => Array.isArray(items) && items.some(looksLikeGame))
    if (known) return known

    const queue = [{value: body, depth: 0}]
    const seen = new Set()
    while (queue.length) {
      const {value, depth} = queue.shift()
      if (!value || typeof value !== "object" || seen.has(value) || depth > 6) continue
      seen.add(value)
      if (Array.isArray(value) && value.some(looksLikeGame)) return value
      if (!Array.isArray(value)) {
        Object.values(value).forEach(child => queue.push({value: child, depth: depth + 1}))
      }
    }
    return []
  }

  const kindFrom = (hint, body) => {
    // The library site names its queries precisely: purchasedTitlesRetrieve is
    // the purchase list, gameLibraryTitlesRetrieve is the played list. Prefer
    // those names (present in both GraphQL responses and the embedded Next.js
    // cache) over the page URL, which goes stale on in-page navigation.
    const collection = text(body?.props?.pageProps?.collection || body?.pageProps?.collection)
    if (collection === "recently-purchased") return "purchased"
    if (collection === "recently-played") return "played"

    const apolloKeys = Object.keys(body?.props?.apolloState?.ROOT_QUERY || {}).join(" ")
    if (/purchasedTitlesRetrieve/i.test(apolloKeys)) return "purchased"
    if (/gameLibraryTitlesRetrieve/i.test(apolloKeys)) return "played"

    const shape = body ? JSON.stringify(body).slice(0, 60000).toLowerCase() : ""
    if (/purchasedtitlesretrieve/.test(shape)) return "purchased"
    if (/gamelibrarytitlesretrieve|lastplayeddatetime/.test(shape)) return "played"

    const request = String(hint || "").toLowerCase()
    if (/\/recently-played(?:[/?#]|$)/.test(request)) return "played"
    if (/\/recently-purchased(?:[/?#]|$)/.test(request)) return "purchased"

    const value = `${request} ${shape}`
    if (/recently.?played|title.?history|last.?played/.test(value)) return "played"
    if (/recently.?purchased|purchased|entitlement/.test(value)) return "purchased"
    return null
  }

  const persist = () => {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify({captures, pages, account}))
      storageError = null
    } catch (error) {
      // Quota or privacy settings: keep collecting in memory, just warn.
      storageError = error
      console.warn("IriPSN could not save to sessionStorage, keeping data in memory only", error)
    }
    updatePanel()
  }

  const capture = (hint, body) => {
    captureAccount(body)
    const kind = kindFrom(hint, body)
    const items = findItems(body)
      .map(normalize)
      .filter(item => isGameName(item.name) && (item.concept_id || item.title_id || item.product_id))
    if (!kind || items.length === 0) return 0

    const added = addCaptures(kind, items)
    if (added === 0) return 0
    pages[kind] += 1
    persist()
    console.info(`IriPSN captured ${added} new ${kind} games`)
    return added
  }

  const stableTitleId = name => {
    let hash = 2166136261
    for (const char of name.toLocaleLowerCase()) {
      hash ^= char.codePointAt(0)
      hash = Math.imul(hash, 16777619)
    }
    return `dom-${(hash >>> 0).toString(16)}`
  }

  const idFromHref = href => {
    const value = String(href || "")
    const concept = value.match(/\/concept\/([^/?#]+)/i)
    if (concept) return {concept_id: decodeURIComponent(concept[1]), title_id: null}
    const product = value.match(/\/product\/([^/?#]+)/i)
    if (product) return {concept_id: null, title_id: decodeURIComponent(product[1])}
    return {concept_id: null, title_id: null}
  }

  const domItem = (element, fallbackImage = null) => {
    const image = fallbackImage || element.querySelector?.("img[alt]")
    if (image?.closest("header, nav, [role='banner']")) return null

    const name = text(
      image?.getAttribute("alt") ||
      element.getAttribute?.("aria-label") ||
      element.getAttribute?.("title")
    )
    // Loading placeholders carry localized alt text ending in an ellipsis
    // ("Inhalt wird geladen ...") before the real cover art hydrates.
    if (!isGameName(name) || /(?:\.{3}|…)$/.test(name)) return null

    const href = element.closest?.("a[href]")?.href || element.href
    const ids = idFromHref(href)
    const container = element.closest?.("[data-concept-id], [data-conceptid], [data-product-id], [data-title-id]")
    ids.concept_id ||= text(container?.getAttribute("data-concept-id") || container?.getAttribute("data-conceptid"))
    ids.title_id ||= text(container?.getAttribute("data-product-id") || container?.getAttribute("data-title-id"))
    ids.title_id ||= stableTitleId(name)

    return {concept_id: ids.concept_id, title_id: ids.title_id, name, platform: null}
  }

  const scanDOM = () => {
    const kind = kindFrom(window.location.href, {})
    if (!kind) return 0

    captureAccountFromDOM()

    const found = []

    document.querySelectorAll("a[href*='/concept/'], a[href*='/product/']")
      .forEach(link => {
        const item = domItem(link)
        if (item) found.push(item)
      })

    document.querySelectorAll("img[alt]")
      .forEach(image => {
        const source = String(image.currentSrc || image.src || "").toLowerCase()
        if (!source.includes("playstation") && !source.includes("psnobj")) return
        if (/loading|placeholder|spinner|defaultavatar/.test(source)) return
        // Covers are portrait tiles. This excludes profile avatars and most UI
        // artwork even if their CDN URL resembles a game image.
        const rect = image.getBoundingClientRect()
        const width = rect.width || image.naturalWidth
        const height = rect.height || image.naturalHeight
        if (width > 0 && width < 56) return
        if (width > 0 && height > 0 && height / width < 1.12) return
        const item = domItem(image.closest("a, article, li, button, div") || image, image)
        if (item) found.push(item)
      })

    const added = addCaptures(kind, found)
    if (found.length > 0) pages[kind] = Math.max(pages[kind], 1)
    if (added > 0) persist()
    return added
  }

  const scanEmbeddedJSON = (root = document, hint = "") => {
    let added = 0
    root.querySelectorAll("script[type='application/json']").forEach(script => {
      // No URL hint: the embedded cache keeps the data of the page that was
      // first loaded, not the section currently shown, so only the payload's
      // own query names can classify it safely.
      try { added += capture(hint, JSON.parse(script.textContent)) } catch (_) {}
    })
    return added
  }

  // Apollo can retain its original fetch function before a pasted script has
  // a chance to wrap it. Each library document also embeds its first result
  // page in __NEXT_DATA__, so read both same-origin documents directly. This
  // makes the initial Played and Purchased captures independent of timing and
  // of the language or markup used for the visible cards.
  const pageInfoFrom = body => {
    const root = body?.props?.apolloState?.ROOT_QUERY || {}
    const info = Object.entries(root)
      .find(([key]) => /(?:gameLibrary|purchased)TitlesRetrieve/i.test(key))?.[1]?.pageInfo
    return info?.__ref ? body.props.apolloState[info.__ref] || null : info || null
  }

  // Fetch one server-rendered library page and report what it held.
  const snapshotPage = async path => {
    const response = await originalFetch(path, {
      credentials: "include",
      cache: "no-store",
      headers: {accept: "text/html"}
    })
    const result = {path, status: response.status, raw: 0, added: 0, pageInfo: null}
    if (!response.ok) return result

    const html = await response.text()
    const snapshot = new DOMParser().parseFromString(html, "text/html")
    snapshot.querySelectorAll("script[type='application/json']").forEach(script => {
      try {
        const body = JSON.parse(script.textContent)
        result.raw += findItems(body).length
        result.added += capture(path, body)
        result.pageInfo ||= pageInfoFrom(body)
      } catch (_) {}
    })
    return result
  }

  const captureLibrarySnapshot = async path => (await snapshotPage(path)).added

  // The library is paginated by path (/recently-purchased/3), and each page
  // is server-rendered with its games in __NEXT_DATA__.
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
  let crawling = false
  let crawlInfo = ""

  // Walk /section/1, /section/2, … using the page's own pageInfo
  // (offset, size, totalCount, isLast) to know when to stop. Pages that
  // bring only already-known games are fine; failures are retried.
  const crawlLog = []

  const crawlSection = async section => {
    let totalPages = null
    for (let page = 1; page <= 300; page++) {
      crawlInfo = `Fetching ${section} page ${page}${totalPages ? `/${totalPages}` : ""}…`
      updatePanel()

      let result = null
      for (let attempt = 1; attempt <= 4; attempt++) {
        try { result = await snapshotPage(`/${section}/${page}`) } catch (error) {
          result = {path: `/${section}/${page}`, status: `error: ${error.message}`, raw: 0, added: 0, pageInfo: null}
        }
        if (result.status === 200 && result.raw > 0) break
        await sleep(1500 * attempt)
      }

      const info = result.pageInfo
      if (info?.totalCount && info?.size) totalPages = Math.ceil(info.totalCount / info.size)
      crawlLog.push({
        page: result.path, status: result.status, games: result.raw, new: result.added,
        offset: info?.offset, total: info?.totalCount, isLast: info?.isLast
      })

      if (result.status !== 200 || result.raw === 0) {
        console.warn(`IriPSN stopped ${section} at page ${page}`, result)
        break
      }
      if (info?.isLast === true) break
      if (info && Number(info.offset) + Number(info.size) >= Number(info.totalCount)) break
      if (totalPages && page >= totalPages) break
      await sleep(500)
    }
  }

  const fetchAllPages = async () => {
    if (crawling) return
    crawling = true
    crawlLog.length = 0
    try {
      await captureLibrarySnapshot("/recently-played")
      await captureLibrarySnapshot("/recently-purchased")
      await crawlSection("recently-purchased")
      await crawlSection("recently-played")
      crawlInfo = "All pages fetched."
    } catch (error) {
      crawlInfo = `Page fetch failed: ${error.message}`
      console.warn("IriPSN page fetch failed", error)
    } finally {
      crawling = false
      persist()
      console.table(crawlLog)
      console.table({purchased: unique("purchased").length, played: unique("played").length})
    }
  }

  const requestHint = (input, init = {}) => {
    const url = typeof input === "string" ? input : input?.url
    return `${url || ""} ${typeof init.body === "string" ? init.body : ""}`
  }

  window.fetch = async (...args) => {
    const response = await originalFetch(...args)
    const hint = requestHint(args[0], args[1])
    response.clone().json().then(body => capture(hint, body)).catch(() => {})
    return response
  }

  class CollectorXHR extends OriginalXHR {
    open(method, url, ...rest) {
      this._iriHint = `${method || ""} ${url || ""}`
      return super.open(method, url, ...rest)
    }

    send(body) {
      if (typeof body === "string") this._iriHint += ` ${body}`
      this.addEventListener("load", () => {
        try {
          const response = typeof this.response === "object" && this.response !== null
            ? this.response
            : JSON.parse(this.responseText)
          capture(this._iriHint, response)
        } catch (_) {}
      })
      return super.send(body)
    }
  }
  window.XMLHttpRequest = CollectorXHR

  const idRank = item =>
    item.concept_id ? 2 : (item.title_id && !String(item.title_id).startsWith("dom-")) || item.product_id ? 1 : 0

  const unique = kind => {
    const byId = new Map()
    captures[kind]
      .filter(item => isGameName(item.name))
      .forEach(item => byId.set(item.concept_id || item.title_id || item.product_id, item))

    // The same tile can be seen with a real ID (network) and a synthetic
    // dom- ID (page scan); keep the best-identified capture per title.
    const byName = new Map()
    byId.forEach(item => {
      const key = String(item.name).toLocaleLowerCase()
      const existing = byName.get(key)
      if (!existing || idRank(item) > idRank(existing)) byName.set(key, item)
    })
    return [...byName.values()]
  }

  const status = () => {
    scanDOM()
    scanEmbeddedJSON()
    const result = {
      purchased: unique("purchased").length,
      played: unique("played").length,
      purchased_responses: pages.purchased,
      played_responses: pages.played
    }
    console.table(result)
    return result
  }

  const download = () => {
    const datasets = ["purchased", "played"]
      .map(kind => ({
        kind,
        complete: false,
        pagination: {pages_observed: pages[kind], final: false},
        items: unique(kind)
      }))
      .filter(dataset => dataset.items.length > 0)

    if (datasets.length === 0) {
      throw new Error("No games captured yet. Visit Played and Purchased, then scroll each list.")
    }
    if (!account) {
      throw new Error("Could not identify the signed-in PSN account. Reload the page, paste the collector again, and wait a moment.")
    }

    const payload = {schema: "iri-psn-export/v3", account, datasets}
    const blob = new Blob([JSON.stringify(payload, null, 2)], {type: "application/json"})
    const link = document.createElement("a")
    link.href = URL.createObjectURL(blob)
    link.download = "iri-psn-games.json"
    link.style.display = "none"
    // Firefox is more reliable with an attached anchor, and revoking the blob
    // after 1 s can break the download while its save dialog is still open.
    document.body.appendChild(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(link.href), 60000)
  }

  const reset = () => {
    captures.purchased.length = 0
    captures.played.length = 0
    seenKeys.purchased.clear()
    seenKeys.played.clear()
    pages.purchased = 0
    pages.played = 0
    persist()
    return status()
  }

  // Floating status panel so nobody has to drive the collector from the
  // console: live counts plus Download and Reset.
  let panel = null

  const buildPanel = () => {
    if (panel || !document.body) return

    panel = document.createElement("div")
    panel.id = "iri-psn-panel"
    panel.style.cssText =
      "position:fixed;right:16px;bottom:16px;z-index:2147483647;background:#0f172a;color:#e2e8f0;" +
      "border:1px solid #334155;border-radius:12px;padding:12px 14px;font:13px/1.5 system-ui,sans-serif;" +
      "box-shadow:0 8px 30px rgba(0,0,0,.5);min-width:220px"

    const counts = document.createElement("div")
    counts.setAttribute("data-iri-counts", "")
    counts.style.cssText = "white-space:pre;margin-bottom:10px"

    const buttonStyle =
      "border:0;border-radius:8px;padding:7px 12px;font:600 12px system-ui,sans-serif;cursor:pointer;"

    const downloadButton = document.createElement("button")
    downloadButton.textContent = "Download for IRI"
    downloadButton.style.cssText = buttonStyle + "background:#5eead4;color:#0f172a;margin-right:8px"
    downloadButton.addEventListener("click", () => {
      try { download() } catch (error) { alert(error.message) }
    })

    const resetButton = document.createElement("button")
    resetButton.textContent = "Reset"
    resetButton.style.cssText = buttonStyle + "background:#334155;color:#e2e8f0"
    resetButton.addEventListener("click", reset)

    const fetchButton = document.createElement("button")
    fetchButton.textContent = "Fetch all pages"
    fetchButton.style.cssText = buttonStyle + "background:#334155;color:#e2e8f0;margin-right:8px"
    fetchButton.addEventListener("click", fetchAllPages)

    panel.append(counts, downloadButton, fetchButton, resetButton)
    document.body.appendChild(panel)
    updatePanel()
  }

  const updatePanel = () => {
    const counts = panel?.querySelector("[data-iri-counts]")
    if (!counts) return
    counts.textContent =
      `IRI PSN collector${account?.online_id ? ` - ${account.online_id}` : ""}\n` +
      `Purchased: ${unique("purchased").length}\nPlayed: ${unique("played").length}\n` +
      (crawlInfo || "Fetching all pages…") +
      (storageError ? "\n⚠ Not saved across reloads (storage error)" : "")
  }

  let scanTimer = null
  const observer = new MutationObserver(() => {
    clearTimeout(scanTimer)
    scanTimer = setTimeout(scanDOM, 150)
  })
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["src", "srcset", "alt", "aria-label", "href"]
  })
  buildPanel()
  scanDOM()
  scanEmbeddedJSON()
  fetchAllPages()
  originalFetch("https://web.np.playstation.com/api/basicProfile/v1/profile/users/me", {
    credentials: "include",
    headers: {accept: "application/json"}
  })
    .then(response => response.ok ? response.json() : null)
    .then(body => {
      if (body && captureAccount(body)) persist()
    })
    .catch(() => {})

  // Manual fallback when neither the page data nor the avatar reveals the
  // signed-in account (the profile API call is often refused with a 403).
  const setAccount = onlineId => {
    const name = text(onlineId)
    if (!name) throw new Error("Usage: IriPSN.setAccount(\"YourPSNOnlineId\")")
    account = {id: name.toLocaleLowerCase(), online_id: name}
    persist()
    return account
  }

  window.IriPSN = {
    status,
    download,
    reset,
    fetchAllPages,
    setAccount,
    account: () => account,
    _restore: () => {
      observer.disconnect()
      clearTimeout(scanTimer)
      panel?.remove()
      panel = null
      window.fetch = originalFetch
      window.XMLHttpRequest = OriginalXHR
    }
  }

  console.info("IriPSN is fetching every Played and Purchased page. Wait for \"All pages fetched.\" in the panel, then press Download for IRI.")
  status()
})()
