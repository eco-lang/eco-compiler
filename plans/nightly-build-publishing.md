# Plan: Nightly builds and release promotion

## Goal

Turn the per-platform `-aot` build outputs into something the public can
download and run, in two tiers:

1. **Nightly** — a single, always-current pre-release that anyone can download
   anonymously, refreshed automatically each day from the latest green
   per-platform builds.
2. **Stable** — a promotion path where pushing a version tag (`v0.1.0`) cuts a
   permanent, non-prerelease GitHub Release from those same artifacts.

The nightly uses a **decoupled publish workflow** (a separate `publish-nightly`
job that pulls the latest successful artifacts from the three build workflows —
*not* atomic, *not* a per-build upload step) and a **single rolling tag** of the
form `v<version>-daily` (e.g. `v0.1.0-daily`) that is **moved** to the newest
built commit on every run, so tags do not accumulate.

## Current state (verified)

- The three build workflows upload their bundles via `actions/upload-artifact`:
  `mac-aot-output`, `linux-aot-dist`, `win-aot-output`. **These are not a
  distribution channel** — run artifacts require a GitHub login to download
  (even on a public repo) and expire (≤90 days).
- `version.txt` = `0.1.0` and is the single source of truth for the bundle
  version (read by `CMakeLists.txt` / CPack). The daily tag derives from it:
  `v0.1.0-daily`.
- The produced asset names are already **platform-unique**, so they coexist in
  one flat release with no collisions:
  | Platform | Asset(s) |
  |---|---|
  | macOS | `eco-0.1.0-arm64-darwin.tar.gz` |
  | Linux | `eco-0.1.0-x86_64-linux-musl.tar.gz`, `…-linux-musl.zip`, `eco_0.1.0_amd64.deb` |
  | Windows | `eco-0.1.0-x86_64-windows.zip` |
- No `release`/`publish`/`nightly` workflow exists yet.

## Design overview

```
  mac-aot ─┐
 linux-aot ─┤  (build daily, each on its own cron; upload-artifact as today)
   win-aot ─┘
              │  latest *successful* run per workflow
              ▼
       publish-nightly  (scheduled after the builds + manual)
              │  gh run download → collect *.tar.gz/*.zip/*.deb → SHA256SUMS
              ▼
   GitHub pre-release  tag = v<version>-daily   (tag MOVED each run)
              │
   (promote) push tag v<version>  ──►  release.yml  ──►  permanent Release
```

GitHub **Releases** are the channel: assets get stable, anonymous URLs that
never expire —
`https://github.com/eco-lang/eco-compiler/releases/download/v0.1.0-daily/<asset>`
— and `…/releases/latest/download/<asset>` keeps pointing at the newest
*stable* (non-prerelease) tag.

## Part 1 — `publish-nightly.yml`

### Trigger

```yaml
on:
  schedule:
    - cron: '0 10 * * *'   # after the 06:00–06:40 build crons clear (linux's
                            # test→bundle chain is the slowest; see Risks)
  workflow_dispatch: {}
permissions:
  contents: write           # create/delete releases + move tags
```

Scheduled well after the builds. Because the design is **not atomic** (by
choice), the job simply consumes whatever the *latest green* run of each
platform is — if a platform's same-day build is still running or red, yesterday's
green build for that platform is published. Timing only needs to be "usually
after the builds," not exact.

### Steps (illustrative — final YAML lands in the workflow)

1. **Resolve + download the latest green build per platform.**
   ```bash
   for wf in mac-aot.yml linux-aot.yml win-aot.yml; do
     rid=$(gh run list --workflow "$wf" --branch master --status success \
              --limit 1 --json databaseId -q '.[0].databaseId')
     [ -n "$rid" ] || { echo "::error::no green $wf build to publish"; exit 1; }
     gh run download "$rid" --dir "stage/$wf"        # all artifacts of that run
     gh run view "$rid" --json headSha,url,createdAt > "stage/$wf.meta.json"
   done
   ```
2. **Collect the distributables** (the extension filter drops the raw `eco` /
   `eco.exe` binaries and the log artifacts that share those upload bundles):
   ```bash
   mkdir dist
   find stage -type f \( -name '*.tar.gz' -o -name '*.zip' -o -name '*.deb' \) \
        -exec cp -n {} dist/ \;
   ( cd dist && sha256sum * > SHA256SUMS )
   ```
3. **Compute the rolling tag + target commit.** Tag from `version.txt`; target
   the **newest** of the three source-run commits (the most honest single
   commit when builds span days), and record all three in the notes.
   ```bash
   DAILY_TAG="v$(cat version.txt)-daily"
   SHA=$(jq -rs 'max_by(.createdAt).headSha' stage/*.meta.json)
   ```
4. **Move the tag + refresh assets in one shot.** Delete the existing rolling
   release *and its tag*, then recreate at the new commit. This is what keeps a
   **single** moving tag instead of accumulating dated tags:
   ```bash
   gh release delete "$DAILY_TAG" --cleanup-tag --yes 2>/dev/null || true
   gh release create "$DAILY_TAG" \
     --target "$SHA" --prerelease \
     --title  "Nightly $DAILY_TAG ($(date -u +%Y-%m-%d))" \
     --notes-file notes.md \
     dist/*
   ```
   `notes.md` lists the UTC build date, the resolved `$SHA`, and each
   platform's source-run URL + commit (from the `.meta.json` files) for
   traceability, plus the `SHA256SUMS` body.
5. **Prune stale `-daily` releases** (only matters across a `version.txt` bump,
   when the tag name changes):
   ```bash
   gh release list --json tagName,isPrerelease \
     -q '.[] | select(.isPrerelease) | .tagName' \
     | grep -E '^v.*-daily$' | grep -vx "$DAILY_TAG" \
     | xargs -r -n1 -I{} gh release delete {} --cleanup-tag --yes
   ```

### Optional polish (note, don't block on)

- **Skip when unchanged:** if `$SHA` already equals the commit on `$DAILY_TAG`,
  skip the republish so an idle day doesn't churn the release.
- Tags (re)created by `GITHUB_TOKEN` do **not** trigger other workflows, so the
  moving `-daily` tag will not accidentally fire `release.yml` (Part 2 also
  excludes it explicitly).

## Part 2 — `release.yml` (promotion to stable)

Same decoupled download, keyed to a real version tag, published as a permanent
(non-prerelease) Release.

```yaml
on:
  push:
    tags: ['v*', '!v*-daily']    # real versions only; never the rolling tag
permissions:
  contents: write
```

Difference from nightly: pin the downloads to the **tagged commit** and fail if
any platform lacks a green build for it (provenance matters for stable):

```bash
SHA="${GITHUB_SHA}"
for wf in mac-aot.yml linux-aot.yml win-aot.yml; do
  rid=$(gh run list --workflow "$wf" --commit "$SHA" --status success \
           --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$rid" ] || { echo "::error::no green $wf build for $SHA — tag a commit CI has built green"; exit 1; }
  gh run download "$rid" --dir "stage/$wf"
done
# …collect + SHA256SUMS as in Part 1…
gh release create "${GITHUB_REF_NAME}" \
  --target "$SHA" --title "${GITHUB_REF_NAME}" --notes-file notes.md \
  dist/*                                 # NOT --prerelease → becomes "latest"
```

**Promotion process:** bump `version.txt` → merge to `master` → let the three
builds go green → push an annotated `v0.1.0` tag at that commit → `release.yml`
assembles the stable Release, and `…/releases/latest/` flips to it. (The bump
also renames the rolling tag to `v0.2.0-daily`; Part 1 step 5 deletes the old
`v0.1.0-daily`.)

## Part 3 — supporting changes to the build workflows

Small, low-risk edits to the three `-aot` workflows:

- **Lower artifact retention:** add `retention-days: 7` to each
  `upload-artifact` step — the durable copy now lives in the release, so the run
  artifacts are just the publish hand-off.
- No other change: the publish workflows read existing artifacts by name and
  extension, so the build workflows stay as-is otherwise.

## The "use" layer (downstream, out of scope here)

The stable URLs are what end-user installation hangs off, e.g.:

- An `install.sh` that `curl`s `…/releases/latest/download/eco-…-$(uname)…` and
  unpacks to `~/.local`.
- A Homebrew tap formula pointing at the macOS TGZ + its SHA256.
- The `.deb` offered directly or served from an apt repo.

These consume the release; none require changing the build/publish design.

## Acceptance criteria

- A scheduled `publish-nightly` run produces/updates a single pre-release tagged
  `v0.1.0-daily` carrying all five platform assets + `SHA256SUMS`, downloadable
  **anonymously** via the stable `releases/download/v0.1.0-daily/<asset>` URLs.
- Re-running it **moves** the tag to the newest built commit and replaces the
  assets — the repo never accumulates more than one `*-daily` tag/release.
- The release notes name each platform's source run + commit and the UTC date.
- Pushing `v0.1.0` (after green builds at that commit) yields a permanent,
  non-prerelease Release; `releases/latest` points at it; pushing the rolling
  `-daily` tag never triggers `release.yml`.
- Build-workflow run artifacts expire in 7 days; releases do not expire.

## Risks / decisions

1. **Non-atomic by design (accepted).** A nightly can mix platforms from
   different commits when one build lags or is red. The notes make the per-asset
   commit explicit so this is visible, not silent.
2. **Publish timing vs. Linux duration.** Linux is now a serial `test → bundle`
   chain and is the slowest platform; if it routinely finishes after 10:00 UTC,
   either push the publish cron later or accept that the *first* run of a new day
   ships the prior day's Linux until the next day catches up. (A `workflow_run`
   trigger could tighten this later but reintroduces per-completion firing.)
3. **Tag-move mechanism.** Delete-and-recreate (`--cleanup-tag` then
   `create --target`) is used deliberately over `git push -f` so the release and
   its tag always agree on the target commit; the brief no-release window is
   irrelevant for a nightly.
4. **Token scope.** `contents: write` is required; the default `GITHUB_TOKEN`
   suffices for releases + tags and (helpfully) does not cascade-trigger
   `release.yml`.

## Estimated effort

~half a day. Two new workflow files (`publish-nightly.yml`, `release.yml`)
sharing the same download-and-assemble shell, plus a one-line `retention-days`
addition to the three `-aot` workflows. No build-system or C++ change.
</content>
