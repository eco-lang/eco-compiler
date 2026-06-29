# Plan: Consolidate CI to one `-aot` build per platform

## Goal

Collapse the current eleven GitHub Actions workflows down to **one `-aot`
workflow per platform** (`linux-aot`, `mac-aot`, `win-aot`), each of which
drives the **full bootstrap process** — all prior stages **and every test
gateway** — and ends by producing the shippable distribution bundle for that
platform. Keep the two **LLVM base-image cache-warmers** (`linux-llvm-build`,
`win-llvm-build`); mac needs none (brew provides LLVM).

Net: **11 workflows → 5**.

| Platform | Today | After |
|---|---|---|
| linux | `linux-bootstrap`, `linux-aot`, `linux-llvm-build` | `linux-aot` + `linux-llvm-build` |
| mac | `mac-bootstrap`, `mac-runtime`, `mac-aot` | `mac-aot` |
| win | `win-bootstrap`, `win-runtime`, `win-aot`, `win-llvm-build` | `win-aot` + `win-llvm-build` |

**Files deleted:** `linux-bootstrap.yml`, `mac-bootstrap.yml`, `mac-runtime.yml`,
`win-bootstrap.yml`, `win-runtime.yml`.

This is a deliberate reversal of the usual "fast-feedback ladder" argument
(see *Trade-offs accepted* below). The cache-eviction objection that made
this risky is removed by the maintainer's stated plan: **daily scheduled
builds keep the LLVM caches warm, and/or self-hosted runners host the
LLVM-from-source builds.**

## Current state (verified against the live workflows + run history, 2026-06-29)

`gh run list --repo eco-lang/eco-compiler` + per-step `gh api .../jobs`.

**Key finding: `-aot` is *not* a superset today.** Each platform's `aot`
workflow builds the full Stage 1–9 chain and ships the bundle, but it **never
runs the two test gateways**:

- `elm-tests` (the compiler's own Elm suite) runs **only** in `*-bootstrap`.
- the **JIT E2E** suite (`./build/test/test`) runs **only** in `*-runtime`.

So consolidation is *not* "delete the redundant jobs" — it is "**fold those
two gateways into `aot`**, then delete the now-empty standalone jobs."

### What each role does (verified)

- **`*-bootstrap`** (mac/win): **front-end only**, `ECO_FRONTEND_ONLY` (no
  LLVM). Stages 1–4b (`eco-boot-verify`) → Stage 5 (`eco-compiler-mlir`) →
  `elm-tests`. The cheap gate. (linux's `bootstrap` is the opposite — the
  *full* glibc suite; see below.)
- **`*-runtime`** (mac/win): full LLVM build + `test` binary + **JIT E2E**.
  (linux has no `runtime` — its `bootstrap` absorbs it.)
- **`*-aot`**: `--target eco` (Stages 1–9 incl. the 8c native MLIR
  fixed-point) → verify Mach-O/PE/static-ELF → `package` → smoke-test bundle.
- **`*-llvm-build`** (linux/win): compiles LLVM+MLIR from source, stores it in
  the Actions cache. `aot`/`runtime` restore it; **win uses
  `fail-on-cache-miss: true`**.
- **linux-bootstrap** is already the consolidated full-suite (glibc/debian
  docker): Gate A `full` (build-all + JIT E2E) → `elm-tests` → `stress` →
  `bootstrap` (stages 1–9 + JS-4b & native-8c fixed points) → Gate B
  `run-aot-e2e`. **linux-aot** is the separate **musl/alpine static**
  distribution build (smoke gates only, *not* the full suite).

### Measured timings (healthy runs)

| Workflow | Wall | Dominant step(s) |
|---|---|---|
| mac-bootstrap | ~7 m | front-end (Node), no LLVM |
| mac-runtime | ~20 m | build-all 358 s, **JIT E2E run 650 s**, test-link 85 s |
| mac-aot | ~31 m | **Stage-9 self-host chain 1758 s** |
| win-bootstrap | ~8 m | front-end |
| win-runtime | ~8–9 m (warm) | build + (Win-stubbed) JIT E2E |
| win-aot | ~54 m | Stage 6 550 s + Stage 7 872 s + **Stage 8/9 1340 s** |
| linux-bootstrap | ~1 h (warm) | full suite |
| linux-aot | ~2.3–3.3 h, **red** | cold LLVM-alpine rebuild → runner OOM |
| win-llvm-build | ~1.3 h | LLVM source build (cache fill) |

**Timing verdict — consolidation fits with room to spare.** `aot` already
pays for the long pole (the self-host fixed-point chain); the JIT gateway only
adds its *run* time (build is shared via ccache):

- consolidated **mac-aot ≈ 31 m + ~12 m ≈ 43 m** (bump timeout 60 → 90).
- consolidated **win-aot ≈ 54 m + ~6 m ≈ 60 m** (cap is 240 — vast headroom).

The earlier "Windows might blow the 6 h cap" worry is **disproven by data**
(win-aot is 54 m).

### Why three of the live workflows are red right now

All one root cause — the **LLVM base-image cache**, not the compiler:

- **linux-aot**: cold `eco-llvm-alpine` cache → rebuilds LLVM from source
  (~3 h) → "runner lost communication" (OOM). Red every recent master run.
- **win-runtime**: `fail-on-cache-miss: true` + the LLVM-MSVC tree was
  **evicted** (GitHub's 7-day idle eviction) → fails in 25–37 s. Only ever
  green on the experiment branch with a warm cache.
- **linux-llvm-build**: the warmer itself OOMs on a cold source build.

mac is the only all-green platform — precisely because it has **no cache
dependency** (brew reinstalls LLVM each run, ~1 min).

**This is why the cache strategy (below) is a first-class part of the plan,
not an afterthought.**

## Target design

### Common shape of a consolidated `-aot` workflow

Steps ordered **cheap → expensive (fail-fast)**, mirroring linux-bootstrap's
gate order so a front-end or runtime regression fails before the multi-stage
self-host chain runs:

1. **Setup** — checkout; platform toolchain (brew `llvm@21` on mac; MSVC +
   LLVM-cache-restore + rapidcheck on win); pnpm; restore ccache.
2. **Configure** the full preset (`mac-build` / `win-build` / linux docker).
3. **Front-end gateway** — Stages 1–4b (`eco-boot-verify`) → Stage 5
   (`eco-compiler-mlir`). Pure Node, ~minutes. (Replaces `*-bootstrap`'s body
   minus the LLVM-free configure — see *Trade-offs*.)
4. **`elm-tests` gateway** — with the existing exit-code-2 / `Failed: +0`
   tolerance for the one intentional `Test.skip`.
5. **JIT E2E gateway** — build `test`, run it (`--target full` where it is
   wired; else `cmake --build build` + `--target test` + run `build/test/test`).
   This is the body of `*-runtime`.
6. **Self-host bootstrap chain** — `--target eco` (Stages 6–9 incl. the 8c
   MLIR byte-equal fixed point; Stages 1–5 already built in step 3). Split into
   per-stage steps as today so the Actions UI shows per-stage durations.
7. **stress / AOT-E2E gateways** — where the platform supports them (linux:
   `stress` + `run-aot-e2e`; mac: `stress` if wired; win: both stay
   `NOT WIN32`-gated and are skipped).
8. **Verify** the binary (Mach-O arm64 + ad-hoc-sign / PE32+ / zero-`NEEDED`
   static ELF).
9. **`package`** the bundle (TGZ / ZIP / `.tar.gz`+`.deb`).
10. **Smoke-test the bundle in isolation** (extract to a fresh prefix, run
    `bin/eco --help`).
11. **Upload** artifacts + logs (`if: always()`).

### Per-platform specifics

**`mac-aot` (single workflow, single job).** Union of the three current mac
jobs. brew installs `llvm@21` once instead of three times — saves two
~10×-billed macOS runners per push. Gateways present: front-end, `elm-tests`,
JIT E2E, self-host chain, verify, package, smoke. `timeout-minutes: 90`.

**`win-aot` (single workflow, single job) + `win-llvm-build`.** Same union,
plus the MSVC env, LLVM-cache restore (`fail-on-cache-miss: true`), and
rapidcheck-from-source. stress/AOT-E2E remain Windows-gated-off. Keep the
per-stage step split (good for the timing UI). `timeout-minutes: 240`
(actual ≈ 60).

**`linux-aot` — the one real design fork.** linux is *not* like mac/win: it
runs **two toolchains** — the full test suite on **glibc/debian** (eco-dev
image) and the shipped binary as **static musl/alpine**. The shipped artifact
must be musl (portability), but the heavy suite is validated on glibc, and the
musl self-host bootstrap is **known-flaky** (the `Map.!`
musl-readdir-ordering bug tracked in `plans/static-link-eco-binary.md`).

**Recommended: one `linux-aot.yml` workflow with two jobs —**

- **job `test`** (glibc/eco-dev): the full current linux-bootstrap body —
  Gate A `full` + `elm-tests` + `stress` + `bootstrap` (stages + fixed
  points) + Gate B `run-aot-e2e`. This *is* "all prior stages and test
  gateways."
- **job `bundle`** (`needs: test`, musl/alpine `static-build.Dockerfile`):
  the current linux-aot body — build the static binary, run the smoke/
  ELF-contract gates, export `.tar.gz`/`.zip`/`.deb`, assert zero `NEEDED`.

This satisfies "a single `-aot` runner" as **one workflow file**, keeps each
toolchain doing what it is good at, and does **not** run the multi-hour suite
twice or depend on the flaky musl self-host. `test` gates `bundle` so we never
ship an artifact that failed the gateways.

*Alternative (rejected for now): one job, everything under musl/alpine
("test exactly what you ship").* Cleaner in principle, but (a) the alpine
image doesn't host the full Node/elm-test-rs suite today, and (b) the musl
self-host bootstrap is flaky (`Map.!`). Revisit once that bug is closed.

### Trigger / path-filter merge

Each consolidated `-aot` triggers on the **union** of the paths its three
predecessors watched, plus its own file:

```
compiler/**, runtime/**, elm-kernel-cpp/**, eco-kernel-cpp/**,
cmake/**, CMakeLists.txt, CMakePresets.json, version.txt,
<platform dockerfiles/preset bits>, .github/workflows/<platform>-aot.yml
```

Keep `workflow_dispatch`. **Add `schedule:` (daily cron)** to all three
`-aot` workflows — this *is* the maintainer's "daily build" and, as a side
effect, resets the 7-day cache-eviction timer on every restore.

### Cache strategy (resolves the current red runs)

1. **Daily `schedule` on the `-aot` workflows** keeps the LLVM caches accessed
   → never evicted. A scheduled *restore* counts as access; it does **not**
   rebuild LLVM (rebuild happens only when `LLVM_VERSION` / the base
   Dockerfile hash changes). So the daily cost is the normal build, not a
   3 h LLVM recompile.
2. **Keep `linux-llvm-build` / `win-llvm-build`** as the warmers, triggered on
   their Dockerfile/version changes (unchanged) **plus** a weekly safety
   `schedule`.
3. **linux-aot `bundle` job: switch to `fail-on-cache-miss: true`** (matching
   win) and **drop the self-build fallback** that OOMs. With the daily warm
   cache this is safe, and it converts the current 3 h-then-die failure into a
   fast, legible "cache cold — run the warmer" error. *(If the maintainer
   prefers resilience over speed, keep the fallback but move the LLVM source
   build to a self-hosted runner — see Risks.)*

## Trade-offs accepted (what consolidation costs)

Stated plainly so the decision is informed:

- **Slower first failure signal.** Today a front-end typo fails `mac-bootstrap`
  in ~7 m with no LLVM. After consolidation it fails inside `mac-aot` only
  after brew-installs LLVM + configures. *Mitigation:* the fail-fast step
  order puts front-end + `elm-tests` before the expensive self-host chain, so
  the *wasted* time is the setup, not the whole build.
- **Coarser failure isolation.** "JIT broke vs AOT broke vs front-end broke"
  now lives in one job's log instead of three differently-named runs.
  *Mitigation:* keep gateways as **distinct named steps** with `::group::`
  markers and per-step artifacts.
- **One toolchain install instead of a free LLVM-free lane.** `*-bootstrap`'s
  genuine virtue was needing **no LLVM at all**. We lose that lane. (We could
  keep a thin `*-frontend` lane later if the slow signal hurts — explicitly
  out of scope here per the "single -aot" directive.)

The wins: **11 → 5 workflows**, no triple LLVM provisioning (big $ on the
10×-billed macOS runners), and the shipped artifact is the thing that runs
every gateway.

## Rollout

Do **mac first** (all-green, no cache dependency → lowest risk), then win,
then linux.

1. **Branch `ci/consolidate-aot`.** `on: push` triggers run the pushed
   version on any branch, so iterate there before touching master.
2. **mac:** write the unified `mac-aot.yml` (union of the three jobs, fail-fast
   order, timeout 90). Push; confirm green; compare wall-clock to the sum of
   the three it replaces.
3. **win:** same for `win-aot.yml`; keep `win-llvm-build`; confirm the
   LLVM-cache restore + combined run is green and well under 240.
4. **linux:** rewrite `linux-aot.yml` as the two-job (`test` → `bundle`)
   workflow; set `fail-on-cache-miss`; confirm the warmer keeps the cache hot.
5. **Add the daily `schedule`** to all three `-aot` workflows and a weekly one
   to the warmers.
6. **Delete** `mac-bootstrap.yml`, `mac-runtime.yml`, `win-bootstrap.yml`,
   `win-runtime.yml`, `linux-bootstrap.yml` in the same PR that lands the
   unified files (so coverage is never dropped before it is re-homed).
7. **Update docs** that name the old workflows (`docs/building.md`,
   `guides/bootstrap.md`, `plans/build-on-mac.md`, `plans/build-on-windows.md`).

## Acceptance criteria

- Exactly five workflow files remain: `linux-aot`, `linux-llvm-build`,
  `mac-aot`, `win-aot`, `win-llvm-build`.
- Each `-aot` run, on a clean checkout, executes **every gateway its
  predecessors did** for that platform — verifiable in the step list:
  front-end stages, `elm-tests`, JIT E2E, the Stage 1–9 self-host chain incl.
  the 8c fixed point, and (linux) `stress` + AOT-E2E.
- Each `-aot` run ends by producing **and smoke-testing** the platform bundle
  (Darwin TGZ / Windows ZIP / linux `.tar.gz`+`.deb`, the last fully static
  with zero `NEEDED`).
- No green-to-red regression vs the workflows replaced: the same
  known-tolerated cases (the one `elm-tests` `Test.skip`; linux's
  `FlagsRecordTest`/`PortEchoTest` AOT-harness limits) are tolerated the same
  way, and nothing else.
- mac-aot ≤ 90 m, win-aot ≤ 240 m, linux `test` ≤ 180 m / `bundle` ≤ 180 m on
  warm caches.
- A daily scheduled run keeps the linux + win LLVM caches from evicting (no
  `fail-on-cache-miss` failures across a 7-day window).

## Risks & open questions

1. **LLVM-from-source reliability on hosted runners.** The warmers OOM on a
   *cold* rebuild (7 GB linux / 4-vCPU win). The daily schedule avoids routine
   rebuilds, but an `LLVM_VERSION` bump still triggers one. *Mitigation:* the
   maintainer's self-hosted-runner option, or a higher-RAM runner label, for
   the warmer jobs specifically.
2. **`--target full` availability on mac/win.** linux uses it for the JIT
   gateway; mac/win-runtime used explicit `build` + `test` + run. Confirm
   which is wired before choosing the step form (the plan's step 5 allows
   either).
3. **Single-job log size / debuggability on linux.** The two-job split keeps
   glibc-test failures separate from musl-ship failures; if a future "one job"
   push is wanted, it is blocked on the `Map.!` musl bootstrap bug.
4. **`schedule` only runs from the default branch** — the daily build won't
   exist until the unified files are merged to master (expected; noted so the
   warm-cache benefit isn't assumed during the `ci/**` iteration phase).

## Estimated effort

~1 day. It is YAML restructuring, not build-system change: the steps already
exist and are proven per platform — this concatenates them in fail-fast order,
adds the daily schedule + `fail-on-cache-miss`, and deletes five files. mac is
~1 h; win ~2 h (cache wiring); linux ~half a day (the two-job split + verifying
the warmer keeps the cache hot).
</content>
</invoke>
