# GC parameter combination run — 2026-09-22

Harness: `heap-profile.py sweep --variants-file plans/gc-param-sweep/combinations-2026-09-22.json`
Results: `/work/heap-profiles/ws-dev-01/2026-09-22T15-04-39Z__gc-combinations/`
11 cells: all 6 pairs, all 4 triples and the quad over the four wall-time winners from
`sensitivity-2026-09-22-results.md`. Compared against that sweep's `baseline` (233.8 s wall,
115.5 s GC) and its 2σ = 5.3 s noise floor.

| cell | output | wall | Δwall | GC | ΔGC | majors | minors |
|---|---|---:|---:|---:|---:|---:|---:|
| `p_age_nmbc` | **OK** | 208.1 | -25.7 | 94.9 | -20.6 | 9 | 1927 |
| `p_age_mio` | **OK** | 204.5 | -29.3 | 89.3 | -26.2 | 5 | 1032 |
| `p_nmbc_mio` | **OK** | 214.1 | -19.7 | 102.3 | -13.2 | 6 | 2099 |
| **`t_age_nmbc_mio`** | **OK** | **195.8** | **-38.0** | **85.4** | **-30.1** | 6 | 1927 |
| `p_abuf_age` | CRASH | — | — | — | — | — | — |
| `p_abuf_nmbc` | CRASH | — | — | — | — | — | — |
| `p_abuf_mio` | CRASH | — | — | — | — | — | — |
| `t_abuf_age_nmbc` | CRASH | — | — | — | — | — | — |
| `t_abuf_age_mio` | CRASH | — | — | — | — | — | — |
| `t_abuf_nmbc_mio` | CRASH | — | — | — | — | — | — |
| `q_abuf_age_nmbc_mio` | CRASH | — | — | — | — | — | — |

"OK" = `eco-compiler-boot.mlir` byte-identical to `ecoghash.mlir`
(`41bd8088cacae67b12329ff3e20ffde6`). The crashed cells are SIGSEGV with no output at all;
their wall times are times-to-crash and are omitted rather than tabulated, because printing
them invites exactly the error that produced the `abuf_128K` retraction.

## Result 1: the three safe factors COMPOSE

| | wall | Δ vs baseline |
|---|---:|---:|
| baseline | 233.8 | — |
| `age_1` alone | 216.1 | -17.7 |
| `nmbc_512` alone | 216.2 | -17.6 |
| `mio_0.95` alone | 222.0 | -11.8 |
| `age`+`nmbc` | 208.1 | -25.7 |
| `age`+`mio` | 204.5 | -29.3 |
| `nmbc`+`mio` | 214.1 | -19.7 |
| **all three** | **195.8** | **-38.0 (-16.3 %)** |

Composition is real but **sub-additive**: the three singles sum to -47.1 s and the triple
delivers -38.0 s, about 81 % of it. That is what should be expected — they act on partly
overlapping costs (`age` on nursery copying, `nmbc` on nursery footprint, `mio` on major
frequency), and GC time cannot go below zero. Every pair beats both its components, and the
triple beats every pair, so there is no antagonistic interaction among them.

GC time 115.5 -> 85.4 s (-26 %) and majors 10 -> 6 in the triple, with output verified
byte-identical. **`t_age_nmbc_mio` is the candidate configuration:**
`promotion_age=1`, `nursery_max_block_count=512`, `major_gc_initiating_occupancy=0.95`.

## Result 2: `alloc_buffer_size=128K` is a RUNTIME BUG

Seven cells, seven SIGSEGVs, zero outputs. Combined with the retracted single
(`sensitivity-2026-09-22-results.md`), that is **8 crashes from 8 attempts**. 256K is clean.
A config that `HeapConfig::validate()` accepts must not segfault the runtime, so this is a
defect to fix, not a parameter to avoid — and until it is fixed, 128K blocks cannot be
evaluated for performance at all.

## Owed

- **Old-gen peak under the triple is unmeasured here** and matters: `mio_0.95` alone pushed
  it to 11,709 MB on a 15 GB box, and `age_1` alone to 10,342 MB. Check before shipping.
- **N=1.** -38.0 s is 7x the noise floor so the direction is not in doubt, but the magnitude
  deserves an interleaved A/B against the default config.
- **The `abuf` 128K crash** wants a debug-build repro and a real backtrace; the compiled
  binary's handler prints GC stats and re-raises without symbolising.

---

# Revised triple (`nmbc_128`) — REFUTED, and it breaks the composition story

After the range extension found the nursery minimum at 64 MiB (`nmbc_128`, -28.5 s alone vs
`nmbc_512`'s -17.6 s), the obvious move was to swap it into the winning triple. Predicted
~185 s. **Measured 265.1 s — 31.3 s WORSE than baseline and 69.3 s worse than the triple it
was meant to improve.**

| | wall | major_s | minor_s | majors | minors | promoted | old-gen peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 233.8 | 23.06 | 92.42 | 10 | 1,114 | 17,616 MiB | 9,125 MB |
| **triple** (`nmbc_512`) | **195.8** | 9.32 | 76.06 | 6 | 1,927 | 19,883 MiB | 9,850 MB |
| revised (`nmbc_128`) | 265.1 | **47.62** | 80.43 | 7 | 7,545 | **22,440 MiB** | **15,078 MB** |

**The wall is swap-contaminated and should not be read as a measurement.** Major #7 alone took
**40.65 s** with **65,660 major page faults** (every earlier major had `major_pf=0`) — that
single cycle is most of the regression, and it is disk I/O, not collector work. Old-gen peak
15,078 MB against 15 GB of RAM.

**The cause is real regardless of the wall.** A 64 MiB nursery collects so often that almost
nothing gets a chance to die young, and `promotion_age=1` tenures whatever survives on its
first cycle. Promotion goes 17,616 -> 22,440 MiB (+27 %). Each factor raises promotion only
modestly on its own (`nmbc_128` peak 10,002 MB, `age_1` peak 10,342 MB); **together they
compound**, and `mio=0.95` then defers collection while the old gen keeps growing.

`mio` did not even help here: **all 7 majors were garbage-fraction triggered, 0 by occupancy.**
The 0.95 threshold was never reached, so its benefit was absent while its cost — deferring
collection of a ballooning old gen — was fully present.

## The lesson

**Single-factor sweeps do not predict combinations when the factors share a downstream
resource.** Both sweeps are monotone and both minima are genuine, but `nursery_max_block_count`
and `promotion_age` push on the SAME quantity — how much survives into the old gen — and the
old gen is where the memory ceiling lives. The original triple composed (sub-additively)
because `nmbc_512` left enough nursery for young objects to die in; the revised one does not.

**Corollary for reading this whole arc:** old-gen peak, not wall time, is the variable that
decides whether a nursery/promotion combination is admissible at all. It should be a gate on
every future combination cell, checked BEFORE the wall is interpreted.

**`t_age_nmbc_mio` (promotion_age=1, nursery_max_block_count=512,
major_gc_initiating_occupancy=0.95) stands as the recommendation at 195.8 s, -16.3 %,
old-gen peak 9,850 MB.**
