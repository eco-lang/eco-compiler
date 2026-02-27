# Bootstrap IO Wiring Plan

## Status: IMPLEMENTED (Phase 1-4 complete, Phase 5-6 pending)

## Goal

Wire up the full three-stage bootstrap pipeline:

1. **Stage 1** (Bootstrap): Stock Elm compiler → `eco-boot.js` using XHR IO → Node.js handler → JS kernel
2. **Stage 2** (Kernel JS): `eco-boot.js` compiles Eco → `eco-node.js` using `Eco.Kernel.*` directly
3. **Stage 3** (Native): `eco-node.js` compiles Eco → `eco-native` linked with C++ IO kernel

## Current State Analysis

### What Already Exists

| Component | Location | Status |
|-----------|----------|--------|
| JS kernel IO | `eco-kernel-cpp/src/Eco/Kernel/*.js` | Complete (Console, File, Process, Env, Runtime, MVar) |
| C++ kernel IO | `eco-kernel-cpp/src/eco/*.cpp` | Complete (same modules) |
| Elm kernel wrappers | `eco-kernel-cpp/src/Eco/*.elm` | Complete (public API over kernel) |
| eco/kernel package | `eco-kernel-cpp/elm.json` | Defined |
| Compiler XHR IO | `compiler/src/Utils/Impure.elm` | Working (Http.task POST to mock server) |
| Compiler IO interface | `compiler/src/System/IO.elm` | Working (Haskell-style IO abstraction) |
| Node.js mock server | `compiler/bin/index.js` | Working (~30 endpoints) |
| Compiled compiler | `compiler/bin/guida.js` | Working |

### What the Compiler Uses Today

The compiler's IO is already XHR-based:
- `System/IO.elm` provides a Haskell-style interface (`hPutStr`, `putStr`, `getLine`, `withFile`, etc.)
- `Utils/Impure.elm` encodes IO requests as HTTP POST payloads (StringBody, JsonBody, BytesBody)
- `compiler/bin/index.js` is a Node.js process that mock-patches XMLHttpRequest and dispatches ~30+ IO operations
- Entry points: `Terminal/Main.elm` (CLI) and `API/Main.elm` (JSON API)

### Gap Analysis

The compiler's current XHR IO layer (`System/IO.elm` + `Utils/Impure.elm`) and the eco-kernel IO layer (`Eco.*.elm` + `Eco.Kernel.*.js`) are **two separate, incompatible interfaces**.

To bootstrap, we need:
1. The compiler to use `Eco.*` module names for IO (not `System.IO` / `Utils.Impure`)
2. Two implementations of those `Eco.*` modules: XHR variant and kernel variant
3. Build configs to select the right variant
4. The Node.js XHR handler to delegate to the JS kernel (not re-implement IO)

---

## Implementation Plan

### Phase 1: Create XHR IO Variant (`src-xhr/Eco/*.elm`)

Create Elm modules that mirror the `eco-kernel-cpp/src/Eco/*.elm` public API but implement IO via HTTP POST (like the current `Utils/Impure.elm` pattern).

#### 1.1 Create `compiler/src-xhr/` directory

New modules to create:

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `Eco/File.elm` | File operations | readString, writeString, readBytes, writeBytes, open, close, etc. |
| `Eco/Console.elm` | Console IO | write (stdout/stderr), readLine, readAll |
| `Eco/Process.elm` | Process management | spawn, wait, exit |
| `Eco/Env.elm` | Environment | lookup, rawArgs |
| `Eco/Runtime.elm` | Runtime utilities | dirname, random, saveState |
| `Eco/MVar.elm` | Concurrency primitives | new, read, take, put |

Each function:
1. Encodes the operation + args as JSON
2. Sends HTTP POST to a well-known endpoint (reuse the existing `Utils/Impure.elm` pattern)
3. Decodes the JSON response

The type signatures must match the existing `eco-kernel-cpp/src/Eco/*.elm` modules exactly.

**Key decision**: Reuse `Utils/Impure.elm`'s HTTP mechanism (it already works with the Node.js mock server). Each `Eco.*` module will import a shared XHR helper (either `Utils/Impure` itself or a minimal extraction of its HTTP plumbing).

#### 1.2 Create XHR helper module

Create `compiler/src-xhr/Eco/XHR.elm` — a minimal module that:
- Constructs HTTP POST requests to the Node handler
- Provides `Task`-based IO primitives
- Handles JSON encoding/decoding of requests and responses

This is essentially a cleaned-up extraction from `Utils/Impure.elm`, specialized for the `Eco.*` operation set.

#### 1.3 Update Node.js handler

Extend `compiler/bin/index.js` to:
- Accept the new Eco.* operation JSON format (alongside existing endpoints for backward compat)
- Delegate to the JS kernel functions from `eco-kernel-cpp/src/Eco/Kernel/*.js`

**Alternative**: Create a new handler (`compiler/bin/eco-io-handler.js`) that imports the JS kernel and exposes them via the mock XHR pattern. This keeps the old handler untouched.

The handler must be a **thin wrapper** — it translates JSON ↔ JS kernel calls, nothing more.

### Phase 2: Adapt Compiler to Use `Eco.*` IO

#### 2.1 Create adapter layer in the compiler

The compiler currently uses `System.IO` (Haskell-style). Rather than rewriting all compiler code to use `Eco.*` directly, create an adapter:

- Keep `System/IO.elm` as the compiler's internal IO interface
- Re-implement `System/IO.elm` to delegate to `Eco.File`, `Eco.Console`, `Eco.Process`, `Eco.Env` etc.
- This way, the compiler source doesn't need massive changes — only `System/IO.elm` changes its backing implementation

This is a **thin translation layer inside the compiler**, not a shared abstraction in the Eco library.

#### 2.2 Map System.IO operations to Eco.* calls

| System.IO operation | Eco.* equivalent |
|---------------------|------------------|
| `hPutStr handle str` | `Eco.Console.write Eco.Console.Stdout str` or `Eco.File.writeString handle str` |
| `putStr str` | `Eco.Console.write Eco.Console.Stdout str` |
| `putStrLn str` | `Eco.Console.write Eco.Console.Stdout (str ++ "\n")` |
| `getLine` | `Eco.Console.readLine` |
| `withFile path mode action` | `Eco.File.open path mode` + action + `Eco.File.close` |
| `hFileSize handle` | `Eco.File.size handle` |
| `hClose handle` | `Eco.File.close handle` |
| `exitWith code` | `Eco.Process.exit code` |

Plus directory operations, environment lookups, etc.

### Phase 3: Build Configurations

#### 3.1 Bootstrap build config (`elm-bootstrap.json`)

```json
{
    "type": "application",
    "source-directories": [
        "src",
        "src-xhr"
    ],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/core": "1.0.5",
            "elm/json": "1.1.3",
            "elm/http": "2.0.0",
            "elm/bytes": "1.0.8",
            ...existing compiler deps...
        }
    }
}
```

- **No** dependency on `eco/kernel`
- `src-xhr` provides the `Eco.*` modules via XHR
- Compiled by stock Elm compiler → `eco-boot.js`

#### 3.2 Kernel build config (`elm-kernel.json`)

```json
{
    "type": "application",
    "source-directories": [
        "src"
    ],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/core": "1.0.5",
            "eco/kernel": "1.0.0",
            ...existing compiler deps minus elm/http...
        }
    }
}
```

- Depends on `eco/kernel` (which provides `Eco.*` modules via kernel JS/C++)
- **No** `src-xhr` directory, **no** `elm/http` dependency
- Compiled by `eco-boot.js` → `eco-node.js`

### Phase 4: Node.js XHR Handler for Bootstrap

#### 4.1 Create `compiler/bin/eco-io-handler.js`

This is a standalone Node.js module that:

```javascript
// Pseudo-structure
const EcoKernelConsole = require('../../eco-kernel-cpp/src/Eco/Kernel/Console.js');
const EcoKernelFile = require('../../eco-kernel-cpp/src/Eco/Kernel/File.js');
const EcoKernelProcess = require('../../eco-kernel-cpp/src/Eco/Kernel/Process.js');
const EcoKernelEnv = require('../../eco-kernel-cpp/src/Eco/Kernel/Env.js');
const EcoKernelRuntime = require('../../eco-kernel-cpp/src/Eco/Kernel/Runtime.js');
const EcoKernelMVar = require('../../eco-kernel-cpp/src/Eco/Kernel/MVar.js');

function handleEcoIO(requestBody) {
    const { op, args } = JSON.parse(requestBody);
    switch (op) {
        case 'Console.write': return EcoKernelConsole.write(args.target, args.text);
        case 'File.readString': return EcoKernelFile.readString(args.path);
        // ... etc
    }
}
```

#### 4.2 Integrate with mock XHR server

Either:
- **Option A**: Extend `compiler/bin/index.js` to import and use `eco-io-handler.js`
- **Option B**: Create a new bootstrap runner (`compiler/bin/eco-boot-runner.js`) that sets up the mock XHR with the eco-io-handler

**Recommendation**: Option B — keeps the existing system untouched and creates a clean entry point for bootstrap.

#### 4.3 Bootstrap runner script

`compiler/bin/eco-boot-runner.js`:
```javascript
// 1. Set up mock XMLHttpRequest
// 2. Register eco-io-handler for /eco-io endpoint
// 3. Load eco-boot.js (the Elm-compiled bootstrap compiler)
// 4. Run it
```

### Phase 5: Wire Up Stage 2 (Kernel JS Build)

#### 5.1 Ensure eco/kernel package is properly structured

Verify `eco-kernel-cpp/elm.json` package definition works with Eco's kernel module system:
- Author: `"eco"`
- Kernel modules: `Eco.Kernel.*`
- Exposed modules: `Eco.File`, `Eco.Console`, `Eco.Process`, `Eco.Env`, `Eco.Runtime`, `Eco.MVar`

#### 5.2 Eco compiler kernel recognition

The Eco compiler must recognize:
- Kernel author `"eco"`
- Kernel module prefix `"Eco.Kernel."`
- Map Elm kernel calls → JS kernel files (Stage 2) or C++ symbols (Stage 3)

Check what's already implemented in the compiler for kernel recognition and what gaps remain.

### Phase 6: Wire Up Stage 3 (Native Build)

#### 6.1 C++ kernel symbol registration

Ensure the C++ kernel exports from `eco-kernel-cpp/src/eco/*Exports.cpp` are:
- Compiled into a library
- Linked into the native Eco binary
- Registered in the MLIR/LLVM symbol table

#### 6.2 Kernel ABI mapping

The compiler's MLIR generation must map `Eco.Kernel.*` calls to C++ function symbols:
- `Eco.Kernel.File.readString` → `eco_file_readString` (or whatever the C++ export name is)
- etc.

This should largely be handled by existing kernel ABI infrastructure.

#### 6.3 CMake integration

Add build targets:
- `eco-boot` — builds `eco-boot.js` using stock Elm compiler + `elm-bootstrap.json`
- `eco-node` — builds `eco-node.js` using `eco-boot.js` + `elm-kernel.json`
- `eco-native` — builds native binary using `eco-node.js` + C++ runtime + C++ kernel

---

## Implementation Order

### Step 1: XHR IO modules (Phase 1)
1. Study `eco-kernel-cpp/src/Eco/*.elm` type signatures thoroughly
2. Study `Utils/Impure.elm` HTTP mechanism
3. Create `compiler/src-xhr/Eco/XHR.elm` (shared HTTP plumbing)
4. Create `compiler/src-xhr/Eco/Console.elm`
5. Create `compiler/src-xhr/Eco/File.elm`
6. Create `compiler/src-xhr/Eco/Process.elm`
7. Create `compiler/src-xhr/Eco/Env.elm`
8. Create `compiler/src-xhr/Eco/Runtime.elm`
9. Create `compiler/src-xhr/Eco/MVar.elm`

### Step 2: Adapter layer (Phase 2)
10. Modify `System/IO.elm` to delegate to `Eco.*` modules
11. Remove direct `Utils/Impure` usage from `System/IO.elm`
12. Verify compiler still works via existing `bin/index.js`

### Step 3: Node handler + bootstrap config (Phases 3-4)
13. Create `eco-io-handler.js` wrapping JS kernel
14. Create `eco-boot-runner.js` bootstrap entry point
15. Create `elm-bootstrap.json`
16. Test: stock Elm compiler → `eco-boot.js` → runs under Node with eco-io-handler

### Step 4: Kernel build config (Phase 5)
17. Create `elm-kernel.json`
18. Verify/fix eco compiler kernel recognition for author `"eco"`
19. Test: `eco-boot.js` compiles compiler → `eco-node.js`
20. Test: `eco-node.js` runs compiler with direct kernel IO

### Step 5: Native build (Phase 6)
21. Verify C++ kernel exports are complete
22. Add CMake targets for bootstrap pipeline
23. Test: `eco-node.js` → native build → `eco-native`
24. Self-host validation: `eco-native` rebuilds itself

---

## Risks and Open Questions

1. **Type signature compatibility**: The `Eco.*` XHR modules must have exactly the same types as the kernel variants. Need to verify all function signatures match.

2. **JS kernel import format**: The JS kernel files in `eco-kernel-cpp/src/Eco/Kernel/*.js` may use Elm's scheduler/kernel conventions that aren't directly importable as regular Node modules. The eco-io-handler may need adaptation.

3. **Compiler IO coverage**: The compiler uses ~30 different IO operations (per `index.js`). All must be mapped through the `Eco.*` interface. Some (like HTTP archive downloads, REPL operations) may not have direct `Eco.*` equivalents and may need additions.

4. **Eco kernel recognition**: Need to verify the compiler already handles kernel author `"eco"` and prefix `"Eco.Kernel."`. If not, this is additional compiler work.

5. **elm/http dependency**: The XHR variant needs `elm/http` for `Http.task`. The kernel variant must NOT depend on `elm/http`. This separation is handled by the two elm.json configs.

---

## Files to Create

```
compiler/
├── src-xhr/
│   └── Eco/
│       ├── XHR.elm          # Shared HTTP plumbing for XHR variant
│       ├── Console.elm      # XHR-based console IO
│       ├── File.elm         # XHR-based file IO
│       ├── Process.elm      # XHR-based process management
│       ├── Env.elm          # XHR-based environment access
│       ├── Runtime.elm      # XHR-based runtime utilities
│       └── MVar.elm         # XHR-based concurrency primitives
├── bin/
│   ├── eco-io-handler.js   # JS kernel wrapper for XHR handler
│   └── eco-boot-runner.js  # Bootstrap entry point
├── elm-bootstrap.json       # Bootstrap build config (XHR variant)
└── elm-kernel.json          # Kernel build config (eco/kernel)
```

## Files to Modify

```
compiler/src/System/IO.elm   # Delegate to Eco.* instead of Utils/Impure
compiler/bin/index.js        # Possibly extend or keep as-is
```
