# `perf` Profiling — Stage 7 Self-Compile

This document captures how to run `perf record` against a Stage-7 self-compile of the Eco compiler (see [bootstrap.md](bootstrap.md)). The goal is a CPU-time profile of the native compiler compiling itself, with enough resolution to see functions down to ~0.2 % of CPU while staying inside the 16 GB RAM budget of the dev machine.

## Why Stage 7?

Stage 7 exercises the entire native pipeline (front-end parsing/typing, monomorphization, MLIR codegen, GC, runtime kernel) under a realistic, large workload — the compiler is the largest Eco program we have. It is also the workload where the bootstrap historically falls over, so the same profile is reusable for diagnosing miscompiles, GC pathologies, and runtime hot spots.

## Pre-flight

- `which perf` — confirm `/usr/bin/perf` is installed.
- `cat /proc/sys/kernel/perf_event_paranoid` — must be ≤ 2 for unprivileged DWARF call-graph sampling. If it is 3 or higher, prefix the command with `sudo` or temporarily relax with `sudo sysctl kernel.perf_event_paranoid=1`.
- `ls /work/compiler/build-kernel/bin/eco-compiler` — confirm Stage 6 has produced the native compiler.
- `free -h` — make sure ≥ 6 GB is available; the compiler peaks at 3–4 GB RSS and perf adds 150–300 MB.

## Recording command

Run from `/work/compiler/build-kernel`:

```bash
perf record \
    -F 499 \
    --call-graph dwarf,6144 \
    -m 256 \
    -z \
    -o /tmp/perf-stage7.data \
    -- timeout --signal=INT 100s \
    bin/eco-compiler make \
        --optimize \
        --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/eco-compiler-boot.mlir \
        /work/compiler/src/Terminal/Main.elm
```

### Parameter rationale (mid-range between memory-conservative and perf defaults)

| Flag | Value | Default | Reason |
| --- | --- | --- | --- |
| `-F` | `499` | `~4000` | 499 Hz × 100 s × ~4 cores ≈ 200 k samples. Resolves functions down to ~0.2 % of CPU. 499 is prime, which avoids aliasing with periodic timers (GC tick, scheduler quantum, etc). |
| `--call-graph` | `dwarf,6144` | `dwarf,8192` | DWARF unwinding works without frame pointers. 6 KB stack snapshot keeps deep monomorphization / Dict-recursion stacks intact while saving 25 % over the default. |
| `-m` | `256` | `128` | 1 MB per-CPU ring buffer absorbs bursty samples (≈ 3 MB/s/CPU at 499 Hz × 6 KB stacks) without `LOST samples` warnings. |
| `-z` | (on) | off | In-kernel compression of the sample stream. Roughly free CPU-wise and shrinks `perf.data` substantially. |
| `-o` | `/tmp/perf-stage7.data` | `./perf.data` | Keeps the artefact off the source tree and on tmpfs/SSD. |
| `timeout --signal=INT 100s` | — | — | Sends SIGINT to the compiler after 100 s; perf detects child exit and flushes `perf.data` cleanly. The compiler runs much longer than 100 s, so this just bounds the trace. |

### Expected cost

- `perf.data` on disk: ~500 MB – 1.5 GB compressed.
- perf process RSS: ~150 – 300 MB.
- Sampling overhead on the target: ~2 – 4 % CPU — low enough not to distort the hot-path picture.

## Post-processing

### Top-of-the-list summary
```bash
perf report -i /tmp/perf-stage7.data --stdio --sort=overhead,symbol --no-children | head -80
```

### Inclusive (caller-attributed) view
```bash
perf report -i /tmp/perf-stage7.data --stdio --sort=overhead,dso,symbol | head -120
```

### DSO / module breakdown
```bash
perf report -i /tmp/perf-stage7.data --stdio --sort=dso --no-children | head -20
```

### Flame graph
```bash
perf script -i /tmp/perf-stage7.data \
  | stackcollapse-perf.pl \
  | flamegraph.pl > /tmp/perf-stage7.svg
```

## What this profile yields

1. **Hot-function table** — wall-clock CPU time bucketed by symbol. Compiler logic (Monomorphization, MLIR codegen, type inference) vs runtime kernel (`Dict_*`, `JsArray_*`, `Bytes_*`) vs GC (`OldGenSpace::*`, `NurserySpace::evacuate`, `markOneObject`).
2. **Call-graph attribution** — inclusive (self + callees) time, so a heavy path through `Builder.crawlNewDeps` or major-GC roots accumulates against the right outer frame.
3. **DSO breakdown** — eco-compiler binary vs libc/libm vs vmlinux — exposes syscall-heavy paths (e.g. `madvise` from BBoP block release).
4. **Inlined-frame attribution** — DWARF unwind keeps inlined C++ runtime frames visible instead of collapsing them into outer callers.
