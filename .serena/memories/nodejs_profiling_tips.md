# Node.js Profiling Tips for Stage 5 Compilation

## --prof vs --cpu-prof
- **Use `--prof`**: Writes V8 tick log incrementally to `isolate-*.log`. Works even if process is killed/times out.
- **Avoid `--cpu-prof`**: Only writes output on clean exit. If process times out (killed by `timeout`), the `.cpuprofile` file is empty/missing. Not worth using for long-running compilations that may not complete.

## Processing prof output
- `node --prof-process <isolate-file>.log` takes a LONG time (minutes) and can even crash/abort on large logs.
- **Always pipe to a file first**: `node --prof-process isolate-*.log 2>&1 | head -200 > prof-output.txt`
- Then grep/read the cached file for results instead of re-running prof-process.

## Stack size
- Stage 5 compilation hits stack overflow at default stack size due to deep monadic bind chains (`System.TypeCheck.IO.andThen`).
- Always use `--stack-size=65536` (64KB) when running Stage 5: `node --stack-size=65536 --prof bin/eco-boot-2-runner.js make ...`

## Memory
- System has 16GB RAM, Node heap set to 12GB: `export NODE_OPTIONS="--max-old-space-size=12000"`
- Never run more than one node process at a time.

## Typical profiling command
```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cd /work/compiler/build-kernel
timeout 300 node --stack-size=65536 --prof bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```
