# Eco Kernel API Alignment Plan

Align the `eco-kernel-cpp` kernel implementations (JS + C++) with the
`compiler/src-xhr/` reference API surface. Also add the missing `Eco.Http`
module to the kernel.

## Background

The `compiler/src-xhr/Eco/*.elm` modules define the IO API surface.
The `eco-kernel-cpp/src/Eco/*.elm` wrappers must expose the same API.
Each wrapper delegates to either:

- **JavaScript kernel** (`eco-kernel-cpp/src/Eco/Kernel/*.js`) — used when
  running compiled Elm in Node.js
- **C++ kernel** (`eco-kernel-cpp/src/eco/*.{hpp,cpp}` +
  `KernelExports.h`) — used when running via the LLVM JIT

Four categories of work:

1. **Process** — fix Elm wrapper + fix `spawn` arity + add `spawnProcess`
2. **Runtime** — add missing `loadState`
3. **Http** — entirely new module (Elm wrapper + JS kernel + C++ kernel)
4. **Verify** — build and cross-check API surface

---

## Step 1: Fix Process module

The src-xhr Process.elm converts types at the Elm layer before sending to
the XHR handler:

- `exit` calls `exitCodeToInt code` → sends raw `Int`
- `spawn` sends `cmd` + `args` separately → gets back `Int` (pid)
- `spawnProcess` calls `encodeStdStream` on each stream → sends strings
  `"inherit"`/`"pipe"` — gets back `{ stdinHandle, processHandle }`
- `wait` gets back raw `Int` → calls `intToExitCode`

The kernel Process.elm wrapper must do the same type conversions.

### 1a. Elm wrapper (`src/Eco/Process.elm`)

Add helper functions matching src-xhr:

```elm
exitCodeToInt : ExitCode -> Int
exitCodeToInt code =
    case code of
        ExitSuccess -> 0
        ExitFailure n -> n

intToExitCode : Int -> ExitCode
intToExitCode code =
    if code == 0 then ExitSuccess else ExitFailure code

stdStreamToString : StdStream -> String
stdStreamToString stream =
    case stream of
        Inherit -> "inherit"
        CreatePipe -> "pipe"
```

Update function bodies:

```elm
exit code =
    Eco.Kernel.Process.exit (exitCodeToInt code)

spawn cmd args =
    Eco.Kernel.Process.spawn cmd args
        |> Task.map ProcessHandle

spawnProcess config =
    Eco.Kernel.Process.spawnProcess
        config.cmd config.args
        (stdStreamToString config.stdin)
        (stdStreamToString config.stdout)
        (stdStreamToString config.stderr)
        |> Task.map (\result ->
            { stdinHandle = result.stdinHandle
            , processHandle = ProcessHandle result.processHandle
            })

wait (ProcessHandle ph) =
    Eco.Kernel.Process.wait ph
        |> Task.map intToExitCode
```

Key differences from current kernel wrapper:
- `exit` now converts `ExitCode → Int` before calling kernel
- `spawnProcess` now converts `StdStream → String` before calling kernel
- `wait` now converts `Int → ExitCode` after kernel returns

### 1b. JavaScript kernel (`src/Eco/Kernel/Process.js`)

Current state: single `_Process_spawn(config)` taking 1 config object arg.

Changes:

**`_Process_exit(code)`** — now receives a raw int (not ExitCode). Already
works since `process.exit(code)` takes an int. No change needed.

**`_Process_spawn(cmd, args)`** — NEW function (2 args). Spawns with
all-inherited stdio, returns just the pid (int).

```js
var _Process_spawn = function(cmd, args) {
    return __Scheduler_binding(function(callback) {
        var child = child_process.spawn(cmd, _List_toArray(args),
            { stdio: ['inherit', 'inherit', 'inherit'] });
        callback(__Scheduler_succeed(child.pid));
    });
};
```

**`_Process_spawnProcess(cmd, args, stdin, stdout, stderr)`** — RENAMED
from old `_Process_spawn`. Takes 5 args. The `stdin`/`stdout`/`stderr`
are now plain strings `"inherit"` or `"pipe"` (converted by Elm wrapper).
Returns `{ stdinHandle: Maybe Int, processHandle: Int }`.

```js
var _Process_spawnProcess = function(cmd, args, stdin, stdout, stderr) {
    return __Scheduler_binding(function(callback) {
        var child = child_process.spawn(cmd, _List_toArray(args),
            { stdio: [stdin, stdout, stderr] });
        var stdinHandle = child.stdin ? __Maybe_Just(child.pid * 1000) : __Maybe_Nothing;
        callback(__Scheduler_succeed({
            stdinHandle: stdinHandle,
            processHandle: child.pid
        }));
    });
};
```

The import header needs `Maybe` added:

```js
/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Maybe exposing (Just, Nothing)
*/
```

**`_Process_wait(handle)`** — now returns raw int (exit code). The Elm
wrapper converts to ExitCode. No change needed (already returns int).

### 1c. C++ kernel

**`src/eco/Process.hpp`:**
- Change `spawn(uint64_t config)` to `spawn(uint64_t cmd, uint64_t args)`
- Add `spawnProcess(uint64_t cmd, uint64_t args, uint64_t stdin_,
  uint64_t stdout_, uint64_t stderr_)`
- `exit` signature: keep as `uint64_t exit(int64_t code)` — now receives
  an unboxed `Int` (`int64_t` per ABI convention)

**`src/eco/Process.cpp`:**
- Update `spawn` stub: 2 args, assert-crash
- Add `spawnProcess` stub: 5 args, assert-crash
- Update `exit` stub: `int64_t code` param, assert-crash

**`src/eco/ProcessExports.cpp`:**
- Update `Eco_Kernel_Process_spawn` to pass 2 args
- Add `Eco_Kernel_Process_spawnProcess` forwarding 5 args
- Update `Eco_Kernel_Process_exit` to use `int64_t code`

**`src/eco/KernelExports.h`:**
- Change: `uint64_t Eco_Kernel_Process_exit(int64_t code);`
- Change: `uint64_t Eco_Kernel_Process_spawn(uint64_t cmd, uint64_t args);`
- Add: `uint64_t Eco_Kernel_Process_spawnProcess(uint64_t cmd,
  uint64_t args, uint64_t stdin_, uint64_t stdout_, uint64_t stderr_);`

---

## Step 2: Add Runtime `loadState`

The Elm wrapper calls `Eco.Kernel.Runtime.loadState` but no C++ kernel
implementation exists.

### 2a. JavaScript kernel (`src/Eco/Kernel/Runtime.js`)

Already has `_Runtime_loadState`. **No changes needed.**

### 2b. C++ kernel

**`src/eco/Runtime.hpp`:**
- Add: `uint64_t loadState();`

**`src/eco/Runtime.cpp`:**
- Add stub with assert-crash:
```cpp
uint64_t loadState() {
    assert(false && "Eco::Kernel::Runtime::loadState not implemented");
    return 0;
}
```

**`src/eco/RuntimeExports.cpp`:**
- Add: `uint64_t Eco_Kernel_Runtime_loadState() {
  return Runtime::loadState(); }`

**`src/eco/KernelExports.h`:**
- Add: `uint64_t Eco_Kernel_Runtime_loadState();`

---

## Step 3: Add Http module (new)

The `compiler/src-xhr/Eco/Http.elm` exposes two functions:

```elm
fetch : String -> String -> List (String, String)
     -> Task Never (Result { statusCode : Int, statusText : String, url : String } String)

getArchive : String
     -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
```

### 3a. Elm wrapper (`src/Eco/Http.elm`) — new file

Create `eco-kernel-cpp/src/Eco/Http.elm` with same module exposing list
and type signatures as src-xhr:

```elm
module Eco.Http exposing (fetch, getArchive)

import Eco.Kernel.Http
import Task exposing (Task)

fetch : String -> String -> List ( String, String )
     -> Task Never (Result { statusCode : Int, statusText : String, url : String } String)
fetch method url headers =
    Eco.Kernel.Http.fetch method url headers

getArchive : String
     -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
getArchive url =
    Eco.Kernel.Http.getArchive url
```

The kernel functions construct and return Elm `Result` values directly
(no JSON encoding/decoding needed like the XHR version).

### 3b. JavaScript kernel (`src/Eco/Kernel/Http.js`) — new file

Port logic from `compiler/bin/eco-io-handler.js` (lines 481–579).

**Import header** — follows the same convention as all existing kernel JS
files (e.g., File.js uses `import Maybe exposing (Just, Nothing)`):

```js
/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Eco.Kernel.Utils exposing (Tuple2)
import List exposing (Nil, Cons)
import Result exposing (Ok, Err)
import Maybe exposing (Just, Nothing)
*/
```

These compile to double-underscore-prefixed globals:
`__Scheduler_succeed`, `__Result_Ok`, `__Result_Err`,
`__Maybe_Just`, `__Maybe_Nothing`, `__List_Nil`, `__List_Cons`,
`__Utils_Tuple2`, etc.

**`_Http_fetch(method, url, headers)`** (3 args):
- `method`: String, `url`: String, `headers`: Elm `List (String, String)`
- Convert Elm list of tuples to JS header object — iterate the linked
  list using `_List_toArray(headers)` then access tuple fields `.a`/`.b`:
  ```js
  var arr = _List_toArray(headers);
  var headerObj = {};
  for (var i = 0; i < arr.length; i++) {
      headerObj[arr[i].a] = arr[i].b;
  }
  ```
- Use `http`/`https` based on URL protocol
- Handle gzip/deflate content-encoding (via `zlib`)
- Return `__Result_Ok(body)` on 2xx
- Return `__Result_Err({ statusCode: ..., statusText: ..., url: ... })`
  on non-2xx or error

**`_Http_getArchive(url)`** (1 arg):
- Download ZIP via HTTP GET, follow 3xx redirects
- Compute SHA1 hash of raw ZIP buffer (via `crypto`)
- Extract ZIP entries using `adm-zip` (via `require('adm-zip')` — the
  package is in the compiler's `package.json` and available at runtime)
- Build Elm list of archive entries — construct the linked list using
  `__List_Cons` and `__List_Nil`:
  ```js
  var entries = zip.getEntries();
  var archive = __List_Nil;
  for (var i = entries.length - 1; i >= 0; i--) {
      archive = __List_Cons(
          { relativePath: entries[i].entryName, data: zip.readAsText(entries[i]) },
          archive);
  }
  ```
- Return `__Result_Ok({ sha: sha, archive: archive })` or
  `__Result_Err(errorMessage)`

### 3c. C++ kernel — new files

**`src/eco/Http.hpp`:**
```cpp
#ifndef ECO_HTTP_HPP
#define ECO_HTTP_HPP
#include <cstdint>
namespace Eco::Kernel::Http {
    uint64_t fetch(uint64_t method, uint64_t url, uint64_t headers);
    uint64_t getArchive(uint64_t url);
}
#endif
```

**`src/eco/Http.cpp`:**
- Assert-crash stubs:
```cpp
uint64_t fetch(uint64_t, uint64_t, uint64_t) {
    assert(false && "Eco::Kernel::Http::fetch not implemented");
    return 0;
}
uint64_t getArchive(uint64_t) {
    assert(false && "Eco::Kernel::Http::getArchive not implemented");
    return 0;
}
```

**`src/eco/HttpExports.cpp`:**
- `Eco_Kernel_Http_fetch(method, url, headers)` → `Http::fetch(...)`
- `Eco_Kernel_Http_getArchive(url)` → `Http::getArchive(...)`

**`src/eco/KernelExports.h`:**
- Add Http section with both function declarations

**`CMakeLists.txt`:**
- Add `EcoKernel_Http` library (Http.cpp + HttpExports.cpp)
- Add to `EcoKernel` INTERFACE link list

---

## Step 4: Verify

- Build eco-kernel-cpp: `cmake --build build`
- Confirm all C++ compiles and links
- Diff the module exposing lists of every `eco-kernel-cpp/src/Eco/*.elm`
  against its `compiler/src-xhr/Eco/*.elm` counterpart to confirm API parity

---

## File change summary

| File | Action |
|------|--------|
| `src/Eco/Process.elm` | Add `exitCodeToInt`, `intToExitCode`, `stdStreamToString`; update `exit`, `spawnProcess`, `wait` |
| `src/Eco/Kernel/Process.js` | Rewrite `spawn` (2 args), add `spawnProcess` (5 args), add Maybe import |
| `src/eco/Process.hpp` | Fix `exit` (int64_t), fix `spawn` sig (2 args), add `spawnProcess` (5 args) |
| `src/eco/Process.cpp` | Fix `exit`, `spawn`, add `spawnProcess`, assert-crash stubs |
| `src/eco/ProcessExports.cpp` | Fix `exit`, `spawn`, add `spawnProcess` |
| `src/eco/Runtime.hpp` | Add `loadState` |
| `src/eco/Runtime.cpp` | Add `loadState` assert-crash stub |
| `src/eco/RuntimeExports.cpp` | Add `loadState` export |
| `src/eco/KernelExports.h` | Fix `exit` (int64_t), fix `spawn`, add `spawnProcess`, `loadState`, Http section |
| `src/Eco/Http.elm` | **New** — Elm wrapper |
| `src/Eco/Kernel/Http.js` | **New** — JS kernel (port from eco-io-handler.js, uses adm-zip) |
| `src/eco/Http.hpp` | **New** — C++ header |
| `src/eco/Http.cpp` | **New** — C++ assert-crash stubs |
| `src/eco/HttpExports.cpp` | **New** — C-linkage exports |
| `CMakeLists.txt` | Add `EcoKernel_Http` target |

15 files total (9 modified, 5 new, 1 CMakeLists update).

---

## Resolved decisions

1. **ZIP extraction dependency** — Use `require('adm-zip')`. The package
   is already in the compiler's `package.json` and available at runtime.

2. **Elm kernel JS import convention** — Follow the same `/* import ... */`
   header comment convention used by all existing kernel JS files. The
   compiler transforms these into double-underscore-prefixed globals
   (e.g., `import Result exposing (Ok, Err)` → `__Result_Ok`, `__Result_Err`).

3. **Elm List/Tuple representation in kernel JS** — Use `_List_toArray`
   to convert Elm lists. Access tuple pair fields via `.a` and `.b`.
   Build Elm lists using `__List_Cons(head, tail)` and `__List_Nil`.

4. **Unboxed Int C++ type** — Use `int64_t` per ABI convention. This
   matches existing exports like `Eco_Kernel_File_size` and
   `Eco_Kernel_File_modificationTime` which already use `int64_t` for
   unboxed Int return types.

---

## Open issues

None — all design questions resolved.
