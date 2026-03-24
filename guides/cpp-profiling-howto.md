# Profiling the C++ Compiler Backend (eco-boot-native)

## Prerequisites

### Enable perf in the container

`perf` is installed but blocked by default. Enable it with:

```bash
sudo sysctl kernel.perf_event_paranoid=-1
```

This lasts until container restart.

### Verify it works

```bash
perf stat echo hello
```

You should see cycle counts, instructions, branch stats, etc.

## Quick Profile (Recommended Starting Point)

### 1. Record a time-limited profile

Use `timeout` to cap the run — Stage 6 on the full compiler MLIR can take minutes:

```bash
timeout 30 perf record -g --call-graph dwarf,16384 -F 997 \
    -o /tmp/perf.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir \
    -o /dev/null
```

**Flags explained:**
- `-g --call-graph dwarf,16384` — capture call stacks via DWARF (works without frame pointers; 16KB stack dump per sample)
- `-F 997` — sample at ~997 Hz (prime number avoids aliasing with periodic code)
- `timeout 30` — kill after 30 seconds (profiles the early phases)
- `-o /dev/null` — discard the output binary (we only care about profiling)

**Warning:** DWARF call graphs produce large perf.data files (~4GB for 30s at 997Hz with 12 threads). If disk is tight, reduce `-F` to 99 or use `--call-graph fp` (requires `-fno-omit-frame-pointer` build).

### 2. Flat profile (fast, always works)

Get the top functions by self time — aggregated across all threads:

```bash
perf report -i /tmp/perf.data --stdio --no-children -g none --percent-limit 0.5
```

This shows per-thread entries. To aggregate across threads:

```bash
perf report -i /tmp/perf.data --stdio --no-children -g none --percent-limit 0.1 2>&1 \
    | grep -E '^\s+[0-9]' \
    | awk '{
        pct=$1; sub(/%/,"",pct);
        sym=""; for(i=5;i<=NF;i++) sym=sym" "$i;
        overhead[sym]+=pct
    } END {
        for(s in overhead) printf "%8.2f%% %s\n", overhead[s], s
    }' \
    | sort -rn | head -20
```

### 3. Call-graph analysis (use small data files)

Call-graph reports on large perf.data files can take forever. Two strategies:

**Strategy A: Short recording**

```bash
timeout 5 perf record -g --call-graph dwarf -F 99 -o /tmp/perf-small.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir -o /dev/null
perf report -i /tmp/perf-small.data --stdio -g fractal,5,caller --percent-limit 3.0
```

**Strategy B: Use a smaller MLIR input**

Profile with a test MLIR file instead of the full 75MB compiler:

```bash
timeout 30 perf record -g --call-graph dwarf -F 997 -o /tmp/perf.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    /work/build/tests/some-test.mlir -o /dev/null
```

## Profiling Specific Phases

### Profile only LLVM codegen (skip MLIR lowering)

If the MLIR → LLVM lowering finishes within N seconds and you want to profile what comes after:

```bash
# Record the full run
perf record -g --call-graph dwarf -F 997 -o /tmp/perf.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir -o /dev/null

# Then filter by time range in perf script output
perf script -i /tmp/perf.data --header | head -5   # check time range
```

### perf stat for high-level counters

No data file needed — just summary stats:

```bash
timeout 30 perf stat -d \
    ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir -o /dev/null
```

This gives IPC (instructions per cycle), cache miss rates, branch mispredictions — useful for diagnosing whether a bottleneck is compute-bound or memory-bound.

## Lightweight Alternative: Frame-pointer call graphs

If you build eco-boot-native with `-fno-omit-frame-pointer`, you can use much cheaper stack unwinding:

```bash
# In CMakeLists.txt or via cmake:
cmake --preset ninja-clang-lld-linux -DCMAKE_CXX_FLAGS="-fno-omit-frame-pointer"
cmake --build build --target eco-boot-native

# Then record with fp-based stacks (much smaller perf.data):
timeout 30 perf record -g --call-graph fp -F 997 -o /tmp/perf.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir -o /dev/null
```

## Other Available Tools

- **gprof**: Compile with `-pg`, run, then `gprof eco-boot-native gmon.out`. Works but adds overhead and doesn't handle multithreading well.
- **valgrind/callgrind**: Not installed by default. `sudo apt install valgrind` then `valgrind --tool=callgrind ./eco-boot-native ...`. Very slow (20-50x) but gives exact call counts.

## Interpreting Results

### What to look for

| Pattern | Meaning | Action |
|---|---|---|
| One function dominates (>20%) | Hot spot | Read the function, look for caching/algorithmic improvements |
| Same function hot on all threads | Per-function lowering bottleneck | The function itself needs optimization |
| High IPC (>2.0) | Compute-bound | Algorithmic improvement needed |
| Low IPC (<0.5) | Memory-bound | Cache locality / data structure changes |
| High branch-miss % (>5%) | Branch prediction issues | Consider branchless alternatives |

### Known hotspots in eco-boot-native (as of 2026-03-22)

- **`mlir::SymbolTable::lookupSymbolIn` (~45%)**: Repeated symbol table lookups during lowering. Consider caching a `DenseMap<StringAttr, Operation*>` upfront.
- **`mlir::Attribute::getContext` (~39%)**: Heavy attribute construction/comparison during lowering passes.
