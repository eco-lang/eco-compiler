# C++ Backend Profile & Fix Loop

Profile and optimize the C++ runtime (GC, allocator, closure dispatch, kernel) by
measuring the **native compiler self-compiling** — Stage 7 of @bootstrap.md. The
target binary is `build/compiler/build-kernel/bin/eco-compiler` (built by Stage 6),
running its own front-end + typed-opt pipeline against the compiler's own
sources. This is the largest, most representative real workload we have.

See @perf-profiling.md for the full recording recipe and parameter rationale.

## Prerequisites

```bash
# Enable perf
sudo sysctl kernel.perf_event_paranoid=-1

# Build the runtime libraries + eco-boot-native (used by Stage 6 to produce eco-compiler)
cmake --build build --target eco-boot-native

# Verify the Stage-6 output (the binary we will profile) exists
ls -l build/compiler/build-kernel/bin/eco-compiler
```

If `build/compiler/build-kernel/bin/eco-compiler` is missing or stale, rebuild it via
the Stage 5 → Stage 6 path described in @bootstrap.md.

## Take Baseline

Run E2E tests first to ensure nothing is broken:

```bash
cmake --build build --target full
```

Record baseline profile (100 s window — enough to capture the front-end +
typed-opt phases of the self-compile):

```bash
cd /work/build/compiler/build-kernel && perf record \
    -F 499 \
    --call-graph dwarf,6144 \
    -m 256 \
    -z \
    -o /tmp/perf-baseline.data \
    -- timeout --signal=INT 100s \
    bin/eco-compiler make \
        --optimize \
        --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/eco-compiler-boot.mlir \
        /work/compiler/src/Terminal/Main.elm
```

`timeout --signal=INT` lets perf flush `perf.data` cleanly. The compiler runs
much longer than 100 s — the SIGINT just bounds the trace.

Extract the flat profile (top symbols by self-time):

```bash
perf report -i /tmp/perf-baseline.data --stdio --no-children -g none --percent-limit 0.1 2>&1 \
    | grep -E '^\s+[0-9]' \
    | awk '{
        pct=$1; sub(/%/,"",pct);
        sym=""; for(i=5;i<=NF;i++) sym=sym" "$i;
        overhead[sym]+=pct
    } END {
        for(s in overhead) printf "%8.2f%% %s\n", overhead[s], s
    }' \
    | sort -rn | head -30
```

For inclusive (children-aggregated) view, drop `--no-children`. For DSO
breakdown, use `--sort=dso`.

Record the baseline in @cpp-prof-hints.md under "Baseline Measurements".

## LOOP

### 1. Check /usage
If over 90%, run: `sleep <seconds until reset + 60>`.
Then continue — do NOT stop or produce a report.

### 2. Pick the next issue
Pick the next issue from @cpp-prof-hints.md that is not marked FIXED or SKIPPED.
If there are none, go to step 2b.

### 2b. Analyse the latest profiling data
Look for new bottlenecks — functions above 1% of total aggregated CPU time.
Add any new issues to @cpp-prof-hints.md ranked by impact.
If you found new issues, go back to step 2.
If no actionable bottleneck above 1% remains, or if the last 3 consecutive
fix attempts (across any issues) all failed to produce measurable improvement,
go to DONE.

### 3. Investigate root cause
Read the relevant runtime source files in `runtime/src/` (allocator,
nursery/old-gen GC, root set, closure dispatch, kernel ops). Reason about the
root cause. Propose a fix.

### 4. Apply the fix
Edit the C++ source files. Keep changes minimal and focused.

### 5. Build and test

```bash
# Build the runtime + eco-boot-native (this also rebuilds any libraries
# that eco-compiler will be re-linked against if you re-run Stage 6).
cmake --build build --target eco-boot-native

# If the change touches code linked into eco-compiler itself (kernel,
# runtime libs), regenerate the Stage 6 binary so the next profile reflects it:
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler

# Run E2E tests to verify correctness
cmake --build build --target full
```

Compare test results to previous run. If tests fail, fix or revert.

### 6. Profile again

```bash
cd /work/build/compiler/build-kernel && perf record \
    -F 499 \
    --call-graph dwarf,6144 \
    -m 256 \
    -z \
    -o /tmp/perf-after.data \
    -- timeout --signal=INT 100s \
    bin/eco-compiler make \
        --optimize \
        --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/eco-compiler-boot.mlir \
        /work/compiler/src/Terminal/Main.elm
```

Extract and compare:

```bash
perf report -i /tmp/perf-after.data --stdio --no-children -g none --percent-limit 0.1 2>&1 \
    | grep -E '^\s+[0-9]' \
    | awk '{
        pct=$1; sub(/%/,"",pct);
        sym=""; for(i=5;i<=NF;i++) sym=sym" "$i;
        overhead[sym]+=pct
    } END {
        for(s in overhead) printf "%8.2f%% %s\n", overhead[s], s
    }' \
    | sort -rn | head -30
```

### 7. Evaluate

Did the fix improve things?

- **YES** → Mark FIXED in @cpp-prof-hints.md. Copy perf-after.data to perf-baseline.data. Go to LOOP.
- **NO** → Revert the fix. Record what you tried and why it did not work
  in @cpp-prof-hints.md under that issue's entry.
  Have you already tried 3 different approaches for this issue?
  - **YES** → Mark SKIPPED in @cpp-prof-hints.md with explanation. Go to LOOP.
  - **NO** → Go back to step 3 with a different approach.

## DONE

Produce a detailed report of what was fixed and what was skipped (and why).
Do NOT go to DONE while there are issues that are not FIXED or SKIPPED.
