# Memory Profiling the Bootstrap Compiler

## Overview

The Elm compiler runs as a single Node.js process. Memory profiling works by
injecting instrumentation into `_Scheduler_step` in the compiled JS output
(eco-boot-2.js). The instrumentation logs heap and RSS usage at two kinds of
boundary:

- **IO boundaries** — every time the scheduler dispatches an IO callback
- **Bind milestones** — every 100,000 andThen binds (pure computation checkpoints)

## Output format

Lines are written to stderr:

    [mem <elapsed>s] <reason> rss=<N>MB heap=<used>/<total>MB ext=<N>MB binds=<N> ios=<N>

Where:
- `elapsed` — seconds since process start
- `reason` — either `io` or `bind`
- `rss` — resident set size (total process memory)
- `heap` — V8 heap used / heap total
- `ext` — V8 external memory (Buffers, TypedArrays)
- `binds` — cumulative andThen bind count
- `ios` — cumulative IO callback count

## Injecting the instrumentation

Run this against a clean eco-boot-2.js (after build-verify.sh confirms fixed point):

```javascript
// inject-mem.js
const fs = require('fs');
const path = process.argv[2] || 'bin/eco-boot-2.js';
let code = fs.readFileSync(path, 'utf8');

const instrumentationCode = `
var _Mem_startTime = Date.now();
var _Mem_bindCount = 0;
var _Mem_ioCount = 0;
var _Mem_lastLogBinds = 0;
var _Mem_BIND_INTERVAL = 100000;

function _Mem_log(reason) {
    var mem = process.memoryUsage();
    var elapsed = ((Date.now() - _Mem_startTime) / 1000).toFixed(1);
    var rss = (mem.rss / 1048576).toFixed(0);
    var heapUsed = (mem.heapUsed / 1048576).toFixed(0);
    var heapTotal = (mem.heapTotal / 1048576).toFixed(0);
    var ext = (mem.external / 1048576).toFixed(0);
    process.stderr.write('[mem ' + elapsed + 's] ' + reason +
        ' rss=' + rss + 'MB heap=' + heapUsed + '/' + heapTotal +
        'MB ext=' + ext + 'MB binds=' + _Mem_bindCount + ' ios=' + _Mem_ioCount + '\\n');
}

`;

// Insert instrumentation globals just before _Scheduler_step
code = code.replace(
    'function _Scheduler_step(proc)\n{',
    instrumentationCode + 'function _Scheduler_step(proc)\n{'
);

// Instrument bind counting (rootTag 0 = andThen, 1 = onError)
code = code.replace(
    `\t\t\tproc.f = proc.g.b(proc.f.a);\n\t\t\tproc.g = proc.g.i;\n\t\t}\n\t\telse if (rootTag === 2)`,
    `\t\t\tproc.f = proc.g.b(proc.f.a);\n\t\t\tproc.g = proc.g.i;\n` +
    `\t\t\t_Mem_bindCount++;\n` +
    `\t\t\tif (_Mem_bindCount - _Mem_lastLogBinds >= _Mem_BIND_INTERVAL) {\n` +
    `\t\t\t\t_Mem_log('bind');\n` +
    `\t\t\t\t_Mem_lastLogBinds = _Mem_bindCount;\n` +
    `\t\t\t}\n` +
    `\t\t}\n\t\telse if (rootTag === 2)`
);

// Instrument IO callback counting (rootTag 2 = binding/callback)
code = code.replace(
    `\t\telse if (rootTag === 2)\n\t\t{\n\t\t\tproc.f.c = proc.f.b(function(newRoot) {`,
    `\t\telse if (rootTag === 2)\n\t\t{\n\t\t\t_Mem_ioCount++;\n\t\t\t_Mem_log('io');\n` +
    `\t\t\tproc.f.c = proc.f.b(function(newRoot) {`
);

fs.writeFileSync(path, code, 'utf8');
console.log('Instrumentation injected into ' + path);
```

A ready-to-use copy of this script lives at `compiler/build-kernel/inject-mem.js`.

Usage:

```bash
cd compiler/build-kernel
node inject-mem.js bin/eco-boot-2.js
```

## Running a profiled Stage 5

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cd compiler/build-kernel

# Cold run (no caches — profiles compilation + codegen)
find eco-stuff -name '*.ecot' -delete
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    src/Terminal/Main.elm \
    > /tmp/stage5-cold-stdout.log 2> /tmp/stage5-cold-stderr.log

# Warm run (caches intact — profiles codegen only)
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    src/Terminal/Main.elm \
    > /tmp/stage5-warm-stdout.log 2> /tmp/stage5-warm-stderr.log
```

## Analysing the output

**Note:** The `[mem ...]` lines are written via `process.stderr.write`, but when
the runner script captures stderr separately, the instrumented scheduler output
may end up in stdout instead (the runner's own stderr redirection takes
precedence). Check both files — use whichever contains the `[mem ...]` lines:

```bash
grep -l '^\[mem ' /tmp/stage5-warm-stdout.log /tmp/stage5-warm-stderr.log
```

Peak RSS and heap (adjust the filename as needed):

```bash
python3 -c "
import re
maxrss = maxheap = 0
for line in open('/tmp/stage5-warm-stdout.log'):
    m = re.search(r'rss=(\d+)MB heap=(\d+)/(\d+)MB', line)
    if not m: continue
    rss, heap = int(m.group(1)), int(m.group(2))
    if rss > maxrss: maxrss = rss
    if heap > maxheap: maxheap = heap
print(f'Peak RSS: {maxrss}MB, Peak heap: {maxheap}MB')
"
```

Finding large jumps between consecutive samples (phase transitions):

```bash
python3 -c "
import re
prev = 0
for line in open('/tmp/stage5-warm-stdout.log'):
    m = re.search(r'\[mem ([\d.]+)s\] \w+ rss=(\d+)MB heap=(\d+)/\d+MB .* ios=(\d+)', line)
    if not m: continue
    t, rss, heap, ios = float(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
    if prev and abs(heap - prev) > 500:
        print(f't={t:.1f}s heap={heap}MB ({heap-prev:+d}MB) rss={rss}MB ios={ios}')
    prev = heap
"
```

Long pure-computation gaps (many seconds between IO samples) indicate phases
where large data structures are being built without yielding to the scheduler.
These are the main targets for memory optimisation.
