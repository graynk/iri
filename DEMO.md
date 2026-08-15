# Hosting the read-only demo branch

The `demo` branch is a deployment profile for publishing a representative IRI
snapshot without exposing registration, administration, imports, sync, or data
mutation. Keep demo-specific commits on this branch and merge `main` into it as
the application evolves.

## Safety model

Demo mode uses independent layers so a missed UI condition does not become a
write vulnerability:

1. Docker mounts the SQLite file and media directory read-only and makes the
   container root filesystem read-only.
2. Ecto opens SQLite with `mode: :readonly`; the connection also applies
   `PRAGMA query_only = true` and never tries to change the journal mode.
3. Demo startup omits migrations, the scheduler, sync task supervisor, provider
   workers, token manager, and AI worker.
4. Every browser receives a viewer-scoped identity from the snapshot without a
   database session token. Login, registration, settings, imports, custom-game,
   collection-editing, and administration routes have server-side guards.
5. Read LiveViews accept only an explicit set of navigation and presentation
   events. Mutation controls are removed or disabled for a coherent UI.

The database and read-only filesystem are the final enforcement boundaries.
The route, event, and UI controls make failures early and understandable.

Demo mode protects the snapshot from modification; it does not make its content
safe to publish. The snapshot can contain usernames, provider identities,
personal notes, collection comments, and media. Curate and review all of those
before putting the instance on the public internet. Apply the normal reverse
proxy, TLS, rate-limit, logging, and denial-of-service protections as well.

## Create the snapshot

Start with a normal database that has already been migrated by the same revision
of IRI you plan to deploy. Pass the username whose library, collections, ratings,
tags, and other personal state should become the demo. The source database is
not modified; the retained user is renamed to `demo` with password `demodemo`
in the new snapshot, and every other user is removed.

```sh
scripts/package-demo data/iri.db graynk --exclude demo-exclusions.txt
```

That builds the whole payload: the sanitised snapshot at `demo/iri.db` plus
exactly the cached media that snapshot still references, and nothing else. It
prints the game count, the number of staged files, and the payload size.

`--exclude` takes a file of individual games to drop, one per line, as either a
numeric game id or an exact slug. Blank lines and `#` comments are ignored:

```text
# Adult titles that are not on sale in Germany
boobs-vr-367875
deep-space-waifu-36977
951
```

Exclusion removes that game and its provider sources, so the rest of the same
library is untouched — you can drop three titles and keep the remaining GOG
games. Every entry must match exactly one game or the run aborts, which catches
a typo before it silently publishes something you meant to remove. Sources are
deleted before the game because `game_sources.game_id` is `ON DELETE SET NULL`;
deleting only the game would leave its sources behind as unmatched entries
still showing the title.

Useful options: `--covers-only` stages cover images and lets screenshots fall
back to the provider URL, which is far smaller but leaves collection exports
without covers; `--media` points at a cache other than `data/media`; `--force`
replaces an existing payload directory.

`--prune-media` additionally deletes files from the media directory that the
**source** database no longer references. Run it after `mix iri.prune_orphans`
to reclaim the cache left behind by deleted libraries. It prunes against the
source rather than the snapshot on purpose: the snapshot drops other users'
libraries, and their cached media is still legitimately yours. This deletes
from your real media directory, not from the payload.

Underneath, `scripts/create-demo-snapshot` does the sanitising and applies the
exclusions, so `--exclude` works the same when you run it directly:

```sh
scripts/create-demo-snapshot data/iri.db demo/iri.db graynk --exclude demo-exclusions.txt
```

It can be run on its own. It uses SQLite's online backup command, so committed WAL data is
folded into one self-contained database. It refuses to overwrite an existing
output, checks integrity and foreign keys, removes every browser session token,
deletes other users and their owned provider accounts, switches the copy out of
WAL mode, and marks it read-only. It does not modify the source database.
Public demo requests are automatically scoped to the retained `demo` user and
do not create login sessions.

Removing the other users' accounts leaves their games behind with no library
item pointing at them, so the snapshot then prunes anything unreachable along
with its cached media. Without that step the payload would ship other people's
library content for games the demo cannot even display.

Media is staged as an explicit copy because the database may refer to private
cached images. Anything you leave out falls back to the remote provider URL
where supported.

## Run it

```sh
cp demo.env.example demo.env
openssl rand -base64 48
```

Put the generated value in `demo.env` as `SECRET_KEY_BASE`, set the public host
and scheme, then run:

The read-only demo does not run imports or metadata enrichment, so it does not
need IGDB, Steam, OpenXBL, or AI provider credentials.

```sh
docker compose -f docker-compose.demo.yml up --build -d
```

The Compose file deliberately repeats `INSTANCE_MODE=DEMO` and the snapshot
paths under `environment`; those values override accidental conflicting values
in `demo.env`. The database and media mounts are read-only, and only `/tmp` is
writable inside the container.

At startup IRI requires the fixed `demo` user to exist, forces that in-memory
identity to the viewer role even if the stored user is an administrator, and
compares the snapshot's applied migration versions with the code. A missing user or a
snapshot missing any migration required by the code prevents the endpoint from
starting. Extra historical rows from IRI's squashed migration history are safe
and accepted.

## Deploy to Fly.io

The demo is immutable and read-only, so it does not need a Fly volume. The
Dockerfile's final `demo` stage copies the staged `demo/` directory into the
image at `/srv/demo`, which means the machine has nothing to seed and a refresh
is just another `fly deploy`. Everything runs from your machine; no CI
credentials are involved.

Stage `demo/` as described above, then:

```sh
fly launch --no-deploy --copy-config
fly secrets set SECRET_KEY_BASE="$(openssl rand -base64 48)"
fly deploy
```

`fly launch` will claim an app name; set `app` and `PHX_HOST` in `fly.toml` to
match it before deploying, or share links will point at the wrong hostname.

Image size is the one thing to watch. The snapshot is small, but cached media
is not: covers are on the order of a hundred megabytes while screenshots run to
roughly a gigabyte. Copy only `media/covers` into `demo/media` if you want a
lean image; IRI redirects uncached screenshots to the provider URL, so detail
pages still look complete. Covers are worth baking, because collection exports
embed local cover files and fall back to a letter placeholder without them.

Because the data lives in the image rather than a volume, `auto_stop_machines`
and scaling to zero are safe, and adding a second machine needs no extra work.

## Verify the deployment

Visit `/library`, a game, `/collections`, a collection, and
`/library/statuses`. Confirm the demo banner is visible, exports and browsing
work, and settings/edit/add routes redirect to `/library`.

You can also verify the filesystem boundary directly; this command must fail
with a read-only database error:

```sh
docker compose -f docker-compose.demo.yml exec iri-demo \
  sqlite3 /data/iri.db "UPDATE users SET username = username;"
```

## Refresh after merging `main`

1. Merge `main` into `demo` and resolve only genuine conflicts in the few
   demo-aware policy, auth, router, and presentation files.
2. Run `mix precommit` and build the new image.
3. Migrate the normal source database with that revision.
4. Rebuild the payload with `scripts/package-demo … --force`, keeping the same
   exclusion file so curated removals are reproducible rather than hand-applied.
5. Recreate the container, or run `fly deploy` again if the demo is hosted on
   Fly.

Never point a demo image at a writable production database, even briefly. Demo
startup does not run migrations; its required-migration check is intentionally
strict so a stale snapshot fails closed after schema changes.
