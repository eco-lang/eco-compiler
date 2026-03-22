# C++ Backend Profile & Fix Loop

Profile and optimize the C++ compiler backend (eco-boot-native, Stage 6 of bootstrap).
Follow the profiling guide in @cpp-profiling-howto.md for recording and interpreting results.

## Prerequisites

```bash
# Enable perf
sudo sysctl kernel.perf_event_paranoid=-1

# Build eco-boot-native
cmake --build build --target eco-boot-native

# Verify MLIR input exists
ls compiler/build-kernel/bin/eco-compiler.mlir
```

## Take Baseline

Run E2E tests first to ensure nothing is broken:

```bash
cmake --build build --target full
```

Record baseline profile (1 minute timeout):

```bash
timeout 60 perf record -g --call-graph dwarf,16384 -F 997 \
    -o /tmp/perf-baseline.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir \
    -o /dev/null
```

Extract the flat profile aggregated across threads:

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
    | sort -rn | head -20
```

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
Read the relevant C++ source files in `runtime/src/codegen/`.
Reason about the root cause. Propose a fix.

### 4. Apply the fix
Edit the C++ source files. Keep changes minimal and focused.

### 5. Build and test

```bash
# Build
cmake --build build --target eco-boot-native

# Run E2E tests to verify correctness
cmake --build build --target full
```

Compare test results to previous run. If tests fail, fix or revert.

### 6. Profile again

```bash
timeout 60 perf record -g --call-graph dwarf,16384 -F 997 \
    -o /tmp/perf-after.data \
    -- ./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir \
    -o /dev/null
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
    | sort -rn | head -20
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
