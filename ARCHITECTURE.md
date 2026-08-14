# IRI architecture

IRI is a self-hosted Phoenix/LiveView application for bringing several game
libraries into one browsable catalog. The application is deliberately a
single-node system: it stores durable state in SQLite, runs work in supervised
processes, and uses provider APIs or user-supplied snapshots to populate the
library.

This document is a map of the codebase. Start with the route that serves the
screen you are investigating, follow it to its context module, then follow the
context to a schema or integration adapter.

## The vocabulary

These relationships are the most important mental model:

```text
ProviderAccount --< LibraryItem >-- GameSource --0..1--> Game
                                              |
                                              `--< MatchCandidate

User --< UserGameState >-- Game
User --< Collection --< CollectionGame >-- Game
```

- `ProviderAccount` is one external identity/library: a Steam profile, public
  GOG profile, Xbox identity, or a manually imported Epic/PSN/custom library.
  It has an owner and sharing policy.
- `GameSource` is a provider-specific title (`steam:620`, an Epic catalog ID,
  etc.). It may be unmatched, in which case `game_id` is `NULL`; that is a
  supported, visible state rather than corrupt data.
- `LibraryItem` says that a provider account owns, played, or manually added a
  particular source. Playtime and visibility are kept here because they are
  account-specific.
- `Game` is the canonical, shared metadata record. IGDB or VNDB matching may
  attach several sources to it. Descriptions, media, taxonomy, companies, and
  catalogue rating belong here.
- Sources and games live only as long as some library item reaches them.
  Deleting a provider account prunes whatever is left unreferenced, and the
  database cascades that to media, personal state, collection entries, and
  matching history. A game another account still owns is untouched.
  `mix iri.prune_orphans` cleans up residue left by earlier versions.
- `UserGameState` and collections are always per IRI user, even when the game
  was made visible through someone else's shared library.

The baseline schema is in
[`priv/repo/migrations/20260716192403_create_iri_v1_baseline.exs`](priv/repo/migrations/20260716192403_create_iri_v1_baseline.exs).
It is the schema shipped by the first public release. From that release onward,
committed migrations are an immutable upgrade path: make schema changes in new
migrations instead of editing or collapsing the baseline.

## Runtime entrypoints

| Entry point | What it starts or serves |
| --- | --- |
| `mix phx.server` | Development endpoint. Migrations are not run automatically. |
| `bin/iri start` / Docker image | Release startup. `Iri.Application` runs pending migrations before the endpoint. |
| `Iri.Application` | Repo, migrator, PubSub, task supervisor, provider rate limiters, IGDB token manager, optional AI worker, optional scheduler, then Phoenix. |
| `IriWeb.Endpoint` | Bandit/Phoenix HTTP endpoint, LiveView websocket, static assets, service worker, and PWA manifest. |

`config/runtime.exs` is the source of production environment configuration.
It enables the scheduler in production, reads secrets from the environment,
and chooses the database/media paths. `config/config.exs` holds the deliberate
SQLite defaults (WAL, a five-connection pool, and busy timeout); they are
operator-independent application defaults, not runtime knobs.

Publishing a GitHub release runs
`.github/workflows/publish-container.yml`, which produces two artifacts. It
builds the Dockerfile for AMD64 and publishes `ghcr.io/graynk/iri` with the
release tag, semantic version aliases, and `latest` for non-prerelease
releases. It also builds a plain Mix release and attaches
`iri-<tag>-linux-x86_64.tar.gz` and its SHA-256 checksum to the release for
operators who do not want Docker. The published image, the tarball, and a local
Docker build all use the same release startup path.

The tarball is a native build: it is glibc Linux x86_64 only, and it carries
the ERTS from the Elixir and OTP versions pinned in the workflow. It is not
portable to musl distributions or to ARM machines, which is why the container
image remains the recommended path.

After the first successful publish, an owner must change the package visibility
to **Public** in GitHub's package settings and verify an anonymous pull; a newly
created GHCR package may otherwise remain private even when its repository is
public.

## HTTP and LiveView surface

[`lib/iri_web/router.ex`](lib/iri_web/router.ex) is the complete route table.
The browser pipeline establishes `@current_scope` via `IriWeb.UserAuth` and
assigns the cookie-selected theme via `IriWeb.Theme`.

| Access | Endpoint or route family | Code |
| --- | --- | --- |
| Public | `GET /health` | `HealthController`; checks the endpoint and SQLite without session work. |
| Public | `GET /` | Redirects to `/library`. |
| Public | `GET /media/:id` | `MediaController`; serves a safe local file or redirects to a validated provider URL. |
| Optional login | `/users/register`, `/users/log-in` | `UserLive.Registration`, `UserLive.Login`. |
| Optional login | `/collections/shared?share_token=…` | `CollectionLive.Shared`; a read-only capability link, not an account-based share. |
| Authenticated | `/library`, `/games/:slug`, `/companies/:id` | `LibraryLive`, `GameLive`, `CompanyLive`. |
| Authenticated | `/collections…` | Collection index, form, show, editor, and export controllers. |
| Authenticated | `/settings/integrations…` | Provider connection plus Epic and PSN snapshot import pages. |
| Administrator | `/settings/accounts`, `/settings/sync`, `/settings/matches…` | Account administration, durable-run status, and catalog matching. |

All authenticated LiveViews are inside the router's existing
`live_session :require_authenticated_user`; administrator pages additionally
use `live_session :require_admin_user`. The distinction matters: context
functions receive `Iri.Accounts.Scope`, not a bare user, and must apply the
same visibility boundary as the route.

## Where functionality lives

### Accounts, visibility, and privacy

- `Iri.Accounts` owns registration, password/session tokens, Steam identity
  linking, and user preferences. Phoenix still owns the signed browser cookie;
  the cookie's random session token is tracked in `users_tokens` so IRI can
  expire and revoke authenticated logins.
- `Iri.InstancePolicy` translates `LIBRARY_MODE` into Family or Public
  defaults. A provider account's explicit policy can still override that
  default.
- `Iri.Integrations` owns provider-account creation, connection validation,
  ownership, and sharing/follower links.
- `Iri.Library.Access` is the central query-level access control helper. Use
  `Access.account_ids/1` or `Access.game_ids/1` for new visibility-sensitive
  queries instead of re-creating the sharing joins.
- `Iri.Library.Personalization` owns completion state, ratings, and notes.
  `Iri.Library.Playtime` deliberately filters playtime to the viewer's own
  account identities, never a family member's hours.
- `Iri.Media.Policy` resolves the user/server NSFW policy before a template or
  media controller exposes an asset.

### Library browsing and game pages

- `Iri.Library` is the read-side facade for the library list, filters, tags,
  game detail loading, and administrator sensitive-media overrides.
- `IriWeb.LibraryLive` is the paginated filter/search interface. Its small
  helpers live under `lib/iri_web/live/library_live/`.
- `IriWeb.GameLive` owns the canonical-game page state and events;
  `IriWeb.GameLive.Detail` renders its personal controls, metadata, media,
  collection picker, and “Fix match” interface.
- `Iri.Library.TaxonomyTerm` normalizes provider labels for deduplication.
  The Tags UI intentionally combines `keyword` and `player_perspective` terms;
  genres, themes, game modes, and tags use AND semantics within their own
  selected group.

### Provider ingestion and metadata

`Iri.Integrations.Provider` is the common ownership-adapter contract. Provider
code lives below `lib/iri/integrations/`:

| Provider | Ingestion path | Notes |
| --- | --- | --- |
| Steam | `Steam.Client` → `Steam.Reconciler` | Public Web API ownership and personal playtime; optional store compatibility refresh. |
| GOG | `GOG.Client` → `GOG.Reconciler` | Public profile pages; no GOG credential is retained. |
| Xbox | `Xbox.Client` → `Snapshot` | OpenXBL title history is treated as played history, not proof of ownership. |
| Epic | `Epic.LegendaryParser` → `Snapshot` | User uploads `legendary list --json`; no Epic session enters IRI. |
| PSN | `PSN.Parser` → `Snapshot` | User runs the bundled browser collector and uploads its output; no Sony cookie enters IRI. |
| Custom | `Custom` → IGDB | A user selects or batch-adds canonical IGDB records into a private custom account. |

`Iri.Integrations.Snapshot` projects manual/partial imports into the shared
`GameSource`/`LibraryItem` model. For complete snapshots it retires entries
absent from the snapshot; for partial history it must not infer removal.

`Iri.Integrations.IGDB.Enricher` performs the canonicalization pipeline:

```text
owned unmatched source
  → exact provider external-ID lookup in IGDB
  → conservative normalized-title fallback
  → exact VNDB store-link fallback for Steam/GOG
  → canonical Game + time-to-beat + taxonomy + companies + MediaAsset rows
  → unresolved sources stay unmatched for review
```

`Iri.Matches` is the administrator path for unresolved sources. It stores
candidate snapshots and applies audited, manually locked decisions through
`Iri.Matches.Decisions`. A match can always be reopened later.

### Media

`Iri.Media` caches covers by default. Screenshots remain remote unless
`DOWNLOAD_SCREENSHOTS=true`; metadata refreshes then cache pending screenshots
in bounded concurrent batches. The media controller prefers a verified local
file, otherwise redirects to an allow-listed IGDB or VNDB URL. The scheduled
monthly maintenance task repairs stale database references and deletes only
unreferenced files below `MEDIA_ROOT`.

### Collections and exports

`Iri.Collections` is the scoped collection facade. `CollectionGame.position`
is the source of truth for custom order; `Iri.Collections.Ordering` maintains
dense positions during moves/removals. The collection-level sort preference was
intentionally removed: collection order is the default, while alternate sorts
are request-local.

Private collections can generate a signed `share_token`. The shared route is a
read-only capability link and sends no-referrer, no-store, and noindex headers.
Revoking sharing increments the share version, invalidating every old token.

`CollectionExportController` produces CSV, text, and a zip. The zip is built
by `Iri.Collections.StaticExport` as a self-contained site with its own theme
switcher and CSS, so it can be opened without a running IRI server.

### Synchronization and scheduled work

`Iri.Sync` is the only facade UI code should use to begin provider imports,
metadata enrichment, or Steam compatibility refreshes. It creates a durable
`SyncRun`, starts a supervised task, records safe diagnostics, and broadcasts
updates on `sync:runs`.

`Iri.Sync.Scheduler` runs only in production. Its `ScheduledTask` rows and
SQLite leases provide recovery across process restarts:

- nightly: enabled Steam/GOG/Xbox libraries, pending metadata, compatibility;
- weekly: forced metadata and compatibility refresh;
- monthly: media-cache maintenance;
- on demand: coalesced pending-library enrichment requested by imports/UI.

The scheduler delegates actual work back through `Iri.Sync`, rather than owning
a second import implementation. If a worker lease expires, the run/task is
marked failed and is retried with backoff on a later tick.

### Optional AI matching

`Iri.AI` stores work in `ai_match_reviews`; `Iri.AI.Worker` claims one durable
review at a time. The model only receives a cleaned source title, bounded
candidate snapshot, and follow-up search feedback. It cannot invent catalog
IDs: a selected candidate key must have been returned by IGDB or VNDB.

The AI pipeline is:

```text
administrator queues unresolved sources
  → CandidateBuilder builds a sanitized request
  → provider adapter (OpenAI, Anthropic, compatible endpoint)
  → DecisionSchema validates exact JSON shape and candidate keys
  → optional corrected catalog search (bounded)
  → auto applies valid match/rejection, or review retains it for an admin
  → Matches.Decisions records the audit trail
```

Provider credentials are environment-only. `Iri.Security.Redactor` is used
before provider or task failures are stored or surfaced.
AI requests have a fixed 500-call UTC-day safety limit to contain accidental
costs; it is deliberately not exposed as another deployment setting.

## Frontend and theme system

- `assets/js/app.js` starts LiveView and imports `gamepad_nav.js`.
- `assets/css/app.css` defines the Noto Sans font, theme tokens, and the dark,
  light, Vapor, and intentionally retained “AI Slop” themes.
- `IriWeb.Theme` persists the selected normal-app theme in the `iri-theme`
  cookie. The layout applies it to HTML and the browser chrome color.
- `priv/static/manifest.webmanifest`, `service-worker.js`, and the IRI icon
  assets provide the installable PWA shell. It still requires a live server;
  it is not an offline game catalogue.
- Static exports are separately styled because they cannot depend on Phoenix
  assets. When changing a global theme concept, check both `assets/css/app.css`
  and `Iri.Collections.StaticExport`.

## Deliberate trade-offs and things to watch

1. **One SQLite writer.** WAL and `Iri.Repo.transact_with_busy_retry/2` make
   the self-hosted workload pleasant, but this is not a multi-node database
   deployment. Run one application instance against a database file and avoid
   out-of-band writers.

2. **Canonical metadata is shared; ownership is not.** A private provider
   library may cause metadata for a `Game` to be available internally, but all
   browsing queries must still begin from accessible `LibraryItem` rows.

3. **Unmatched is first-class.** Do not turn `GameSource.game_id == nil` into a
   generic error. It is how store-only games, uncertain matches, and the admin
   queue are represented.

4. **Provider snapshots have different truth guarantees.** Steam/GOG complete
   imports may retire missing items. Xbox history and manual uploads cannot
   necessarily prove absence; use `Snapshot`'s `complete?` semantics correctly.

5. **The static export has intentional duplication.** It embeds CSS, JS, and
   theme definitions so the export remains portable. This makes it easy for
   app and export styling to drift; inspect both when changing common UI
   behavior.

6. **PWA installation is a shell, not an offline mode.** Service-worker and
   manifest changes need testing on iOS/Safari as well as Chromium. Reinstall
   after changing iOS icon metadata because Safari snapshots it aggressively.

7. **AI is constrained assistance, not a catalog authority.** Deterministic
   matching comes first; the model can reason about aliases and editions but
   must pick a verified candidate or make a bounded search request.

8. **Public collection links are secrets.** The signed token is intentionally
   query-based so it remains revocable and does not need a public database
   identifier. Do not log it, include it in telemetry, or turn it into a
   cacheable page.

## How to investigate a behavior

1. Find the route in `IriWeb.Router`.
2. Read the named controller or LiveView's `mount`, `handle_params`, and event
   handlers.
3. Follow its context call (`Iri.Library`, `Iri.Collections`, `Iri.Sync`,
   `Iri.Matches`, etc.). Context module docs describe their public entrypoints.
4. Follow the context aliases into schemas or integration adapters.
5. Use the corresponding test directory as executable behavior documentation:
   `test/iri/` for domain/integration code and `test/iri_web/` for controllers,
   LiveViews, PWA assets, and presentation behavior.

Run `mix precommit` before handing off a change. It formats source, checks the
frontend helpers, and executes the full test suite.
