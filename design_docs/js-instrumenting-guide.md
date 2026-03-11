# Instrumenting the Eco Bootstrap Compiler (Compiled JS)

Guide for adding debug instrumentation to `eco-boot-2.js` — the Elm-compiled
bootstrap compiler that runs under Node.js.

## Why JS-level patching?

The bootstrap build uses `--optimize`, which strips all `Debug.log` and `Debug.todo`
calls from the Elm source. You cannot use Elm-level debugging in the compiled output.
Instead, patch the generated JS directly.

## The IIFE scoping problem

`eco-boot-2.js` wraps all compiled code in an IIFE:

```javascript
(function(scope){ 'use strict';
    // ... all compiled Elm code lives here ...
    // Variables declared here are NOT accessible from outside
})(this);
```

This means:
- Variables declared with `var`/`let`/`const` inside the IIFE are invisible to the
  runner script (`eco-boot-2-runner.js`)
- The runner script cannot read debug counters or state from inside the IIFE
- `this` inside the IIFE refers to `globalThis` in Node.js (module scope)

## Solution: Use `globalThis` for cross-scope communication

Declare debug variables inside the IIFE but **also assign them to `globalThis`** so
the runner can read them:

```javascript
// Inside eco-boot-2.js, at the top of the IIFE (after 'use strict';)
var __dbg_total = 0;
var __dbg_occ = 0;
var __dbg_deep = 0;
var __dbg_maxD = 0;
var __dbg_maxN = '';

// After every update, mirror to globalThis:
__dbg_total++;
globalThis.__dbg_total = __dbg_total;
```

In the runner (`eco-boot-2-runner.js`), read via `globalThis`:

```javascript
process.on('exit', (code) => {
    var g = globalThis;
    process.stderr.write("Total calls: " + (g.__dbg_total !== undefined ? g.__dbg_total : 'N/A') + "\n");
    process.stderr.write("Max depth: " + (g.__dbg_maxD !== undefined ? g.__dbg_maxD : 'N/A') + "\n");
});
```

### Gotcha: falsy zero

`globalThis.__dbg_total || 'N/A'` shows `'N/A'` when the value is `0` because
`0` is falsy in JS. Always use `!== undefined` checks:

```javascript
// WRONG:
console.error("Total: " + (globalThis.__dbg_total || 'N/A'));

// RIGHT:
console.error("Total: " + (globalThis.__dbg_total !== undefined ? globalThis.__dbg_total : 'N/A'));
```

## Finding functions to patch

### MonoType discriminants

Elm compiles union type constructors to objects with a `$` discriminant field.
The MonoType variants in the compiled JS use these values:

| Elm constructor | JS `.$` value | Numeric |
|-----------------|---------------|---------|
| `MInt`          | `0`           | 0       |
| `MFloat`        | `1`           | 1       |
| `MBool`         | `2`           | 2       |
| `MChar`         | `3`           | 3       |
| `MString`       | `4`           | 4       |
| `MUnit`         | `5`           | 5       |
| `MList`         | `6`           | 6       |
| `MTuple`        | `7`           | 7       |
| `MRecord`       | `8`           | 8       |
| `MCustom`       | `9`           | 9       |
| `MFunction`     | `10`          | 10      |
| `MVar`          | `11`          | 11      |
| `MErased`       | `12`          | 12      |

### Locating functions by name

Elm compiles top-level functions with mangled names based on module path.
Search for the function by its module-qualified name:

```bash
# Find insertBinding in the compiled JS
grep -n 'insertBinding' eco-boot-2.js | head -20

# Find resolveMonoVarsHelp
grep -n 'resolveMonoVarsHelp' eco-boot-2.js | head -20
```

The compiled name pattern is typically:
`$author$project$Module$SubModule$functionName`

For example: `$author$project$Compiler$Monomorphize$TypeSubst$insertBinding`

### Understanding compiled function structure

Elm functions compile to curried form. A 3-argument function becomes:

```javascript
var $author$project$Mod$func = F3(function(a, b, c) {
    // body
});
```

`F3` is an Elm runtime wrapper for 3-argument functions. The actual logic is
in the inner `function(a, b, c) { ... }`.

## Practical instrumentation patterns

### Pattern 1: Counting calls

```javascript
// Before the function body, declare counter at IIFE scope
var __dbg_total = 0;

// Inside the function, increment and mirror
var $author$project$Mod$func = F3(function(name, ty, subst) {
    __dbg_total++; globalThis.__dbg_total = __dbg_total;
    // ... original body ...
});
```

### Pattern 2: Depth measurement helper

Add a helper function near the top of the IIFE:

```javascript
function __dbg_depth(monoType, maxDepth) {
    if (!monoType || maxDepth <= 0) return 0;
    switch (monoType.$) {
        case 6: // MList
            return 1 + __dbg_depth(monoType.a, maxDepth - 1);
        case 7: // MTuple
            var elems = monoType.a; // Elm List
            var max = 0;
            while (elems.$ !== '[]' && elems.$ !== 0) {
                var d = __dbg_depth(elems.a, maxDepth - 1);
                if (d > max) max = d;
                elems = elems.b;
            }
            return 1 + max;
        case 9: // MCustom
            var args = monoType.c; // third field
            var max = 0;
            while (args.$ !== '[]' && args.$ !== 0) {
                var d = __dbg_depth(args.a, maxDepth - 1);
                if (d > max) max = d;
                args = args.b;
            }
            return 1 + max;
        case 10: // MFunction
            // args in .a, ret in .b
            return 1 + __dbg_depth(monoType.b, maxDepth - 1);
        default:
            return 0;
    }
}
```

### Pattern 3: Occurs check helper

```javascript
function __dbg_hasMVar(name, monoType, maxDepth) {
    if (!monoType || maxDepth <= 0) return false;
    if (monoType.$ === 11 && monoType.a === name) return true; // MVar
    switch (monoType.$) {
        case 6: return __dbg_hasMVar(name, monoType.a, maxDepth - 1);
        case 7: // MTuple - iterate Elm list
            var elems = monoType.a;
            while (elems.$ !== '[]' && elems.$ !== 0) {
                if (__dbg_hasMVar(name, elems.a, maxDepth - 1)) return true;
                elems = elems.b;
            }
            return false;
        case 9: // MCustom
            var args = monoType.c;
            while (args.$ !== '[]' && args.$ !== 0) {
                if (__dbg_hasMVar(name, args.a, maxDepth - 1)) return true;
                args = args.b;
            }
            return false;
        case 10: // MFunction
            if (__dbg_hasMVar(name, monoType.b, maxDepth - 1)) return true;
            var args = monoType.a;
            while (args.$ !== '[]' && args.$ !== 0) {
                if (__dbg_hasMVar(name, args.a, maxDepth - 1)) return true;
                args = args.b;
            }
            return false;
        default:
            return false;
    }
}
```

### Pattern 4: Sampling to reduce noise

For high-frequency functions, sample every Nth call:

```javascript
if (__dbg_total % 100 === 0) {
    var d = __dbg_depth(normalizedTy, 30);
    if (d > __dbg_maxD) { __dbg_maxD = d; __dbg_maxN = name; }
    globalThis.__dbg_maxD = __dbg_maxD;
    globalThis.__dbg_maxN = __dbg_maxN;
    if (d > 10) {
        __dbg_deep++;
        globalThis.__dbg_deep = __dbg_deep;
        console.error("DEEP_BINDING #" + __dbg_deep + ": \"" + name + "\" depth=" + d);
    }
}
```

## Elm List representation in JS

Elm lists compile to linked-list cons cells:

```javascript
// Non-empty: { $: '::', a: head, b: tail }   (or $: 1 with --optimize)
// Empty:     { $: '[]' }                      (or $: 0 with --optimize)
```

With `--optimize`, the discriminants are numeric (`0` for nil, `1` for cons).
Without `--optimize`, they are strings (`'[]'` and `'::'`).

Iterate an Elm list in JS:

```javascript
var list = someElmList;
while (list.$ !== '[]' && list.$ !== 0) {
    var element = list.a;
    // ... process element ...
    list = list.b;
}
```

## Running with increased memory

The bootstrap compiler's monomorphization phase is memory-intensive.
Default Node.js heap (4GB) is often insufficient:

```bash
node --max-old-space-size=8192 --stack-size=65536 bin/eco-boot-2-runner.js \
    make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/output.mlir \
    ../src/Terminal/Main.elm \
    2> /tmp/debug-output.err
```

- `--max-old-space-size=8192`: 8GB heap (use 12288 for 12GB if needed)
- `--stack-size=65536`: 64MB stack (prevents stack overflow in deep recursion)
- `2> /tmp/debug-output.err`: Capture `console.error` debug output separately from stdout

## Important: monomorphization only runs for MLIR output

The monomorphization pass only executes when `--output=*.mlir` is specified.
Using `make` (JS output) skips monomorphization entirely — `insertBinding` and
related functions will never be called.
