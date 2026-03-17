# elm-coverage: Program Theory

This document captures the **theory** of elm-coverage in the sense of Peter Naur's
"Programming as Theory Building" — the mental model, design rationale, invariants,
and constraints that live in the heads of those who understand the system.

The code is a by-product. This document is an attempt to preserve the understanding.

---

## 1. Core Philosophy

### Coverage is Visualization, Not a Metric

The fundamental belief driving this system:

> **The goal is NOT to condense coverage information into a single percentage.**

A single coverage number creates perverse incentives. Engineers write tests that
touch code without asserting anything meaningful. High coverage becomes a false
sense of security.

Instead, elm-coverage generates **visual reports** that show:
- Which expressions were evaluated
- How many times each was evaluated
- Which functions are most complex (and thus most deserving of tests)

This is a philosophical stance baked into the architecture. There is no
"get coverage percentage" API. The system is designed to guide humans, not
satisfy CI thresholds.

### Expression-Level, Not Line-Level

Coverage is tracked at the **expression** level, not the line level.

This is a critical distinction. A single line may contain multiple expressions:

```elm
if condition then doA else doB
```

Line coverage would mark this as "covered" if any part executes. Expression
coverage distinguishes whether `doA`, `doB`, or both were evaluated.

The system tracks five expression types:
1. **Declaration** — top-level function bodies
2. **LetDeclaration** — let-binding bodies
3. **LambdaBody** — anonymous function bodies
4. **CaseBranch** — individual case pattern branches
5. **IfElseBranch** — if/else branches

This granularity is intentional. It reveals which code paths are untested.

---

## 2. Mental Execution Model

### The Pipeline

Think of elm-coverage as a **linear pipeline**:

```
Source Files
     │
     ▼
┌─────────────────┐
│  elm-instrument │  (Rust binary)
│  AST transform  │
└────────┬────────┘
         │ Injects Coverage.track calls
         ▼
  Instrumented Sources + info.json (metadata)
         │
         ▼
┌─────────────────┐
│    elm-test     │  via fake-elm compiler
│  (runs tests)   │
└────────┬────────┘
         │ Captures evaluation counts
         ▼
  data-<pid>.json files (raw counts)
         │
         ▼
┌─────────────────┐
│    aggregate    │  (Node.js)
│  merge counts   │
└────────┬────────┘
         │
         ▼
  Unified coverage data
         │
         ▼
┌─────────────────┐
│    Analyzer     │  (Elm via Node.js)
│  generate HTML  │
└────────┬────────┘
         │
         ▼
  coverage.html
```

**Read the system as a pipeline, not as interacting components.**

Each stage transforms data and passes it forward. There is no bidirectional
communication. Understanding any stage requires only understanding its input
and output formats.

### The Fake Compiler Trick

**Why does a "fake elm" binary exist?**

elm-test compiles your tests using the Elm compiler. We cannot modify the Elm
compiler itself. But we need to inject coverage tracking into the generated
JavaScript.

The solution: **intercept the compilation**.

`fake-elm` is a wrapper that:
1. Delegates to the real `elm` compiler
2. After compilation, reads the generated JS
3. Finds the `Coverage.track` function (which is a no-op in source)
4. Replaces it with actual tracking code that records evaluations
5. Hooks into elm-test's port to write data when tests finish

This is a **necessary hack**. Elm's compiler is a black box. The fake compiler
pattern is the only way to inject runtime behavior without forking Elm itself.

**Invariant**: The fake-elm must produce output compatible with elm-test's
expectations. It cannot change the shape of the compiled program, only inject
side effects into the Coverage.track function.

### The Placeholder Module Pattern

In `kernel-src/Coverage.elm`:

```elm
track : String -> Int -> ()
track line index = ()
```

This is a **placeholder**. The real implementation is injected at compile time.

Why? Because:
1. Elm source code must be valid Elm — no inline JS
2. The instrumented code calls `Coverage.track moduleName index`
3. During normal Elm compilation, this would be a no-op
4. fake-elm replaces this with actual tracking at the JS level

**Do not modify this file thinking it controls coverage behavior.** The real
logic is in `fake-elm`'s regex replacement.

---

## 3. Key Invariants

### info.json Structure

The `elm-instrument` binary produces `.coverage/info.json` with this structure:

```json
{
  "Module.Name": [
    {
      "from": {"line": 10, "column": 1},
      "to": {"line": 15, "column": 20},
      "type": "declaration",
      "name": "functionName",
      "complexity": 3
    },
    ...
  ]
}
```

**Invariants**:
- Module names are dot-separated (e.g., `"Module.Submodule"`)
- Regions are **ordered by position** within each module
- Each region has a unique index (its array position)
- The `count` field is **added later** by aggregation — not present in info.json

### Coverage Data Flow

1. `elm-instrument` assigns each instrumented expression an **index** (0, 1, 2, ...)
2. Instrumented code calls `Coverage.track "Module.Name" 0` (or 1, 2, etc.)
3. fake-elm's injected code maintains `counters["Module.Name"] = [0, 0, 2, ...]`
4. When tests finish, indices are written to `data-<pid>.json`
5. `aggregate.js` reads info.json, then merges counts from all data files
6. Result: info.json structure with `count` field added to each region

**The index in `Coverage.track` must match the array index in info.json.**
This is maintained by elm-instrument. If this invariant breaks, counts will
be attributed to wrong regions.

### Module Name to File Path Mapping

Module names map to file paths via convention:

```
Module.Submodule → src/Module/Submodule.elm
```

This is computed in `aggregate.js`:
```javascript
function toPath(sourcePath, moduleName) {
    var parts = moduleName.split(".");
    var moduleFile = parts.pop();
    parts.push(moduleFile + ".elm");
    return path.join.apply(path, [sourcePath].concat(parts));
}
```

**This must match how Elm resolves modules.** If your project uses non-standard
source directories, the mapping must account for it.

---

## 4. Design Decisions and Rejected Alternatives

### Why External Binary for Instrumentation?

**Decision**: Use a separate Rust binary (`elm-instrument`) for AST transformation.

**Rejected alternative**: Do instrumentation in JavaScript/Node.js.

**Rationale**:
- Elm's AST is complex; a proper parser is needed
- Rust is fast and produces native binaries
- The instrumentation logic is isolated and can be tested independently
- Platform-specific binaries are distributed via `binwrap`

**Trade-off**: Adds complexity to distribution (must ship binaries for each platform).
But the alternative — shipping a JS-based Elm parser — would be slower and harder
to maintain.

### Why Elm for Report Generation?

**Decision**: Generate HTML reports using Elm code running in Node.js.

**Rejected alternatives**:
- Generate HTML in JavaScript directly
- Use a templating engine

**Rationale**:
- Type safety for the data model (Coverage types are complex)
- Functional approach to HTML generation (no side effects, easy to test)
- Domain alignment — this is a tool for Elm developers
- `zwilias/elm-html-string` allows running Elm's Html API server-side

**Trade-off**: Requires compiling Elm to JS and running it via Node. But the
type safety and maintainability benefits outweigh the build complexity.

### Why Platform.worker?

The Analyzer uses `Platform.worker`, not `Browser.application`.

**Rationale**:
- No DOM needed — we're generating HTML as a string
- Runs in Node.js, not a browser
- Pure transformation: input → output via ports
- The `Service.elm` abstraction provides a clean request/response pattern

**Invariant**: The Analyzer must remain a pure function from (coverage data, source files)
to HTML string. It must not depend on browser APIs.

### Why Cyclomatic Complexity?

**Decision**: Track and display cyclomatic complexity for each declaration.

**Rationale**:
- Guides developers toward testing complex code first
- A function with complexity 15 has more paths than one with complexity 2
- Visual indicators (the red dots in the line gutter) draw attention to complexity

**Philosophy**: Complexity is a better guide than coverage percentage. A simple
function with 50% coverage may be fine. A complex function with 90% coverage
may still hide bugs.

---

## 5. Danger Zones

### Modifying fake-elm's Regex

The regex in `fake-elm` that finds `Coverage.track`:

```javascript
var pattern = new RegExp(
    "(^var\\s+\\$author\\$project\\$Coverage\\$track.*$\\s+function\\s+\\()" +
    "([a-zA-Z]+)" + // arg1
    "\\s*,\\s*" +
    "([a-zA-Z]+)" + // arg2
    "\\)\\s+{$",
    "gm"
);
```

**This is extremely fragile.** It depends on:
- Elm's exact JS output format
- The mangled name `$author$project$Coverage$track`
- Specific whitespace patterns

If Elm's compiler changes its JS output format, this will silently fail.
Coverage will appear to work but record nothing.

**Warning**: Any Elm compiler upgrade requires verifying this regex still matches.

### The elm-test Port Hook

fake-elm subscribes to `elmTestPort__send` to detect test completion:

```javascript
app.ports.elmTestPort__send.subscribe(function(rawData) {
    var data = JSON.parse(rawData);
    if (data.type === "FINISHED") {
        fs.writeFileSync("data-" + process.pid + ".json", JSON.stringify(counters));
    }
});
```

**This depends on elm-test's internal port protocol.** If elm-test changes how
it signals completion, coverage data won't be written.

**Warning**: elm-test upgrades require verifying the port protocol still works.

### The .coverage Directory

All intermediate files live in `.coverage/`:
- `instrumented/` — modified source files
- `info.json` — instrumentation metadata
- `data-*.json` — raw coverage counts
- `coverage.html` — final report

**Invariant**: `runner.js` deletes `.coverage/` at the start of each run. Do not
rely on files persisting between runs.

**Warning**: If a run fails partway, `.coverage/` may contain partial data from
different runs. Always start fresh.

### Source File Timestamps

After test completion:

```javascript
return Promise.map(allSources(args), function(file) {
    return touch(file);
});
```

**Why touch files?** To invalidate Elm's compilation cache. Instrumented files
have different content than originals. If Elm's cache thinks nothing changed,
it may use stale compiled output.

**Warning**: If you see "tests pass but coverage is zero", suspect caching issues.

---

## 6. What This System Is NOT

### Not a Mutation Testing Tool

Coverage tells you what code was **evaluated**. It does not tell you if that
code was **tested meaningfully**.

```elm
-- This test provides 100% coverage but tests nothing:
test "covers add" <|
    \_ -> let _ = add 1 2 in Expect.pass
```

elm-coverage explicitly does not try to solve this problem. That would require
mutation testing, which is a different tool.

### Not a CI Gating Mechanism

There is no "fail if coverage below X%" feature. This is intentional. The
README explicitly warns against using coverage as a single metric.

If you add such a feature, you are working against the design philosophy.

### Not a Profiler

The evaluation counts show **how many times** code was evaluated, but this is
not performance profiling. The counts come from test runs, not production
workloads. High counts mean "tested thoroughly", not "hot path".

---

## 7. Reading the Code

### Entry Points

- **CLI invocation**: `bin/elm-coverage` → `lib/runner.js:run()`
- **Report generation only**: `lib/runner.js:generateOnly()`
- **Elm analyzer**: `src/Analyzer.elm:main`

### Key Data Types

In Elm (`src/Coverage.elm`):
- `Annotation` — the type of instrumented expression
- `AnnotationInfo` — `(Region, Annotation, Int)` where Int is evaluation count
- `Map` — `Dict String (List AnnotationInfo)` keyed by module name

In JavaScript:
- `coverageData` — mirrors the Elm `Map` structure
- `moduleMap` — maps module names to file paths

### Following a Coverage Report

To understand how a line gets marked as covered/uncovered:

1. `Source.render` converts source + coverage info into `Content` tree
2. `Markup.render` converts `Content` tree into `Line` list
3. `Markup.wrapper` wraps text in `<span class="covered">` or `<span class="uncovered">`
4. `toClass` decides class based on count (0 = uncovered)

The key insight: coverage markers are **nested spans**. An expression inside
another expression produces nested `<span>` elements. The innermost span's
class determines the color.

---

## 8. Summary: The Theory in One Page

**elm-coverage exists because**:
- Elm has no built-in coverage tooling
- Coverage visualization (not metrics) helps write better tests
- Complex functions deserve more testing attention

**The core trick is**:
- Instrument Elm source with `Coverage.track` calls at expression boundaries
- Intercept compilation to inject actual tracking into the no-op placeholder
- Aggregate counts from test runs
- Render visual reports showing evaluation patterns

**The system assumes**:
- elm-test is the test runner
- The Elm compiler's JS output format is stable (fragile assumption)
- elm-test's port protocol is stable (fragile assumption)
- Module names map to file paths by standard convention

**The system explicitly rejects**:
- Coverage as a single percentage metric
- CI gating based on coverage thresholds
- Mutation testing (different problem)

**If you're modifying this code**:
- The fake-elm regex is the most fragile part
- The data flow is a pipeline — follow it linearly
- The Elm analyzer is pure — it transforms data, nothing more
- The philosophy is anti-metric — don't add percentage-based features

**If the original authors are gone**:
- Test that fake-elm's regex matches current Elm compiler output
- Test that elm-test's port protocol still signals FINISHED
- Verify module name to path mapping matches your project structure
- When in doubt, trace data through the pipeline manually
