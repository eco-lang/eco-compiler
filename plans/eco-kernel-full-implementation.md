# Eco Kernel Full Implementation Plan

Fully implement all eco-kernel-cpp kernel functions — both the JavaScript
kernel (Node.js) and the C++ kernel (LLVM JIT).

## Current State

**JS kernel** (`src/Eco/Kernel/*.js`): 7 files, ~50 functions.
Most are already implemented. Three stubs remain:
- `_File_lock` / `_File_unlock` — no-op stubs
- `_Process_wait` — returns 0 immediately

**C++ kernel** (`src/eco/*.{hpp,cpp}`): 7 modules, 43 functions.
ALL are stubs (return 0 or assert-crash). None perform real IO.

---

## Part A: Complete JS Kernel

The JS kernel is nearly complete. Three stubs need real implementations,
and a few functions have minor behavioral differences from the XHR handler
that should be harmonized.

### A1. Implement `_Process_wait`

The XHR handler tracks spawned processes and waits for exit via the `exit`
event. The kernel JS needs the same.

**Current:** Returns 0 immediately.

**Implementation:**
- Maintain a `_Process_children` map from pid → child process object
- In `_Process_spawn` and `_Process_spawnProcess`, store the child object
- In `_Process_wait`, register a `child.on('exit', ...)` handler that
  calls the scheduler callback with the exit code

```js
var _Process_children = {};

// In _Process_spawn, after spawning:
_Process_children[child.pid] = child;

// In _Process_wait:
var _Process_wait = function(handle) {
    return __Scheduler_binding(function(callback) {
        var child = _Process_children[handle];
        if (!child) {
            callback(__Scheduler_succeed(0));
            return;
        }
        if (child.exitCode !== null) {
            delete _Process_children[handle];
            callback(__Scheduler_succeed(child.exitCode));
            return;
        }
        child.on('exit', function(code) {
            delete _Process_children[handle];
            callback(__Scheduler_succeed(code || 0));
        });
    });
};
```

### A2. Implement `_File_lock` / `_File_unlock`

The XHR handler also has these as no-ops. For now, implement the same
behavior with explicit TODO markers, matching the XHR version.

**Current state in both XHR and kernel:** No-op returning Unit.
**Action:** Keep as-is (already matching). Both are TODOs.

### A3. Harmonize behavioral differences

**`_File_findExecutable`:**
- XHR uses `which` npm package (third-party)
- Kernel JS does manual PATH searching
- The kernel implementation is correct and doesn't need `which`. Keep as-is.

**`_File_canonicalize`:**
- XHR has fallback `path.resolve()` when `fs.realpathSync()` throws
- Kernel JS only does `fs.realpathSync()` (throws on non-existent paths)
- **Fix:** Add the `path.resolve()` fallback to match XHR behavior

**`_File_list`:**
- XHR returns JS array; kernel returns JS array
- Elm runtime converts JS arrays to Elm Lists — verify this works
- **Action:** Keep as-is

**`_Console_write`:**
- XHR handler supports stream handles (from spawnProcess) in addition to
  stdout/stderr
- Kernel JS only handles stdout (1) and stderr (2)
- **Fix:** Add stream handle support. Maintain a `_Process_streamHandles`
  map from handle ID → writable stream (populated by `_Process_spawnProcess`)

**`_File_close`:**
- XHR handler also closes stream handles (from spawnProcess)
- Kernel JS only closes file descriptors
- **Fix:** Check `_Process_streamHandles` before calling `fs.closeSync`

### A4. JS Kernel file changes

| File | Changes |
|------|---------|
| `Process.js` | Add `_Process_children` map, implement `_Process_wait`, add stream handle tracking |
| `File.js` | Add `path.resolve` fallback in `canonicalize` |
| `Console.js` | Add stream handle support in `write` |

---

## Part B: Implement C++ Kernel

### B1. Infrastructure

All C++ kernel functions follow the same pattern:
1. Decode `uint64_t` inputs to `HPointer` using `Export::decode()`
2. Resolve `HPointer` to raw pointers using `Allocator::instance().resolve()`
3. Extract native C++ values (strings, ints, bools)
4. Perform the IO operation using POSIX/C++ stdlib
5. Construct result heap objects using `alloc::*` helpers
6. Wrap the result in a Task using `Scheduler::instance().taskSucceed()`
7. Return as `uint64_t` using `Export::encode()`

**Required includes for all kernel .cpp files:**
```cpp
#include "ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "platform/Scheduler.hpp"
```

**String conversion helpers** (add to a shared header or inline in each file):
```cpp
// Extract UTF-8 std::string from HPointer-encoded ElmString
std::string hptrToString(uint64_t val) {
    HPointer h = Export::decode(val);
    void* ptr = Allocator::instance().resolve(h);
    return StringOps::toStdString(ptr);
}

// Allocate ElmString from UTF-8 and return as encoded uint64_t
uint64_t stringToHptr(const std::string& s) {
    HPointer h = alloc::allocStringFromUTF8(s);
    return Export::encode(h);
}
```

**Task wrapping** — every kernel function must return a `Task`:
```cpp
// Wrap a result HPointer in Task.succeed and return as uint64_t
uint64_t succeedWith(HPointer value) {
    HPointer task = Elm::Platform::Scheduler::instance().taskSucceed(value);
    return Export::encode(task);
}

// Wrap a raw uint64_t-encoded value in Task.succeed
uint64_t succeedWith(uint64_t encodedValue) {
    return succeedWith(Export::decode(encodedValue));
}
```

### B2. Shared helper file

Create `src/eco/KernelHelpers.hpp` with the infrastructure above.

### B3. Per-module implementation

#### Console Module (3 functions)

**`write(handle, content)`:**
- Decode `handle` as unboxed int, `content` as ElmString
- If handle == 1: `write(STDOUT_FILENO, ...)` or `std::cout`
- If handle == 2: `write(STDERR_FILENO, ...)`  or `std::cerr`
- Return Task of Unit

**`readLine()`:**
- Use `std::getline(std::cin, line)`
- Return Task of ElmString

**`readAll()`:**
- Read all of stdin into a string
- Return Task of ElmString

#### Env Module (2 functions)

**`lookup(name)`:**
- Decode `name` as string
- Call `std::getenv(name.c_str())`
- Return `Maybe String`: `alloc::just(stringHPtr)` or `alloc::nothing()`
- Wrap in Task

**`rawArgs()`:**
- Access stored argc/argv from `Eco::Kernel::Env::init()` globals
- Build `List String` using `alloc::listFromPointers()`
- Wrap in Task

#### File Module (21 functions)

All file operations use POSIX APIs (`open`, `read`, `write`, `stat`,
`readdir`, `realpath`, `unlink`, `rmdir`, `chdir`, `getcwd`).

**`readString(path)`:**
- `std::ifstream` or `open`/`read`/`close` to read file
- `alloc::allocStringFromUTF8(content)`
- Task of ElmString

**`writeString(path, content)`:**
- Extract UTF-8 content string
- `std::ofstream` or `open`/`write`/`close`
- Task of Unit

**`readBytes(path)`:**
- Read file into buffer
- `alloc::allocByteBuffer(data, size)`
- Task of ByteBuffer

**`writeBytes(path, bytes)`:**
- Resolve ByteBuffer, extract raw bytes
- Write to file
- Task of Unit

**`open(path, mode)`:**
- Map IOMode int to POSIX flags: 0→O_RDONLY, 1→O_WRONLY|O_CREAT|O_TRUNC,
  2→O_WRONLY|O_CREAT|O_APPEND, 3→O_RDWR|O_CREAT
- `::open(pathStr, flags, 0644)`
- Return fd as unboxed int via Task

**`close(handle)`:**
- `::close(handle)` on the fd
- Task of Unit

**`size(handle)`:**
- `fstat(handle, &st)`, return `st.st_size` as unboxed int64_t
- Note: This function returns `int64_t` directly (not wrapped in Task?)
  — actually it IS a Task per the Elm type. Wrap in Task.

**`lock(path)` / `unlock(path)`:**
- Use `flock()` or advisory locks: `fcntl(fd, F_SETLK, ...)`
- Or keep as no-op stubs matching XHR behavior
- Task of Unit

**`fileExists(path)`:**
- `stat(pathStr, &st)` → check `S_ISREG(st.st_mode)`
- Return boxed Bool via `Export::encodeBoxedBool(result)`
- Task of Bool

**`dirExists(path)`:**
- `stat(pathStr, &st)` → check `S_ISDIR(st.st_mode)`
- Task of Bool

**`findExecutable(name)`:**
- Parse `PATH` env var, search each directory for executable
- `access(fullPath, X_OK)` to check executability
- Return `Maybe String`
- Task of Maybe String

**`list(path)`:**
- `opendir`/`readdir`/`closedir`
- Build `List String` from entries
- Task of List String

**`modificationTime(path)`:**
- `stat(pathStr, &st)` → extract `st.st_mtim`
- Convert to milliseconds since epoch
- Return as unboxed int64_t via Task

**`getCwd()`:**
- `getcwd(buf, sizeof(buf))`
- Task of ElmString

**`setCwd(path)`:**
- `chdir(pathStr.c_str())`
- Task of Unit

**`canonicalize(path)`:**
- `realpath(pathStr.c_str(), resolvedPath)`
- Task of ElmString

**`appDataDir(name)`:**
- Get HOME from env, construct platform-specific path:
  - Linux: `$HOME/.name`
  - macOS: `$HOME/Library/Application Support/name`
- Task of ElmString

**`createDir(createParents, path)`:**
- If createParents: recursive `mkdir` (or use `std::filesystem::create_directories`)
- Else: single `mkdir`
- Task of Unit

**`removeFile(path)`:**
- `unlink(pathStr.c_str())`
- Task of Unit

**`removeDir(path)`:**
- Recursive directory removal via `std::filesystem::remove_all`
- Task of Unit

#### Process Module (4 functions)

**`exit(code)`:**
- `::exit(static_cast<int>(code))`
- Nominally returns Task (but never returns)

**`spawn(cmd, args)`:**
- Extract cmd string and args list
- `fork()` + `execvp()` (or `posix_spawn`)
- Return child PID as unboxed int
- Task of Int

**`spawnProcess(cmd, args, stdin_, stdout_, stderr_)`:**
- Extract stream config strings ("inherit" or "pipe")
- Set up pipes for "pipe" streams
- `fork()` + `execvp()` with pipe redirection
- Return record `{ stdinHandle : Maybe Int, processHandle : Int }`
  using `alloc::record()` with hardcoded unboxed-first layout:
  - Slot 0: `processHandle` (Int, unboxed)
  - Slot 1: `stdinHandle` (Maybe Int, boxed)
  - Bitmap: `0b01`
- Task of Record

**`wait(handle)`:**
- `waitpid(handle, &status, 0)`
- Extract exit code via `WEXITSTATUS(status)`
- Return as unboxed int via Task

#### MVar Module (4 functions)

Single-threaded implementation (no mutexes/condvars needed).

**`newEmpty()`:**
- Allocate a new MVar slot in a global map (incrementing ID counter)
- Return MVar ID as unboxed int
- Task of Int

**`read(id)`:**
- Look up MVar slot by ID
- If value is set: return a copy without clearing
- If empty: for now, assert-crash (blocking requires scheduler integration)
- Task of Bytes value

**`take(id)`:**
- Look up MVar slot
- If value set: extract value, clear slot
- If empty: assert-crash (blocking requires scheduler integration)
- Task of Bytes value

**`put(id, value)`:**
- Look up MVar slot
- If slot empty: store value
- If full: assert-crash (blocking requires scheduler integration)
- Task of Unit

**Implementation approach:** Simple `std::unordered_map<int64_t, MVarSlot>`
where `MVarSlot` holds an `std::optional<HPointer>`. No locking needed
in single-threaded mode. Full blocking semantics would require cooperative
scheduling integration with the Elm scheduler (future work).

#### Runtime Module (4 functions)

**`dirname()`:**
- Use `/proc/self/exe` readlink on Linux
- Extract directory component
- Task of ElmString

**`random()`:**
- Use `<random>` C++ header or `drand48()`
- Return as unboxed double
- Task of Float

**`saveState(state)` / `loadState()`:**
- Store/retrieve a global `HPointer` variable (simple global, no mutex needed)
- Task of value / Task of Unit

#### Http Module (2 functions)

**`fetch(method, url, headers)`:**
- Use libcurl (CMake already detects it): `curl_easy_setopt()` /
  `curl_easy_perform()`
- Extract method string, URL string, headers list
- Set up request, handle gzip/deflate via `CURLOPT_ACCEPT_ENCODING`
- On 2xx: return `alloc::ok(bodyString)` → `Result.Ok body`
- On non-2xx: return `alloc::err(errorRecord)` where record has
  `{ statusCode : Int, statusText : String, url : String }` with
  hardcoded unboxed-first layout:
  - Slot 0: `statusCode` (Int, unboxed)
  - Slot 1: `statusText` (String, boxed)
  - Slot 2: `url` (String, boxed)
  - Bitmap: `0b001`
- Task of Result

**`getArchive(url)`:**
- Use libcurl to download ZIP
- Follow redirects via `CURLOPT_FOLLOWLOCATION`
- Compute SHA1 via OpenSSL `SHA1()` (CMake already detects OpenSSL)
- Extract ZIP using libzip
- Build list of `{ relativePath : String, data : String }` records
  (all boxed, bitmap `0b00`, pure alphabetical: [data, relativePath])
- Build outer record `{ sha : String, archive : List (...) }` records
  (all boxed, bitmap `0b00`, pure alphabetical: [archive, sha])
- Return `alloc::ok(outerRecord)` or `alloc::err(errorString)`
- Task of Result

### B4. CMakeLists.txt changes

- Link `EcoKernel` against the runtime's `Allocator`, `Scheduler`,
  and `StringOps` libraries
- Add libcurl and OpenSSL link dependencies for Http module
- Add libzip (or bundled minizip) for ZIP extraction
- Add `std::filesystem` link flag if needed (`-lstdc++fs` on older GCC)

### B5. C++ kernel file changes

| File | Changes |
|------|---------|
| `src/eco/KernelHelpers.hpp` | **New** — shared string/task helpers |
| `src/eco/Console.cpp` | Implement `write`, `readLine`, `readAll` |
| `src/eco/Env.cpp` | Implement `lookup`, `rawArgs` |
| `src/eco/File.cpp` | Implement all 21 file operations |
| `src/eco/Process.cpp` | Implement `exit`, `spawn`, `spawnProcess`, `wait` |
| `src/eco/MVar.cpp` | Implement with simple map (single-threaded) |
| `src/eco/Runtime.cpp` | Implement `dirname`, `random`, `saveState`, `loadState` |
| `src/eco/Http.cpp` | Implement with libcurl + OpenSSL + libzip |
| `CMakeLists.txt` | Link runtime, libcurl, OpenSSL, libzip |

---

## Part C: Verification

1. **Build:** `cmake --build build` — verify all C++ compiles and links
2. **JS smoke test:** Run a simple Elm program through the kernel JS path
   and verify Console, File, Env, Process, Runtime operations work
3. **C++ unit tests:** Add basic tests for string conversion helpers and
   each module's core operations
4. **API parity check:** Diff all `eco-kernel-cpp/src/Eco/*.elm` exposing
   lists against `compiler/src-xhr/Eco/*.elm`

---

## Implementation order

1. **JS kernel fixes** (Part A) — small scope, quick wins
2. **C++ infrastructure** (B1–B2) — KernelHelpers.hpp, CMake links
3. **C++ Console + Env** — simplest modules, validate the pattern
4. **C++ File** — largest module, bulk of POSIX work
5. **C++ Runtime** — straightforward
6. **C++ Process** — fork/exec complexity
7. **C++ MVar** — simple map, single-threaded
8. **C++ Http** — libcurl integration, most external dependencies
9. **Verification** (Part C)

---

## Resolved Design Decisions

1. **Task wrapping in C++** — The compiler does NOT wrap kernel return values
   in `Scheduler::taskSucceed()`. Kernel functions must do it themselves.
   Every C++ kernel function must call `Scheduler::instance().taskSucceed(result)`
   (or `taskFail(error)`) and return the resulting Task HPointer.

2. **argc/argv access** — Use a global init function called from `main()` that
   stores argc/argv. This is more portable than `/proc/self/cmdline` and works
   on macOS. The runtime's `main()` already has argc/argv; add a
   `Eco::Kernel::Env::init(argc, argv)` call there.

3. **Record field ordering** — **CRITICAL**: Record fields in C++ must follow
   the compiler's `computeRecordLayout` ordering, NOT pure alphabetical order.

   **Approach**: Hardcode the correct layout in each C++ kernel function.
   There are only a few record types in the kernel. Dynamic type-table-based
   lookup is deferred to future work. (The type table does contain the full
   ordering info — fields are emitted in layout order with type IDs that can
   determine unboxability — but using it adds unnecessary runtime complexity.)

   The layout rule is: **unboxed fields first** (alphabetically within the
   group), then **boxed fields** (alphabetically within the group).

   - Only Int, Float, and Char are unboxable (NOT Bool, NOT String)
   - The unboxed bitmap is contiguous low bits: `(2^unboxedCount) - 1`
   - Source: `compiler/src/Compiler/Generate/MLIR/Types.elm:423-466`

   **Example**: `{ stdinHandle : Maybe Int, processHandle : Int }`
   - Unboxable: processHandle (Int) → slot 0
   - Boxable: stdinHandle (Maybe Int) → slot 1
   - Bitmap: `0b01` (1 unboxed field at bit 0)

   **Example**: `{ statusCode : Int, statusText : String, url : String }`
   - Unboxable: statusCode (Int) → slot 0
   - Boxable: statusText, url → slots 1, 2
   - Bitmap: `0b001` (1 unboxed field at bit 0)

   **Example**: `{ relativePath : String, data : String }`
   - Unboxable: (none)
   - Boxable: data, relativePath → slots 0, 1
   - Bitmap: `0b00`

   **Example**: `{ sha : String, archive : List (...) }`
   - Unboxable: (none)
   - Boxable: archive, sha → slots 0, 1
   - Bitmap: `0b00`

   **NOTE**: The existing `elm-kernel-cpp/src/http/HttpExports.cpp` and
   `elm-kernel-cpp/src/regex/RegexExports.cpp` use WRONG ordering (pure
   alphabetical with interleaved unboxing, e.g., bitmap `0b00100` and `0b0101`).
   This is a latent bug that hasn't been caught because tests only exercise
   the JS path. The eco-kernel-cpp MUST use correct unboxed-first ordering.

4. **ZIP extraction library** — Use libzip.

5. **External dependencies** — Add same dependencies as elm-kernel-cpp:
   `find_package(CURL QUIET)`, `find_package(OpenSSL QUIET)`, plus libzip.
   Follow the same conditional linking pattern with defines.

6. **Error handling convention** — Use `taskFail` for IO errors, matching the
   JS kernel behavior. Even though Elm types say `Task Never X`, the runtime
   scheduler handles failures gracefully.

7. **Stream handle management** — Yes, needed. Maintain a global
   `std::unordered_map<int64_t, int>` mapping handle IDs to file descriptors
   (from pipe creation in `spawnProcess`). Used by `Console::write` and
   `File::close`.

8. **Thread safety** — Single-threaded for now. No mutexes needed on global
   state (MVar map, process map, stream handles). May add later if
   multi-threaded execution is implemented.

   For MVar specifically: since we're single-threaded, MVar operations can use
   simple storage without condition variables. Blocking semantics would need
   scheduler integration (cooperative scheduling) rather than OS-level blocking.
