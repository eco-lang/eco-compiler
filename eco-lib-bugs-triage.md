# Eco kernel C++ suspected bugs: triage

Triage of every entry of `eco-lib-bugs.md` (2026-11-04) by reading the current code; nothing was
built or run. Each entry keeps its original ID and title. **Status:** CERTAIN (the defect is in
the code, with its trigger), LIKELY (very probably real, one point unconfirmed), UNSURE (plausible,
needs a test), WEAK (mostly unfounded: guarded elsewhere, unreachable or a misreading), RESOLVED
(fixed in the current code). **Severity:** HIGH (memory or GC unsafety, crash, wrong results or data
loss reachable from ordinary programs, security), MEDIUM (edge cases, leaks, unusual but reachable
crashes), LOW (cosmetic, dead code, unreachable from well-typed Elm).

## Summary

| Status | HIGH | MEDIUM | LOW | Total |
|---|---|---|---|---|
| CERTAIN | 5 | 32 | 127 | 164 |
| LIKELY | 0 | 6 | 19 | 25 |
| UNSURE | 0 | 3 | 1 | 4 |
| WEAK | 0 | 0 | 134 | 134 |
| RESOLVED | 2 | 2 | 14 | 18 |
| **Total** | 7 | 43 | 295 | 345 |

## CERTAIN and LIKELY, HIGH severity

| ID | Status | Title |
|---|---|---|
| [TIME-01](#time-01) | CERTAIN | tagger/router encodings decoded after an allocation |
| [HEAP-01](#heap-01) | CERTAIN | listToStringVector resolves the empty-string constant |
| [PARSE-01](#parse-01) | CERTAIN | long UTF-16 ropes reach flatStringView unflattened |
| [UTILS-05](#utils-05) | CERTAIN | eqHelp assumes equal past depth 100 |
| [TIME-07](#time-07) | CERTAIN | duplicate intervals with different taggers |

## CERTAIN and LIKELY, MEDIUM severity

| ID | Status | Title |
|---|---|---|
| [REGEX-03](#regex-03) | CERTAIN | replaceAtMost/splitAtMost catch paths use unrooted strings |
| [TASK-01](#task-01) | CERTAIN | task effect manager closures unrooted at registration |
| [TIME-NEW-1](#time-new-1) | CERTAIN | Time effect manager closures unrooted at registration (same as TASK-01) |
| [HEAP-02](#heap-02) | CERTAIN | NativeDriver resolves Bytes without the empty-Bytes check |
| [PARSE-03](#parse-03) | CERTAIN | consumeBase accumulation overflows int64 |
| [CORE-01](#core-01) | CERTAIN | SysWorkPool partial thread start use-after-free |
| [FS-01](#fs-01) | CERTAIN | stale FileHandle accepted after fd reuse |
| [ABI-04](#abi-04) | CERTAIN | filesystem_error thrown outside the guard |
| [JSON-01](#json-01) | CERTAIN | Json.encode throws on invalid UTF-8 |
| [ABI-NEW-1](#abi-new-1) | CERTAIN | binding-body exceptions are never caught; ECO_KERNEL_GUARD on Task-returning exports is ineffective |
| [JSON-05](#json-05) | CERTAIN | JSON ints above INT64_MAX wrap |
| [JSON-06](#json-06) | CERTAIN | Decode.int rejects 1.0 |
| [URL-02](#url-02) | CERTAIN | percentDecode decodes + as space |
| [URL-03](#url-03) | CERTAIN | percentDecode returns Just on invalid UTF-8 |
| [JSON-NEW-1](#json-new-1) | CERTAIN | Encode.float of an integral value prints a trailing ".0" |
| [REGEX-06](#regex-06) | CERTAIN | regex engine is byte-wise over UTF-8 |
| [FILE-04](#file-04) | CERTAIN | Task Never wrappers over failing kernels |
| [CONSOLE-01](#console-01) | CERTAIN | readAllBody drops leading empty lines |
| [FILE-07](#file-07) | CERTAIN | write functions ignore write errors |
| [PROC-NEW-1](#proc-new-1) | CERTAIN | Console.write to a spawnProcess stdin handle is a silent no-op |
| [FILE-12](#file-12) | CERTAIN | Windows strerror on non-errno codes |
| [TIME-05](#time-05) | CERTAIN | Windows _timezone ignores DST |
| [PROC-05](#proc-05) | LIKELY | kill on exited run with open output does nothing |
| [ECO-NEW-1](#eco-new-1) | LIKELY | appDataDir fails a `Task Never` |
| [WATCH-02](#watch-02) | CERTAIN | renamed sub-dir keeps stale relative path |
| [WATCH-03](#watch-03) | CERTAIN | directory moved out keeps reporting |
| [WATCH-04](#watch-04) | CERTAIN | inotify vs poll disagree on symlinked root |
| [HTTPS-NEW-1](#https-new-1) | LIKELY | proxy CONNECT response posted as the final response |
| [HTTPS-NEW-2](#https-new-2) | LIKELY | method string not validated (request-line injection) |
| [WS-12](#ws-12) | CERTAIN | closeFrameWritten ignores err |
| [WS-21](#ws-21) | LIKELY | failed open may leave WsEntry |
| [TERM-04](#term-04) | CERTAIN | no restore on _exit/abort/SIGHUP/SIGQUIT |
| [WS-NEW-1](#ws-new-1) | LIKELY | open over HTTP/1.1 can report success while the core is never attached (permanent hang) |
| [WATCH-07](#watch-07) | CERTAIN | IN_Q_OVERFLOW dropped silently |
| [WATCH-08](#watch-08) | CERTAIN | files in new sub-dir before watch added missed |
| [REGEX-08](#regex-08) | CERTAIN | regexTable never freed |
| [PROC-07](#proc-07) | CERTAIN | Windows startCollector leaks pipe read ends |
| [STREAM-07](#stream-07) | CERTAIN | maybeErase never erases some pairs |

## New findings (not in eco-lib-bugs.md)

| ID | Status | Severity | Title |
|---|---|---|---|
| [TIME-NEW-1](#time-new-1) | CERTAIN | MEDIUM | Time effect manager closures unrooted at registration (same as TASK-01) |
| [ARRAY-NEW-1](#array-new-1) | UNSURE | MEDIUM | JsArray map/initialize store results in the closure's result kind, so an Int array can be kind 0 |
| [BASICS-NEW-1](#basics-new-1) | CERTAIN | LOW | runtime eco_int_pow has the same UB as pow_Int (the more reachable path) |
| [PARSE-NEW-1](#parse-new-1) | CERTAIN | LOW | Allocator::resolve on an embedded constant crashes in every build; the kernels' "if (!ptr)" guards after it are dead |
| [ABI-NEW-1](#abi-new-1) | CERTAIN | MEDIUM | binding-body exceptions are never caught; ECO_KERNEL_GUARD on Task-returning exports is ineffective |
| [JSON-NEW-1](#json-new-1) | CERTAIN | MEDIUM | Encode.float of an integral value prints a trailing ".0" |
| [FILE-NEW-1](#file-new-1) | UNSURE | MEDIUM | readString of a directory or >4 GiB file is unguarded (huge allocation, abort) |
| [PROC-NEW-1](#proc-new-1) | CERTAIN | MEDIUM | Console.write to a spawnProcess stdin handle is a silent no-op |
| [ECO-NEW-1](#eco-new-1) | LIKELY | MEDIUM | appDataDir fails a `Task Never` |
| [HTTPS-NEW-1](#https-new-1) | LIKELY | MEDIUM | proxy CONNECT response posted as the final response |
| [HTTPS-NEW-2](#https-new-2) | LIKELY | MEDIUM | method string not validated (request-line injection) |
| [WS-NEW-1](#ws-new-1) | LIKELY | MEDIUM | open over HTTP/1.1 can report success while the core is never attached (permanent hang) |
| [DEAD-NEW-1](#dead-new-1) | CERTAIN | LOW | socketNotImplementedTask / notImplementedBody dead |

## All entries

| ID | Status | Severity |
|---|---|---|
| ARRAY-01 | CERTAIN | LOW |
| ABI-01 | CERTAIN | LOW |
| REGEX-01 | RESOLVED | HIGH |
| REGEX-02 | RESOLVED | HIGH |
| REGEX-03 | CERTAIN | MEDIUM |
| REGEX-04 | WEAK | LOW |
| TIME-01 | CERTAIN | HIGH |
| TIME-02 | RESOLVED | MEDIUM |
| TIME-03 | RESOLVED | MEDIUM |
| TIME-04 | WEAK | LOW |
| TASK-01 | CERTAIN | MEDIUM |
| TASK-02 | WEAK | LOW |
| TASK-03 | WEAK | LOW |
| ARRAY-02 | CERTAIN | LOW |
| TIME-NEW-1 | CERTAIN | MEDIUM |
| ARRAY-03 | CERTAIN | LOW |
| ARRAY-04 | WEAK | LOW |
| ARRAY-05 | UNSURE | MEDIUM |
| LIST-01 | CERTAIN | LOW |
| LIST-02 | WEAK | LOW |
| LIST-03 | CERTAIN | LOW |
| LIST-04 | CERTAIN | LOW |
| LIST-05 | CERTAIN | LOW |
| STRING-01 | CERTAIN | LOW |
| STRING-02 | WEAK | LOW |
| HEAP-01 | CERTAIN | HIGH |
| HEAP-02 | CERTAIN | MEDIUM |
| HEAP-03 | WEAK | LOW |
| HEAP-04 | WEAK | LOW |
| ARRAY-NEW-1 | UNSURE | MEDIUM |
| PROC-01 | WEAK | LOW |
| RESET-01 | LIKELY | LOW |
| RESET-02 | LIKELY | LOW |
| RESET-03 | WEAK | LOW |
| MVAR-01 | WEAK | LOW |
| MVAR-02 | WEAK | LOW |
| UTILS-01 | WEAK | LOW |
| BASICS-01 | CERTAIN | LOW |
| BASICS-02 | CERTAIN | LOW |
| BASICS-03 | WEAK | LOW |
| BYTES-01 | RESOLVED | LOW |
| BYTES-02 | RESOLVED | LOW |
| BYTES-03 | WEAK | LOW |
| BYTES-04 | CERTAIN | LOW |
| BASICS-NEW-1 | CERTAIN | LOW |
| PARSE-01 | CERTAIN | HIGH |
| PARSE-02 | WEAK | LOW |
| PARSE-03 | CERTAIN | MEDIUM |
| HTTP-01 | RESOLVED | LOW |
| HTTP-02 | RESOLVED | LOW |
| HTTP-03 | WEAK | LOW |
| HTTP-04 | WEAK | LOW |
| HTML-01 | WEAK | LOW |
| FILE-01 | CERTAIN | LOW |
| FILE-02 | CERTAIN | LOW |
| BROWSER-01 | CERTAIN | LOW |
| PLATFORM-01 | WEAK | LOW |
| SYS-01 | WEAK | LOW |
| HTTPSRV-01 | WEAK | LOW |
| PARSE-NEW-1 | CERTAIN | LOW |
| SYS-02 | WEAK | LOW |
| SOCK-01 | WEAK | LOW |
| STREAM-01 | WEAK | LOW |
| CORE-01 | CERTAIN | MEDIUM |
| FD-01 | UNSURE | LOW |
| FD-02 | WEAK | LOW |
| SOCK-02 | WEAK | LOW |
| FS-01 | CERTAIN | MEDIUM |
| RESET-04 | CERTAIN | LOW |
| PROC-02 | CERTAIN | LOW |
| TLS-01 | CERTAIN | LOW |
| WATCH-01 | WEAK | LOW |
| ABI-02 | CERTAIN | LOW |
| CORE-02 | WEAK | LOW |
| TLS-02 | WEAK | LOW |
| CORE-03 | WEAK | LOW |
| CORE-04 | WEAK | LOW |
| CORE-05 | WEAK | LOW |
| CORE-06 | WEAK | LOW |
| ABI-03 | LIKELY | LOW |
| ABI-04 | CERTAIN | MEDIUM |
| JSON-01 | CERTAIN | MEDIUM |
| FILE-03 | CERTAIN | LOW |
| HTTP-05 | WEAK | LOW |
| TLS-03 | WEAK | LOW |
| JSON-02 | RESOLVED | LOW |
| JSON-03 | RESOLVED | LOW |
| JSON-04 | WEAK | LOW |
| ABI-NEW-1 | CERTAIN | MEDIUM |
| JSON-05 | CERTAIN | MEDIUM |
| JSON-06 | CERTAIN | MEDIUM |
| JSON-07 | RESOLVED | LOW |
| JSON-08 | RESOLVED | LOW |
| JSON-09 | RESOLVED | LOW |
| JSON-10 | WEAK | LOW |
| JSON-11 | WEAK | LOW |
| URL-01 | CERTAIN | LOW |
| URL-02 | CERTAIN | MEDIUM |
| URL-03 | CERTAIN | MEDIUM |
| URL-04 | CERTAIN | LOW |
| UTILS-02 | LIKELY | LOW |
| UTILS-03 | LIKELY | LOW |
| UTILS-04 | WEAK | LOW |
| JSON-NEW-1 | CERTAIN | MEDIUM |
| UTILS-05 | CERTAIN | HIGH |
| UTILS-06 | CERTAIN | LOW |
| UTILS-07 | WEAK | LOW |
| HASH-01 | CERTAIN | LOW |
| PARSE-04 | CERTAIN | LOW |
| PARSE-05 | WEAK | LOW |
| PARSE-06 | WEAK | LOW |
| REGEX-05 | WEAK | LOW |
| REGEX-06 | CERTAIN | MEDIUM |
| REGEX-07 | RESOLVED | LOW |
| BYTES-05 | CERTAIN | LOW |
| HTTP-06 | CERTAIN | LOW |
| HTTP-07 | RESOLVED | LOW |
| HTTP-08 | WEAK | LOW |
| HTTP-09 | CERTAIN | LOW |
| LIST-06 | WEAK | LOW |
| LIST-07 | WEAK | LOW |
| LIST-08 | CERTAIN | LOW |
| ARRAY-06 | WEAK | LOW |
| RUNTIME-01 | RESOLVED | LOW |
| FILE-04 | CERTAIN | MEDIUM |
| FILE-05 | CERTAIN | LOW |
| CONSOLE-01 | CERTAIN | MEDIUM |
| FILE-06 | CERTAIN | LOW |
| FILE-07 | CERTAIN | MEDIUM |
| PROC-03 | CERTAIN | LOW |
| FILE-08 | CERTAIN | LOW |
| FILE-09 | CERTAIN | LOW |
| FILE-NEW-1 | UNSURE | MEDIUM |
| PROC-NEW-1 | CERTAIN | MEDIUM |
| FILE-10 | CERTAIN | LOW |
| FILE-11 | CERTAIN | LOW |
| FILE-12 | CERTAIN | MEDIUM |
| HTTP-10 | CERTAIN | LOW |
| HTTP-11 | CERTAIN | LOW |
| HTTP-12 | CERTAIN | LOW |
| TIME-05 | CERTAIN | MEDIUM |
| TIME-06 | CERTAIN | LOW |
| TIME-07 | CERTAIN | HIGH |
| DEBUG-01 | CERTAIN | LOW |
| ABI-05 | CERTAIN | LOW |
| DEAD-01 | CERTAIN | LOW |
| PROC-04 | WEAK | LOW |
| PROC-05 | LIKELY | MEDIUM |
| ECO-NEW-1 | LIKELY | MEDIUM |
| CORE-07 | CERTAIN | LOW |
| CORE-08 | LIKELY | LOW |
| CORE-09 | WEAK | LOW |
| WS-01 | WEAK | LOW |
| CORE-10 | WEAK | LOW |
| CORE-11 | WEAK | LOW |
| WATCH-02 | CERTAIN | MEDIUM |
| WATCH-03 | CERTAIN | MEDIUM |
| WATCH-04 | CERTAIN | MEDIUM |
| WATCH-05 | CERTAIN | LOW |
| WATCH-06 | WEAK | LOW |
| WS-02 | WEAK | LOW |
| WS-03 | WEAK | LOW |
| WS-04 | WEAK | LOW |
| WS-05 | WEAK | LOW |
| WS-06 | WEAK | LOW |
| WS-07 | WEAK | LOW |
| STREAM-02 | WEAK | LOW |
| STREAM-03 | CERTAIN | LOW |
| TLS-04 | CERTAIN | LOW |
| TLS-05 | LIKELY | LOW |
| TLS-06 | CERTAIN | LOW |
| TLS-07 | WEAK | LOW |
| TLS-08 | LIKELY | LOW |
| TLS-09 | WEAK | LOW |
| STREAM-04 | WEAK | LOW |
| STREAM-05 | WEAK | LOW |
| STREAM-06 | WEAK | LOW |
| HTTPS-01 | CERTAIN | LOW |
| HTTPS-02 | WEAK | LOW |
| HTTPS-03 | LIKELY | LOW |
| HTTPS-04 | LIKELY | LOW |
| HTTPS-05 | WEAK | LOW |
| HTTPS-06 | WEAK | LOW |
| HTTPS-07 | WEAK | LOW |
| HTTPS-08 | WEAK | LOW |
| HTTPS-09 | CERTAIN | LOW |
| HTTPS-10 | WEAK | LOW |
| HTTPSRV-02 | CERTAIN | LOW |
| HTTPSRV-03 | CERTAIN | LOW |
| HTTPSRV-04 | CERTAIN | LOW |
| HTTPSRV-05 | WEAK | LOW |
| HTTPS-NEW-1 | LIKELY | MEDIUM |
| HTTPS-NEW-2 | LIKELY | MEDIUM |
| H2-01 | WEAK | LOW |
| H2-02 | WEAK | LOW |
| H2-03 | WEAK | LOW |
| H2-04 | WEAK | LOW |
| HTTPSRV-06 | CERTAIN | LOW |
| HTTPSRV-07 | WEAK | LOW |
| HTTPSRV-08 | WEAK | LOW |
| HTTPSRV-09 | WEAK | LOW |
| HTTPSRV-10 | WEAK | LOW |
| HTTPSRV-11 | WEAK | LOW |
| HTTPSRV-12 | CERTAIN | LOW |
| SOCK-03 | CERTAIN | LOW |
| SOCK-04 | WEAK | LOW |
| SOCK-05 | WEAK | LOW |
| SOCK-06 | WEAK | LOW |
| SOCK-07 | WEAK | LOW |
| SOCK-08 | WEAK | LOW |
| SOCK-09 | WEAK | LOW |
| SOCK-10 | WEAK | LOW |
| SOCK-11 | WEAK | LOW |
| SOCK-12 | CERTAIN | LOW |
| SOCK-13 | WEAK | LOW |
| WS-08 | CERTAIN | LOW |
| WS-09 | WEAK | LOW |
| WS-10 | WEAK | LOW |
| WS-11 | CERTAIN | LOW |
| WS-12 | CERTAIN | MEDIUM |
| WS-13 | CERTAIN | LOW |
| WS-14 | WEAK | LOW |
| WS-15 | WEAK | LOW |
| WS-16 | LIKELY | LOW |
| WS-17 | WEAK | LOW |
| WS-18 | LIKELY | LOW |
| WS-19 | LIKELY | LOW |
| WS-20 | WEAK | LOW |
| WS-21 | LIKELY | MEDIUM |
| WS-22 | WEAK | LOW |
| WS-23 | WEAK | LOW |
| TERM-01 | WEAK | LOW |
| TERM-02 | WEAK | LOW |
| TERM-03 | WEAK | LOW |
| TERM-04 | CERTAIN | MEDIUM |
| WS-NEW-1 | LIKELY | MEDIUM |
| TERM-05 | LIKELY | LOW |
| TERM-06 | CERTAIN | LOW |
| FS-02 | WEAK | LOW |
| FS-03 | CERTAIN | LOW |
| FS-04 | WEAK | LOW |
| FS-05 | WEAK | LOW |
| SOCK-14 | WEAK | LOW |
| CORE-12 | WEAK | LOW |
| WS-24 | WEAK | LOW |
| CORE-13 | WEAK | LOW |
| TLS-10 | LIKELY | LOW |
| IO-01 | WEAK | LOW |
| CONSOLE-02 | CERTAIN | LOW |
| CONSOLE-03 | CERTAIN | LOW |
| CONSOLE-04 | CERTAIN | LOW |
| TIME-08 | CERTAIN | LOW |
| TIME-09 | CERTAIN | LOW |
| ZLIB-01 | CERTAIN | LOW |
| CORE-14 | CERTAIN | LOW |
| CORE-15 | WEAK | LOW |
| CORE-16 | WEAK | LOW |
| FD-03 | LIKELY | LOW |
| FD-04 | WEAK | LOW |
| FD-05 | CERTAIN | LOW |
| SIG-01 | WEAK | LOW |
| SIG-02 | WEAK | LOW |
| SIG-03 | CERTAIN | LOW |
| SIG-04 | CERTAIN | LOW |
| CORE-17 | WEAK | LOW |
| CORE-18 | CERTAIN | LOW |
| WATCH-07 | CERTAIN | MEDIUM |
| WATCH-08 | CERTAIN | MEDIUM |
| REGEX-08 | CERTAIN | MEDIUM |
| PROC-06 | LIKELY | LOW |
| PROC-07 | CERTAIN | MEDIUM |
| PROC-08 | CERTAIN | LOW |
| RESET-05 | CERTAIN | LOW |
| STREAM-07 | CERTAIN | MEDIUM |
| STREAM-08 | WEAK | LOW |
| STREAM-09 | WEAK | LOW |
| STREAM-10 | WEAK | LOW |
| SYS-03 | WEAK | LOW |
| FS-06 | WEAK | LOW |
| RESET-06 | CERTAIN | LOW |
| RESET-07 | CERTAIN | LOW |
| RESET-08 | CERTAIN | LOW |
| RESET-09 | CERTAIN | LOW |
| RESET-10 | CERTAIN | LOW |
| SOCK-15 | LIKELY | LOW |
| WS-25 | WEAK | LOW |
| HEAP-05 | WEAK | LOW |
| HTTPSRV-13 | WEAK | LOW |
| HTTPSRV-14 | CERTAIN | LOW |
| HTTPSRV-15 | WEAK | LOW |
| HTTPSRV-16 | CERTAIN | LOW |
| RESET-11 | CERTAIN | LOW |
| CORE-19 | WEAK | LOW |
| CRASH-01 | LIKELY | LOW |
| SOCK-16 | WEAK | LOW |
| WS-26 | WEAK | LOW |
| SYNC-01 | WEAK | LOW |
| SYNC-02 | CERTAIN | LOW |
| SYNC-03 | CERTAIN | LOW |
| HTTPS-11 | WEAK | LOW |
| DEAD-02 | CERTAIN | LOW |
| DEAD-03 | CERTAIN | LOW |
| DEAD-04 | CERTAIN | LOW |
| DEAD-05 | CERTAIN | LOW |
| DEAD-06 | CERTAIN | LOW |
| DEAD-07 | CERTAIN | LOW |
| DEAD-08 | CERTAIN | LOW |
| DEAD-09 | CERTAIN | LOW |
| DEAD-10 | CERTAIN | LOW |
| DEAD-11 | CERTAIN | LOW |
| DEAD-12 | CERTAIN | LOW |
| DEAD-13 | WEAK | LOW |
| DEAD-14 | CERTAIN | LOW |
| DEAD-15 | CERTAIN | LOW |
| DEAD-16 | CERTAIN | LOW |
| DEAD-17 | CERTAIN | LOW |
| DEAD-18 | CERTAIN | LOW |
| DEAD-19 | CERTAIN | LOW |
| DEAD-20 | CERTAIN | LOW |
| DEAD-21 | CERTAIN | LOW |
| DEAD-22 | CERTAIN | LOW |
| DEAD-23 | CERTAIN | LOW |
| DEAD-24 | CERTAIN | LOW |
| DEAD-25 | CERTAIN | LOW |
| DEAD-26 | CERTAIN | LOW |
| DEAD-27 | CERTAIN | LOW |
| DEAD-28 | RESOLVED | LOW |
| DEAD-29 | CERTAIN | LOW |
| DEAD-30 | CERTAIN | LOW |
| DEAD-31 | CERTAIN | LOW |
| DEAD-32 | CERTAIN | LOW |
| DEAD-33 | WEAK | LOW |
| DEAD-34 | CERTAIN | LOW |
| DEAD-35 | CERTAIN | LOW |
| DEAD-36 | CERTAIN | LOW |
| DEAD-37 | CERTAIN | LOW |
| DEAD-38 | WEAK | LOW |
| DEAD-39 | CERTAIN | LOW |
| DEAD-40 | CERTAIN | LOW |
| DEAD-41 | CERTAIN | LOW |
| DEAD-42 | RESOLVED | LOW |
| DEAD-43 | CERTAIN | LOW |
| DEAD-44 | CERTAIN | LOW |
| DEAD-45 | CERTAIN | LOW |
| DEAD-NEW-1 | CERTAIN | LOW |


## Memory safety & GC

### ARRAY-01: unsafeSet range check truncates the index to 32 bits
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/JsArrayExports.cpp:238-244 (`Elm_Kernel_JsArray_unsafeSet`), :882 (`_Int`), :892 (`_Float`), :901-902 (`_Char`)
- **Original claim:** the bound check compares `static_cast<uint32_t>(idx) < len` but the store uses the full 64-bit `elements[idx]`.
- **Analysis:** Confirmed: in all four functions the guard truncates while the write indexes with the `int64_t`. An index such as `2^32 + 1` passes the check against a length-2 array and writes ~32 GiB past it. Reachability: `JsArray` is a kernel module only `elm/core` may import. Every `JsArray.unsafeSet` call in `elm/core` `Array.elm` (lines 309, 330, 335, 337, 431, 440, 795) takes `Bitwise.and bitMask index` or a `pos` produced the same way, so the index is always in 0..31. `Array.set` also checks `0 <= index < length` before it gets here. A user program cannot reach the kernel with a bad index. The same truncation is in `unsafeGet` (:205, `alloc::arrayGet(ptr, (uint32_t)idx)`), which at worst reads the wrong in-range element.
- **Impact:** an out-of-bounds heap write, but only from a hand-written kernel call or a future compiler/core bug. Not reachable from well-typed Elm.
- **Suggested fix / next step:** check `idx >= 0 && static_cast<uint64_t>(idx) < len` and keep the 64-bit index. This is a cheap hardening change.

### ABI-01: modBy throws across an extern "C" export
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/BasicsExports.cpp:181-183 `Elm_Kernel_Basics_modBy` → E/core/Basics.cpp:94-95 `Basics::modBy` (`throw std::runtime_error`)
- **Original claim:** `std::runtime_error` from `modBy 0` escapes an `extern "C"` export that has no `ECO_KERNEL_GUARD`.
- **Analysis:** Confirmed. The export calls `Basics::modBy` directly. The macro is defined in K/../KernelExports.h:68, but `grep` finds no use of `ECO_KERNEL_GUARD` anywhere under `elm-kernel-cpp/src`. Saturated `modBy` at `Int Int` is lowered inline to `eco.int.modby` (compiler/src/Compiler/IR/Kernel/Intrinsics.elm:205), which yields 0 (CGEN_084). The kernel symbol is still exported and registered (runtime/src/codegen/RuntimeSymbols.cpp:748), and it is reached whenever `modBy` is not intrinsified, for example as a first-class function value or a closure call. The exception then unwinds into LLVM-generated frames that likely have no usable unwind info, so the result is `std::terminate` (formally UB). That same call path also makes `modBy 0` crash where the inline path returns 0.
- **Impact:** the process aborts with "terminate called after throwing..." instead of the structured `[eco-runtime] FATAL` message. In the worst case unwinding misbehaves. The program dies either way, so this is mostly a UB and diagnostics issue. The separate semantic divergence (the kernel throws, inline returns 0) is the deliberate exclusion noted in the header.
- **Suggested fix / next step:** wrap the body in `ECO_KERNEL_GUARD`, or better make the kernel match CGEN_084 (return 0) so both paths agree. To settle reachability, test `List.map (modBy 0) [5]` (or `let f = modBy in f 0 5`) and check that it calls `Elm_Kernel_Basics_modBy`.

### REGEX-01: createMatch kind mask swaps String and Int slots — **FIXED on master**: createMatch writes fields in layout order (the mask was right, the order was wrong)
- **Status:** RESOLVED · **Severity:** HIGH
- **Where:** E/regex/RegexExports.cpp:112-150, `createMatch`
- **Original claim:** mask `0b0101` marks the match String slot Int and the `number` Int slot boxed.
- **Analysis:** The current code writes `fields[0].i = index`, `fields[1].i = number`, `fields[2].p = matchStrHP`, `fields[3].p = submatchList` (:140-144) with mask `0b0101` (:146). With 2-bit kinds that makes slots 0 and 1 Int (01) and slots 2 and 3 boxed (00), matching the layout the comment at :107-111 describes (unboxed fields first, each group sorted by name). `submatchList` and `matchStrHP` are rooted across the allocations (:118-120). The fix is in place.
- **Impact:** none now. Before the fix, the GC treated an Int as a pointer.
- **Suggested fix / next step:** none. The elm-conformance repro guards it.

### REGEX-02: Regex custom built with 2-bit kind mask 0b111 — **FIXED on master**: never uses kind mask 0x15
- **Status:** RESOLVED · **Severity:** HIGH
- **Where:** E/regex/RegexExports.cpp:209 (`Elm_Kernel_Regex_never`), :257 (`Elm_Kernel_Regex_fromStringWith`)
- **Original claim:** `custom(CTOR_REGEX, values, 0b111)` declares slot 2 boxed while it holds a raw 0/1.
- **Analysis:** Both sites now pass `0x15` (= 0b01_01_01), so all three slots (id, caseInsensitive, multiline) are Int, which matches the values written (:203-205, :251-253). No `0b111` remains in the file.
- **Impact:** none now.
- **Suggested fix / next step:** none.

### REGEX-03: replaceAtMost/splitAtMost catch paths use unrooted strings
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/regex/RegexExports.cpp:427-430 (`Elm_Kernel_Regex_replaceAtMost`, `return str;`), :486-490 (`Elm_Kernel_Regex_splitAtMost`, `Export::decode(strEnc)` then `cons`)
- **Original claim:** the catch paths return or decode `str`/`strEnc`, which are not rooted across the loop's allocations.
- **Analysis:** Confirmed. The comments at :428 and :487 even say so. In `replaceAtMost` the loop calls `createMatch` (allocates) and `eco_apply_closure` on the user's replacer, which runs arbitrary Elm code and makes a GC very likely. Only `closureHP` and the per-iteration `matchRecord` are rooted (:371, :410). In `splitAtMost` the loop allocates via `utf8ToElmString`, with only `parts` rooted. If a later iteration throws, the catch hands back the pre-GC word of the input string. Triggers: srell `regex_error` (complexity/stack limit on catastrophic backtracking in a later match), `std::bad_alloc`, or any C++ exception from the replacer's kernel calls (for example the `modBy` throw, ABI-01). If the string was in the nursery and a minor GC ran first, the returned pointer is dangling. The happy paths are fine because they work only from the `strUtf8` copy. The `catch (...)` also silently swallows exceptions from the user closure, which masks real failures.
- **Impact:** a dangling String pointer returned into Elm, leading to memory corruption or a crash, but only when an exception happens after at least one GC in the loop.
- **Suggested fix / next step:** decode `str` into a rooted `HPointer` (`StackRootGuard`) before the loop and return or encode that in the catch. Alternatively rebuild the result from `strUtf8`.

### REGEX-04: getCompiledRegex does not check the object tag
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/regex/RegexExports.cpp:89-101, `getCompiledRegex`
- **Original claim:** reads `ctor` without checking that the object is a `Tag_Custom`.
- **Analysis:** True as written, and the comment at :86-88 documents it. Regex values come only from `fromStringWith` (:257) and `never` (:209), which always build a `Custom` with `CTOR_REGEX`. Elm's type system keeps any other object out of a `Regex` argument. An embedded constant (for example `never` returning the `nothing()` constant when compiling `(?!)` throws, :212) gives `toPtr == null` and is handled at :91. The id lookup in the side table (:97-99) is a second check, so even a misread ctor of 0xFF00 would need a matching id.
- **Impact:** none reachable from well-typed Elm.
- **Suggested fix / next step:** optionally add `getHeader(ptr)->tag == Tag_Custom` as hardening. No action needed.

### TIME-01: tagger/router encodings decoded after an allocation
- **Status:** CERTAIN · **Severity:** HIGH
- **Where:** E/time/TimeEffectManager.cpp:166-186, `timerTickEvaluator`
- **Original claim:** `taggerEnc`/`routerEnc` are copied under `g_timerMutex`, then `Scheduler::taskSucceed` allocates before they are decoded and rooted.
- **Analysis:** Confirmed. The words are copied out of `g_intervals` at :172-173. The mutex is released, then `Scheduler::instance().taskSucceed(unit())` (:178) calls `allocTask` (runtime/src/platform/Scheduler.cpp:159-161), which is a GC point. The "time-effects" root scanner (:95-108) updates `state.taggerEnc` and `state.routerEnc` inside the map, not the local copies. The stale copies are then decoded and rooted at :185-186, and the code calls the tagger (:203) and `sendToApp(routerHP, ...)` (:206). The comment at :183-184 states the opposite of what the code does. Reachability: Elm calls `subscriptions` after every update, and `timeOnEffectsEvaluator` overwrites `taggerEnc` with the newly built tagger each time (:303-304), so the tagger is usually a young nursery object. Any `Time.every` program hits this whenever the nursery fills on the tick's `taskSucceed` allocation. That happens with probability roughly (task size / nursery size) per tick, which is near-certain over a long run with a busy update loop.
- **Impact:** `eco_apply_closure` on a moved or evacuated closure address, giving a crash, wrong message, or heap corruption in ordinary `Time.every` programs.
- **Suggested fix / next step:** move the `taskSucceed` call to after the decode and rooting (put `succeedTask` inside the guard block), or re-copy the words under the mutex after the allocation. To reproduce: a `Time.every 1` program whose `update` allocates heavily, under `ECO_HEAP_VALIDATE` (the stale-nursery tripwire in `Allocator::resolve`, runtime/src/allocator/Allocator.cpp:1146-1151).

### TIME-02: subMap kind bitmap marks a Float field as Int — **FIXED on master**: subMap uses kind mask 0b10 (Float)
- **Status:** RESOLVED · **Severity:** MEDIUM
- **Where:** E/time/TimeEffectManager.cpp:~396, `timeSubMapEvaluator`
- **Original claim:** kind bitmap `0b01` while field 0 holds a Float.
- **Analysis:** The code now has `custom(CTOR_TIME_EVERY, values, 0b10)`, with `values[0].f = interval` and `values[1].p = composedTagger`. Slot 0 is Float (10) and slot 1 is boxed (00), which is correct. The mapper, origSub and origTagger are rooted across `allocClosure` and `custom`.
- **Impact:** none now.
- **Suggested fix / next step:** none.

### TIME-03: setInterval writes Int kind for a Float field — **FIXED on master**: setInterval uses kind mask 0b10 (Float)
- **Status:** RESOLVED · **Severity:** MEDIUM
- **Where:** E/time/TimeExports.cpp:273-281, `Elm_Kernel_Time_setInterval`
- **Original claim:** mask `0b01` (Int) written for a Float field.
- **Analysis:** The code now uses `custom(CTOR_TIME_EVERY, values, 0b10)` with `values[0].f = intervalMs`, so the kind is correct. The boxed `values[1].p` taken from the `task` argument needs no rooting because `custom` is the only allocation and it roots the boxed entries of `values` itself.
- **Impact:** none now.
- **Suggested fix / next step:** none.

### TIME-04: setInterval skips capture when the binding callback does not resolve
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/time/TimeExports.cpp:237-256 (`Elm_Kernel_Time_now`; the cited :251-253 now lies in `now`, not `setInterval`), evaluator `timeNowBindingEvaluator` :175-200
- **Original claim:** if `resolve(bindingCB)` is null the capture is skipped, but the evaluator then reads uncaptured `rawArgs[0]`.
- **Analysis:** `bindingCB` is the closure `allocClosureK` has just returned (:247-250), a fresh heap object, so `resolve` cannot return null for it. The `if (clPtr)` is defensive dead code. `setInterval` itself has no binding callback any more (:273-281). `mtpHP` is rooted across the allocations (:245).
- **Impact:** none in practice.
- **Suggested fix / next step:** replace the `if` with an assert, or leave it.

### TASK-01: task effect manager closures unrooted at registration
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/core/TaskEffectManager.cpp:199-215, `eco_register_task_effect_manager`
- **Original claim:** `initCl`/`onEffectsCl`/`onSelfMsgCl` are held unrooted across later `allocClosure` calls.
- **Analysis:** Confirmed. There are four consecutive `allocClosure` calls with no `StackRootGuard`, and the comment at :197-198 admits it. The words are only rooted once `registerManager` stores them in `managers_`, which a scanner covers (runtime/src/platform/PlatformRuntime.cpp:116). This runs once at startup (runtime/src/codegen/eco_entry.cpp:156, EcoRunner.cpp:267, embed/eco_embed.cpp:204), but after `__eco_init_globals` (:151), which can allocate a lot. A minor GC on one of these small allocations is therefore possible but unlikely. If it happens, a 0-capture closure in the nursery moves and `managers_` gets a stale word, so the Task manager (`Task.perform`/`attempt`) breaks or corrupts memory later. The Http registrar fixes the same pattern (E/http/HttpEffectManager.cpp:415-437, each closure guarded). The Time registrar does not (see TIME-NEW-1).
- **Impact:** a rare startup heisenbug: corrupt manager closures for Task commands.
- **Suggested fix / next step:** add a `StackRootGuard` after each `allocClosure`, as in `eco_register_http_effect_manager`.

### TASK-02: taskOnEffectsEvaluator reads state unrooted after allocations
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/TaskEffectManager.cpp:123-125, `taskOnEffectsEvaluator`
- **Original claim:** reads state from `args[3]` after `allocClosure`/`taskAndThen`/`rawSpawn` without rooting it.
- **Analysis:** The read happens after GC points, as described (comment at :78). But the Task manager's state is always `[]`: `taskInitEvaluator` returns `taskSucceed(listNil())` (:~42-46), and `onEffects`/`onSelfMsg` only pass the incoming state back. Nil is an embedded constant, not a heap pointer, so it cannot go stale. Every other value in the function is rooted (router, cmds :89, sendToAppCl :103, RootedListCursor).
- **Impact:** none while the state stays the Nil constant. It would become a real bug only if the state became a heap value.
- **Suggested fix / next step:** read `args[3]` before the first allocation (one-line hardening).

### TASK-03: resolve on a constant command asserts
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/TaskEffectManager.cpp:~108 (`taskOnEffectsEvaluator`, `resolve(cmdHP)`), :~160 (`taskCmdMapEvaluator`, `resolve(origCmd)`)
- **Original claim:** calls `resolve` on a command that may be an embedded constant.
- **Analysis:** The Task manager's `MyCmd` has a single constructor, `Perform (Task Never msg)`, which carries an argument and so is always a heap `Custom`, never an embedded constant (only nullary constructors, Unit, Nil, Bool and so on are constants). `Allocator::resolve` asserts `ptr_ind == 0` only under `ECO_HEAP_VALIDATE` (runtime/src/allocator/Allocator.cpp:1143-1144). Well-typed Elm cannot supply a constant here.
- **Impact:** none reachable.
- **Suggested fix / next step:** none, or check `ptr_ind` before `resolve` for robustness.

### ARRAY-02: boxed unsafeSet marks Float/Char sources Int-kind
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/JsArrayExports.cpp:226-246, `Elm_Kernel_JsArray_unsafeSet` (boxed)
- **Original claim:** Float/Char sources are marked Int kind and read via `unboxInt`.
- **Analysis:** Confirmed. `srcUnboxed = header.unboxed != 0` (:227), `unboxedNew = unboxInt(value)` (:228, which reads `ElmInt::value` as `int64`), and `dst->header.unboxed = srcUnboxed ? 1 : 0` (:246). For a Float array (kind 2) or Char array (kind 3) the copy is relabelled Int (kind 1). The stored element bits happen to be right: `ElmFloat` has a `double` at the same offset, and `ElmChar` has a `u32` plus zero padding (runtime/src/allocator/Heap.hpp:426-430). The kind is wrong, though, so later kind-driven readers (`unsafeGet` boxing via `boxElement(val, kind)` at :207-209, Debug.toString, equality, folds) see an Int, giving garbage Ints for Floats and Ints for Chars. GC safety is unaffected because the elements are still unboxed. The typed variants `copyForUnsafeSet` + `_Int/_Float/_Char` (:848-905) do it right. Reachability: the compiler intrinsifies (`ArraySet`) or suffix-dispatches (compiler/src/Compiler/GenerateMlir/KernelAbi.elm:300-307) every call whose array element or value type is Int, Float or Char (compiler/src/Compiler/IR/Kernel/Intrinsics.elm:713-724). The boxed kernel is reached only when both are type variables, which after monomorphization means the elements should be boxed. elm/core always calls it saturated. It is very likely unreachable today.
- **Impact:** a silent kind change to Int on unboxed Float/Char arrays if the boxed fallback is ever hit.
- **Suggested fix / next step:** keep `kind = header.unboxed & 3`, store the raw 64 bits (or decode per kind), and write `dst->header.unboxed = kind`. That is the same logic as `copyForUnsafeSet`, which the boxed path could reuse.

### TIME-NEW-1: Time effect manager closures unrooted at registration (same as TASK-01)
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/time/TimeEffectManager.cpp:413-429, `eco_register_time_effect_manager`
- **Original claim:** (new) same pattern as TASK-01.
- **Analysis:** Four `allocClosure` calls (`initCl`, `onEffectsCl`, `onSelfMsgCl`, `subMapCl`) with no rooting between them, before `registerManager` stores the words in `managers_`. It runs first in `eco_register_all_effect_managers` (E/EffectManagerRegistry.cpp:15), after `__eco_init_globals`. The Http registrar in the same function list roots each closure (E/http/HttpEffectManager.cpp:415-437), which shows the intended pattern.
- **Impact:** a rare startup GC leaves stale Time manager closures, so `Time.every` breaks or memory is corrupted.
- **Suggested fix / next step:** add a `StackRootGuard` per closure, as in Http.

### ARRAY-03: push reads Char padding as part of a 64-bit value
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/JsArrayExports.cpp:258-310, `Elm_Kernel_JsArray_push` (boxed root export)
- **Original claim:** for an unboxed source the new element is read as 64 bits after the boxed value's header (including `ElmChar::padding`), and the result is always marked Int-kind.
- **Analysis:** The defect is in the code. For any `src->header.unboxed != 0` the function reads `*(int64_t*)(valPtr + sizeof(Header))` (:272-276) and sets `dst->header.unboxed = 1` (:288-289). That is wrong in two ways. (a) For a Char source the upper 32 bits come from `ElmChar::padding` (runtime/src/allocator/Heap.hpp:426-430), and `allocChar` never writes it (HeapHelpers.hpp:335-340). Under per-site nursery zeroing that is poison or garbage, so the slot breaks the "bits 32..63 zero" rule (Heap.hpp:229, REP_HEAP_002). (b) A Float (kind 2) or Char (kind 3) array comes out tagged kind 1 (Int), which is worse than the padding problem. The same forcing to kind 1 is in the boxed `Elm_Kernel_JsArray_unsafeSet` (:215-256: `unboxInt(value)`, `header.unboxed = srcUnboxed ? 1 : 0`). Reachability, though, is close to nil. Every direct `JsArray.push` call goes through the `ArrayPush` intrinsic (compiler/src/Compiler/IR/Kernel/Intrinsics.elm, `jsArrayIntrinsic` "push"), which lowers to `elm_array_push_int/_float/_char/_box` by the SSA element type (runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:1557-1585). A kernel-as-value closure gets the `_Int/_Float/_Char` symbol through suffix selection (Compiler/IR/Kernel/Abi.elm:69-71, GenerateMlir/KernelAbi.elm:290-297). So the root is reached only when the element type is a boxed `CEcoValue` variable, and then the source array is kind 0. elm/core 1.0.5 Array.elm calls push only directly (:346, :409, :417).
- **Impact:** If it were reached, Char slots would carry garbage high bits and Float or Char arrays would be relabelled Int, giving wrong values from get, compare and toString. It is not reachable from well-typed Elm through the current codegen. The exception is NEW-1 (below), which can produce mismatched arrays, and even there this export is not on the path.
- **Suggested fix / next step:** Keep the source kind (`dst->header.unboxed = srcKind`) and read the payload according to that kind (`ElmChar::value` for kind 3, the f64 for kind 2). Do the same in boxed `unsafeSet`. Alternatively assert `srcKind == 0` in both, since the typed variants own the primitive cases.

### ARRAY-04: unsafeSet_* force the result kind regardless of source
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/JsArrayExports.cpp:877-907, `Elm_Kernel_JsArray_unsafeSet_Int/_Float/_Char` (copy made by `copyForUnsafeSet`, :849-873)
- **Original claim:** the result kind is forced unboxed even when the source array is boxed-kind, so source HPointers get reinterpreted as raw values.
- **Analysis:** The forcing is real (`dst->header.unboxed = 1/2/3` at :884, :894, :905), but it is the intended design and it matches the inline path. The inline `eco.array.set` lowering does the same thing (`eco_clone_array` followed by `eco_array_set_fix_kind`, EcoToLLVMHeap.cpp:1415-1460; RuntimeExports.cpp:4752-4761), because a copy of an empty or kind-0 array must not leave an Int slot traced as a pointer. Arrays are assumed to have one uniform kind equal to the element type: `eco.array.get` loads the slot as i64/f64/i32 with no kind check (EcoToLLVMHeap.cpp:1386-1405). The `_Int` variant is chosen only when the element type is Int (KernelAbi.elm:300-307). A nonempty kind-0 `Array Int` therefore breaks the inline reads already, and forcing the kind is not the root cause. The only way I found to build such an array is NEW-1. There, setting kind 1 turns the copied HPointer words into Ints: wrong values, but not memory-unsafe, because the GC simply stops tracing them.
- **Impact:** None under the uniform-kind invariant. Under NEW-1, the other elements come back as pointer bits interpreted as Ints.
- **Suggested fix / next step:** No change needed here. Fix NEW-1 instead. Optionally assert `kind == 0 ? len == 0 : kind == wanted` in `copyForUnsafeSet` builds that have heap validation on.

### ARRAY-05: elm_array_push_* writes raw words into a boxed array
- **Status:** UNSURE · **Severity:** MEDIUM
- **Where:** E/core/JsArrayExports.cpp:713-741, `elm_array_push_int/_float/_char` (copy made by `copyAndExtendForPush`, :680-709)
- **Original claim:** on a non-empty boxed (kind 0) array these functions write an unboxed raw word.
- **Analysis:** The code does what the claim says. The copy keeps `srcKind` (:697), and the kind is rebound only when `len == 0` (:719, :729, :739). A nonempty kind-0 source therefore gets a raw i64/f64/char word in a slot the GC scans as an HPointer (HEAP/REP_HEAP_002 2-bit kinds). That is GC memory corruption, and a later `unsafeGet_Int` returns `val.p` (:829-844) as a pointer. Reaching it requires a nonempty kind-0 array whose element type is Int, Float or Char, which the uniform-kind design rules out (see ARRAY-04). The one plausible producer I found is NEW-1: `JsArray.map`/`initialize`/`indexedMap` store results in the closure's own result kind, and that can be 0 for an Int-typed result. I could not run a test to confirm the trigger end to end.
- **Impact:** If NEW-1 holds, `Array.push 4 (Array.map (Debug.log "x") (Array.fromList [1,2,3]))` would store raw `4` in a traced slot, giving a crash or heap corruption at the next GC or read.
- **Suggested fix / next step:** In `copyAndExtendForPush`'s typed callers, rebind the kind when `len == 0`, and assert (or convert, by unboxing the prefix) when `srcKind != 0 && srcKind != wanted`. To settle it, write an E2E test with the program above under `ECO_HEAP_VALIDATE` (and also check `Array.get 0` on the mapped array).

### LIST-01: List.fromArray conses Float/Char as Int-kind cells
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/ListExports.cpp:318-359, `Elm_Kernel_List_fromArray`
- **Original claim:** unboxed Float or Char array elements are consed into Int-kind cells.
- **Analysis:** The loop calls `List::cons(head, result, !isUnboxed)` (:353), and `alloc::cons` with `headIsBoxed=false` writes kind Int. The comment at :346-348 admits it. Float and Char arrays would therefore produce Int-kind cells. However, the Eco annotation of `Elm.Kernel.List.fromArray` is `List a -> List a` (compiler/src/Compiler/Type/KernelIntrinsics.elm:166-171), and its only use site is elm/core String.elm:191, `fromArray (String.split sep string)`. That receives a list (Tag_Cons/ConsChunk), which takes the passthrough at :332-334. No C++ caller exists. The ElmArray branch cannot be reached from Elm.
- **Impact:** None today. If the ElmArray branch were ever revived, Float and Char lists would get the wrong cell kind (wrong compare, toString and pattern reads).
- **Suggested fix / next step:** Use the kind-aware cons (`alloc::cons` with the array's kind, e.g. `consKind`), or remove the ElmArray branch as dead.

### LIST-02: element kind differing from closure kind delivered unconverted
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/ListExports.cpp:476-505, `kernelListMapN` (delivery-kind selection)
- **Original claim:** an unboxed element whose kind differs from the closure's (nonzero) slot kind is passed in its own kind, and `eco_apply_closure_eval` asserts on that (RuntimeExports.h:592-596).
- **Analysis:** The final `else` branch (:503-505) does pass `cb[i].kind` unchanged when both kinds are nonzero and differ. `eco_apply_closure_eval` documents that a primitive-to-primitive mismatch is an assertion failure (RuntimeExports.h:589-597). For well-typed code the two kinds cannot differ. List cells take their kind from the SSA head type (CGEN_027, `List.cons_Int/_Float/_Char`), and a closure parameter of the same Elm type has the same primitive kind (CGEN_003/CGEN_049). Parameters beyond the first stage have kind 0 from `closureNewArgKind`, so they take the boxing branch. A mismatch would need a mis-kinded list. LIST-01 could produce one, but it is unreachable.
- **Impact:** An assertion only, and only with mis-kinded input. Unreachable from well-typed Elm.
- **Suggested fix / next step:** Replace the branch with `assert(false)` or a box-then-unbox conversion, so a mis-kind fails loudly instead of being delivered.

### LIST-03: dead sortWith resolves raw bits after a boxed first node
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/List.cpp:52-87, `Elm::Kernel::List::sortWith`
- **Original claim:** boxedness is decided from the first node, then raw bits of later nodes are resolved.
- **Analysis:** `element_kind` comes from the first cell's slot-0 kind (:58-64). For a later element with `b_boxed == false`, `alloc::boxElement(b, element_kind)` with kind 0 returns `v.p` unchanged (HeapHelpers.hpp:1911-1917), and `allocator.resolve` is then called on raw Int bits. That needs a list of mixed kinds, which well-typed code never builds. The function is dead: there are no callers of `Elm::Kernel::List::sortWith/sortBy/fromArray` anywhere in elm-kernel-cpp, eco-kernel-cpp, system-kernel-cpp, runtime or test (grep). It is still compiled (elm-kernel-cpp/CMakeLists.txt:79).
- **Impact:** None while it is dead. If revived it would dereference a bad pointer.
- **Suggested fix / next step:** Delete `sortBy`, `sortWith` and `fromArray` from List.cpp/List.hpp (dead code).

### LIST-04: dead List.cpp sorts resolve embedded constants
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/List.cpp:25-43 (`sortBy`: `resolve(val.p)`, `resolve(keyResult)`) and :70-82 (`sortWith`: `resolve(a.p)`, `resolve(b.p)`)
- **Original claim:** these functions call `resolve` on elements that may be embedded constants.
- **Analysis:** Boxed elements such as `Nothing`, `True`, `()`, `[]` and `""` are embedded constants (Heap.hpp:169-172). `Allocator::resolve` requires a non-constant pointer (Allocator.hpp:99-104). `fromPointerRaw` asserts `ptr_ind == 0` (Allocator.hpp:660-666), and in non-assert builds it masks the word to a tiny address (6 or 7) and reads a header there (Heap.hpp:336-338), which segfaults. Both functions are dead (see LIST-03).
- **Impact:** None while dead. If revived, sorting a list that contains a constant would assert or segfault.
- **Suggested fix / next step:** Delete them (same as LIST-03).

### LIST-05: dead sortBy boxes unboxed elements as Int
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/List.cpp:23-46, `Elm::Kernel::List::sortBy`
- **Original claim:** unboxed elements are boxed as Int and keys are read as `ElmInt`.
- **Analysis:** The function calls `alloc::allocInt(val.i)` for every unboxed element (:33-35) and reads the key as `ElmInt::value` (:38-41), so Float and Char elements and keys are misread. The extractor also allocates on each call, which can move list cells while `ListOps::sortBy` iterates over them. The function is dead (no callers, see LIST-03).
- **Impact:** None while dead.
- **Suggested fix / next step:** Delete it.

### STRING-01: String foldl/foldr resolve a possibly-constant accumulator
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/String.cpp:129-161, `Elm::Kernel::String::foldl/foldr`
- **Original claim:** `resolve` is called on an accumulator that may be an embedded constant.
- **Analysis:** `allocator.resolve(result)` runs before every `func` call (:141, :157). An accumulator such as `[]`, `""` or `0`-like constants fails the `ptr_ind == 0` assert, or reads a near-null header (Allocator.hpp:660-666, Allocator.cpp:1140-1171). The header documents the restriction (String.hpp:100-103). There are no callers anywhere: the `String.foldl/foldr` exports go through closures elsewhere (String.hpp:21, :75, and a grep for `String::fold` found nothing).
- **Impact:** None while dead. An assert or crash if revived with a constant initial accumulator, which is common (`String.foldl f [] s`).
- **Suggested fix / next step:** Delete both functions (dead), or pass the HPointer to `func` instead of a resolved `void*`.

### STRING-02: String foldl/foldr leave the accumulator unrooted across func
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/String.cpp:129-161, `foldl/foldr`
- **Original claim:** the result is held unrooted across the call to `func`, so it is stale after a GC.
- **Analysis:** The HPointer `result` is not needed after `func` returns: it is overwritten with `func`'s return value at once (:142, :158), and the next `resolve` happens with no allocation in between. The only hazard is the raw `accObj` handed to `func`. It goes stale if `func` allocates before it finishes reading `accObj`. That is a documented contract of `FoldFunc` (String.hpp:107-110), not a defect in the loop. The functions are dead in any case.
- **Impact:** None while dead. A careless `func` could read a moved accumulator.
- **Suggested fix / next step:** Delete with STRING-01.

### HEAP-01: listToStringVector resolves the empty-string constant
- **Status:** CERTAIN · **Severity:** HIGH
- **Where:** K/KernelHelpers.hpp:214-221, `Eco::Kernel::listToStringVector`. Callers: K/Process.cpp:67 and :90 (argument lists), S/ChildProcess/ChildProcess.cpp:67 (`spec.args`), S/Tls/Tls.cpp:186 and :246 (ALPN), S/WebSocket/WebSocket.cpp:272 (addresses)
- **Original claim:** every element is passed to `Allocator::resolve`, including the empty-string constant.
- **Analysis:** `forEachListElement` hands each head to `Allocator::instance().resolve(head.p)` (:217) with no `isEmptyString` check. The sibling `toString` has that check (:45-52), and the function's own comment admits the omission (:212-213). The empty String is the `Const_Empty` embedded constant (Heap.hpp:171). `resolve` → `fromPointerRaw` asserts `ptr_ind == 0` (Allocator.hpp:661), and the standard `build` preset keeps assertions on. Without assertions the word masks to address 6 and its "header" is read (Heap.hpp:336-338), which segfaults. A child-process call such as `Process.exec "git" ["commit", "-m", ""]` (or `ChildProcess` with any `""` argument) is an ordinary program that hits this. Tls ALPN `""` and an empty WebSocket address are less likely but use the same path.
- **Impact:** The process crashes (assertion abort or SIGSEGV) whenever an empty string appears in a process argument list or in an ALPN or address list.
- **Suggested fix / next step:** In the lambda, `if (Elm::alloc::isEmptyString(head.p)) { result.emplace_back(); return; }`, or call `toString(Export::encode(head.p))`. Add an E2E test that runs a child process with an empty-string argument.

### HEAP-02: NativeDriver resolves Bytes without the empty-Bytes check
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/NativeDriver.cpp:59-81, `lowerAndLinkBytesBody` (:68)
- **Original claim:** `resolve(bytesHP)` is called without the empty-Bytes constant check.
- **Analysis:** Empty Bytes is the `Const_Empty` constant (HeapHelpers.hpp:217-222, `emptyBytes() = empty()`). `resolveBytesOrNull` exists for exactly this case, and `byteBufferLength`/`byteBufferData` already accept null (HeapHelpers.hpp:1552-1554). The code calls `Elm::Allocator::instance().resolve(bytesHP)` directly (:68), which asserts or reads address 6, as in HEAP-01. The trigger is `NativeDriver.lowerAndLinkBytes` with empty MLIR bytes. The normal compiler never passes those deliberately, but an upstream failure can produce empty or truncated output (see the earlier "swallowed crash, truncated .mlir" incident).
- **Impact:** A crash instead of the intended "lowering/linking failed" Task failure, on empty input.
- **Suggested fix / next step:** Use `Elm::alloc::resolveBytesOrNull(bytesHP)` at :68. The null pointer then gives len 0, and the driver reports an error.

### HEAP-03: eco ExportHelpers toPtr(0) reads address 0
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/ExportHelpers.hpp:47-58, `Export::toPtr`
- **Original claim:** `toPtr(0)` reaches `resolveFast` and dereferences address 0.
- **Analysis:** This is true mechanically. Word 0 has `ptr_ind == 0`, so it skips the constant early-return (:50) and goes to `Allocator::resolveFast`, which reads `getHeader(nullptr)->tag` (Allocator.hpp:111-116). The elm-kernel twin returns `raw` (nullptr) because address 0 is not in the heap (E/ExportHelpers.hpp:51-66). Elm values are never the null word, though: `wrap` asserts non-null (Allocator.cpp:1175), and constants have `ptr_ind = 1`. A 0 would mean an uninitialised slot, which is a bug somewhere else. Not reachable from well-typed Elm.
- **Impact:** A defensive gap only. It would segfault where the elm-kernel helper returns null.
- **Suggested fix / next step:** Add `if (val == 0) return nullptr;` (or an assert) for parity with the elm-kernel helper.

### HEAP-04: eco toPtr sends PermanentSpace words through resolveFast
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/ExportHelpers.hpp:47-58, `Export::toPtr`
- **Original claim:** PermanentSpace words go through `resolveFast`, whereas the elm-kernel version returns them unchanged, which may misresolve.
- **Analysis:** `resolveFast` reads the header and calls `resolve` only for `Tag_Forward` (Allocator.hpp:111-116). PermanentSpace objects have well-formed headers and are never forwarded (HEAP_036; Allocator.cpp:1153-1160 explicitly accepts PermanentSpace addresses). The result is therefore the raw address, the same thing the elm-kernel helper returns via `return raw` (E/ExportHelpers.hpp:60-65). The two helpers differ in path, not in result.
- **Impact:** None. At most a predictable header load.
- **Suggested fix / next step:** None needed. Optionally make the two helpers identical for maintainability.

### ARRAY-NEW-1: JsArray map/initialize store results in the closure's result kind, so an Int array can be kind 0
- **Status:** UNSURE · **Severity:** MEDIUM
- **Where:** E/core/JsArrayExports.cpp:120-145, `pushTypedResult`, and its callers `initialize` (:432, :925), `map` (:478-489), `indexedMap` (:531, :975), `initializeFromList`. Kind source: `readClosureResultKind` (:60-64). Codegen: compiler/src/Compiler/GenerateMlir/Expr.elm:1067-1095, `instanceClosureResult`
- **Original claim:** (new) array kinds follow the closure's `result_kind`, not the element type. Every inline array read and typed kernel assumes they match.
- **Analysis:** `JsArray.map` and the others call the closure with `desired_kind = closure->result_kind`, and the first result fixes the array's kind (:120-123). A kernel used as a function value is a `papCreate` whose `_result_kind` comes from the kernel's ABI result type (Expr.elm:1086-1095). For `Debug.*`, and for any kernel with a type-variable result, that type is `MVar CEcoValue`, so the result kind is 0 (Compiler/IR/Kernel/Abi.elm:84-87 `alwaysPolymorphicModules = [Debug]`; Monomorphize/KernelAbi.elm `PreserveVars`). EtaExpand does not wrap a partially applied kernel used as an argument (PreMono/EtaExpand.elm docstring: only lambda literals and definitions). `Array.map (Debug.log "x") (Array.fromList [1,2,3])` should therefore yield a nonempty kind-0 `Array Int`. After that: the inline `eco.array.get` loads the slot as i64 and returns pointer bits (EcoToLLVMHeap.cpp:1386-1405); `push_Int` writes raw words into a traced slot (ARRAY-05, GC corruption); `unsafeSet_Int` relabels the HPointers as Ints (ARRAY-04). I have not confirmed that the PAP made from `Debug.log "x"` keeps `result_kind` 0, or that no later pass inserts an unboxing wrapper.
- **Impact:** Possibly wrong values from `Array.get`, and a GC crash after `Array.push`, in dev programs that map with a point-free polymorphic-result kernel (`Debug.log tag`).
- **Suggested fix / next step:** To settle it, write an E2E test of `Array.map (Debug.log "x") (Array.fromList [1,2,3])`, then `Array.get 0`, `Array.push 4` and `Array.toList`, under ECO_HEAP_VALIDATE. If it reproduces, have `pushTypedResult` (or the callers) convert results to the element kind the call site expects, for example a kind argument passed from the intrinsic or kernel ABI, or give kernel-value closures the call-site result kind.

### PROC-01: spawnProcessBody holds stdinMaybe unrooted
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/Process.cpp:102-112, `spawnProcessBody`; runtime/src/allocator/HeapHelpers.hpp:1274-1286, `tuple2`
- **Original claim:** `stdinMaybe` (a fresh `Just` box) is unrooted across the `tuple2` allocation.
- **Analysis:** `stdinMaybe` is built by `justKind` (K/Process.cpp:106) and passed straight to `tuple2(boxed(stdinMaybe), unboxedInt(pid), 0x4)` at :111. Nothing allocates between the two calls (startChild has already run, and `s_streamHandles[...]` is a plain C++ map). `tuple2` copies both words into a local `roots[]` array and calls `eco_alloc_with_roots(..., roots, 2, mask)` with slot 0 marked boxed (HeapHelpers.hpp:1275-1284), so the allocation itself roots `stdinMaybe` and writes back the possibly-moved word. Mask 0x4 gives slot 1 kind 01 = Int, which is correct. `succeed(tup)` gets the fresh result. The earlier string reads (`cmdHP`..`stderrHP`) are all copied into `std::string` before any allocation.
- **Impact:** None. The value is rooted by the allocation helper.
- **Suggested fix / next step:** No change needed. At most add a comment at :111 saying `tuple2` roots its boxed arguments.

### RESET-01: Runtime root scanner not re-registered after reset
- **Status:** LIKELY · **Severity:** LOW
- **Where:** K/Runtime.cpp:25-28 (`s_savedState`, `s_hasState`), :91-101 `registerGcRootScanner`; runtime/src/allocator/RootSet.cpp:156-165 `RootSet::reset`; NurserySpace.cpp:185
- **Original claim:** a heap reset clears the scanner while `s_hasState`/`s_savedState` survive, which leaves a stale HPointer.
- **Analysis:** This is true as stated. `RootSet::reset` clears `external_scanners` (RootSet.cpp:163). Also, `Allocator::reset` destroys every ThreadLocalHeap, so the root set itself is new afterwards (Allocator.cpp:1067-1112). `s_hasState` is never cleared ("Nothing clears it", Runtime.cpp:27), so `loadState` after a reset would return a dangling word. But `Allocator::reset` is reachable only through `AllocatorTestAccess::reset` (Allocator.hpp:709), called from test/allocator/TestHelpers.cpp:51 and the gc-heap-tsan harnesses. Every production entry (EcoRunner.cpp:246-251, eco_entry.cpp:144-147, eco_embed.cpp:198-200, ecoc.cpp:411-415) calls `initialize()` once, which is a no-op when already initialized (Allocator.cpp:219), and then registers all scanners once. `forkChild` (Allocator.cpp:285-292) does not reset. E2E children are spawned as fresh processes.
- **Impact:** Only a unit-test process that runs `saveState` before an `initAllocator()` reset and `loadState` after it would see a stale pointer. No effect on user programs.
- **Suggested fix / next step:** Add a reset hook that clears `s_hasState` and re-registers the scanner, or document that the kernel scanners are per-heap-lifetime and that tests must re-call `Eco_Kernel_register_all_gc_roots` after `initAllocator`.

### RESET-02: Time root scanner not re-registered after reset
- **Status:** LIKELY · **Severity:** LOW
- **Where:** E/time/TimeEffectManager.cpp:95-108 `timerRegisterScannerOnce` (process-wide `std::once_flag`), :88 `g_intervals`
- **Original claim:** the scanner is registered via `call_once` and never re-registered after a reset; `g_intervals` is not cleared.
- **Analysis:** This is accurate. The `static std::once_flag` means that after `RootSet::reset` (RootSet.cpp:163) or the heap teardown in `Allocator::reset`, the "time-effects" scanner is gone for good while `g_intervals` still holds `taggerEnc`/`routerEnc` words. After that, a GC would neither root nor update them, and a later tick would use dangling closures. As with RESET-01, a reset happens only in test harnesses (TestHelpers.cpp:51). Production initializes the heap once per process, and the first `Time.every` registers on the eco thread's root set, which is the right one.
- **Impact:** Unit tests only: a Time.every test running after another test's `initAllocator()` in the same process gets unrooted interval closures, which means flaky crashes. No production effect.
- **Suggested fix / next step:** Replace `call_once` with a check on the allocator's `heapGeneration` (re-register when it changes, and clear `g_intervals`), the same way the list-scratch scanner was fixed on Oct 6.

### RESET-03: MVar root scanner has no once guard and no re-registration
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/MVar.cpp:307-327 `registerGcRootScanner`; K/MVarExports.cpp:63-65; K/RuntimeExports.cpp:43-48 `Eco_Kernel_register_all_gc_roots`
- **Original claim:** with no once guard the scanner may be registered twice, and it is not re-registered after a reset.
- **Analysis:** The only caller is `Eco_Kernel_register_all_gc_roots`, which each production entry calls exactly once (EcoRunner.cpp:250-251, eco_entry.cpp:147, eco_embed.cpp:200, ecoc.cpp:414-415), so double registration does not happen in practice. The double call in EcoRunner.cpp:253-256 is the Order hook, and `initOrderSingletons` is an empty function (E/core/Utils.cpp:23). Even a double registration would only evacuate each slot twice. The second call sees an already-forwarded or to-space word, which should be idempotent, though this was not verified for every collector mode. Because there is no once guard, re-calling the hook after a reset does re-register, which is better behaviour than RESET-01/02. The reset gap is test-only, as above, and `s_mvars` would still hold stale values.
- **Impact:** Unit tests at most. Nothing in production.
- **Suggested fix / next step:** Optional: clear `s_mvars` on a heap-generation change. No production change needed.

### MVAR-01: MVar read/take/put skip capture when the callback does not resolve
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/MVar.cpp:243-282, `read`/`take`/`put`
- **Original claim:** when `resolve(cb)` returns null, the capture is skipped silently and a Binding is built over an uncaptured closure.
- **Analysis:** `cb` comes straight from `allocClosureK(...)`, which returns a fresh heap object. `Allocator::resolve` returns null only for embedded constants and nil, which a closure allocation never produces (an allocation failure throws `bad_alloc` rather than returning a constant). So the `if (void* clPtr = ...)` test is always true, and the null branch is a defensive dead path, the same idiom as Scheduler.cpp:986-994. In `put`, `valueHP` is rooted across the allocation (MVar.cpp:271).
- **Impact:** None in practice.
- **Suggested fix / next step:** Optionally replace the `if` with an assert.

### MVAR-02: unordered_map iterator held across callClosure1
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/MVar.cpp:138-160 (`readBindingEvaluator`), :164-189 (`takeBindingEvaluator`), :193-218 (`putBindingEvaluator`), :59-75 `wakeWaiter`, :79-109
- **Original claim:** an iterator or reference into `s_mvars` is held across `callClosure1`, and would be invalidated if the resumed code re-enters `newEmpty`/`drop`.
- **Analysis:** All `callClosure1` calls here go to the scheduler-made resume closure (the last raw argument of the Binding callback). `resumeEvaluator` (runtime/src/platform/Scheduler.cpp:452-466) only builds a new Process version and calls `enqueue`; it never runs Elm code synchronously. So neither `newEmpty` nor `drop` can run during the call. `dropBody` itself runs only when the scheduler steps a Binding. Also, `newEmpty`'s `s_mvars[id] = ...` could at most rehash, and rehashing invalidates iterators but not the element references (`MVarSlot&`) that processPutArrival/processTakeDeparture use. In `readBindingEvaluator`, `it` is not used after the call. In take/put, only `it->second` (a reference) is used during the call.
- **Impact:** None under the current scheduler design. The code would become unsafe if resume closures ever ran the fiber synchronously.
- **Suggested fix / next step:** Optionally add a comment or assert that resume closures only enqueue, or re-look up `s_mvars.find(id)` after each wake.

### UTILS-01: two different constants in a boxed slot pair hit unreachable
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/Utils.cpp:165-198, `compareUnboxableSlot` (the assert plus `__builtin_unreachable` at about :190-197); `resolveAndCompare` :69-91
- **Original claim:** two distinct constants in compared boxed slots fall into `__builtin_unreachable()`.
- **Analysis:** The constants are False/True, Empty (Unit, `{}`, Nil, Nothing, `""`, empty Bytes) and NullCons (runtime/src/allocator/Heap.hpp:169-172). Of the comparable Elm types (Int, Float, Char, String, List, tuples), only String and List have constant values, and both use the same Empty word. So two comparable values of one type are either equal constants (caught by `eq`) or at most one is a constant, which is handled at :170-187. Bool, Order and custom types are not comparable and are rejected by the type checker. Reaching the unreachable needs ill-typed input, for example a kernel bug that compares mixed types.
- **Impact:** UB only if some other bug feeds mismatched values. Not reachable from well-typed Elm.
- **Suggested fix / next step:** Optionally replace `__builtin_unreachable` with an ordering by constant word (or a hard abort) so that a kernel bug fails deterministically.

### BASICS-01: Int arithmetic relies on signed overflow
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/BasicsExports.cpp:120-142, `Elm_Kernel_Basics_add_Int`/`sub_Int`/`mul_Int` (plain `a + b`, `a - b`, `a * b` on `int64_t`); also `pow_Int` :146-159
- **Original claim:** signed `int64_t` overflow is UB, while Elm semantics wrap.
- **Analysis:** The UB is real, and the comment at :55 admits it. No `-fwrapv` appears in any CMake file. Reachability: saturated typed calls become intrinsics (`eco.int.add` etc., compiler/src/Compiler/IR/Kernel/Intrinsics.elm:~190-218), but the kernel `_Int` symbols are still used when `(+)`/`(*)` are passed first-class or are not inlined (KernelAbi.elm:245-261 picks `_Int`; RuntimeSymbols.cpp:734-745). As separate `extern "C"` functions they compile to a plain wrapping `add`/`imul` today, so results are wrapped in practice. A miscompile would need inlining into a caller where range reasoning exploits `nsw` (for example LTO or bitcode linking of the kernel).
- **Impact:** Latent UB. UBSan would flag it, and a future LTO or inlining build could miscompile overflow checks. No wrong result is observed today.
- **Suggested fix / next step:** Compute in `uint64_t` and cast back (or use `__builtin_add_overflow` and discard the flag) in add/sub/mul/pow_Int, and in runtime `eco_int_pow`.

### BASICS-02: pow_Int overflows even when the result fits
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/BasicsExports.cpp:146-159 `Elm_Kernel_Basics_pow_Int`; the same pattern in runtime/src/allocator/RuntimeExports.cpp:4709-4727 `eco_int_pow` (the target of `eco.int.pow`, EcoToLLVMArith.cpp:236-248, which is the much more common path)
- **Original claim:** `b` is squared once past the last needed bit.
- **Analysis:** The loop does `b *= b` unconditionally before `e >>= 1`. For `2 ^ 62`, after the last iteration (e=1: result=2^62) it computes b = 2^32 * 2^32 = 2^64, which is signed-overflow UB even though the result fits. The same happens for any base where base^(2^k) overflows past the top bit. In practice the overflowed `b` is dead and the generated code wraps, so results are correct today. The genuine-overflow case (the result itself overflows) is BASICS-01.
- **Impact:** Latent UB on ordinary inputs such as `2 ^ 62` or `3 ^ 39`, in both the kernel and the runtime helper. Risk only under a stricter optimizer or UBSan.
- **Suggested fix / next step:** Square only when `e > 1` (`if (e >>= 1) b *= b;`) and do the multiplications in `uint64_t`. Apply the same fix to `eco_int_pow`.

### BASICS-03: boxed arithmetic reads b with a's kind
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/BasicsExports.cpp:92-118, boxed `Elm_Kernel_Basics_add`/`sub`/`mul`/`pow`
- **Original claim:** `b` is read using `a`'s kind without checking `b`'s tag.
- **Analysis:** The boxed form serves an unspecialized `number`. Both operands have the same Elm type, `number -> number -> number`, so after type checking both are Int or both are Float. Number literals in a Float context are emitted as Floats. A heap ElmInt and a heap ElmFloat both store an 8-byte value at the same offset, so a mismatch would give a misread value, not a memory fault. A mismatch needs a compiler or kernel bug.
- **Impact:** None from well-typed programs.
- **Suggested fix / next step:** Optionally add `assert(tagOfBoxed(b) == tagOfBoxed(a))`.

### BYTES-01: getHostEndianness returns raw 0/1 words — **FIXED on master**: returns the LE/BE value passed in, wrapped in a Task
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/bytes/BytesExports.cpp:321-327 `Elm_Kernel_Bytes_getHostEndianness`
- **Original claim:** the export returns raw words 0/1 (0 is the null word) instead of the proper constructor constants.
- **Analysis:** The current code selects the caller-supplied `le` or `be` value (:324) and returns `taskSucceed(result)` (:325-326). No raw 0/1 words remain. One leftover: compiler/src/Compiler/Monomorphize/Solver/kernel-license-audit.csv:152 still describes the old behaviour ("NO arguments; returns fromBits(isLE ? 0 : 1)") and cites lines 321-327 as if unchanged.
- **Impact:** None (fixed). The audit CSV row is stale documentation.
- **Suggested fix / next step:** Refresh the audit row for Elm.Bytes.getHostEndianness.

### BYTES-02: getHostEndianness arity mismatch with Elm — **FIXED on master**: takes (le, be) and returns a Task
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/bytes/BytesExports.cpp:321; E/KernelExports.h:790-792
- **Original claim:** the export has arity 0 while Elm passes LE and BE and expects a Task.
- **Analysis:** The signature is now `HPtr Elm_Kernel_Bytes_getHostEndianness(HPtr le, HPtr be)`, both in the definition and in the declaration (KernelExports.h:792). It returns a Task as described above.
- **Impact:** None (fixed).
- **Suggested fix / next step:** None beyond the stale audit row noted under BYTES-01.

### BYTES-03: read_string length 0 skips the bounds check
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/bytes/BytesExports.cpp:590-606 `Elm_Kernel_Bytes_read_string`
- **Original claim:** `length == 0` skips the bounds check at any offset, so the decoder succeeds where it should fail.
- **Analysis:** The early return at :595-597 accepts any offset when the length is 0, but no bytes are read. The offset only comes from the decoder state, which starts at 0 and advances only past successful, bounds-checked reads, so it is always in [0, buffer length]. A negative or past-end offset cannot reach this function from Elm. Upstream elm/bytes JS (`_Bytes_read_string`) also never touches the DataView when len is 0 and returns `(offset, "")`, so the behaviour matches the reference. A negative `length` is non-zero and goes through the check at :603.
- **Impact:** None observable. It matches elm/bytes JS.
- **Suggested fix / next step:** None. Optionally note in the comment that the offset is always ≤ length.

### BYTES-04: encoder size narrowed size_t to u32 unchecked
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/bytes/BytesExports.cpp:390-404 `elm_encoder_size`/`elm_encoder_write_into`; consumers runtime/src/codegen/Passes/BFToLLVM.cpp:160-161, :1047-1097; also runtime/src/allocator/HeapHelpers.hpp:1508-1527 `allocByteBufferBlank` (`header.size = static_cast<u32>(length)`)
- **Original claim:** an unchecked `size_t` -> `uint32_t` narrowing.
- **Analysis:** This is real, and the comment at :386-388 admits it. In the fused BytesFusion path, `bf.encoder.width` returns the truncated u32 width, which then sizes the destination buffer, but `writeEncoder` (inside `elm_encoder_write_into`) writes the full `size_t` length. For an encoding of 4 GiB + k bytes, that means k bytes are allocated and about 4 GiB are written: a heap overflow, not a clean failure. The non-fused `Elm_Kernel_Bytes_encode` (:406-423) allocates `totalSize` correctly but stores a truncated u32 `header.size`, which gives a wrong length. Triggering either needs a single encoding of at least 4 GiB, which is beyond the representation limit (`header.size` is u32 everywhere).
- **Impact:** Memory corruption, but only for encodings of at least 4 GiB. Practically unreachable.
- **Suggested fix / next step:** In `encoderSize`, or in both exports, check `size > UINT32_MAX` and crash cleanly (or throw a kernel error) instead of narrowing. Do the same in `allocByteBufferBlank`.

### BASICS-NEW-1: runtime eco_int_pow has the same UB as pow_Int (the more reachable path)
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** runtime/src/allocator/RuntimeExports.cpp:4709-4727 `eco_int_pow`; lowered from `eco.int.pow` at runtime/src/codegen/Passes/EcoToLLVMArith.cpp:236-248
- **Original claim:** (new) not in the original list; found while checking BASICS-01/02.
- **Analysis:** Every saturated Int `^` in user code goes through this helper, not the kernel `pow_Int`. It has both defects: the extra final `base *= base` (BASICS-02) and plain signed multiplication (BASICS-01). It is declared `gcLeaf` and may be inlined if the runtime is ever linked as bitcode.
- **Impact:** Latent UB on ordinary `Int ^ Int` such as `2 ^ 62`. Currently wraps in practice.
- **Suggested fix / next step:** Fix it together with `pow_Int` (unsigned arithmetic, square only while `exp > 1`).

### PARSE-01: long UTF-16 ropes reach flatStringView unflattened
- **Status:** CERTAIN · **Severity:** HIGH
- **Where:** `E/parser/ParserExports.cpp:66-71` (`parserFlatten`), `:76-85` (`parserView`), used by every export through `resolveString` (`:89-94`) and in `findSubString`; `runtime/src/allocator/StringOps.cpp:235-252` (`ensureFlat`); `runtime/src/allocator/HeapHelpers.hpp:2177-2182` (`flatStringView`); `runtime/src/allocator/Heap.hpp:525-529` (`flatStringChars`).
- **Original claim:** ropes/slices above `string_flatten_limit` are passed to `flatStringView` without being flattened.
- **Analysis:** `ensureFlat` hands back a `Tag_StringRope`/`Tag_StringSlice` unchanged when `hdr->size > string_flatten_limit` (StringOps.cpp:247-251; the limit is `128 * 1024` units, AllocatorCommon.hpp:130). `parserFlatten` returns that value. `parserView` skips it only if it is a constant or UTF-8 leaf/view (`isUtf8` covers just those two tags, StringOps.hpp:89-92), so a rope or slice goes on to `flatStringView`. That function only asserts the tag (HeapHelpers.hpp:2179). With asserts off (the release presets use `-DNDEBUG`, CMakePresets.json:56-62) `flatStringChars` returns `((ElmString*)obj)->chars` (Heap.hpp:528) and uses `hdr->size` as the length. For a rope that means reading the rope's left/right/height fields and then up to 2x`size` bytes past a 24-to-32-byte object as UTF-16. The file comment at :62-65 even says "`parserView` cannot read that". Reaching it is easy: `String.append`/`concat`/`join` build a rope whenever the total exceeds the limit (StringOps.cpp:524, :617, `buildBalancedRope` :583/:698; HEAP_025 states the same). So `Parser.run p (a ++ b)` with a combined length over 131,072 UTF-16 units hits it, ASCII or not, on the first primitive call (`isSubChar`, `chompBase10`, `findSubString`, ...). A large flat string straight from a file read is not affected.
- **Impact:** with asserts on (the `build` preset) elm/parser on a large concatenated source aborts. In release builds it reads past the heap object: wrong parse results, or a segfault near the end of a mapping.
- **Suggested fix / next step:** in `parserFlatten` use `StringOps::flattenToLeaf` (it copies any form into a leaf or large String, StringOps.hpp:211-214) rather than `ensureFlat`, or have `parserView` read ropes/slices segment-wise. Add a test that runs `Parser.run` on `String.repeat 70000 "ab" ++ "x"` or a similar input over 128K units.

### PARSE-02: number chompers lack an offset < 0 check
- **Status:** WEAK · **Severity:** LOW
- **Where:** `E/parser/ParserExports.cpp:289-300` (`chompBase10`), `:307-320` (`consumeBase`), `:325-345` (`consumeBase16`).
- **Original claim:** there is no `offset < 0` check before `s.at(offset)`.
- **Analysis:** it is true that nothing checks this: the loop condition is just `offset < len`, and `ParserStr::at` has no bounds check (:52-54). Every caller, though, is elm/parser's own Elm code, which passes `s.offset` from the internal `State`. That offset starts at 0 and only grows. The negative sentinel results (-1/-2 from `isSubChar`) are compared before anyone uses them as an offset, and user code cannot build a `State`. The doc comments (:287-288, :305-306) record the precondition.
- **Impact:** an out-of-bounds read only if a caller breaks the documented precondition. Well-typed Elm does not.
- **Suggested fix / next step:** optional hardening with `if (offset < 0) return offset` (or the tuple form), which costs nothing.

### PARSE-03: consumeBase accumulation overflows int64
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** `E/parser/ParserExports.cpp:316` (`total = base * total + digit`) and `:341` (`total = 16 * total + digit`).
- **Original claim:** the i64 accumulation can overflow, which is UB, whereas JS accumulates in doubles.
- **Analysis:** nothing guards the accumulation. elm/parser's `number`/`int` reach `consumeBase16` for `0x...` and `consumeBase 8`/`consumeBase 2` for `0o...`/`0b...` (decimal goes through `chompBase10` plus `String.toInt`). So input as ordinary as `0x1FFFFFFFFFFFFFFFF` (17 hex digits), 22+ octal digits or 64+ binary digits overflows signed i64. That is UB. In practice it wraps, so for example `0xFFFFFFFFFFFFFFFF` comes out as -1 and longer runs come out as garbage. Stock Elm/JS gives an inexact but large double instead.
- **Impact:** a silently wrong (possibly negative) number from hex/octal/binary literals beyond 64 bits, plus formal UB. UBSan would flag it.
- **Suggested fix / next step:** accumulate as `uint64_t` (wrapping is well defined) or saturate with `__builtin_mul_overflow`/`__builtin_add_overflow`. Decide which overflow semantics we want (Eco Int is 64-bit, so none matches JS exactly) and pin them with a test.

### HTTP-01: Bytes/File bodies read as Strings — **FIXED on master**: bodyBytes reads Bytes bodies and parts as raw bytes (File gives ""; no File reaches the native kernel)
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** `E/http/HttpExports.cpp:248-257` (`bodyBytes`), used at `:689`, `:692`, `:700` in `extractRequest`.
- **Original claim:** Bytes/File bodies and multipart parts were read through `elmStringToUTF8`/`toStdString` on non-String objects.
- **Analysis:** `bodyBytes` now resolves with `resolveOrNull` (constant gives ""). For any Bytes form (`isByteBuffer` covers ByteBuffer/LargeByteHeader/ByteBufferSlice, HeapHelpers.hpp:2186-2190) it copies `byteBufferData`/`byteBufferLength`. It uses `toStdString` only after an `isString` check, and returns "" for anything else (a File). The plain body (:700), a `stringPart` value (:692) and the blob bytes of a `bytesPart` (:689) all go through it. The remaining `elmStringToUTF8` calls are on fields that are Strings by type: method, url, header name/value, content type, part key, blob mime.
- **Impact:** none left.
- **Suggested fix / next step:** none. A test that sends `Http.bytesBody` and `bytesPart` to a local echo server would pin the fix if none exists.

### HTTP-02: headers Dict built with Unit colour and unbalanced tree — **FIXED on master**: buildHeadersTree builds a balanced red-black tree with real colours
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** `E/http/HttpExports.cpp:294-333` (`buildHeadersTree`, `buildHeadersDict`).
- **Original claim:** the Dict colour slot held Unit and the tree was unbalanced.
- **Analysis:** the colour is now `custom(DICT_RED/DICT_BLACK, {}, 0)`, and for zero fields `custom` returns the null-cons word for that ctor (HeapHelpers.hpp:1385-1388, HEAP_044), the same representation as Elm's `Red`/`Black`. Keys are sorted and de-duplicated through `std::map` (last value wins), and the tree is built by midpoint split. Left subtree size is floor(s/2) and right is ceil(s/2)-1, so every level but the deepest is full. Only deepest-level non-root nodes are Red, so black-height is uniform and no Red node has a Red child. Every intermediate is rooted with `StackRootGuard` across the allocations (:299-305). One residual point: when a deepest-level parent has two children, both are Red. That is a 4-node with a right-leaning Red, which elm/core's LLRB `insert` never makes. `get` is unaffected (BST order holds) and `remove`'s `removeHelpPrepEQGT` rotates a red left first, so this is very probably harmless, but nothing confirms it.
- **Impact:** none known.
- **Suggested fix / next step:** optional test: build a 3- and 7-header response, then run `Dict.remove`/`Dict.insert` on every key and compare `Dict.toList` with a reference.

### HTTP-03: HttpEffectManager unchecked casts
- **Status:** WEAK · **Severity:** LOW
- **Where:** `E/http/HttpEffectManager.cpp:185-191` (tracker `Just` cast to `Custom`), `:241-245` (self-msg cast to `Tuple2`), `:258-262` (sub cast to `Custom`).
- **Original claim:** unchecked casts to Record/Tuple2/Custom could misread unexpected values.
- **Analysis:** every cast is on a value whose shape is fixed by elm/http's types or by this kernel. `req` is the `Request` record. Field 6 is `tracker` in alphabetical order with all fields boxed (allowCookies…, body, expect, headers, method, timeout, tracker, url), which matches `REQ_TRACKER = 6` in HttpExports.cpp:126. `mt` is checked for `ptr_ind` before it is resolved (:187). The self-message is only ever built by the kernel as `tuple2(boxed(tracker), boxed(progress), 0)` (HttpExports.cpp:505-506). Subscriptions are `MySub tracker toMsg`, which the kernel's own `subMap` rebuilds as a 2-field Custom (:381-397). No well-typed program yields anything else.
- **Impact:** a misread only on heap corruption or a kernel/Elm layout mismatch.
- **Suggested fix / next step:** none needed. A debug-only `assert(tag == ...)` would document the assumptions.

### HTTP-04: HttpEffectManager onEffects resolves a possibly-constant command
- **Status:** WEAK · **Severity:** LOW
- **Where:** `E/http/HttpEffectManager.cpp:155-159` (`httpOnEffectsEvaluator`).
- **Original claim:** `resolve(cmdHP)` is called without a ptr/constant check.
- **Analysis:** the call is unguarded, and `Allocator::resolve` on a constant does not return null. It asserts in `fromPointerRaw` (Allocator.hpp:661) and otherwise reads a header at address 0x5/0x7, a segfault (Allocator.cpp:1141-1163, Heap.hpp:336-338). So the `if (cmdPtr)` test at :160 is dead, and a constant would crash in every build, not only validating ones. But every command reaching this manager is `Cancel String` or `Request {...}` (each has a field, so it is a heap Custom) or a Task heap object (:209). elm/http has no nullary `MyCmd`.
- **Impact:** none from well-typed programs.
- **Suggested fix / next step:** optional: guard with `cmdHP.ptr_ind == 0` (or use `Export::toPtr`) so the existing null check means something.

### HTML-01: HtmlWriter reads node fields without kind/tag checks
- **Status:** WEAK · **Severity:** LOW
- **Where:** `E/virtual-dom/HtmlWriter.cpp:59-61` (`str`), `:52-55` (`field`), uses at ~:394-412 (facts), ~:577-579 (`expand`), ~:629-633 (text nodes).
- **Original claim:** field kinds are read unchecked, and any non-null object goes to `toStdString` without a String tag check, contrary to VDOM_005 "total".
- **Analysis:** the node-level reads are already defensive. `asCustom` checks `Tag_Custom` (:45-49), `field` bounds-checks against `header.size` (:52-55), and keyed children are checked for `Tag_Tuple2` (~:585). Unboxed kinds are not an issue: every VirtualDom Custom is built with mask 0 (VirtualDomExports.cpp:65; VirtualDomLayout.hpp:13 "unboxed bitmap is zero"). What is left is that `str()` trusts a field to be a String or constant. Those fields (tag, text, attribute key/value) are typed `String` in the Elm API that builds them through the kernel. VDOM_005's totality is about every Elm-constructible `Html` value, which this meets. A non-String there would mean heap corruption or a kernel bug.
- **Impact:** a misread only on malformed heap values that well-typed Elm cannot construct.
- **Suggested fix / next step:** optional: make `str()` check `alloc::isString(p)` and return "" otherwise, so the writer is total even over malformed input.

### FILE-01: dead File accessors use alphabetical slot numbers
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** `E/file/File.cpp:9-17` (`FIELD_*`) and `:33-78` (`Elm::Kernel::File::name/mime/size/lastModified`).
- **Original claim:** the namespace accessors index record slots alphabetically rather than by compiler layout.
- **Analysis:** they do (`content`=0 ... `size`=4). The file's own comment admits that "No native code builds such a record; in a compiler-built record unboxed fields would come first", and elm/file's `File` is an opaque JS object, not a record, anyway. The code is dead. Nothing outside `elm-kernel-cpp/src/file/` references `Elm::Kernel::File::*` (grep over elm-kernel-cpp, eco-kernel-cpp, system-kernel-cpp, runtime, test). The C exports in `FileExports.cpp:18-80` are separate asserting stubs that never call these. The eco-kernel `File::` calls are `Eco::Kernel::File` (eco-kernel-cpp/src/eco-kernel/File.hpp:26), a different namespace. It is still compiled (elm-kernel-cpp/CMakeLists.txt:216).
- **Impact:** none at runtime. It misleads readers.
- **Suggested fix / next step:** delete the `Elm::Kernel::File` namespace in `File.cpp`/`File.hpp` (and drop it from CMakeLists) after confirming nothing links it.

### FILE-02: dead File accessors treat void* as Record* without decoding
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** `E/file/File.cpp:33-78` (e.g. `:36` `static_cast<Record*>(file)`).
- **Original claim:** a `void*` is used as a raw `Record*` without HPointer decoding.
- **Analysis:** the cast is there, and a caller passing an encoded word instead of a resolved address would get a bad dereference. As shown under FILE-01, these functions have no callers, so it cannot happen. Same dead code as FILE-01.
- **Impact:** none at runtime.
- **Suggested fix / next step:** remove it together with FILE-01.

### BROWSER-01: Browser stubs return word 0 under NDEBUG
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** `E/browser/BrowserExports.cpp:30-195` (27 `assert(false && ...)` stubs, e.g. `Elm_Kernel_Browser_load` :30-34, `getViewport` :63, `on` :95, `rAF` :126). The same pattern is in `E/file/FileExports.cpp:18-80`.
- **Original claim:** asserting stubs return word 0 once asserts are off.
- **Analysis:** with `-DNDEBUG` (release presets, CMakePresets.json:56-62) each stub returns `HPtr::fromBits(0)`. Word 0 has `ptr_ind` clear, so it is not a constant (Heap.hpp:340-342, "The null word 0 is not a constant"). It is a heap pointer to address 0, and the first `resolve`/header read of the returned Task/Sub segfaults or misbehaves somewhere else. Only a program that calls a browser-only API natively (`Browser.Navigation.load`, `Browser.Dom.*`, `Browser.Events.*`) reaches it. `element/document/application` (:18-28) pass through. In the default asserts-on build the outcome is an abort with a clear message.
- **Impact:** release builds crash late, with a misleading location and no diagnostic, when a native program uses a browser-only API.
- **Suggested fix / next step:** replace `assert(false); return 0;` with an unconditional `reportFatal`/throw ("<fn> is not supported natively"), inside `ECO_KERNEL_GUARD`, in Browser and File exports alike.

### PLATFORM-01: port registration passes a null name to resolve
- **Status:** WEAK · **Severity:** LOW
- **Where:** `E/core/PlatformExports.cpp:87-100` (`registerIncomingPort`), `:109-118` (`registerOutgoingPort`).
- **Original claim:** a null (word 0) name could reach `resolve`/`toStdString`.
- **Analysis:** constants are skipped (`ptr_ind != 0` gives nullptr, :92-94/:111-113), but word 0 would go to `resolve` and segfault. The only caller is compiler-generated code: `generateRegisterPorts` passes `Ops.ecoStringLiteral ... port_.name` (compiler/src/Compiler/GenerateMlir/Functions.elm, ~:250-255). Per HEAP_025/HEAP_032 that is an interned heap leaf (`eco_alloc_string_literal_utf8`), and it is never 0. Port names are non-empty identifiers.
- **Impact:** none reachable.
- **Suggested fix / next step:** none needed. Could use `Export::toPtr` for uniformity.

### SYS-01: SystemManager uses resolve results without null checks
- **Status:** WEAK · **Severity:** LOW
- **Where:** `S/System/SystemManager.cpp:167-174` (`onEffectsEval` subs walk), `:190-193` (cmd walk), `:228-232` (`subMapEval`).
- **Original claim:** `resolve` results are dereferenced without null checks.
- **Analysis:** `resolve` never returns null for a valid word. On a constant it asserts or segfaults (Allocator.hpp:661, Allocator.cpp:1141-1163), so a null check would not help anyway, and the `if (!obj) continue;` at :169 is dead code. What matters is whether a constant can arrive. `System.elm:492-506` defines `MyCmd = Execute (Task Never ())` and `MySub = OnEmptyEventLoop msg | OnSignalInterrupt msg | OnSignalTerminate msg`. Every constructor has a field, so every value is a heap Custom (no newtype erasure appears in invariants.csv). `subMapEval` rebuilds with `custom(ctor, {mapped}, 0)`, which is still 1-field. The `sub->ctor < SUB_CTOR_COUNT` check covers ctor range.
- **Impact:** none from well-typed programs.
- **Suggested fix / next step:** none, or drop the misleading `if (!obj)` check.

### HTTPSRV-01: HttpServerManager onEffectsEval unchecked
- **Status:** WEAK · **Severity:** LOW
- **Where:** `S/HttpServer/HttpServerManager.cpp:183-197` (cmd walk in `onEffectsEval`), and the sub walk at `:160-167`.
- **Original claim:** the code checks neither the ctor tag nor a null `resolve`.
- **Analysis:** `Http/Server.elm:957-972` has a single-ctor `MyCmd = Respond (Task Never ())`, so there is no tag to check, and a single-ctor `MySub = OnRequest Int (... -> msg)`, whose ctor the code does check (:164). Both carry fields, so values are always heap objects and `resolve` cannot meet a constant. The Int server id is read as `.i`, and `subMap` rebuilds it with `ON_REQUEST_MASK` (:250), consistent with Int being unboxed (REP rules). As in SYS-01, the `if (!obj)` at :162 is dead.
- **Impact:** none from well-typed programs.
- **Suggested fix / next step:** none.

### PARSE-NEW-1: Allocator::resolve on an embedded constant crashes in every build; the kernels' "if (!ptr)" guards after it are dead
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** `runtime/src/allocator/Allocator.cpp:1140-1172`, `Allocator.hpp:660-666`, `Heap.hpp:336-338`. Dead guards: `E/http/HttpEffectManager.cpp:160`, `S/System/SystemManager.cpp:169`, `S/HttpServer/HttpServerManager.cpp:162`, and others.
- **Original claim:** (new) several entries above assume `resolve` returns null for a constant or null value.
- **Analysis:** `fromPointerRaw` asserts `ptr_ind == 0` (on in the default build). Under NDEBUG, `hpToAddr` masks the word to its low 43 bits, which for a constant gives 0x4-0x7, and `getHeader` then reads there. So `resolve` never yields nullptr: it either aborts or segfaults. Every kernel that writes `void* p = resolve(x); if (!p) ...` is relying on a guard that cannot fire. None of the reviewed sites can receive a constant, but this is a general trap for reviewers and future code.
- **Impact:** a latent crash pattern: any new site that can see a constant will crash, not take the null branch.
- **Suggested fix / next step:** document it on `Allocator::resolve` and recommend `Export::toPtr`/`resolveOrNull` helpers for possibly-constant words.

### SYS-02: payloadInt casts unchecked to ElmInt
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/System/System.cpp:219-221 `payloadInt`; callers System.cpp:274 (`systemExitWithCodeBody`), :290 (`systemSetExitCodeBody`)
- **Original claim:** `payloadInt` casts `resolve(captured)` to `ElmInt*` without checking the tag.
- **Analysis:** The only bindings that use these bodies are built in S/System/SystemExports.cpp:36 and :44 as `makeBinding<...>(alloc::allocInt(code))`. `allocInt` (runtime/src/allocator/HeapHelpers.hpp:318-323) always allocates a fresh boxed `Tag_Int` object. It never returns an embedded constant. The payload is therefore always a boxed Int, and the cast is correct by construction. The identical helpers in Tls.cpp:45, Stream.cpp:109 and WebSocket.cpp:54 follow the same pattern.
- **Impact:** None today. It would only matter if a future export passed a different payload shape.
- **Suggested fix / next step:** Optionally add `assert(header.tag == Tag_Int)` in a debug build. No other action.

### SOCK-01: socketAcceptBody re-lookup not null-checked
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Socket.cpp:468-497 `socketAcceptBody` (re-lookup at :491, dereference at :492)
- **Original claim:** `findListener(id)`, looked up again after `makeKillHandle`, is dereferenced without a null check.
- **Analysis:** Listener entries are erased in only two places. `onListenerClosed` (S/Socket/SocketTables.cpp:193-198) runs from socket-event dispatch on the eco thread. `resetTables` (SocketTables.cpp:41-61) runs when `socketTables()` sees a new heap generation (:221-229). `makeKillHandle` only allocates. A GC does not dispatch socket events, run Elm code, or change the heap generation: the generation is bumped only in `Allocator::initialize`/`reset` (runtime/src/allocator/Allocator.cpp:222, :1070), and `reset` is test-only via `AllocatorTestAccess`. Line 475 has already checked the entry is present and not closing, so the second lookup cannot return null. The re-lookup is defensive (std::unordered_map value pointers are stable anyway).
- **Impact:** None reachable.
- **Suggested fix / next step:** Optionally add an `assert(e)` or a cheap null check for robustness.

### STREAM-01: mappedReadResult dereferences p without a null check
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/Stream.cpp:901-905 `mappedReadResult`; only caller `channelDispatch` Stream.cpp:660-676
- **Original claim:** dereferences `p` and relies on `channelDispatch` having validated it.
- **Analysis:** The only call (:674-675) is guarded by `p && p->kind == StreamKind::MappedSource`, with `p = t.find(id)` and a channel-id match (:665-668). Nothing allocates or runs Elm code between that check and the `find(id)` at :903, so the pair cannot vanish in between. The precondition "Pair `id` must exist" is documented at :900. Later uses of `p` after `feedReader`/`pumpStream` do not exist (those calls are tail calls).
- **Impact:** None while the single caller keeps its guard.
- **Suggested fix / next step:** Optionally add `if (!p) return;` or an assert. Not a bug.

### CORE-01: SysWorkPool partial thread start use-after-free
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/Core/SysWorkPool.cpp:24-38 `SysWorkPool::instance` / `SysWorkPool::SysWorkPool`
- **Original claim:** if only some threads start, the detached workers use freed state, and a retry creates a second pool.
- **Analysis:** The constructor starts `nThreads_` (1..4) detached threads capturing `this` (:35-37) and does not catch the `std::system_error` that `std::thread` throws on EAGAIN. If thread i>0 fails, the exception leaves the constructor. The `new SysWorkPool()` in the function-local static initializer (:25) then frees the storage, while the threads already started still run `workerLoop()` on it (they wait on `jobsCV_`/`jobsMutex_`): a use-after-free. Because the static initializer threw, the next `instance()` call runs the initializer again and builds a second pool, while the old workers keep touching freed memory. The exception is reachable: callers such as `fsPoolSubmit` (S/FileSystem/FileSystem.cpp:193) and `socketTcpListenBody` run under `ECO_SYSTEM_ASYNC_GUARD`, which converts it to a Task failure, so the program goes on and the retry happens. Contrast FdChannel (S/Core/FdChannel.cpp:403-412), which catches `std::system_error` from its thread start.
- **Impact:** Heap corruption or a crash in the worker threads when the thread limit is hit on the first pool use (RLIMIT_NPROC, cgroup pids limit, memory exhaustion). Rare, but such resource-pressure situations are realistic.
- **Suggested fix / next step:** Catch `std::system_error` in the loop and keep the pool with the threads that did start (fail only if 0 started; then mark it unusable and do not free it). Alternatively, start the workers only after construction has completed.

### FD-01: FdChannel closes a possibly reused fd after POLLNVAL
- **Status:** UNSURE · **Severity:** LOW
- **Where:** S/Core/FdChannel.cpp:339-346 (POLLNVAL handling), :375-378 (final `::close(st.fd)`), `channelThread`
- **Original claim:** after POLLNVAL on an already-closed fd, the thread later `::close`s the same number.
- **Analysis:** The pattern is real. On POLLNVAL with a closed fd, `failPending(st, EBADF)` runs and the loop continues. On `close`/`shutdown`, the finish block calls `::close(st.fd)` whenever `fd > 2`, even if another thread has reused that number in the meantime. However, POLLNVAL on a closed fd means someone else closed an fd the channel owns exclusively. Every channel fd is owned: FileSystem stream ops open a fresh fd (FileSystem.cpp:119-130), and `createFdSource`/`createFdSink` dup non-owned fds with `F_DUPFD_CLOEXEC` (Stream.cpp:1051-1079). FileSystem handle fds sit in a separate table and never become channel fds. So the trigger needs a second, independent ownership bug, and I found none. The other POLLNVAL route, an open fd at or above FD_SETSIZE on macOS, closes a still-valid fd that is ours, which is correct.
- **Impact:** It would turn an existing double-close bug elsewhere into closing an unrelated fd. It has no effect on its own.
- **Suggested fix / next step:** After `fcntl(F_GETFD) == -1` (EBADF), set `st.fd = -1` so the finish block does not close it. A test would need to close the channel's fd behind its back. That is cheap and would settle the question.

### FD-02: closeQuietly retries close on EINTR
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SocketUtil.cpp:93-98 `closeQuietly`; uses at :119 (`socketCloexec`, `#else` branch) and :147 (`acceptCloexec`, non-Linux branch)
- **Original claim:** retries `close()` after EINTR and may close a reused fd on non-Linux platforms; Linux is fine.
- **Analysis:** Retrying `close` on EINTR is wrong on both Linux and macOS, because both release the descriptor even when close reports EINTR. So the claim that "Linux is fine" holds only because these paths are not compiled on Linux (`SOCK_CLOEXEC`/`SOCK_NONBLOCK` and `accept4` exist there). On macOS/BSD the function closes a socket just returned by `socket()`/`accept()` after a failed `fcntl`. An unconnected or freshly accepted socket without SO_LINGER does not block in close, so EINTR is practically impossible.
- **Impact:** Theoretical only: an unrelated fd could be closed on macOS if close ever returned EINTR here.
- **Suggested fix / next step:** Replace the loop with a single `::close(fd)`, matching the "no retry on EINTR" rule already used at FdChannel.cpp:375-378. Trivial.

### SOCK-02: mapIPv4ToIPv6 copies without a length check
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SocketUtil.cpp:296-316 `mapIPv4ToIPv6`; only caller S/Socket/Udp.cpp:185
- **Original claim:** copies address bytes without checking the length, so a short address could be over-read.
- **Analysis:** The source is `sa.ss`, a `sockaddr_storage` (128 bytes on Windows, SocketUtil.hpp:99-105) that the `SockAddr()` constructor zeroes. The function copies `sizeof(sockaddr_in)` = 16 bytes out of it, which is always in bounds whatever `len` is. The function returns early unless `family() == AF_INET`, and `family()` is AF_UNSPEC when `len == 0`. The only caller passes an address that `inetToSockaddr` has just filled (Udp.cpp:181).
- **Impact:** None.
- **Suggested fix / next step:** No change needed.

### FS-01: stale FileHandle accepted after fd reuse
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/FileSystem.cpp:35-38 `openHandles`, :138-142 `fsCompleteOpen`, :178-188 `fsPoolSubmit`
- **Original claim:** the handle table is keyed by fd number only, so a stale handle matches a later `open` that reused the fd.
- **Analysis:** A FileHandle is the raw fd number. `open` inserts `r.n` into an `unordered_set<int64_t>` (:140), and `close` erases it before submitting the close job (:187). Handle ops check only membership (:181). The trigger sequence:
  1. `h1 <- open a`; `close h1`.
  2. `h2 <- open b`. POSIX returns the lowest free fd, so h2 usually has the same number as h1.
  3. `write h1 ...` is accepted and writes to file b.

  This needs only a use-after-close in an ordinary Elm program, which should yield EBADF but instead silently does I/O on the wrong file. A second window: `close` erases the entry and then submits, but a handle job submitted earlier may still be queued or running on another pool worker (4 workers, SysWorkPool.cpp:34). That job can run after the close and after a new open reuses the number. This needs concurrent tasks on one handle.
- **Impact:** Reads from, or writes and truncates, the wrong file: possible data corruption.
- **Suggested fix / next step:** Return an opaque handle id (a counter mapped to {fd, generation}) instead of the fd. Add a regression test: open/close/open/write through the stale handle should fail with EBADF.

### RESET-04: FileSystem handle table never cleared on reset
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/FileSystem/FileSystem.cpp:35-38 `openHandles`
- **Original claim:** the table is not keyed by heap generation and is never cleared on heap reset.
- **Analysis:** `openHandles()` is a leaky static set with no generation check, unlike `socketTables()` (S/Socket/SocketTables.cpp:221-229), which calls `resetTables` when `currentHeapGeneration()` changes. Its fds are never closed on reset. However, a heap reset only happens through `Allocator::reset` (Allocator.cpp:1067), which is reachable only via `AllocatorTestAccess::reset` (runtime/src/allocator/Allocator.hpp:709-711): unit tests, plus re-`initialize` after a teardown. Production programs run one heap per process.
- **Impact:** Leaked fds and stale numbers across resets inside a single unit-test process. A stale number from a prior test could even validate a coincidentally equal handle. No production impact.
- **Suggested fix / next step:** Key the table by generation, and close or clear it on change as SocketTables does. This falls out of the FS-01 opaque-id fix if the ids carry the generation.

### PROC-02: killJob can signal a reused pid
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/ChildProcess/ChildProcess.cpp:506-512 `killJob`; reap at runtime/src/platform/WaitService.cpp:78; `waitDrain` ChildProcess.cpp:412-426
- **Original claim:** `killJob` can send SIGTERM to a pid between the WaitService reap and `waitDrain`.
- **Analysis:** The WaitService thread reaps with a blocking `waitpid(pid, &status, 0)` (WaitService.cpp:78), which frees the pid immediately, and only queues the result. `j->exited` is set later, on the eco thread, in `waitDrain` (:418). Inside that window, `killJob` (called from a kill handle via `cancelRunByToken`/`cancelSpawnByToken` :464-470/:515-521, the run-duration timer :253, or output overflow :392) sees `!j->exited` and calls `::kill(pid, SIGTERM)`. That pid is already free and may belong to a new process. Reuse inside the window needs the pid space to wrap around in a few milliseconds, which is very unlikely on Linux (pid_max is commonly 4M) but possible on systems with small pid_max or heavy fork churn.
- **Impact:** A SIGTERM can reach an unrelated process of the same user. The race is real but the window is very narrow.
- **Suggested fix / next step:** Reap with `waitid(..., WNOWAIT)` and do the final reap from the eco thread after `exited` is set. Or, on Linux, use pidfds (`pidfd_open` + `pidfd_send_signal`).

### TLS-01: TlsTransport copyable while owning SSL*
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Tls/TlsTransport.cpp:53-66, :390 (class `TlsTransport`, in an anonymous namespace :22-407)
- **Original claim:** an implicitly copyable class owns a raw `SSL*`.
- **Analysis:** The destructor calls `SSL_free(ssl_)` (:66). Neither `TlsTransport` nor its base `Transport` (S/Socket/Conn.hpp:94) deletes copy or move, so a copy would double-free. The comment at :51-52 says it "must not be copied or moved", but nothing enforces that. The class is file-local and only ever built with `std::make_unique<TlsTransport>` (:465, :480) and held as `unique_ptr<Transport>`. No copy exists today.
- **Impact:** Latent only. No current code copies it.
- **Suggested fix / next step:** Add `TlsTransport(const TlsTransport&) = delete; TlsTransport& operator=(const TlsTransport&) = delete;`, or delete copying on `Transport`.

### WATCH-01: WatchService implicitly copyable
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/WatchService.hpp:63, :87-88
- **Original claim:** a copy would share `impl_`.
- **Analysis:** The constructor is private and `instance()` returns a reference. `impl_` is "Owned, never freed" (:88), so no destructor frees it. An accidental `auto ws = WatchService::instance();` would compile, because the copy constructor is implicitly public. The resulting object would just share the immortal `impl_` and forward to the same state, with no double free and no divergence.
- **Impact:** Harmless.
- **Suggested fix / next step:** Optionally `= delete` copy and assignment for clarity.

### ABI-02: C++ helpers declared inside extern "C" in ListExports
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/ListExports.cpp:285 (`extern "C" {`) to :828; `kernelListMapN` :425, `static listToKindedVectors` :660, `static listFromPermutation` :702
- **Original claim:** `kernelListMapN`, `listToKindedVectors` and `listFromPermutation` sit inside `extern "C"`. `kernelListMapN` has C linkage, a C++ signature and an unprefixed name.
- **Analysis:** Confirmed. `kernelListMapN(int, HPointer*, HPointer&)` is non-static inside the `extern "C"` block, so it exports an unmangled global symbol `kernelListMapN` that takes a C++ reference. The two `static` helpers have internal linkage, so their language linkage is practically irrelevant. A repo-wide grep finds no other definition or external user of `kernelListMapN` (callers are only :574-611 in the same file), so there is no clash today.
- **Impact:** Hygiene and ABI hazard only. A future same-named C symbol would clash silently, and the symbol pollutes the exported namespace.
- **Suggested fix / next step:** Move the three helpers above `extern "C" {` into an anonymous namespace.

### CORE-02: IoHandler::key() non-atomic cross-thread read
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/IoReactor.hpp:79-85 `IoHandler::key()`; writes IoReactor.cpp:528, :574; S/Socket/Udp.cpp:58-62 `~UdpHandler` (same pattern Listener.cpp:42, Conn.cpp:206)
- **Original claim:** a non-atomic field is read from other threads, and `~UdpHandler` reads it off the reactor thread.
- **Analysis:** `key_` is written only on the reactor thread, in `add` and `remove` (both `ECO_IOR_REACTOR_ONLY`). All non-destructor reads are in handler methods that the eco thread invokes only through `reactor().submit(...)` lambdas (e.g. Udp.cpp:386, 525, 614, 629, 696, 728, 744, 789), so they run on the reactor. The destructor runs only when the last `shared_ptr` reference drops. `shared_ptr`'s acq_rel refcount decrement orders the reactor's `h->key_ = 0` before that point. Once the destructor runs, no other thread holds a reference, so no concurrent access is possible and the read is race-free under the C++ memory model. The header comment ("must be read there") is stricter than needed for the destructor.
- **Impact:** None found.
- **Suggested fix / next step:** No change needed. TSan on the socket E2E tests would confirm.

### TLS-02: ensureTlsInit uses an unsynchronised static flag
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Tls/TlsContext.cpp:254-263, `ensureTlsInit`
- **Original claim:** a plain `static bool done` guards OpenSSL init, so two threads could race.
- **Analysis:** The flag is commented "eco thread only" (TlsContext.cpp:255). It has three callers, and all of them are kernel binding bodies or exports that touch the Elm heap, so they run on the eco thread: Tls.cpp:191 (`Tls.connect`), Tls.cpp:248 (`Tls.listen`), and HttpServer.cpp:256, which calls it on purpose before `SysWorkPool::submit` hands the job to a worker ("on the eco thread, before the worker uses OpenSSL"). Workers start only after the call, and the submit's mutex gives happens-before. `OPENSSL_init_ssl` is itself thread-safe, so even a double call would be harmless. The only exposure is a double `std::atexit` registration, and that needs two threads.
- **Impact:** None under the single-mutator design (CR-012 option F: no second mutator).
- **Suggested fix / next step:** Optional: use a `std::once_flag` to make it robust. Not needed.

### CORE-03: Runtime statics unsynchronised
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/Runtime.cpp:26-28 (`s_savedState`, `s_hasState`), :44-45 (`randomBody` statics), :91-101 (root scanner)
- **Original claim:** plain statics are accessed without synchronisation.
- **Analysis:** `saveStateBody`, `loadStateBody` and `randomBody` are binding bodies that the Scheduler steps on the eco thread. The root scanner that reads and writes `s_savedState` runs inside the GC root phase. Minor GC calls it on the leader (mutator) thread, w0 (NurseryParallel.cpp:716). The major-mark root snapshot calls it through `forEachMajorRoot` (ThreadLocalHeap.cpp:1027-1044) from the pausing thread, so it never runs at the same time as the mutator. Concurrent marking needs no barrier on this root: old objects are immutable, so anything later stored in `s_savedState` was either reachable at the snapshot or is new. The `mt19937_64` function-local static has thread-safe initialisation, and only the eco thread uses it afterwards.
- **Impact:** Only a hypothetical second mutator would be affected, and that is forbidden by design.
- **Suggested fix / next step:** None. At most, add an "eco thread only" comment like the one on TlsContext.

### CORE-04: getenv races concurrent setenv
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/Env.cpp:24-29, `lookupBody`
- **Original claim:** `getenv` can race a concurrent `setenv`.
- **Analysis:** Nothing in eco-kernel-cpp, system-kernel-cpp, elm-kernel-cpp or runtime/src calls `setenv` or `putenv` (grep finds no hits). No Elm API mutates the environment, so concurrent `getenv` calls are read-only and safe. A race would need foreign code linked into the process (an embed host) calling `setenv` on another thread, and that is outside Eco's control.
- **Impact:** None reachable from Elm programs.
- **Suggested fix / next step:** None. If an Env.set API is ever added, snapshot `environ` at init instead.

### CORE-05: AsyncSources drain list unsynchronised
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/AsyncSources.cpp:23-26 (`sources()`), :57-64 (`addDrainSource`); callers SysWorkPool.cpp:43, ChannelDrain.cpp:56-59 and others
- **Original claim:** the drain list is appended from `call_once` in SysWorkPool and ChannelDrain, and nothing enforces the eco-thread-only rule.
- **Analysis:** The readers are all on the eco thread. `runDrainSources` and `anyReady` run only from `Scheduler::runEventLoop` and its drain (Scheduler.cpp:657-661, 694-696, 798-800), and the `eventCV_.wait` predicate is evaluated by the waiting eco thread. The writers are also on the eco thread:
  - `SysWorkPool::submit` is called from kernel bodies that park a resume on the Scheduler.
  - `ByteChannel` subclasses are constructed in bodies that also allocate Elm results: FileSystem.cpp:122/129, WebSocket.cpp:533/695, HttpStream.cpp:206/261.
  - SignalService, HttpTables, WsEvents and SocketEvents register from eco-thread kernel code.

  The rule really is unenforced (no assert), but no current caller breaks it.
- **Impact:** A latent hazard only. If a future worker constructed a `ByteChannel` first, a `push_back` reallocation racing `anyReady` would be a use-after-free.
- **Suggested fix / next step:** Add a debug-build `assert(onEcoThread())` in `addDrainSource`.

### CORE-06: SignalService readFd_ plain int read from any thread
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:177-195 (`ensureStarted`), :130-145 (`takeFromPipe`), :56-73 (`readerThread`)
- **Original claim:** `readFd_` is a plain int, and `takeFromPipe` can run on any thread, so there is a race at first start.
- **Analysis:** `readFd_ = fds[0]` (line 183) is written before `std::thread(readerThread, ...)` is constructed (line 185). Thread creation synchronises-with the start of the new thread, so the reader thread always sees the value. The thread also gets the fd as an argument, but calls `takeFromPipe`, which reads `readFd_`. The only later write, `readFd_ = -1` at :187, happens when thread creation threw, so no reader exists then. The eco thread calls `pollReady -> takeFromPipe` only after `started_` is true, and both values are set on that same thread. `pipeMutex_` serialises the two readers.
- **Impact:** None.
- **Suggested fix / next step:** None, or make it `std::atomic<int>` for documentation value.

### ABI-03: eco exports not under ECO_KERNEL_GUARD
- **Status:** LIKELY · **Severity:** LOW
- **Where:** K/CrashExports.cpp:9-11, EnvExports.cpp, HttpExports.cpp, NativeDriverExports.cpp, RuntimeExports.cpp:14-28, MVarExports.cpp, HashExports.cpp:8-14 (guard macro at KernelExports.h:68-77; only File, Process, Console and GC exports use it)
- **Original claim:** these `extern "C"` exports are not wrapped in `ECO_KERNEL_GUARD`, so `bad_alloc` and other exceptions unwind through C linkage.
- **Analysis:** The exports really are unguarded. Most of them only build a Binding Task with `makeBinding`, so the only possible throw is `bad_alloc` from a small `std::string` or container (Crash.cpp:20 `toString`, MVar.cpp's `unordered_map` and `deque`). `Hash_*` runs only arithmetic over the string. The real IO happens in binding bodies, which the Scheduler runs later (Scheduler.cpp:982-997 `callClosure1(bindCallback, ...)`), outside any export, so a guard on the export would not cover them anyway (see ABI-NEW-1). There is no top-level `catch` anywhere in runtime/src, so an escaping exception reaches `std::terminate`. The process dies either way. The only differences: buffered stdout is not flushed (`reportFatal` flushes it, KernelExports.h:49), and the message is libstdc++'s instead of `[eco-runtime] FATAL`.
- **Impact:** Only on out-of-memory inside these small exports: abnormal termination with a worse message and possibly lost stdout. No memory corruption.
- **Suggested fix / next step:** Wrap them for consistency. The more valuable fix is ABI-NEW-1.

### ABI-04: filesystem_error thrown outside the guard
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/File.cpp:254-276 (`listBody`, the range-for at :267), :341-358 (`canonicalizeBody`, `std::filesystem::absolute(pathStr)` at :353)
- **Original claim:** throwing `std::filesystem` overloads are used outside `ECO_KERNEL_GUARD`, so permission and similar errors throw across the C boundary.
- **Analysis:**
  - `listBody` opens the iterator with the `error_code` overload. The range-for then advances it with `operator++`, which throws `filesystem_error` on a `readdir` failure, for example EIO, or a directory removed or unmounted during iteration.
  - `canonicalizeBody` falls back to the throwing `std::filesystem::absolute(pathStr)` whenever `canonical` fails, which happens for every path that does not exist. `absolute` throws when `current_path()` fails (the cwd was deleted, then any relative path is passed). libstdc++ also throws for an empty path ("cannot make absolute path"), so `Eco.File.canonicalize ""` is a plausible trigger. Eco/File.elm:263 exposes canonicalize to user code.
  - Both are binding bodies run by the Scheduler. The `ECO_KERNEL_GUARD` on `Eco_Kernel_File_list` / `_canonicalize` (FileExports.cpp) covers only building the Task, not running the body. Nothing catches the exception (no `catch` in Scheduler.cpp or runtime main), so the process terminates.
- **Impact:** The program crashes with std::terminate, where it should get a failed `Task IOError` it can handle. Reachable from ordinary Elm with unusual filesystem states, or possibly `canonicalize ""`.
- **Suggested fix / next step:** Use `absolute(pathStr, ec)` and an explicit `iter.increment(ec)` loop, mapping `ec` to `failErrno`. Add a test for `canonicalize ""` and for canonicalize of a relative path after removing the cwd.

### JSON-01: Json.encode throws on invalid UTF-8
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/json/JsonExports.cpp:1900-1912, `Elm_Kernel_Json_encode` (`j.dump(...)` at :1905/:1907); string conversion at :1571 and :1627 through `elmStringToStd` (:148) -> `StringOps::toStdString` (runtime/src/allocator/StringOps.cpp:1066-1120)
- **Original claim:** `json::dump` throws `type_error` on invalid UTF-8, and the exception crosses the C boundary.
- **Analysis:** Eco Strings are UTF-16, or UTF-8 views. `toStdString` encodes an unpaired surrogate as a 3-byte sequence (StringOps.cpp:1115-1118 else branch), which is invalid UTF-8. nlohmann's `dump()` uses the default `error_handler_t::strict` and throws `type_error.316` on it. Unpaired surrogates come from ordinary code:
  - `Char.fromCode 0xD800` passes surrogates through (CharExports.cpp:10-16).
  - Any UTF-16 slice that splits a pair, such as `String.left 1 "😀"`, produces one.

  The export has no guard and nothing upstream catches, so the program terminates. elm/json in JS returns `"\ud83d"` (an escaped lone surrogate) here.
- **Impact:** Crash, instead of valid JSON output, when encoding strings with lone surrogates. Reachable from well-typed Elm, for example truncating user text and then encoding it.
- **Suggested fix / next step:** Serialise strings with a custom writer that emits `\uXXXX` for lone surrogates, as JS does. At minimum, call `dump(indent, ' ', false, error_handler_t::replace)` and wrap the export in a guard. Test: `Encode.encode 0 (Encode.string (String.left 1 "😀"))` should give `"\"\\ud83d\""`.

### FILE-03: readStringBody has no size cap
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:101-131, `readStringBody` (`allocByteBufferBlank(size)` at :114, `makeUtf8View(bufHp, 0, (u32)size)` at :126); compare `readBytesBody` :146-148, which has the cap
- **Original claim:** a size over 4 GiB is passed to `allocByteBufferBlank` and cast to u32 for `makeUtf8View`.
- **Analysis:** `readBytesBody` rejects sizes over `UINT32_MAX` with EFBIG. `readStringBody` does not. `allocByteBufferBlank` (runtime/src/allocator/HeapHelpers.hpp:1508-1527) allocates the body at its full length, but stores `header.size = (u32)length` (the large path goes through ThreadLocalHeap.cpp:529). The file read fills the whole body, so there is no overflow. On the all-ASCII path, though, `makeUtf8View` gets `size` mod 2^32, so the String silently has the wrong length (data loss, no error). The non-ASCII path builds a >4 GiB `std::string` and a UTF-16 string whose u32 length fields will also truncate. A >4 GiB read also needs more than 8 GiB of heap.
- **Impact:** Silent truncation for files of 4 GiB or more. Very rare in practice.
- **Suggested fix / next step:** Copy the readBytes guard (`sz > UINT32_MAX` gives EFBIG "file too large for String") into readStringBody.

### HTTP-05: zip_stat_index result unchecked
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/Http.cpp:209-227, the archive-extraction loop of `getArchive`
- **Original claim:** a `zip_stat_index` failure is ignored, and the uninitialised `st.size` is used for `resize` and `zip_fread`.
- **Analysis:** The return value is ignored, but `zip_get_name(archive, i, 0)` already succeeded for the same index (:200-205). `zip_stat_index` fails only for an invalid or deleted index, which that excludes, and in a read-only archive `st.size` comes from the central directory. More relevant, from the same code:
  - `st.size` is attacker-controlled (the central-directory claim), so a huge value makes `content.resize` throw `bad_alloc` in an unguarded body (terminate).
  - A short or failed `zip_fread` (got != size, or -1 on a CRC or inflate error) is only logged (:223-228). The entry is still pushed with zero-filled content.
  - An entry whose `zip_fopen_index` fails is silently dropped (:216-220).

  The caller (compiler Builder/Deps, through Eco/Http.elm:35-46) checks the archive sha, which covers transport corruption but not a hostile archive with a valid hash.
- **Impact:** The original claim is practically unreachable. The neighbouring silent zero-fill on read failure is a real but low-impact data-integrity hole.
- **Suggested fix / next step:** Check the `zip_stat_index` return value and `st.valid & ZIP_STAT_SIZE`, cap `st.size`, and treat `got != st.size` as an `Err` for the whole archive.

### TLS-03: fill() ignores BIO_write result
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Tls/TlsTransport.cpp:313-331, `fill()` (`(void)BIO_write` at :318); BIOs created at :410-420 `attachBios`
- **Original claim:** the `BIO_write` return value is ignored, so ciphertext could be silently dropped and the session desynchronised.
- **Analysis:** `rbio_` is a `BIO_s_mem()` (:412). A memory BIO grows without limit, and its `BIO_write` fails only when the internal `BUF_MEM_grow` allocation fails, that is, on out-of-memory. `got` is at most `kRecvChunk`, so the int cast cannot overflow. There is no partial-write case for a memory BIO.
- **Impact:** Only under malloc failure, where the TLS session would see a MAC or decrypt error, not silent corruption.
- **Suggested fix / next step:** Optional: check for `<= 0` and set `fatal_` with "ENOMEM" for completeness.


## Correctness

### JSON-02: makeErr builds the wrong Error ctor — **FIXED on master**: makeErr is gone; failures are Failure (ctor 3)
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:175-229 (`ERR_FIELD` 0, `ERR_INDEX` 1, `ERR_ONE_OF` 2, `ERR_FAILURE` 3; `makeFailure` :204-210)
- **Original claim:** `makeErr` built ctor 0 (`Field msg Nil`) where elm/json `Failure` is ctor 3.
- **Analysis:** `makeErr` no longer exists (grep finds no hits). Every failure goes through `makeFailure`, which builds `custom(ERR_FAILURE, {msg, value})` with the value preserved, as in elm/json's `_Json_expecting`. `wrapField`, `wrapIndex` (Int in slot 0, kind bitmap 0x1 = Int in the 2-bit encoding) and `OneOf` (:1407) follow declaration order. `makeFailure` roots both `value` and `msgStr`.
- **Impact:** Fixed.
- **Suggested fix / next step:** None.

### JSON-03: DEC_ARRAY picks element kind from the decoder's top ctor — **FIXED on master**: DEC_ARRAY takes the element kind from the decoded value
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:1195-1232, `DEC_ARRAY` case of `runDecoder`
- **Original claim:** the element kind was chosen from the element decoder's top constructor, which is wrong for, e.g., `array (field "v" int)`.
- **Analysis:** The kind now comes from `decodedSlot(allocator, elements[0], firstSlot)` (:1225-1229), with a comment naming the `array (field "v" int)` case. `DEC_LIST` (:1124-1192) does the same per element. The element buffer is rooted through `rootBuffer`, and the root range is restored on both exits.
- **Impact:** Fixed.
- **Suggested fix / next step:** None.

### JSON-04: Json.wrap renders a boxed Char as null
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:1918-1995, `Elm_Kernel_Json_wrap` (generic); `_Char` variant near :2000-2040; `elmToJson` fallthrough :1622-1630
- **Original claim:** a boxed Char passed to the generic `Json.wrap` is passed through and rendered as null.
- **Analysis:** The generic `wrap` has no `Tag_Char` case, so a boxed Char falls through to `return value` (:1994). `elmToJson` then finds no matching tag and emits `null` (:1629). So the mechanism is real. It is not reachable through Eco's own API, though:
  - elm/json uses `Elm.Kernel.Json.wrap` only at String, Int, Float and Bool, or Value (Json/Encode.elm:78-170). It exposes no Char encoder.
  - When `wrap` is called at `MChar`, the compiler selects `Elm_Kernel_Json_wrap_Char` (compiler/src/Compiler/GenerateMlir/KernelAbi.elm:278-279), which encodes the code point as `ENC_INT`.

  The only polymorphic use found is elm/browser's `Debugger/History.elm:128-131` (`elmToJs : a -> Value`), which is browser-debugger only. Even in JS, a Char there would be a string, not null.
- **Impact:** A wrong value only in the browser debugger's history export. Unreachable from ordinary native programs.
- **Suggested fix / next step:** Add a `Tag_Char` branch to the generic `wrap`, consistent with `wrap_Char` (or emit a one-character string, as JS does), for completeness.


## Memory safety & GC

### ABI-NEW-1: binding-body exceptions are never caught; ECO_KERNEL_GUARD on Task-returning exports is ineffective
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** runtime/src/platform/Scheduler.cpp:982-997 (the `Task_Binding` step calls `callClosure1(bindCallback, ...)` with no try/catch); K/FileExports.cpp (the guard wraps only Task construction); no `catch` in runtime/src apart from RootSet.cpp, HeapConfigJson.cpp and WaitService.cpp
- **Original claim:** None; found while checking ABI-03 and ABI-04.
- **Analysis:** Kernel IO lives in binding bodies (KERNEL_TASK_IO_001), which the Scheduler invokes when it steps the Task, long after the guarded export has returned. Any C++ exception in a body propagates through the Scheduler loop, and possibly through LLVM-generated Elm frames, to `std::terminate`, with no `reportFatal` and no stdout flush. Examples: `std::filesystem` (ABI-04), nlohmann, `bad_alloc` from `std::string`/`vector` in every body, and libzip-driven `resize` (HTTP-05). This means the File guards (and any others that wrap only Task construction) give a false sense of coverage.
- **Impact:** Any throwing path in any kernel body kills the process, where it should become a failed Task or at least a clean `reportFatal` with flushed stdout.
- **Suggested fix / next step:** Put one try/catch around the binding-callback invocation in the Scheduler (or inside `Elm::Platform::makeBinding`'s trampoline). It should map `std::exception` to `reportFatal`, or preferably to a failed Task where the body's error shape is known.


## Correctness

### JSON-05: JSON ints above INT64_MAX wrap
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/json/JsonExports.cpp:337 (`OrderedDomBuilder::number_unsigned`), :755-757 (`jsonToHeap`)
- **Original claim:** integers above INT64_MAX wrap to wrong values.
- **Analysis:** The SAX builder stores nlohmann's `number_unsigned` (any non-negative literal nlohmann reads as unsigned, which covers 2^63..2^64-1) as an unsigned json at :337. `jsonToHeap` tests `j.is_number_integer()` (true for unsigned too) and calls `j.get<i64>()` at :756, which converts modulo 2^64. So `"9223372036854775808"` becomes `CTOR_JSON_INT` -9223372036854775808. Literals above 2^64-1 overflow to float in nlohmann, so only the band [2^63, 2^64) is affected. Every consumer sees the wrapped value: `Decode.int` (:1090), `Decode.float` (:1104, a negative float), `Decode.value` and re-encoding. Any program that calls `Decode.decodeString` on outside JSON can reach this (u64 IDs, hashes).
- **Impact:** Silent wrong values with a flipped sign. JS gives a positive float, and `Decode.int` accepts it as an integral number.
- **Suggested fix / next step:** In `jsonToHeap`, check `is_number_unsigned()` first: if the value is above INT64_MAX, make it `CTOR_JSON_FLOAT` (`static_cast<f64>`), which is what JS has. Add an elm-json test with `"18446744073709551615"`.

### JSON-06: Decode.int rejects 1.0
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/json/JsonExports.cpp:1090-1096 (`runDecoder`, `DEC_INT`); :758-760 (`jsonToHeap` float branch); :1567 (`elmToJson` ENC_FLOAT)
- **Original claim:** an integral float such as `1.0` (or `Encode.float 1` run through `decodeValue`) is rejected by `Decode.int`.
- **Analysis:** `DEC_INT` accepts only `jctor == CTOR_JSON_INT`. nlohmann reads `1.0`, `1e3` and `-0.0` as floats, so `jsonToHeap` makes them `CTOR_JSON_FLOAT`, and they get "Expecting an INT". `Decode.decodeValue Decode.int (Encode.float 1)` takes the same path: ENC_FLOAT, then `json(double)` (:1567), then `CTOR_JSON_FLOAT` (:1853-1855). elm/json's `_Json_decodeInt` accepts any finite number with no fractional part. `DEC_FLOAT` already accepts both ctors (:1098), so only `DEC_INT` is asymmetric.
- **Impact:** Valid JSON from producers that write `1.0` or exponent forms makes `Decode.int` fail where Elm/JS succeeds.
- **Suggested fix / next step:** In `DEC_INT`, also accept `CTOR_JSON_FLOAT` when the value is finite, `trunc(d)==d`, and it fits in i64, and box it as an Int. Add tests for `"1.0"`, `"1e3"` and `Encode.float 1`.

### JSON-07: DEC_INDEX/DEC_FIELD errors lack context — **FIXED on master**: DEC_FIELD/DEC_INDEX failures are wrapped in Field/Index
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:217-230 (`wrapField`, `wrapIndex`), :1259-1260 (DEC_FIELD), :1284-1286 (DEC_INDEX)
- **Original claim:** field/index failures carry no Field/Index wrapper.
- **Analysis:** DEC_FIELD returns `isOk(result) ? result : wrapField(fieldNameHP, result)`, with the name rooted by `fieldRoots` (:1247). DEC_INDEX returns `wrapIndex(index, result)`. Both helpers take the inner error out first and root it (`StackRootGuard`) before `custom(...)` allocates. `wrapIndex` marks slot 0 as an unboxed Int (bitmap 0x1), which matches the Index layout. A missing field or an out-of-range index still gives a plain `expecting` Failure, which matches elm/json.
- **Impact:** None. The fix is in place and is GC-safe.
- **Suggested fix / next step:** None. Make sure an elm-json test checks `Decode.errorToString` for a nested field/index failure.

### JSON-08: oneOf drops alternatives' errors — **FIXED on master**: oneOf collects every alternative's error into OneOf
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:1387-1408 (`runDecoder`, `DEC_ONEOF`)
- **Original claim:** the OneOf error does not collect every alternative's error.
- **Analysis:** Each failing alternative's error is pushed in order into `RootedSlots errors` (:1401), which stays rooted across the later decodes. `listFromPointers(errors)` builds the list in order, and the result is `Err (OneOf list)` with the list rooted during the `custom` allocation. The decoder list is walked with a `RootedListCursor`. With an empty `oneOf []`, the result is `OneOf []`, as in JS.
- **Impact:** None.
- **Suggested fix / next step:** None.

### JSON-09: duplicate keys in Encode.object may resolve differently — **FIXED on master**: repeated keys keep their first position and take the last value, as in JS
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/json/JsonExports.cpp:256-289 (`dedupeObject`), :296 (`putInJsKeyOrder`), :1583-1598 (`elmToJson` ENC_OBJECT), :343-344 (parser `end_object`)
- **Original claim:** duplicate keys may resolve first vs last differently from JS.
- **Analysis:** `elmToJson` appends the fields in program order (it reverses the prepended list), then calls `dedupeObject`, which keeps the first occurrence's position and moves in the last occurrence's value. It then applies JS key order (integer-like keys first). The parser does the same at `end_object`. So both encode and `decodeString` give one value per key, and DEC_FIELD's "first match" (:1255) sees the deduplicated (last) value, as JS `obj[k]` does.
- **Impact:** None.
- **Suggested fix / next step:** None.

### JSON-10: jsToString false for Number/Bool
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/json/JsonRead.cpp:178-190 (`jsToString`); only caller is E/virtual-dom/VirtualDomExports.cpp:234-238 (`Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson`)
- **Original claim:** returns false for Number/Bool where JS `String(v)` gives text.
- **Analysis:** The return value for Number/Bool/Null/Object is documented (JsonRead.hpp:92-94). The only caller treats `false` as "keep the value": it only needs to know whether `String(v)` starts with a `javascript:` or `data:text/html` URI. For a number, bool, null or object, JS's `String(v)` (`"5"`, `"true"`, `"null"`, `"[object Object]"`) can never match either prefix, so returning false gives the same result as JS. Arrays, which can render to a matching string, are handled.
- **Impact:** None observable today. A future caller that needs the real text would get nothing.
- **Suggested fix / next step:** None needed. Optionally rename the function or note in the doc comment that it is only for the XSS check.

### JSON-11: jsToString Int above 2^53 loses precision
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/json/JsonRead.cpp:104-108, :128-132 (`view`), :72-76 (`appendJs` Number)
- **Original claim:** large ints lose precision in jsToString.
- **Analysis:** `view` turns Int (heap or `CTOR_JSON_INT`/`ENC_INT`) into a double, and `appendJs` prints it with `formatFloatShortest`. This is exactly JS's `String(Number)` behaviour. It can only affect a number inside an array given to the XSS check, where a numeric element cannot change the prefix test.
- **Impact:** None. The behaviour is intended and matches JS.
- **Suggested fix / next step:** None. Close as intended.

### URL-01: percentEncode escapes !*'()
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/url/UrlExports.cpp:38-44 (`shouldEncode`), :59-77 (`Elm_Kernel_Url_percentEncode`)
- **Original claim:** escapes `!*'()`, which `encodeURIComponent` leaves alone.
- **Analysis:** `shouldEncode` keeps only `A-Za-z0-9-_.~`, so `Url.percentEncode "a(b)!"` gives `"a%28b%29%21"`. JS gives `"a(b)!"`. The file header (:7-9) documents this. The unused `Url.cpp::isUnreserved` (:7-19) has the JS set. This affects every `Url.Builder` call (`string`, `crossOrigin`, query params). Servers decode the two forms the same way, so meaning is kept, but the resulting `String` differs from Elm/JS.
- **Impact:** URL strings differ from stock Elm, which breaks string-comparison tests and signature/cache keys computed over URLs. Requests are not broken.
- **Suggested fix / next step:** Add `! * ' ( )` to the unreserved set in `shouldEncode`, or reuse `Url.cpp`'s `isUnreserved`. Extend UrlPercentEncodeTest with `"a(b)!*'"`.

### URL-02: percentDecode decodes + as space
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/url/UrlExports.cpp:100-102 (`Elm_Kernel_Url_percentDecode`)
- **Original claim:** `+` is decoded as a space, unlike `decodeURIComponent`.
- **Analysis:** The `'+'` branch writes `' '`, and the comment says it on purpose. elm/url's JS kernel is a bare `decodeURIComponent`, which keeps `+`. `Url.Parser.Query` decodes every key and value through `percentDecode`, so `?q=c++` parses to `"c  "` on eco and `"c++"` on JS. Strings that a program builds itself with `Url.percentEncode` never contain a raw `+` (it is encoded as `%2B`), so round-trips work. Input from outside (`Url.fromString` of a real URL, form-style queries) is changed.
- **Impact:** Data is silently corrupted for any literal `+` in parsed URLs: e-mail addresses like `a+b@x`, `c++`, base64 tokens.
- **Suggested fix / next step:** Remove the `'+'` branch. Add `percentDecode "a+b" == Just "a+b"` to UrlPercentDecodeTest.

### URL-03: percentDecode returns Just on invalid UTF-8
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/url/UrlExports.cpp:79-111; runtime/src/allocator/HeapHelpers.hpp:470-477 (`allocStringFromUTF8`, lenient decoding)
- **Original claim:** returns `Just` where the decoded bytes are invalid UTF-8; JS returns Nothing.
- **Analysis:** The decoded bytes go straight to `allocStringFromUTF8`. Its documented behaviour (HeapHelpers.hpp:472-476) is to drop invalid lead bytes, skip continuation checks, and fill a truncated sequence with zero bytes. So `percentDecode "%FF"` gives `Just ""`, and `"%E2%82"` gives `Just "\u{2080}"` (garbage made from the zero-filled bytes). JS `decodeURIComponent` throws URIError, which elm/url turns into `Nothing`. The strict decoder `utf8ToUtf16` already exists in the dead E/url/Url.cpp:83-133.
- **Impact:** Malformed or hostile URLs decode to wrong text instead of failing, so validation done through `Maybe` is bypassed.
- **Suggested fix / next step:** Validate the bytes strictly (move `Url.cpp::utf8ToUtf16`, or a StringOps validator, into the export) and return `nothing()` when validation fails. Add tests for `"%FF"`, `"%E2%82"` and `"%ED%A0%80"`.

### URL-04: dead percentEncode encodes lone surrogates
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/url/Url.cpp:38-74 (`utf16ToUtf8`), :135-151 (`Url::percentEncode`); declared in E/url/Url.hpp:25,35; compiled by elm-kernel-cpp/CMakeLists.txt:290
- **Original claim:** the dead namespace `percentEncode` encodes lone surrogates instead of failing.
- **Analysis:** A grep of the whole repo finds no caller of `Url::percentEncode` or `Url::percentDecode` (only definitions and declarations). The exports in UrlExports.cpp have their own code. `utf16ToUtf8` encodes an unpaired surrogate as the 3-byte sequence for its unit (its own comment says so), where JS throws URIError. Since nothing calls it, there is no impact. The useful part of this file is its JS-correct unreserved set and strict UTF-8 decoder, which would fix URL-01 and URL-03.
- **Impact:** None (dead code). It adds a little maintenance cost and can mislead readers ("the namespace follows JavaScript").
- **Suggested fix / next step:** Either wire Url.cpp's `isUnreserved` and `utf8ToUtf16` into the exports (fixing URL-01 and URL-03) and delete the rest, or delete Url.cpp/Url.hpp and the CMake line.

### UTILS-02: mixed boxed/unboxed Float comparison uses raw operators
- **Status:** LIKELY · **Severity:** LOW
- **Where:** E/core/Utils.cpp:241-245 (`compareListElem`, primKind==2 branch); compare `compareFloat` in E/core/Utils.hpp:84-91
- **Original claim:** raw `<`/`==` are used instead of `compareFloat`, so NaN ordering differs between paths.
- **Analysis:** When one element is a boxed heap Float and the other an unboxed Float, the code is `ord = (x==y)?0:(x<y?-1:1)`. Any NaN gives 1 whichever side holds it: `compare 1.0 NaN` gives GT, and `compare NaN NaN` gives GT. The same-kind path (`compareFloat`) gives LT and EQ. Utils.hpp:81-82 documents this, so the code defect is certain. The trigger needs two `List Float` values whose elements have different kinds at the same position. REP_HEAP_001 and MONO_029 make heap layout a static function of the type, so compiled code always unboxes Float list heads. Only a kernel that builds lists with boxed Float heads could produce the mismatch. The code comments (Utils.cpp:118-119) say this happens but give no current example. Even when it happens, it only matters with NaN inside lists.
- **Impact:** `compare`/`sort` of Float lists containing NaN could be inconsistent between representations, giving a non-total order. That is very narrow.
- **Suggested fix / next step:** Call `compareFloat(x, y)` (negated for the swapped side) in that branch. A unit test in test/kernel can build a mixed-kind list pair directly to show it.

### UTILS-03: compare and == disagree on tuples with one boxed slot
- **Status:** LIKELY · **Severity:** LOW
- **Where:** E/core/Utils.cpp:342, :349 (Tuple2 in `cmp`), :363 (Tuple3 in `cmp`) vs :103-136 (`eqUnboxableSlot`, used by `eqHelp` Tuple2/Tuple3 at :549-575)
- **Original claim:** `cmp` orders by kind when slot kinds differ, while `equal` compares by value.
- **Analysis:** In `cmp`, Tuple2/Tuple3 return `aKind < bKind ? -1 : 1` as soon as the slot kinds differ, without looking at the values. `eqUnboxableSlot` instead compares a boxed heap Int/Float/Char against an unboxed value by value. So `(1, x)` with slot 0 boxed and `(1, x)` with slot 0 unboxed are `==` but `compare` gives LT/GT. Lists handle this already: `compareListElem` compares across kinds, but tuples were not given the same treatment. The code defect is certain. Reachability depends on the same mixed-representation premise as UTILS-02, which REP_HEAP_001 rules out for compiled code. A kernel-built tuple with a boxed Int/Float/Char slot would be needed. JSON `keyValuePairs` sets slot kinds from the decoded value (`decodedSlot`, :1300), which looks consistent with the compiled layout.
- **Impact:** If triggered, `Dict`/`Set` keyed by such tuples could keep `==` keys as separate entries, and `sort` would disagree with `==`.
- **Suggested fix / next step:** In the Tuple2/Tuple3 arms, when kinds differ, compare through `compareListElem` (rename it to `compareMixedSlot`) instead of ordering by kind. A unit test that builds both tuple forms by hand would settle it.

### UTILS-04: boxed constant list element orders above unboxed one
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/Utils.cpp:230 (`compareListElem`: `if (!boxedPtr) return (aKind == 0) ? 1 : -1;`), also :254 (order-by-kind fallback)
- **Original claim:** a boxed constant element orders above an unboxed one, by representation rather than value.
- **Analysis:** `safeResolve` returns null only for embedded constants (Empty/Unit/Nil/Nothing/""/True/False, REP_CONSTANT_001). None of these is a value of type Int, Float or Char, the only unboxed kinds. The other element is unboxed, so its type is Int/Float/Char, which means a well-typed program can never compare these two elements. The order-by-kind fallback at :254 is equally unreachable: the boxed side would have to be a heap object that is not an Int/Float/Char, compared with an Int/Float/Char.
- **Impact:** None for well-typed programs. It is only a defensive fallback.
- **Suggested fix / next step:** None, or replace it with an `assert` and an "unreachable in well-typed Elm" comment, as `compareUnboxableSlot` does.

### JSON-NEW-1: Encode.float of an integral value prints a trailing ".0"
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/json/JsonExports.cpp:1567-1568 (`elmToJson` ENC_FLOAT gives `json(double)`), :1902-1909 (`Elm_Kernel_Json_encode` uses nlohmann `j.dump()`)
- **Original claim:** (new) none.
- **Analysis:** `Encode.float 3` is stored as a double, and nlohmann's serializer prints integral doubles with a ".0" suffix. The repo's own test pins this: test/elm-json/src/EncodeFloatTest.elm:9 expects `zero: "0.0"`. elm/json on JS uses `JSON.stringify`, which gives `"0"` and `"3"`. `Encode.float 1e21` and similar numbers probably also differ from JS formatting (nlohmann uses shortest round-trip with its own exponent style). Every JSON-producing program that encodes Floats is affected. JSON-06 makes it worse: eco's own output `{"n":3.0}`, read back with `Decode.int`, fails on eco.
- **Impact:** Output differs from stock Elm for every integral Float. This breaks golden-output comparisons and strict consumers that expect integer formatting.
- **Suggested fix / next step:** Serialize numbers with `StringOps::formatFloatShortest` (JS `Number.prototype.toString` semantics, already used in JsonRead.cpp:73), through a custom dump or a post-pass. Change EncodeFloatTest to expect `"0"`.

### UTILS-05: eqHelp assumes equal past depth 100
- **Status:** CERTAIN · **Severity:** HIGH
- **Where:** E/core/Utils.cpp:488-523 (`eqHelp`, the `if (depth > 100) return true;` at :520-522); depth is incremented only in `eqUnboxableSlot` :111-115 (boxed slot → `eqHelp(ao, bo, depth + 1)`).
- **Original claim:** returns equal when recursion depth exceeds 100.
- **Analysis:** Once two objects reached through more than 100 nested boxed slots have the same tag (and are not Strings/Bytes, which are tested before the cut-off at :498-509), `eqHelp` returns true without looking at them. Stock elm/core does NOT do this: `_Utils_eqHelp` pushes the pair `(x, y)` onto an explicit stack when `depth > 100` and returns true only provisionally; `_Utils_eq` then pops and compares every deferred pair. Eco dropped the stack, so the deferral became "assume equal". The Cons walk (:579-603) is iterative and does not add depth, so long flat lists are fine, but any user recursive type adds one level per node: e.g. `type Nat = Z | S Nat`, `S^150 Z == S^200 Z` reaches two `S` Customs at depth 101 and answers `True`. The same holds for ASTs, trees, linked custom lists, nested records/Maybes, lists of lists, Dict values (`dictEq` passes `depth` along). Reachable from ordinary well-typed programs via `==`/`/=` (`Elm_Kernel_Utils_equal`, E/core/UtilsExports.cpp:99-118), and from `List.member`, `Dict`/`Set` value comparisons, etc.
- **Impact:** `==` silently returns True for unequal deep values: wrong results, e.g. memoisation, change detection or test assertions accepting wrong data.
- **Suggested fix / next step:** Do what JS does: keep an explicit work stack (vector of pairs, which the GC cannot move during a non-allocating compare) and continue comparing the deferred pairs instead of returning true; or make the comparison fully iterative. Pin with an elm-conformance test using `S^150 Z == S^200 Z`.

### UTILS-06: function equality returns false
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/Utils.cpp:678-679 (`case Tag_Closure: return false;` in `eqHelp`), plus `default: return false;` :681-682.
- **Original claim:** returns false where elm/core JS throws.
- **Analysis:** Elm's type system allows `==` on function-typed values (and on records/customs that contain functions); elm/core JS calls `_Debug_crash(5)` ("Trying to use `(==)` on functions") when it meets a function, unless the two references are identical (`x === y` comes first; Eco mirrors that with `a == b` at :491). Eco instead returns `False`, so `f == g` and `{ f = f } == { f = f }` (different closure objects) quietly yield False and `/=` yields True. Reachable from ordinary programs, but only from ones that are buggy in stock Elm.
- **Impact:** Divergence from elm/core: a program that crashes under JS runs on with a False answer, which can hide the bug. It is not memory-unsafe.
- **Suggested fix / next step:** Decide whether this is intended. If so, document it in the conformance notes. If not, throw/crash with the elm/core message (through the kernel guard, not across `extern "C"`). An elm-conformance case with `(\x -> x) == (\x -> x)` would record the decision.

### UTILS-07: empty Bytes constant vs zero-length ByteBuffer unequal
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/UtilsExports.cpp:99-111 (`equalRespectingConstants`), E/core/Utils.cpp:68-91 (`resolveAndCompare`), :493 and :503-509 (`eqHelp`).
- **Original claim:** two representations of empty Bytes compare unequal.
- **Analysis:** The code itself would answer False for the Empty constant against a zero-length ByteBuffer object: the constant-vs-heap paths only accept a zero-length *String* (`isZeroLengthString`). But such an object cannot exist. HEAP_071 (design_docs/invariants.csv:736, "enforced") says no ByteBuffer is ever allocated at length 0 and the empty Bytes is always the Empty constant. Every producer enforces it: `allocByteBuffer` (runtime/src/allocator/HeapHelpers.hpp:1469), `allocByteBufferBlank` :1509, `allocByteBufferZero` :1531, and the slice constructor :2127 all return `emptyBytes()` for length 0. Two empty Bytes are therefore always the same constant word and compare equal at UtilsExports.cpp:105. Two non-empty heap Bytes are compared by content in any form (:503-509).
- **Impact:** None as long as HEAP_071 holds. It would only appear if some future producer allocated a 0-length ByteBuffer, LargeByteHeader or slice.
- **Suggested fix / next step:** Optionally add an `assert(length > 0)` on Bytes objects reached in `eqHelp`, or make the constant-vs-heap branch also accept a zero-length Bytes, as defence in depth. No functional fix needed.

### HASH-01: negative seed gives negative narrow hash
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Hash.cpp:28 (`int64_t h = seed % kBase;` in `stringWithSeed`); `mix` :21-23.
- **Original claim:** truncating `%` with a negative seed yields a negative value, breaking [0, 2^26) packing.
- **Analysis:** C++ `%` truncates, so a negative seed gives a starting `h` in (-2^26, 0]. `mix` uses `%` as well, and with a negative `h`, `h*33 + c + 7` can stay negative, so the result can be negative. The empty string returns the negative seed remainder directly. The pure-Elm twin (compiler/src-xhr/Eco/Hash.elm:39-41) uses `modBy`, which is always non-negative, so the two diverge, and its module doc admits this (:15-18). Callers: the compiler uses seeds 23 and 7919 only (compiler/src/Compiler/IR/Mono.elm:722, Builder/File.elm:312-314, TypeTable.elm:726 via `Eco.Hash.string`), so the `layoutH * hashBase + specH` packing (Mono.elm:205-219) is never fed a negative value. `Eco.Hash.stringWithSeed` is public in eco/kernel (eco-kernel-cpp/src/Eco/Hash.elm:38-41), and its doc promises the `mod 2^26` formula without a sign caveat. A user who passes a negative seed and uses the hash as a bucket index (e.g. `Array.get`) would get misses rather than corruption.
- **Impact:** Latent. A wrong (negative) hash only for negative user seeds. No in-tree trigger.
- **Suggested fix / next step:** Use a floored remainder: `h = ((seed % kBase) + kBase) % kBase`. Then `mix` stays non-negative because `x` (a UTF-16 unit) is non-negative.

### PARSE-04: isHighSurrogate accepts low surrogates
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/parser/ParserExports.cpp:99-102 (`isHighSurrogate`: `(c & 0xF800) == 0xD800`), used in `Elm_Kernel_Parser_isSubChar` :164-175, `advancePosition` :107-121, `isSubString` :225-230.
- **Original claim:** range check admits low surrogates; two lows decode to >= 0x110000.
- **Analysis:** The mask accepts 0xD800-0xDFFF, as its own comment says. In `advancePosition`/`isSubString` this mirrors elm/parser JS exactly (JS uses the same `& 0xF800` test). In `isSubChar`, though, Eco decodes a code point where JS passes `string.substr(offset, 2)`. If `c0` is a lone low surrogate (0xDC00-0xDFFF) followed by another low surrogate, :171 computes `0x10000 + ((c0 - 0xD800) << 10) + (c1 - 0xDC00)` = 0x110000..0x10FFFF+0x100000, an invalid Char above U+10FFFF, and hands it to the user predicate. Reachable from well-typed Elm, since Strings may hold lone surrogates (e.g. `String.fromList [Char.fromCode 0xDC00, Char.fromCode 0xDC00]`, or text decoded with `\udc00` escapes), followed by `Parser.chompIf`/`chompWhile`/`getChompedString`.
- **Impact:** The predicate sees a Char outside Unicode. Char functions (`Char.toCode` gives > 0x10FFFF, case-mapping tables) may misbehave. Malformed input is needed, so the impact is low.
- **Suggested fix / next step:** In `isSubChar`, test `c0` against the real high range (`(c0 & 0xFC00) == 0xD800`) before pairing. Keep the 0xF800 mask in the position-advancing code for JS parity (or document the divergence).

### PARSE-05: findSubString with empty target and negative offset
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/parser/ParserExports.cpp:244-286 (`Elm_Kernel_Parser_findSubString`, `index = (offset <= bigLen) ? offset : -1;` at :262-263).
- **Original claim:** returns a negative index.
- **Analysis:** True as written: with `smallLen == 0` and `offset < 0` it returns `index = offset` (negative and not -1), and JS `indexOf("", -5)` would give 0. But the only callers are elm/parser's `chompUntil`/`chompUntilEndOr` (~/.eco/0.1.3/packages/elm/parser/1.1.0/src/Parser/Advanced.elm:890, :913), which pass `s.offset`. The parser state offset starts at 0 and only grows, so it is never negative. The kernel function is not exposed to user code.
- **Impact:** None reachable. In theory a negative non-(-1) index would be taken as success.
- **Suggested fix / next step:** Optional: guard with `offset >= 0 && offset <= bigLen`, or clamp to 0 to match JS. No test needed.

### PARSE-06: consumeBase accepts :..@ as digits for base > 10
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/parser/ParserExports.cpp:307-320 (`Elm_Kernel_Parser_consumeBase`, `digit = code - 0x30; if (digit < 0 || digit >= base) break;`).
- **Original claim:** digit range check spans the ASCII gap between '9' and 'A'.
- **Analysis:** True for base > 10, but the code is a line-for-line copy of elm/parser's JS `_Parser_consumeBase`, which has the same property. It is called only with bases 8, 2 and 10 (Advanced.elm:649, :651, :656). Hex goes through `consumeBase16` (:325-346), which checks the ranges correctly. The kernel function is not exposed, so base > 10 never occurs.
- **Impact:** None reachable.
- **Suggested fix / next step:** None needed. Optionally add an `assert(base <= 10)` to document the contract.

### REGEX-05: Regex.never returns Nothing if compile throws
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/regex/RegexExports.cpp:196-215 (`Elm_Kernel_Regex_never`, `catch (...)` returns `nothing()`).
- **Original claim:** a compile failure surfaces as Nothing.
- **Analysis:** The fixed pattern `(?!)` is valid ECMAScript, and SRELL compiles it. The only possible throw is `std::bad_alloc` from `new`/`registerRegex`/`custom`, which is effectively out-of-memory. Even then the returned Empty constant is handled safely: `getCompiledRegex` (:89-101) returns null for a constant (`toPtr` gives null), and every matcher then returns False / [] / the input unchanged, which is exactly `never`'s behaviour. So the "contract" is still kept in practice, through a type-confused value. A separate, apparently unused `Elm::Kernel::Regex::never()` in E/regex/Regex.cpp:8-18 swallows the exception similarly (u16regex design, see Regex.hpp:7-8).
- **Impact:** Practically none. Only under OOM, and the result still matches nothing.
- **Suggested fix / next step:** Optional: drop the catch (let OOM be fatal) or build a Custom with an id that is not in the table. Consider whether Regex.cpp's parallel design is dead code (likely a DEAD-* candidate).

### REGEX-06: regex engine is byte-wise over UTF-8
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/regex/RegexExports.cpp:12-15 (header comment), :54-60 (table of `srell::regex*`), :200, :249 (`new srell::regex(...)`), :281, :316 (`sregex_iterator` over the UTF-8 `std::string`); typedef in elm-kernel-cpp/vendor/srell.hpp:24469 (`typedef basic_regex<char> regex;`), while the UTF-8-aware one is `u8cregex` (:24471).
- **Original claim:** `.`, case-insensitivity and classes operate on bytes.
- **Analysis:** Every pattern and subject is converted to UTF-8 and matched with `basic_regex<char>` under default traits, which treats each byte as a character. Consequences that ordinary programs reach: `.` matches one byte of a multi-byte char, so `Regex.find (fromString ".") "é"` yields two matches whose `match` strings are invalid UTF-8 halves; `[éü]` becomes a set of 4 bytes; `é` / `\u{1F600}` escapes in patterns match code units the subject never holds in UTF-8; `icase` folds ASCII only (`É` vs `é` fail, where JS `i` folds them); `^.{3}$` counts bytes; `split`/`replace` can cut inside a character and produce corrupt Strings. `Utf16Index` (:159-190) converts offsets correctly for byte offsets on character boundaries, but a mid-character offset is counted as if on a boundary.
- **Impact:** Wrong matches and malformed match/replace strings on non-ASCII text, versus elm/regex in JS. Reachable from ordinary programs that process non-ASCII text.
- **Suggested fix / next step:** Switch to `srell::u8cregex` / `u8csregex_iterator` (same API, UTF-8 aware, so `Utf16Index` still applies) or to the `u16regex` path that Regex.cpp already sketches (this matches JS semantics most closely, since the Elm String is UTF-16). Add elm-conformance cases: `find "."` on "é😀", and `caseInsensitive` "É" vs "é".

### REGEX-07: Match.index counts code points, not UTF-16 units — **FIXED on master**: Utf16Index converts offsets to UTF-16 code units
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/regex/RegexExports.cpp:159-190 (`Utf16Index`), used in `findAtMost` :311/:323 and `replaceAtMost` :376/:394.
- **Original claim:** index measured in code points over UTF-8.
- **Analysis:** The fix is present. `Utf16Index::at` walks the UTF-8 lead bytes and counts 2 units for a 4-byte sequence and 1 otherwise, giving a UTF-16 index; both match-record producers pass `utf16Index.at(match.position())` to `createMatch`. Offsets are requested in non-decreasing order as the iterator yields them. Remaining caveat: under the byte-wise engine (REGEX-06) a match can start mid-character, and the index then counts as if at the character's start. That belongs to REGEX-06.
- **Impact:** None for this entry once REGEX-06 is fixed.
- **Suggested fix / next step:** None. Keep the elm-conformance repro (MEMORY: "Match.index" fixed Nov 3).

### BYTES-05: byte swaps ignore host endianness
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/bytes/BytesExports.cpp:183-217 (encoder writes: `if (be) bswap`), :487-489 (comment "The swap assumes a little-endian host"), :509-530+ (`read_i16`/`read_i32`/... `if (!le) bswap`). By contrast `getHostEndianness` :321-324 and E/bytes/Bytes.cpp:19-26 do detect the host order.
- **Original claim:** swaps conditioned only on requested order.
- **Analysis:** On a big-endian host every multi-byte read/write would come out byte-reversed. The code documents this assumption, and the runtime as a whole assumes little-endian anyway (e.g. runtime/src/allocator/BitmapScan.hpp:14, the HPointer bit-field layouts). Supported targets (x86-64, aarch64 Linux/macOS/Windows) are all LE.
- **Impact:** Latent only. Wrong Bytes encode/decode on a BE port.
- **Suggested fix / next step:** Add `static_assert(std::endian::native == std::endian::little)` in BytesExports.cpp (and the BF codegen) so a BE port fails at build time, or condition the swap on `requested != native`.

### HTTP-06: BadUrl_ string always empty
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** runtime/src/platform/HttpService.cpp:296-308 (`perform`: the `CURLE_URL_MALFORMAT` branch sets only `result.error = ErrorKind::BadUrl`); E/http/HttpExports.cpp:375-380 (`buildResponse` builds `BadUrl_ r.finalUrl`); `Result::finalUrl` at runtime/src/platform/HttpService.hpp:132.
- **Original claim:** HttpService fills only token/error, so the URL is never reported.
- **Analysis:** `finalUrl` is assigned only in the `CURLE_OK` branch (:299). For a malformed URL it stays default-constructed (""), so `buildResponse` allocates an empty String and Elm receives `Http.BadUrl ""`. elm/http JS reports the request URL (`__Http_BadUrl_(request.url)` when `xhr.open` throws). Reachable from any program that issues a request with a malformed URL. The GC handling in that branch is fine (`custom` roots its values, runtime/src/allocator/HeapHelpers.hpp:1330-1337). Related: curl codes such as `CURLE_UNSUPPORTED_PROTOCOL` map to `NetworkError`, where JS would usually give `BadUrl`.
- **Impact:** Error messages and handling that show the bad URL get "". This is a wrong value, not a crash.
- **Suggested fix / next step:** In `perform`, set `result.finalUrl = req.url;` before the error branches (or in the BadUrl branch). Consider mapping `CURLE_UNSUPPORTED_PROTOCOL` to BadUrl as well.

### HTTP-07: bytesToBlob parameter order swapped — **FIXED on master**: parameters are now (mimeType, bytes), and multipart serialisation reads BODY_BLOB
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** E/http/HttpExports.cpp:1010-1020 (`Elm_Kernel_Http_bytesToBlob(HPtr mimeType, HPtr bytes)`), E/KernelExports.h:777-778, multipart reader E/http/HttpExports.cpp:678-689.
- **Original claim:** `(bytes, mimeType)` vs stock mime-first.
- **Analysis:** Fixed. The signature is mime-first, matching elm/http's `Elm.Kernel.Http.bytesToBlob mime bytes` (Http.elm:387, JS `F2(function(mime, bytes)`). The blob Custom stores `[bytes, mime]` (:1017-1018). The form-data serialiser recognises a `Tag_Custom` with ctor `BODY_BLOB` and reads `values[1]` as mime and `values[0]` as bytes (:683-689), which is consistent. Both arguments are rooted across the allocation (:1015).
- **Impact:** None.
- **Suggested fix / next step:** None. An E2E multipart `bytesPart` test, if not already present, would pin it.

### HTTP-08: unresolved request returns Unit and never resumes
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/http/HttpExports.cpp:762-796 (`httpBindingEval`: `if (!ex.ok) return unit`), `extractRequest` :633-727 (`ok` set only after the record and its Expect resolve, :719-726).
- **Original claim:** when record/expect does not resolve, returns Unit.
- **Analysis:** `ex.ok` is false only if the request word or the `expect` field decodes to a constant/null. The request is an elm/http record with 7+ fields (always a heap object), and `Expect` is built by the kernel `expect` as a 3-field Custom (EXPECT_CTOR, :78-80), so it is never a constant. Both are guaranteed by the types for well-typed Elm, so the path is unreachable. The other Unit return (cancelled ticket, :777-780) is deliberate: the task was killed before it started.
- **Impact:** None reachable. If it were hit, the Task would hang silently.
- **Suggested fix / next step:** Optional: replace with an assert or `ecoFatal`, so a layout mismatch (e.g. after an elm/http field reorder) fails loudly instead of hanging.

### HTTP-09: HttpEffectManager uses unchecked field literals
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/http/HttpEffectManager.cpp:186 (`values[6]`, tracker read in the Request-cmd branch of the effect loop), E/http/HttpEffectManager.cpp:320-330 (`constexpr int kReqExpect = 2` in the cmd mapper); canonical constants E/http/HttpExports.cpp:116-128 (`REQ_BODY`..`REQ_URL`, file-`static`).
- **Original claim:** the effect manager duplicates the Request record slot indexes instead of using the REQ_* constants.
- **Analysis:** True. The `REQ_*` constants are `static constexpr` in HttpExports.cpp, so they cannot be seen from HttpEffectManager.cpp, which hard-codes 6 (tracker) and 2 (expect) and says in comments (:179-180, :318-319) that they "must agree" with `REQ_TRACKER`/`REQ_EXPECT`. The current values do agree: the record `{ allowCookiesFromOtherDomains, body, expect, headers, method, timeout, tracker, url }` has only boxed fields (Bool is boxed per REP rules, Maybe/String/List are boxed), so the slots follow name order: expect=2, tracker=6. Nothing checks that they agree, but there is no defect today.
- **Impact:** None now. If elm/http's internal Request record ever gained or renamed a field, the effect manager would read the wrong slot (a wrong tracker, or `mapExpect` applied to a non-Expect: type confusion) while HttpExports.cpp stayed correct.
- **Suggested fix / next step:** Move the REQ_* constants into a shared header (e.g. `http/HttpRequestLayout.hpp`) and use them in both files, or add a `static_assert` there.

### LIST-06: List.toArray accepts any heap object
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/ListExports.cpp:361-404, `Elm_Kernel_List_toArray`.
- **Original claim:** a heap object that is not a list gives a 0-length Array instead of an error.
- **Analysis:** The code does what the claim says. Constants (`[]`) and Cons/ConsChunk nodes are returned unchanged (:363-372). Any other heap object falls through to `listToVectorU64`, whose `ListCursor` stops at once (comment :374-375), so the result is an empty Array. The kernel is typed `List a -> Array a`, so well-typed Elm can only pass a list (Nil constant, Cons or ConsChunk). The fall-through needs a heap or codegen bug that is already present. The rooting on the fall-through path is correct (`pushStackRootRange` over `rooted`, :384-389).
- **Impact:** A miscompile could be masked rather than caught. Ordinary programs are not affected.
- **Suggested fix / next step:** Optional: replace the fall-through with `assert(false)` / `ECO_UNREACHABLE` in debug builds. No functional fix needed.

### LIST-07: sortBy constant keys all compare equal
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/ListExports.cpp:720-777, `Elm_Kernel_List_sortBy` comparator lambda (:760-770); E/core/Utils.cpp:282-285 (`cmp` null handling).
- **Original claim:** constant (embedded) keys are passed as null, so they all compare equal and the order is wrong.
- **Analysis:** A constant key is passed as `nullptr` (:764-767). `cmp` returns 0 for null vs null, 0 for null vs a zero-length heap String, and otherwise -1 for null vs non-null (Utils.cpp:283-285). The only embedded constants that a `comparable` key can be are `[]` and the empty String. Int/Float/Char keys come back from the closure boxed as heap objects, and tuples are heap objects. `[]` and `""` never meet in one sort, because all keys share one type. So the results are: `[]` vs `[]` is EQ (correct), `[]` vs a non-empty list is LT (correct, since `[]` is smallest), `""` vs `""` or a heap empty String is EQ (correct), and `""` vs a non-empty String is LT (correct). `std::stable_sort` keeps equal keys in their original order, as Elm does. No well-typed input gives a wrong order.
- **Impact:** None for well-typed programs. The design relies on a typing argument that the code does not state.
- **Suggested fix / next step:** None needed. Optionally document that only `[]` and `""` can be constant comparable keys.

### LIST-08: dead sortWith narrows i64 to int
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/List.cpp:49-84, `Elm::Kernel::List::sortWith` (cast at :81); also the dead `sortBy` at :23-47.
- **Original claim:** the comparator result is narrowed from i64 to `int`, so values that differ by a multiple of 2^32 read as equal; the code is dead.
- **Analysis:** `static_cast<int>(cmpFunc(elemA, elemB))` (:81) truncates an `i64`, so 2^32 reads as 0 (EQ) and 2^31 reads as negative. The code is really dead: a grep over all kernel, runtime and test trees finds no caller of `Elm::Kernel::List::sortWith` or `sortBy` (List.hpp:13 says so too). The live exports `Elm_Kernel_List_sortBy/sortWith` (ListExports.cpp:720/780) do not use them. The dead functions are also GC-unsafe: they hold raw `void*` from `resolve` across `allocInt`/`boxElement` and the closure call (List.cpp:29-37, 66-79). So they would be dangerous to revive.
- **Impact:** None while dead. Dead code that a later change could wire in.
- **Suggested fix / next step:** Delete `sortBy`/`sortWith` and their typedefs from List.cpp/List.hpp (see the DEAD-* entries).

### ARRAY-06: appendN with negative n copies whole source
- **Status:** WEAK · **Severity:** LOW
- **Where:** E/core/JsArrayExports.cpp:348-404 (`Elm_Kernel_JsArray_appendN`, cast at :349) and :981-1033 (`elm_array_append_n`, cast at :982; reached from `Elm_Kernel_JsArray_appendN_Int` :826).
- **Original claim:** a negative n is cast to `uint32_t` and becomes huge, so the whole source is copied.
- **Analysis:** The cast is real: `static_cast<uint32_t>(n)`. n = -1 becomes 0xFFFFFFFF, so `available` is large and `toCopy = srcLen`. An n of 2^32 or more is also truncated. elm/core's JS returns `dest.length + (n - dest.length)` elements in that case (fewer). But `Elm.JsArray` is an internal module that elm/core does not expose, and its only callers pass the constant `branchFactor` (32): ~/.eco/0.1.3/packages/elm/core/1.0.5/src/Array.elm:605 and :630. User code cannot reach this with any other n.
- **Impact:** None from Elm programs.
- **Suggested fix / next step:** Optional: clamp `n_signed < 0` to 0 before the cast, for JS parity and defence in depth.

### RUNTIME-01: loadState returns Nothing for a non-Maybe type — **FIXED on master**: loadStateBody returns JSON null when nothing is saved
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** K/Runtime.cpp:56-68, `loadStateBody`; Elm type K/../Eco/Runtime.elm:42 (`loadState : Task Never Encode.Value`).
- **Original claim:** with no saved state, loadState returns the `Nothing` constant although the Elm type is not Maybe.
- **Analysis:** The fix is in place. With no saved state the result is `succeed(hpFromBits(nullConsWordFor(JSON_ENC_NULL)))` (:63-67), the `Json.Encode.null` value (ENC_NULL = 0, matching E/json/JsonExports.cpp:129 and :2041). `Json.Decode` turns ENC_NULL into JSON null (JsonExports.cpp:1841-1843), so `Decode.null` accepts it. Side note: `Nothing` (null-cons index 0) and ENC_NULL have the same word, so the old code was bit-identical and the fix clarifies intent more than it changes behaviour. The header comment is now stale: K/KernelExports.h:327-328 still says "or with the `Nothing` constant when nothing has been saved".
- **Impact:** None remaining, apart from the stale doc comment.
- **Suggested fix / next step:** Update the KernelExports.h:327-328 doc comment to say "JSON null (`Json.Encode.null`)".

### FILE-04: Task Never wrappers over failing kernels
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/../Eco/File.elm:248-250 (`getCwd : Task Never String`), :271-273 (`appDataDir`); K/../Eco/Runtime.elm:21-23 (`dirname`); K/../Eco/MVar.elm:52-72 (`read`/`take`/`put`). Failing kernels: K/File.cpp:308-322 (`getCwdBody` → `failErrno`), :362-394 (`appDataDirBody` → `failString`), K/Runtime.cpp:33-39 (`dirnameBody` → `failString`), K/MVar.cpp:111-119 (`resumeNotFound` → `taskFailIO`, called from the read/take evaluators :141-145, :166-170 and put).
- **Original claim:** these are declared `Task Never` although their kernels can fail.
- **Analysis:** Confirmed. None of the Elm wrappers attaches a `mapError`, and each kernel can return a failing Task. The triggers are reachable: getCwd when the cwd has been deleted (ENOENT from `current_path`); appDataDir when `HOME` is unset (cron/systemd/containers); dirname when `currentExecutableDir()` is empty; MVar read/take/put after `drop` (`MVar.drop` is exposed). A failure of a `Task Never` cannot be handled in Elm. In the native scheduler a top-level failure prints "[eco-runtime] unhandled top-level Task.fail ... failure value dropped" and ends the process (runtime/src/platform/Scheduler.cpp:949-956), so the rest of the `andThen` chain never runs and `Task.perform` never delivers a message, which looks like a silent hang or no-op. Code that relies on the type, e.g. `Task.mapError never` (a common idiom: system-kernel-cpp/src/System.elm:266) or `onError (\n -> never n)`, would apply `Basics.never` to a String or tuple, which is type confusion (`never` pattern-matches `JustOneMore`). The XHR twin crashes instead, via `Eco.XHR.orCrash` (compiler/src-xhr/Eco/File.elm:24-26, :322-325), so the backends disagree.
- **Impact:** Programs silently stop or hang when the cwd is deleted, HOME is unset, or an MVar is used after drop. They could also reach type-confused execution through `mapError never`.
- **Suggested fix / next step:** Make the native kernels crash (`Debug.todo`-style / `eco_crash`) on these failures, matching the XHR `orCrash` contract. Alternatively change the Elm types to `Task IOError` and add `Task.mapError IOErr.ofKernelTuple`.

### FILE-05: appDataDir fails with a plain String
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:362-394, `appDataDirBody` (`failString` at :372 and :382); same pattern in K/Runtime.cpp:36 (`dirnameBody`).
- **Original claim:** the failure value is a raw String with no mapError.
- **Analysis:** True. Every other File body fails with the `(tag, path, message)` IO error tuple via `failErrno`, but appDataDir (and Runtime.dirname) fail with `failString`. Because the Elm type is `Task Never String` (Eco/File.elm:271), no decoder ever sees the value, so the wrong shape on its own does no harm: this is a sub-case of FILE-04. It would matter only if FILE-04 were fixed by retyping to `Task IOError` without also switching to `failErrno`/`taskFailIO`. `IOErr.ofKernelTuple` would then read a String as a Tuple3, which is a heap type confusion.
- **Impact:** Inconsistent failure shape. It becomes a type-confusion bug if the Elm type is changed later.
- **Suggested fix / next step:** Fix together with FILE-04: crash, or use `failErrno(ENOENT /* or 0 */, "", "HOME environment variable not set")`.

### CONSOLE-01: readAllBody drops leading empty lines
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/Console.cpp:106-116, `readAllBody`; contract K/KernelExports.h:210-213.
- **Original claim:** `"\n\nx"` becomes `"x"`; stdin data is lost.
- **Analysis:** The loop adds `'\n'` before a line only when `content` is non-empty (:110-112). Leading empty lines leave `content` empty, so their separators are never added: `"\n\nx"` gives `"x"`. Also, a final newline is always dropped (`"a\n"` gives `"a"`), and `"a\n\n"` gives `"a\n"`. The header documents this ("Empty lines before the first non-empty line are dropped", "no line break after the last"), so the code matches its doc. But the doc describes a bug: Elm's `Eco.Console.readAll` (Eco/Console.elm:68-73) promises "Read all of stdin as a string", and the XHR/JS backends return the bytes unchanged. Reachable by any program that pipes input with leading blank lines or a significant trailing newline, e.g. diffs, formatters that preserve whitespace, or hash/compare of stdin.
- **Impact:** Stdin content is silently changed (leading blank lines and the trailing newline lost), and the result differs from the JS/XHR backends.
- **Suggested fix / next step:** Read raw bytes (`std::cin.read`/`std::istreambuf_iterator`, or `read(0, …)` in a loop) and return them unchanged. Update the KernelExports.h doc.

### FILE-06: touch ignores open failure
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:426-446, `touchBody`.
- **Original claim:** only the time-set failure is reported.
- **Analysis:** `_eco_open(O_WRONLY|O_CREAT)` failure is ignored by design (:429-433); then `last_write_time` sets the time. Ignoring the open failure is right for an existing file that is read-only to us (we own it) or a directory (EISDIR), as touch(1) does. But when the file does not exist and cannot be created (EACCES on the parent, EROFS, ENOSPC, ENAMETOOLONG), the error reported is the one from `last_write_time`, normally ENOENT. That is classified `FileNotFound` instead of `PermissionDenied`/`NoSpaceLeft`.
- **Impact:** A misleading error class or message in edge cases. The operation still fails, so no silent success.
- **Suggested fix / next step:** Save `errno` from the failed open, and if `last_write_time` then fails with ENOENT, report the saved open errno.

### FILE-07: write functions ignore write errors
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/File.cpp:483-507 (`writeStringBody`: `file << data` at :502, no check), :510-541 (`writeBytesBody`: `file.write` at :535, no check), :645-667 (`hWriteStringBody`: a single `_eco_write` at :657, only `< 0` checked).
- **Original claim:** writeString/writeBytes ignore errors, and hWriteString does one `write` and ignores short writes.
- **Analysis:** Confirmed. `writeString` and `writeBytes` check only that the open succeeded. They never test the stream after `<<`/`write`, and errors on close or flush in the `ofstream` destructor (ENOSPC, EDQUOT, EIO, NFS close errors) are lost. They then return `succeedUnit()`. `hWriteString` does one `write()`. A short write (ENOSPC partway, a signal, or Linux's ~0x7ffff000-byte cap per write call) succeeds silently, and EINTR is reported as a failure instead of being retried. Compare `writeBytesAtomicBody` (:567-577) and Console `writeBody` (K/Console.cpp:75-90), which loop and check. This path is used by the compiler itself: `Builder.File.withStreamingWriter` (compiler/src/Builder/File.elm:436-449) writes generated output via `Eco.File.hWriteString`, called from compiler/src/Builder/Generate.elm:2106. So a full disk can silently truncate generated `.mlir`, and `writeString`/`writeBytes` users (caches) can be left with truncated files.
- **Impact:** Silent data loss or truncated output files, reported as success.
- **Suggested fix / next step:** Loop `write` until all is written, retrying EINTR. Check `file.flush()`/`file.close()` and `file.fail()` and return `failErrno(errno ? errno : EIO, …)`. Or reuse the writeBytesAtomic loop.

### PROC-03: spawnProcess ignores stdout_/stderr_
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Process.cpp:78-114, `spawnProcessBody` (:92-95 `(void)stdoutCfg; (void)stderrCfg;`); Elm side K/../Eco/Process.elm:42-44 (`StdStream = Inherit | CreatePipe`), :66-90.
- **Original claim:** a 'pipe' request for stdout/stderr is silently treated as inherit.
- **Analysis:** True. Only `stdin == "pipe"` is honoured (:97). For stdout and stderr the setting is read and thrown away, so the child always inherits them. The Elm API returns no stdout/stderr handle in any case (`{ stdinHandle, processHandle }`), so a `CreatePipe` for stdout could never be read. Its only visible effect would be to stop child output reaching the parent's terminal, and that does not happen. The compiler does not call `spawnProcess` (it appears only in KernelSetFacts.elm:1404).
- **Impact:** A caller asking for `CreatePipe` on stdout/stderr (e.g. to keep a child quiet) gets the child's output on the parent's streams. Nothing crashes and no data is lost.
- **Suggested fix / next step:** Either implement pipes and return handles, or remove the stdout/stderr fields (or fail on `CreatePipe`) so the API does not promise what it cannot do.

### FILE-08: readStringBody uses errno after ifstream failure
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:89-131, `readStringBody` (errno reads at :95, :102, :116); compare `readBytesBody` :134-170, which has the fixes.
- **Original claim:** there is no EIO fallback, so errno may be 0 and the error tag is built from 0.
- **Analysis:** True. `std::ifstream` does not promise to set errno. In practice libstdc++ open failures leave the errno from `open()`, so the open path (:94-99) usually works. But after `tellg() < 0` (:101-104) and after a short read (:115-120, e.g. the file shrank after sizing, which gives EOF with no errno), `errno` may be 0 or stale. `failErrno(0, …)` falls into the default tag of `ioErrorTagFromErrno` (K/KernelHelpers.hpp:99-), giving `OtherIOError`. A stale errno is worse: it can give a wrong class such as `FileNotFound` from an earlier failed syscall. `readBytesBody` has exactly these fixes (`err ? err : EIO` at :147 and :166). readStringBody also lacks readBytes's `> UINT32_MAX` size guard (:149-151); see FILE-NEW-1.
- **Impact:** A wrong or meaningless error class on rare read failures.
- **Suggested fix / next step:** Copy readBytesBody's `err ? err : EIO` fallbacks and its size check into readStringBody.

### FILE-09: findExecutable matches directories
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:200-205, POSIX `isExecutableCandidate` (`access(X_OK)`), used by `findExecutableBody` :209-252.
- **Original claim:** `access(X_OK)` is true for directories, so a directory can be returned as an executable.
- **Analysis:** True, and the comment at :200 admits it ("A searchable directory passes too"). If any PATH entry, searched in order, contains a directory with the requested name (e.g. a `~/bin/foo/` checkout before `/usr/bin/foo`), the result is `Just "<dir>/foo"`, and a later spawn fails with EACCES. The Windows version checks `is_regular_file`. Haskell's `findExecutable`, which this mirrors, also skips non-files.
- **Impact:** A wrong `Just` path in an unusual but plausible PATH layout, then a confusing spawn failure. A later executable of the same name in PATH is never found.
- **Suggested fix / next step:** Also require `std::filesystem::is_regular_file(p, ec)` (or `stat` + `S_ISREG`) on POSIX.

### FILE-NEW-1: readString of a directory or >4 GiB file is unguarded (huge allocation, abort)
- **Status:** UNSURE · **Severity:** MEDIUM
- **Where:** K/File.cpp:93-113, `readStringBody`.
- **Original claim:** (new) readStringBody has no size sanity check before `allocByteBufferBlank(size)`.
- **Analysis:** The function opens with `std::ifstream(path, binary|ate)` and allocates `tellg()` bytes. On Linux, `fopen` of a directory for reading succeeds, so `!file` does not catch it. `lseek(SEEK_END)` on an ext4 htree directory returns 0x7fffffffffffffff (EXT4_HTREE_EOF_64BIT), so `size` is about 2^63. `allocByteBufferBlank` → `allocLargeByteBuffer` (runtime/src/allocator/ThreadLocalHeap.cpp:521-552) then runs a minor GC and a major GC and calls `largeBodyExhausted` (fatal), instead of failing with `IsADirectory`. On tmpfs, `lseek` gives EINVAL, so the code takes the `sz < 0` path and works. readBytesBody is protected by its `> UINT32_MAX` → EFBIG guard (:149-151), though with the wrong class. A real file of 4 GiB or more in readString passes `size_t` into a `u32` length (`BlankByteBuffer.length`, `header.size` truncated at ThreadLocalHeap.cpp:529, `makeUtf8View(..., (u32)size)`), which gives a truncated String or a header that does not match the body.
- **Impact:** `File.readString "<some directory>"` may abort the whole process instead of returning `IsADirectory`. Depends on the filesystem.
- **Suggested fix / next step:** Test: call `Eco.File.readString` on a directory on ext4 and on tmpfs. Fix: `stat` first and fail with EISDIR for non-regular files, and add the UINT32_MAX guard (EFBIG) as readBytes has.

### PROC-NEW-1: Console.write to a spawnProcess stdin handle is a silent no-op
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/../Eco/Process.elm:63-65 (doc: "The stdin handle ID can be used with Console.write and File.close"); K/Console.cpp:65-72 (`writeBody`: any handle other than 1 or 2 → `return succeedUnit()`); K/Process.cpp:31, :103-106 (`s_streamHandles`, written but never read, cf. DEAD-17).
- **Original claim:** (new) the documented way to feed a child's stdin does nothing.
- **Analysis:** `spawnProcess` with `stdin = CreatePipe` returns `Just fd`, and the Elm doc tells users to write to it with `Console.write`. But `Console.writeBody` writes only to handles 1 and 2. For any other handle it writes nothing and reports success. The child sees no input and waits until the pipe is closed. `File.hWriteString (File.Handle fd)` does write to the descriptor, because `File.Handle(..)` is exposed, but nothing points the user there.
- **Impact:** Silent data loss: a child process fed through the documented API gets empty stdin, and the parent believes the write succeeded.
- **Suggested fix / next step:** Make `Console.write` write to any fd ≥ 3 (or to fds in `s_streamHandles`), or fail for unknown handles. Or fix the Process.elm doc to name `Eco.File.hWriteString`.

### FILE-10: empty PATH entry tests the name against cwd
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:209-251, `findExecutableBody` (loop at :230-248)
- **Original claim:** an empty PATH entry is treated as the current directory.
- **Analysis:** For an empty entry `dir` is `""` (:234), `dir / name` is the bare relative `name` (:236), and `access(name, X_OK)` (:203) checks the cwd. That matches the legacy POSIX/execvp rule. The handling is not consistent, though. A leading or middle empty entry (`:/bin`, `/a::/b`) is tested, but a trailing one (`/bin:`) is skipped, because the loop condition `pos < pathStr.size()` (:231) ends the loop once `pos = sep + 1` reaches the end. On a match the result is a bare relative name such as `foo`, not `./foo`, so a caller that later spawns it through a PATH search would not find the same file. `isExecutableCandidate` also accepts directories (:200-204). Callers reach this through `Eco.File.findExecutable` (eco-kernel-cpp/src/Eco/File.elm:211).
- **Impact:** an executable in the cwd can be found (or shadow one later in PATH) when PATH has an empty entry. A trailing `:` behaves differently from a leading one. The returned path is relative.
- **Suggested fix / next step:** decide on a policy: either skip empty entries (the safer choice), or treat every empty entry as `.`, including a trailing one, and return `./name`. Also reject directories.

### FILE-11: appDataDir accepts empty HOME on POSIX
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/File.cpp:362-393, `appDataDirBody` (POSIX branch :378-389)
- **Original claim:** an empty HOME produces `/.<name>`; Windows rejects the equivalent.
- **Analysis:** The POSIX branch checks only `!home` (:379). With `HOME=""` it returns `"" + "/." + name`, which is `/.eco` (:387) or `/Library/Application Support/eco` on macOS (:385). The Windows branch rejects empty values with `!*base` (:367-369). The compiler uses this for its home: Builder/Stuff.elm:496 falls back to `Utils.dirGetAppUserDataDirectory "eco"` when `ECO_HOME` is unset. With `HOME=""` (seen in some sandboxes and CI containers), eco then tries to create caches under `/.eco`. That fails with permission errors for normal users and writes to the root directory when run as root. There is no getpwuid fallback.
- **Impact:** confusing failures, or cache files written under `/`, when HOME is empty. The platforms behave differently.
- **Suggested fix / next step:** treat an empty HOME as unset (`if (!home || !*home)`), and optionally fall back to `getpwuid(getuid())->pw_dir`. See also ECO-NEW-1: the failure path itself is unsound.

### FILE-12: Windows strerror on non-errno codes
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** K/File.cpp:254-276 `listBody` (:262-265); the same pattern is in `removeDirBody` (:418) and `createDir` (:691); the tag mapping is in K/KernelHelpers.hpp:99-113 `ioErrorTagFromErrno`
- **Original claim:** `strerror(ec.value())` is used for Win32 codes.
- **Analysis:** The Windows preset builds with clang-cl against the MSVC STL (CMakePresets.json:95-107). There, `std::filesystem` reports Win32 codes in `system_category`. `listBody` passes `ec.value()` both to `strerror` (log only) and to `failErrno`, and `failErrno` maps the value through `ioErrorTagFromErrno` as if it were an errno. That is worse than a wrong message: the IOError **tag** comes out wrong. ERROR_PATH_NOT_FOUND (3) becomes ESRCH and so OtherIOError, not FileNotFound. ERROR_ACCESS_DENIED (5) becomes EIO and so Other, not PermissionDenied. ERROR_ALREADY_EXISTS (183) becomes Other, not AlreadyExists. Only ERROR_FILE_NOT_FOUND (2) matches ENOENT, by coincidence. `createDir` and `removeDir` include `ec.message()` in their message text, so their messages are right but their tags are still wrong. `list` has no `ec.message()`, so its message is just "could not open directory".
- **Impact:** on Windows, Elm code that branches on the IOError kind (not found, already exists, permission) takes the wrong branch. Windows is low priority (user rule).
- **Suggested fix / next step:** map with `ec.default_error_condition()` and compare against `std::errc` values, or map `std::errc` to the tag directly, in one helper used by every `std::filesystem` failure.

### HTTP-10: archive short read zero-padded
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Http.cpp:209-231, `buildGetArchiveResponse`
- **Original claim:** a short read is logged and the zero-padded content is returned.
- **Analysis:** `content.resize(st.size)` (:222) zero-fills the buffer. If `zip_fread` returns fewer bytes, or -1 on a CRC, decompression or unsupported-method error, the mismatch is only logged (:224-228) and the entry is still pushed (:231) with zero-padded or all-zero content. The return value of `zip_stat_index` (:210) is not checked either, so if it fails, `st.size` is uninitialized and the resize uses a garbage length. Two things limit the reach. The SHA-1 of the whole archive is checked against the registry hash (compiler/src/Builder/Deps/Details.elm:2537-2543). An archive that passes the hash but fails decompression needs a malformed upstream zip or a libzip build that lacks a compression method.
- **Impact:** silently corrupted package source files written to the package cache, in rare cases. A garbage `st.size` could cause a huge allocation or a crash.
- **Suggested fix / next step:** check `zip_stat_index(...) == 0` and `(st.valid & ZIP_STAT_SIZE)`. On `got != st.size`, fail the whole getArchive with `err("Failed to read zip entry ...")`.

### HTTP-11: getArchive ignores HTTP status
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Http.cpp:137-154, `buildGetArchiveResponse`
- **Original claim:** a 404 body is fed to libzip.
- **Analysis:** Only `r.error` is checked (:140). `r.status` is never looked at, so a 404 or 500 HTML body is hashed and passed to `zip_open_from_source`, which fails with "Failed to open zip archive" (:183-192). It is very unlikely, but a non-2xx body that happens to be a valid zip would be accepted, although the hash check in Details.elm:2539 still guards it. The error text never reaches the user anyway: Builder/Http.elm:290-303 maps every `Err` to the caller's `defaultError` (`PP_BadArchiveContent`).
- **Impact:** a misleading "bad archive content" error where "HTTP 404" would be right. Diagnostics only.
- **Suggested fix / next step:** return `err("HTTP <status>")` for a status outside 200-299 before hashing. Optionally keep the cause in Builder/Http.elm.

### HTTP-12: Windows SHA-1 shim limited to 4 GiB
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Http.cpp:37-51, the Windows `SHA1` shim
- **Original claim:** only the first 0xffffffff bytes are hashed.
- **Analysis:** `static_cast<ULONG>(len > 0xffffffff ? 0xffffffff : len)` (:47) truncates longer input. The return value of `BCryptHash` is also ignored, so on failure `out` is left uninitialized. The provider-open failure path returns an all-zero digest (:40-43). Package archives are far below 4 GiB, and the digest is compared against the registry hash, so a wrong digest only produces a hash mismatch error.
- **Impact:** practically unreachable. A failure would show as a false "bad hash" error, not a security hole.
- **Suggested fix / next step:** use `BCryptCreateHash`/`BCryptHashData` in a loop over ULONG-sized chunks and check the NTSTATUS. Low priority (Windows).

### TIME-05: Windows _timezone ignores DST
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/time/TimeExports.cpp:81-93, `getLocalTimezoneOffset` (else branch :89-92). Used by `timeHereBody` (:212-216) and `timeGetZoneNameBody` (:221-230)
- **Original claim:** no `_tzset`, so DST is ignored.
- **Analysis:** The non-Linux/macOS branch returns `-(_timezone / 60)`. `_timezone` is the standard-time offset, so DST is never applied (the comment at :79-80 says so). Nothing in the repository calls `_tzset` or `tzset` (grep over elm-kernel-cpp, eco-kernel-cpp, system-kernel-cpp and runtime/src finds nothing). In the UCRT, `_timezone` is only filled in by `_tzset`, which `localtime` and similar calls make implicitly. Before that it holds the CRT default of 28800 (UTC-8). So unless some earlier code happened to call a localtime-family function, `Time.here` on Windows returns UTC-8 whatever the real zone is. That is a wider bug than the DST one described.
- **Impact:** wrong local times for every Windows program that uses `Time.here`: off by one hour in summer, and possibly a constant UTC-8.
- **Suggested fix / next step:** on Windows, call `_tzset()` and then compute the offset as Linux does, from `localtime_s` plus `_mkgmtime` or `GetTimeZoneInformation` with the DST bias. A Windows test with TZ unset settles the UTC-8 question.

### TIME-06: any non-empty TZ becomes a Name
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/time/TimeExports.cpp:103-165, `getTimezoneName` (Linux :105-111, macOS :137-143, Windows :156-160)
- **Original claim:** POSIX TZ strings like `EST5EDT` are treated as zone names.
- **Analysis:** Any non-empty `TZ`, with one leading `:` stripped, is returned verbatim as `Name`. Examples: `PST8PDT,M3.2.0,M11.1.0`, `UTC0`, `CET-1CEST`, and file paths such as `/usr/share/zoneinfo/Europe/Paris` (the `:`-stripped form is also a path). `EST5EDT` happens to be a valid IANA link name, but the general POSIX form is not. JS (`Intl...resolvedOptions().timeZone`) returns a canonical IANA name, `Etc/Unknown`, or a UTC fallback. Programs that feed the name to a tz database lookup get garbage. The `/etc/localtime` symlink handling also fails for non-`zoneinfo/` paths, but that falls back correctly to `Offset`.
- **Impact:** `Time.getZoneName` reports a non-IANA name when TZ uses POSIX syntax or a path. This is uncommon.
- **Suggested fix / next step:** accept TZ as a Name only if it looks like an IANA id (no digits or `,`, or it resolves under the zoneinfo directory). Strip a `.../zoneinfo/` prefix from path forms. Otherwise fall through to `Offset`.

### TIME-07: duplicate intervals with different taggers
- **Status:** CERTAIN · **Severity:** HIGH
- **Where:** E/time/TimeEffectManager.cpp:243-266 (`onEffects` evaluator), with `IntervalState` holding one `taggerEnc` (:76-81) and the tick at :166-206
- **Original claim:** with duplicate intervals the last tagger wins, and only one message is sent per tick.
- **Analysis:** `requestedIntervals[interval] = taggerEnc` (:253) and `normalizedRequested[...] = taggerEnc` (:265) keep one tagger per interval and overwrite earlier ones. Each `IntervalState` stores a single tagger, and a tick applies only that one (:172, :204). Since the native gatherer delivers subscriptions in declaration order (runtime/src/platform/PlatformRuntime.cpp:463-467), the last-declared tagger wins. elm/core's `Time` manager builds `Dict Float (List (Posix -> msg))` and sends to every tagger on each tick. Duplicates are easy to reach: `Sub.batch [ Time.every 1000 Tick, Time.every 1000 Clock ]`, or two nested TEA components that each subscribe `Time.every 1000` through `Sub.map`, which is a common pattern.
- **Impact:** subscriptions silently get no messages. Ordinary programs produce wrong results without any error.
- **Suggested fix / next step:** store a list of encoded taggers per interval (scanned by the existing root scanner), and on each tick apply every tagger and send each message. First add an E2E test with two `Time.every` subscriptions on the same interval (expose-bug-first rule).

### DEBUG-01: Debug.todo exits without stderr/eco_crash
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/DebugExports.cpp:40-48, `Elm_Kernel_Debug_todo`; output routing at runtime/src/allocator/RuntimeExports.cpp:82-88
- **Original claim:** the message is written to a possibly captured stream, then `exit(1)` is called.
- **Analysis:** `eco_output_text` writes to `tl_output_stream` when one is set (RuntimeExports.cpp:83-84). That is the case under `startOutputCapture` (runtime/src/codegen/EcoRunner.cpp:98-103, the JIT test runner). The function then calls `exit(1)`, so the captured buffer is never flushed and the message is lost. Without capture it goes to stderr, so the standalone binary is fine. `eco_crash` (RuntimeExports.cpp:2791-2807) always writes to stderr and uses the `Elm runtime error:` prefix, so `Debug.todo` is reported inconsistently with other crashes. The symbol is live: it is registered at runtime/src/codegen/RuntimeSymbols.cpp:952.
- **Impact:** a `Debug.todo` that fires inside the JIT or test harness shows only exit status 1 with no message, which makes debugging harder.
- **Suggested fix / next step:** write with `fprintf(stderr, ...)` and `fflush`, or route through `eco_crash` with a built message.

### ABI-05: Browser_reload takes a C bool
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/browser/BrowserExports.cpp:36-40; declared at E/KernelExports.h:605; registered at runtime/src/codegen/RuntimeSymbols.cpp:993
- **Original claim:** this goes against REP_ABI_001 (Bool is `!eco.value`).
- **Analysis:** REP_ABI_001 (invariants.csv:9) says Bool crosses every kernel ABI as `!eco.value`. elm/browser calls `Elm.Kernel.Browser.reload False`, so the compiler passes a boxed True/False HPointer constant in a 64-bit register, and the C++ function reads only the low byte as `bool`. The body only does `assert(false)` and returns `HPtr(0)`, so the value is never used today. In release builds the asserts are compiled out (the `release` preset has NDEBUG), so `Browser.Navigation.reload` would return a null HPtr as its Cmd/Task and probably crash later.
- **Impact:** latent ABI mismatch. The function is a stub that is unusable natively anyway.
- **Suggested fix / next step:** change the signature to `HPtr skipCache`. Make the stub crash explicitly (for example `eco_crash` with "not supported natively") instead of using `assert`.

### DEAD-01: dead namespace APIs divergent from exports
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/browser/Browser.hpp:25-94 and Browser.cpp; E/core/Debug.hpp:20-23 and Debug.cpp:8-19; E/core/Char.cpp:7-16 (`fromCode`, `toCode`)
- **Original claim:** unused namespace APIs behave differently from the exports.
- **Analysis:** Nothing outside its own files references `Elm::Kernel::Browser::*` (grep over all kernels, runtime and test). `Browser::element/document/application` wrap `impl` in a Custom (Browser.cpp:8-18), while the exports return `impl` unchanged (BrowserExports.cpp:22-28). `Debug::log` writes to `std::cout`, `toString` returns `"<internals>"`, and `todo` throws `std::runtime_error` (Debug.cpp:8-19). The exports use the typed printer and exit. `Char::fromCode(int32_t)` truncates a 64-bit Int before its range check, so `0x100000041` would become `'A'`. The export checks the full i64 (CharExports.cpp:10-16, whose comment says so). `toCode` is trivially the same as the export. Only `Char::toLower/toUpper/...` are used by the exports, so `fromCode` and `toCode` are dead.
- **Impact:** none today. Anyone calling these later would get semantics that differ from Elm.
- **Suggested fix / next step:** delete `Browser.hpp/.cpp`, `Debug.hpp/.cpp` and `Char::fromCode/toCode`, and adjust CMake source lists. Run the exports' tests afterwards.

### PROC-04: ChildProcessManager does not reverse the command list
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/ChildProcess/ChildProcessManager.cpp:183-213 `onEffectsEval`; S/../ChildProcess.elm:591-596; runtime/src/platform/PlatformRuntime.cpp:399-500 `gatherEffects`
- **Original claim:** unlike Elm/JS `onEffects`, the native manager does not reverse the list, so batch spawn order differs.
- **Analysis:** The Elm `onEffects` reverses because the JS `_Platform_gatherEffects` conses and so delivers commands newest-first. The native gatherer does not: it `push_back`s each leaf in walk order (PlatformRuntime.cpp:463-467), and `listFromEncoded` (:311-316) keeps that order. The C++ manager therefore receives the commands in declaration order and spawns them in that order (:191-211), which is the documented behaviour ("in the order the commands were given", ChildProcess.elm:588-589). Not reversing is correct for the native runtime. Other native managers (TaskEffectManager.cpp:75, SystemManager.cpp:155) also process "in order". One related risk: any Elm-written effect manager that runs natively and does `List.reverse cmds` would get the order inverted. That is outside this entry.
- **Impact:** none for ChildProcess.
- **Suggested fix / next step:** none. Optionally add an E2E test that spawns two children in a `Cmd.batch` and checks the `onInit` order.

### PROC-05: kill on exited run with open output does nothing
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** S/ChildProcess/ChildProcess.cpp:464-473 `cancelRunByToken`, :506-512 `killJob`; compare with `runDurationEval` :247-258 and `advanceJob` :386-401
- **Original claim:** `Process.kill` waits until EOF or the timer fires.
- **Analysis:** `cancelRunByToken` calls `killJob`, which returns at once when `j->exited` (:508) without setting `killed` or calling `advanceJob`. If the child has exited but a grandchild still holds stdout or stderr open, the collector keeps reading. `advanceJob` wakes the collector only when `exited && !outputDone && killed` (:395), and `killed` is never set here. Only the runDuration timer path handles this case (:254-256). The Elm task is dead (the resume was taken), but the job, the collector thread, the pipes and the job's **hold** stay live until the grandchild closes the pipes or a runDuration timer fires. `cancelRunByToken` returns false, so the hold stays with the job (:464-466). Since the scheduler stays alive while holds are live (Scheduler.hpp:118-139), a program that kills such a run and then has nothing else to do does not exit. Without runDuration this could last indefinitely, for example when the child starts a daemon that inherits the pipes.
- **Impact:** the kill looks ineffective, resources leak, and the program can hang at quiescence.
- **Suggested fix / next step:** in `cancelRunByToken`, when `job.exited && !job.outputDone`, set `killed = true` and call `advanceJob(id)`, as `runDurationEval` does. Test: run `sh -c 'sleep 30 & exit 0'` without runDuration, kill the task, and assert that the program exits promptly.

### ECO-NEW-1: appDataDir fails a `Task Never`
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** K/File.cpp:373 and :382 (`failString` in `appDataDirBody`); eco-kernel-cpp/src/Eco/File.elm:271-273 (`appDataDir : String -> Task Never String`); compiler/src/Utils/Main.elm:1020-1022; Builder/Stuff.elm:496
- **Original claim:** (new) the kernel fails a Task whose Elm error type is `Never`.
- **Analysis:** When HOME is unset on POSIX (or APPDATA, USERPROFILE and HOME are all unset on Windows), the kernel returns a failed Task carrying a String. The Elm type promises `Never`, so no Elm code can handle it. `Task.andThen` chains skip, and the failure reaches whatever top-level handler runs a `Task Never`. Code that relies on `Never` being uninhabited (for example `never`, or `Task.onError` with a pattern over `Never`) then sees a String value. That breaks the type system's guarantee, and the program dies with an unclear error or misbehaves. The compiler reaches this path when `ECO_HOME` and `HOME` are both unset, for example in some systemd units and `env -i` runs.
- **Impact:** the type contract is unsound. With no home the compiler fails obscurely instead of giving a clear message.
- **Suggested fix / next step:** either change the Elm type to `Task IOError String` (or `Task String String`) and handle it in Stuff.elm, or crash with a clear message such as "HOME not set; set ECO_HOME". Check what the runtime does with a failed root `Task Never` (an `env -i` run of `eco make` would show it).

### CORE-07: failureFor(RunErr) drops the message
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/Core.cpp:118-126, `detail::failureFor` (case `ErrShape::RunErr`, line 123); documented as intended in S/Core/Core.hpp:186-191.
- **Original claim:** The exception message is thrown away for the RunErr shape.
- **Analysis:** `failureFor` builds `w` from `what`, and FErr and SErr both pass it on (`failFErr("EIO", w)`, `failSErr(1, w)`). RunErr calls `failRun(0, "EIO", -1, "", "")` and never uses `w`. The RunErr tuple `(kind, code, (exitCode, stdout, stderr))` (Core.cpp:96-110) has no message slot, but stderr is a Bytes slot that could carry it. The header says the drop is intended ("which drops `what`"). This path only runs when a ChildProcess-style kernel body throws (bad_alloc, std::exception) inside `ECO_SYSTEM_BODY_GUARD`/`ASYNC_GUARD(RunErr, ...)`.
- **Impact:** A kernel failure in a run-style Task shows up in Elm as a generic EIO with exit code -1 and empty output. It cannot be diagnosed, but the result is not wrong.
- **Suggested fix / next step:** Pass `w` as the stderr argument: `failRun(0, "EIO", -1, "", w)`.

### CORE-08: asyncFailure may complete a Task twice
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Core/Core.cpp:129-141, `detail::asyncFailure`; macro S/Core/Core.hpp:237-255. Example bodies: S/Stream/Stream.cpp:1180-1239 (`readImpl`) and Stream.cpp:1313-1394 (`writeOrEnqueue`).
- **Original claim:** The body may already have resumed before it threw, so the Task gets completed twice.
- **Analysis:** When an exception is caught, `asyncFailure` calls `takePendingResume(token)` and ignores the result. It then calls `callClosure1(resume, failTask)` no matter what, and then `releaseHold(token)` if `counted`. Nothing checks whether the token was already completed. Several bodies park the token and then call code that can complete that same token synchronously and can also throw:
  - `writeOrEnqueue`, in-memory path: `registerPendingResume`, then `pumpStream(id)` (Stream.cpp:1379-1381). `pumpCore` transforms the write, and `finishWrite`/`completeOk` resume it.
  - `readImpl`, MappedSource path: `parkResume` (counted), then `pumpStream(id)` at Stream.cpp:1237. `mapHead` plus step 1 of `pumpCore` (Stream.cpp:651-661) completes `parkedReadToken` with `completeOk`, which calls the resume and `releaseHold`.
  `drive()` deliberately rethrows exceptions after clearing the work list (Stream.cpp:578-602), so a throw from a later work item reaches the guard after the token was completed. The guard then resumes the same process again. `resumeEvaluator` (runtime/src/platform/Scheduler.cpp:452-466) has no once-only check, so it enqueues a second version with the failure root. The latest version wins, which turns a delivered success into a failure. With `counted`, the hold is also released a second time. That decrements `pendingAsync` twice (Scheduler.cpp:1102-1118), which can make the program look idle too early; in hold-census builds it is `holdFatal("second release of a hold")`. Realistic throw sources in these paths are only `std::bad_alloc` and the zlib init `runtime_error` (S/Stream/StreamCodec.cpp:272). Elm-side crashes inside callbacks are fatal, not thrown.
- **Impact:** Under OOM or a zlib init failure during a stream pump, a Task is resumed twice and its liveness hold is released twice. That gives a wrong result and possibly an early exit or a census abort.
- **Suggested fix / next step:** In `asyncFailure`, resume only when `token == 0` (nothing parked yet) or when `takePendingResume(token)` returned non-nil, and release the hold only in that same case. Test: a unit test that makes `pumpStream` throw after completing the parked token (fault injection in `transformCodec`).

### CORE-09: failureReason does not escape \x1f
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/Core.cpp:150-161, `failureReason`; decoder system-kernel-cpp/src/Stream/Internal.elm:83-97 (`decodeReason`).
- **Original claim:** origin and code are not escaped for the separator, so the fields can be parsed wrongly.
- **Analysis:** The lack of escaping is real and documented (Core.hpp:115-116). The message, the only free-text field, is safe, because `decodeReason` splits on `\x1f` and re-joins everything after the second field (`String.join "\u{001F}" rest`). Every C++ caller passes a constant origin ("socket", "tls", "websocket", "stream", "codec", or `failureOrigin()`). Codes come from constants, `errnoName`, OpenSSL error-code names, `ERR_WS_*` prefixes, or the text after "read "/"write " in Conn.cpp:674-773, which is itself `errnoName` or `transport_->errCode`. None of these sources can contain `\x1f`. Elm-built reasons go through `encodeFailure` in Elm, not this function.
- **Impact:** None reachable today. A future caller that passes free text as `code` would split the fields wrongly.
- **Suggested fix / next step:** Optional: assert, or strip `\x1f` from `origin`/`code`.

### WS-01: binary body announcement flagged as text
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:588-592, `WsCore::deliverReads` (`r.text = m.tag != 2`); announcement built in `startBody` (WsProtocol.cpp:402-418).
- **Original claim:** `text` is set to true for tag 4 (binary body), so binary messages are marked as text.
- **Analysis:** For tags 3 and 4 the readable's chunk is not the payload. It is the announcement, whose bytes are the decimal stream-pair id of the body (WsProtocol.hpp:21-23). That id has to arrive as a String: `wireTuple` (Stream.cpp:826-832) puts text chunks in the String slot, and `fromWireStreamed ( tag, bodyId, _ )` (WebSocket.elm:1469-) reads the id from that slot and uses tag 4 to choose Binary. If `text` were false, the id would land in the Bytes slot and the body id would read as 0. Whether the body itself is text or binary is set separately by `body_->text` (WsProtocol.cpp:405, 502).
- **Impact:** None. The code is right; the comment could say why tag 4 is text.
- **Suggested fix / next step:** Add a comment at line 590.

### CORE-10: Registry insert of a mapped id keeps old entry
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/Registry.hpp:78-83, `Registry::insert`.
- **Original claim:** `insert` returns the id while keeping the old entry, so the caller believes the insert succeeded.
- **Analysis:** `insert` uses `m_.emplace(nextId_++, e)` and ignores whether the emplace happened. A collision needs an id that was placed directly through `map()` (documented at Registry.hpp:67-69). Every `map()` use only iterates (Stream.cpp:642, ChildProcess.cpp:468, 516), and all 11 registries add entries only through `insert`. `nextId_` survives heap resets, so ids from `insert` never collide with each other.
- **Impact:** Unreachable with current callers.
- **Suggested fix / next step:** Optional `assert(inserted)` on the emplace result.

### CORE-11: re-adding a drain keeps the first ready
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/AsyncSources.cpp:58-65, `addDrainSource`.
- **Original claim:** Adding the same drain again silently keeps the first `ready` callback, so the new one is ignored.
- **Analysis:** Duplicates are matched on `drain` only, so a different `ready` would be dropped. But all 11 call sites (ChildProcess.cpp:485-486, ChannelDrain.cpp:59, WsEvents.cpp:80, SysWorkPool.cpp:43, SocketEvents.cpp:87, FileSystemManager.cpp:206, SignalService.cpp:193, HttpTables.cpp:394, HttpStream.cpp:242) pass fixed function-pointer pairs, and each drain is always paired with the same ready predicate. Repeated adds (for example FileSystemManager's "idempotent" one) are meant to be idempotent.
- **Impact:** None with current callers.
- **Suggested fix / next step:** Optional `assert(s.ready == ready)` in the duplicate branch.

### WATCH-02: renamed sub-dir keeps stale relative path
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/WatchService.cpp:201-210 (`addDir`), 283-286 (`mapInotify`), 214-227 (`addTree`).
- **Original claim:** Paths are not updated after a directory is renamed.
- **Analysis:** inotify watch descriptors belong to inodes. When a watched sub-directory `a` is renamed to `b` inside a recursive watch, the parent reports IN_MOVED_FROM `a` and then IN_MOVED_TO `b` with IN_ISDIR. `mapInotify` calls `addDir(id, root/b, "b")`. `inotify_add_watch` on the same inode returns the same wd, `addDir` finds an existing use for this watch id, and it returns true at line 206 without updating `rel`. `addTree` does the same for every descendant. Nothing on IN_MOVED_FROM removes or renames the old use. All later events inside the directory are reported as `a/...` (line 282 uses `u.rel`). Reachable from any `FileSystem.watchRecursive` program in default inotify mode on Linux. Poll mode is not affected, because it re-snapshots paths.
- **Impact:** Events after a directory rename carry paths that no longer exist, so the program may react to the wrong file or ignore real changes.
- **Suggested fix / next step:** In `addDir`, when this watch already uses the wd, overwrite `u.rel` (and the descendants' rels by prefix). Alternatively, on IN_MOVED_FROM|IN_ISDIR drop this watch's uses whose rel is the old path or under it. Test: watchRecursive, `mkdir a; mv a b; touch b/x`, expect the path `b/x`.

### WATCH-03: directory moved out keeps reporting
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/WatchService.cpp:249-290, `mapInotify` (line 276 skips sub-directory self events; nothing handles IN_MOVED_FROM|IN_ISDIR or IN_MOVE_SELF for sub-directories).
- **Original claim:** The watch is not dropped when a directory leaves the tree, which causes spurious events.
- **Analysis:** When a watched sub-directory is moved outside the watched root, its inode lives on, so the kernel keeps its wd and sends no IN_IGNORED. The parent's IN_MOVED_FROM is reported, but no use is removed. The sub-directory's IN_MOVE_SELF is skipped at line 276 (`self && !u.rel.empty()`). Every later change inside the moved directory, now outside the tree, is still reported under its old relative path. Only deleting the directory (IN_IGNORED, lines 253-265) cleans up. Reachable in default inotify mode with any recursive watch.
- **Impact:** Spurious events for files outside the watched tree, under paths that no longer exist there. The wd and its table entries also leak until the watch is removed.
- **Suggested fix / next step:** On IN_MOVED_FROM with IN_ISDIR (or the sub-directory's IN_MOVE_SELF), drop this watch's uses of that rel and below with `dropWd(..., rmWatch=true)`. Test: `mv watched/sub /tmp/elsewhere; touch /tmp/elsewhere/x` should give no event.

### WATCH-04: inotify vs poll disagree on symlinked root
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/WatchService.cpp:395-399 (`add`, inotify) against 69-71, 88-93 (`sigOf`/`takeSnapshot`, poll).
- **Original claim:** inotify follows a symlinked root while poll `lstat`s it.
- **Analysis:** `inotify_add_watch` is called without IN_DONT_FOLLOW (kMask, lines 159-160), so a root that is a symlink to a directory is watched as that directory. `addTree`'s `recursive_directory_iterator(abs)` also opens the root through the link. Poll mode's `takeSnapshot` uses `lstat` (line 71). For a symlink root `rootSig.type` is S_IFLNK, it returns after recording the link alone (line 93), and changes inside the target directory are never reported. Poll mode is the only backend on macOS and other non-Linux POSIX systems (line 379), and on macOS common paths such as `/tmp` and `/var` are symlinks.
- **Impact:** On macOS, or with ECO_SYSTEM_WATCH_POLL set, watching a symlinked directory reports nothing about its contents, while Linux reports everything.
- **Suggested fix / next step:** Resolve the root once with `stat`/`realpath` in `add` (or use `stat` for the "" entry in `takeSnapshot`), and keep `lstat` below the root. Test: in poll mode, watch a symlink to a directory and touch a file inside it.

### WATCH-05: poll-mode vanished root events
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/FileSystem/WatchService.cpp:336-354, `pollThread`.
- **Original claim:** Poll mode gives one pathless Moved when the root vanishes, and a Moved for every entry when it reappears.
- **Analysis:** When the root disappears and `old` is non-empty, one pathless Moved is queued and `old` becomes the empty snapshot (line 354). While the root stays missing, nothing is reported, because `old` is empty and `now` is empty. When it reappears, every entry in `now`, including `""` (the pathless root) and every file in the tree, has no match in `old` and is reported as Moved (line 344-345). inotify mode behaves differently: the root's IN_DELETE_SELF/IN_IGNORED drops the wd and the watch goes silent for good, so a reappearance is never reported. The poll behaviour is consistent (those entries did appear), but it is noisy and differs from inotify.
- **Impact:** Floods of Moved events when a watched tree is recreated, for example by an atomic directory swap or `rm -rf` plus re-checkout, and behaviour that depends on the backend.
- **Suggested fix / next step:** Decide one semantic. Either stop the poll watch after the vanish event (to match inotify), or report a single pathless Moved on reappearance and seed `old` silently.

### WATCH-06: failed inotify add consumes an id
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/WatchService.cpp:393-398, `WatchService::add`.
- **Original claim:** The id is allocated before the add succeeds, which leaves gaps in the ids.
- **Analysis:** True as described: `nextId++` happens before `addDir`, and on failure the id is discarded. Poll mode allocates after success. The contract (WatchService.hpp:63-66) only promises ids greater than 0 that are never reused, and a gap breaks neither. The `iwatches[id]` entry is erased on failure, so nothing leaks.
- **Impact:** None beyond cosmetic gaps in the ids.
- **Suggested fix / next step:** Optional: allocate the id after `addDir` succeeds (that needs `addDir` to take a provisional id).

### WS-02: abandonMessage drops window under context takeover
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsDeflate.cpp:128-134 (`Inflater::abandonMessage`), called only from `WsCore::abandonRx` (WsProtocol.cpp:392-398).
- **Original claim:** The window is discarded even with context takeover, so later messages decompress wrongly.
- **Analysis:** `abandonMessage` does `inflateReset`, which drops the window; the header says so on purpose (WsDeflate.hpp:137-140). Every caller of `abandonRx` is a point after which no more data messages are inflated:
  - a Close frame received (WsProtocol.cpp:198-204, then `endReadable`);
  - `readShutdown` in whole mode, after `decoder_.setDiscardData(true)` (WsProtocol.cpp:630-633);
  - `queueGracefulClose`, after `setDiscardData(true)` (1007-1012);
  - `failWith` (`inputDone_ = true`, 1070);
  - `ended` (1095).
  Discarding is never turned off (`setDiscardData(true)` is the only call). The streamed `readShutdown` case keeps inflating and does not abandon.
- **Impact:** None reachable. No later message is inflated after an abandon.
- **Suggested fix / next step:** None. If a non-terminal caller is ever added, it must use `resetStream(!noContext_)`.

### WS-03: deflate stream never reset after failure
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsDeflate.cpp:40-71 (`Deflater::chunk`/`message`); callers S/WebSocket/WsProtocol.cpp:756-762 and 817-822.
- **Original claim:** There is no reset after a deflate failure, so subsequent compressions are broken.
- **Analysis:** Both callers react to a false return from `chunk`/`message` with `failConnection(kCloseInternalError, "compression failed")` and return. `failWith` sets `writeClosed_` and `failQueued`, so nothing is compressed on that connection again. Each connection has its own `deflater_`. A failure is also practically impossible: deflate with valid parameters only fails on init OOM.
- **Impact:** None. The connection is failed anyway.
- **Suggested fix / next step:** None.

### WS-04: resetStream drops window on inflateGetDictionary failure
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsDeflate.cpp:115-126, `Inflater::resetStream`.
- **Original claim:** The window is lost when fetching the dictionary fails, which desynchronises the stream (rarely).
- **Analysis:** `inflateGetDictionary` returns only Z_OK or Z_STREAM_ERROR, and Z_STREAM_ERROR means a null or uninitialised stream. `resetStream` returns early when `!z_->init` (line 116), so with an initialised stream the call cannot fail. The 32 KiB buffer is the maximum for the 15-bit inflate window (`inflateInit2(..., -15)`, line 92), so it is never too small.
- **Impact:** None in practice.
- **Suggested fix / next step:** Optional: treat a non-Z_OK result as an Error step instead of silently continuing.

### WS-05: setDiscardData mid-message leaves state
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsFrame.cpp:174-180 `WsDecoder::setDiscardData`; frame loop `WsDecoder::feed` :265-271, :316-323; callers S/WebSocket/WsProtocol.cpp:285 (`onDataEnd`), :630 (`readShutdown`), :1007 (`queueGracefulClose`)
- **Original claim:** Turning discarding on mid-message leaves `inMessage_`/`utf8_` set, giving a truncated message or an unmatched `onDataEnd`.
- **Analysis:** Leaving `inMessage_` set is what keeps framing correct: the rest of the message's continuation frames are still accepted (:221), and the FIN frame clears `inMessage_` (:317). After that, `if (discard_) continue;` (:320) skips `onDataEnd`/`onMessage`. A stale `utf8_` does no harm, because it is reset when the next data message starts (:229). No caller ever calls `setDiscardData(false)` (all three call sites pass `true`), so the "discard turned off mid-message, then a truncated message is delivered" case cannot happen. The missing `onDataEnd` after an `onDataStart` in raw mode is handled by the callers. `queueGracefulClose` (:1008-1012) and `readShutdown` (:631-633, Whole mode) call `abandonRx()`/`bodyFail`. Streamed `readShutdown` with a message in progress does not discard at all. It sets `discardAfterMessage_` and turns discarding on only inside `onDataEnd` (:281-285), after the message ends.
- **Impact:** None reachable. The only risk is a future caller that turns discarding off mid-message.
- **Suggested fix / next step:** Optionally document (or assert) in WsFrame.hpp that discarding is one-way, or reset `utf8_`/`message_` on an off-transition.

### WS-06: setAllowRsv1 without raw mode delivers compressed
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsFrame.hpp:222-225; WsFrame.cpp:203, :226, :288-298, :329-331; S/WebSocket/WsProtocol.cpp:81-84 (`WsCore::WsCore`)
- **Original claim:** With RSV1 allowed but raw mode off, a compressed payload is passed through as an ordinary message.
- **Analysis:** In the pure decoder the hazard is real: Whole mode ignores `msgCompressed_` and calls `onMessage` with deflated bytes (:329-331), after running UTF-8 validation on compressed data (:292). It cannot happen in practice. The only production construction, WsProtocol.cpp:82-83, sets `setRawData(streamed || deflate)` and `setAllowRsv1(deflate)`, so RSV1 is allowed only when raw mode is on. The entry itself says it is unreachable.
- **Impact:** None today. It is a latent API trap for a new user of `WsDecoder`.
- **Suggested fix / next step:** Make `setAllowRsv1(true)` imply raw mode, or assert `raw_` in `startFrame` when `msgCompressed_`.

### WS-07: non-positive message limit rejects all messages
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WebSocket.cpp:450 (`cfg.maxMessage = maxMsg > 0 ? ... : 0`); WsFrame.cpp:234; WsProtocol.cpp:312
- **Original claim:** `maxMessage = 0` (from a non-positive Elm value) makes every non-empty message fail with 1009.
- **Analysis:** True, and intended and documented in three places. WsFrame.hpp:204-205 says "A `maxMessage` of 0 fails every checked data frame with a non-empty payload; it is not 'no limit'". The public Elm doc, system-kernel-cpp/src/WebSocket.elm:884-886, says "A value of 0 or less accepts only empty messages. It does not apply to a streamed connection". Streamed mode passes `UINT64_MAX` (WsProtocol.cpp:81).
- **Impact:** Documented behaviour, not a defect.
- **Suggested fix / next step:** None. Possibly close as by-design.

### STREAM-02: input after flush lost
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/StreamCodec.cpp:110-131 `deflateRun`, :283-295 `codecTransform`, :312-319 `codecFlush`; caller S/Stream/Stream.cpp:521-536 (pump step 4), :1324-1326 `writeOrEnqueue`
- **Original claim:** Input given after a flush is silently lost because Z_BUF_ERROR is reported as success.
- **Analysis:** `codecFlush` runs only in pump step 4, when `w == Closing` and `writeQ`/`waitingForRoom` are empty (Stream.cpp:521). New writes are refused once the writable side is Closing or Closed (Stream.cpp:1324-1326). So no input can reach a codec after its flush. Even if it did, it would not be lost silently. zlib's `deflate()` returns Z_STREAM_ERROR for any non-Z_FINISH call in FINISH_STATE, which is turned into an error (:120). An inflater that has ended rejects extra input with "Junk found..." (:141-142). The only Z_BUF_ERROR→success path is :125, in finish mode with `have == 0` and `avail_in == 0`, where "no progress possible" is the correct reading. In `inflateRun`, Z_BUF_ERROR (:151) is zlib's normal "needs more input" result.
- **Impact:** None reachable.
- **Suggested fix / next step:** None needed.

### STREAM-03: concatenated gzip members rejected
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Stream/StreamCodec.cpp:141-143, :153-155 `inflateRun`
- **Original claim:** Gunzip stops after the first gzip member and rejects the rest.
- **Analysis:** On Z_STREAM_END the codec sets `zEnded`. Any remaining or later input then returns "Junk found after end of compressed data." and the stream fails. There is no `inflateReset` for a following gzip member, so a valid multi-member file (RFC 1952 §2.2, e.g. `cat a.gz b.gz`, as produced by pigz/bgzip) fails. This matches the WHATWG DecompressionStream approach (trailing data is an error), and the behaviour is documented in system-kernel-cpp/src/Stream/Transformation.elm:279-282 ("the native backend fails the transformation").
- **Impact:** Multi-member gzip input, such as concatenated logs or BGZF, cannot be decompressed. The behaviour is deliberate and documented.
- **Suggested fix / next step:** If wanted: for `kCodecGzip` only, after Z_STREAM_END with input left, call `inflateReset` and continue when the next bytes are `1f 8b`. Otherwise close as by-design.

### TLS-04: bad SSL_CERT_FILE disables good SSL_CERT_DIR
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Tls/TlsContext.cpp:80-91 `makeSystemContext`
- **Original claim:** When `SSL_CERT_FILE` fails to load, the `SSL_CERT_DIR` load is skipped.
- **Analysis:** One call, `SSL_CTX_load_verify_locations(ctx, file, dir)`, loads both, and its result is discarded (:88). In OpenSSL 3.x that function returns 0 as soon as `SSL_CTX_load_verify_file` fails, before it calls `SSL_CTX_load_verify_dir`. So an unreadable or garbage `SSL_CERT_FILE` silently drops a valid `SSL_CERT_DIR`, and every handshake then fails verification. The code comment admits it (:86-87, "a file that fails to load stops the directory being added"). A related point: setting only `SSL_CERT_FILE` also drops OpenSSL's default directory, and setting only `SSL_CERT_DIR` drops the default bundle. OpenSSL's own `X509_STORE_set_default_paths` honours each variable separately. The trigger is a misconfigured environment, so this is an edge case.
- **Impact:** All `SystemCertificates` TLS connections fail with a CERT_* verify error. Reproducing it needs a bad env var plus a good directory.
- **Suggested fix / next step:** Call `SSL_CTX_load_verify_file` and `SSL_CTX_load_verify_dir` separately, each guarded by its own non-null check, ignoring each failure.

### TLS-05: ERR_SSL_NO_CERTIFICATES likely unreachable
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Tls/TlsContext.cpp:138-153 `makeTrustedContext`
- **Original claim:** The `ERR_SSL_NO_CERTIFICATES` rename path is probably never taken.
- **Analysis:** The rename happens only when `tlsTakeError` finds an empty queue (code `ERR_SSL_UNKNOWN`, :267). When no certificate is added, the read loop ends because `PEM_read_bio_X509` failed, and that call pushes `PEM_R_NO_START_LINE` (or an ASN1/base64 error for a corrupt block) onto the queue. `ERR_get_error` returns the earliest error, so the code becomes e.g. `ERR_SSL_NO_START_LINE`, even for an empty PEM string. The only way to reach `added == 0` with an empty queue is `X509_STORE_add_cert` failing without queueing an error. That does not happen for duplicates (OpenSSL ≥1.1.1 returns 1). The Elm docs advertise "NO_CERTIFICATES" as an example code (system-kernel-cpp/src/Socket/Tls.elm:328, Http/Server.elm:861), so a program matching on it would never match.
- **Impact:** A dead branch, and a documented code that is never produced. Users see `ERR_SSL_NO_START_LINE` instead.
- **Suggested fix / next step:** When `added == 0`, always set `ERR_SSL_NO_CERTIFICATES` (keep the OpenSSL text in the message). A unit test calling `buildTlsClientConfig(1, "", ...)` would confirm the current code.

### TLS-06: ERR_SSL_ prefix on all libraries' errors
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Tls/TlsContext.cpp:265-274 `tlsErrorCode`
- **Original claim:** Errors from non-SSL OpenSSL libraries (PEM, X509, ASN1, EVP) get an ERR_SSL_ code.
- **Analysis:** The code is always "ERR_SSL_" plus the upper-cased reason string, whatever the library (`ERR_GET_LIB` is never looked at). A PEM parse failure becomes `ERR_SSL_NO_START_LINE`, where Node would say `ERR_OSSL_PEM_NO_START_LINE`. This is the documented design (TlsContext.hpp:38, :123-124). The uniform prefix is also what the Elm side's classification relies on (Http/Server.elm:928 `String.startsWith "ERR_SSL_"`; Eco/Kernel/Stream.js:257).
- **Impact:** Codes are cosmetic and differ from Node's. There is no functional failure.
- **Suggested fix / next step:** Leave as is, or map non-SSL libraries to `ERR_OSSL_<LIB>_` and update the Elm classifiers in the same change.

### TLS-07: unknown verify modes treated as 0
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Tls/TlsContext.cpp:307-337 `buildTlsClientConfig` (switch `default:` :327)
- **Original claim:** Unknown verify modes are not rejected, so verification may be weaker than requested.
- **Analysis:** Any mode other than 1 or 2 gets the mode-0 system-certificate context with `SSL_VERIFY_PEER`, and `cfg->verify = mode != 2` is true (:316). Unknown modes therefore get full verification against system roots, which is not weaker than any mode. Only the exact value 2 disables verification. The mode comes from the Elm `Verification` custom type, which the Elm code encodes as 0/1/2, so other values cannot occur from well-typed Elm.
- **Impact:** None. It fails safe.
- **Suggested fix / next step:** Optionally reject an unknown mode with EINVAL for clarity.

### TLS-08: failed send error overwritten by reads
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Tls/TlsTransport.cpp:115-153 `TlsTransport::read`, :277-308 `sendOut`, :313-332 `fill`, :374-387 `protocolFailed`; consumer S/Socket/Conn.cpp:727-730 `writeFailed`
- **Original claim:** A later read overwrites the stored error of a failed send.
- **Analysis:** `read()` calls `sendOut()` "best effort" (:119). If the send fails, `broken_` is set and `failErrno(EPIPE/ECONNRESET)` records `errCode`/`errNo`, but `read()` carries on. A later `fill()` recv error (:329) or `protocolFailed` (:374) overwrites `errCode`/`errNo` in the shared `Transport` fields. The next `write()` returns -2 because `broken_` is set (:160), and `Conn::writeFailed` builds `writeErrReason_` from whatever is stored now (Conn.cpp:728-730). So the write failure is reported with the read's code (e.g. "write ECONNRESET" or an ERR_SSL_ code, where "write EPIPE" was the real cause). It only happens when both directions fail around the same time, and the substituted error is usually just as plausible.
- **Impact:** The error code in a write failure can be wrong. Nothing else is affected.
- **Suggested fix / next step:** Keep a separate `sendErr` captured in `sendOut`, and report it from `write`/`flush` when `broken_` is set.

### TLS-09: failing flush ends shutdown without SHUT_WR
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Tls/TlsTransport.cpp:199-213 `shutdownWrite`, :228-251 `flush`
- **Original claim:** A flush whose send fails ends the shutdown without `::shutdown(SHUT_WR)`, so the peer never sees EOF.
- **Analysis:** True as written: on `broken_` or `sendOut() < 0`, `shut_ = Done` and -2 is returned, and `SHUT_WR` is never called (:230-242). But `broken_` is set only after `::send` fails with a hard error (EPIPE, ECONNRESET, ...; :301). At that point the TCP write side is already shut or the connection reset, so a FIN cannot be delivered anyway. The connection is then failed and the fd closed by `Conn` (writeFailed / flushPending → closeNow). Close of the fd sends whatever FIN or RST is still possible. The failure is reported to the caller through `finishShutdown(writeErr_)` (Conn.cpp:716-722).
- **Impact:** None practical. The peer already sees a reset or broken connection.
- **Suggested fix / next step:** None. Optionally call `::shutdown` best effort and ignore its result.

### STREAM-04: pipe failures always report Cancelled
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/StreamPipe.cpp:116-139 `finishPipe` (:135), :200-215 `streamRunPipe`; Elm decoder system-kernel-cpp/src/Stream.elm:599-623 `decodeError`
- **Original claim:** `pipeTo` completes with `Cancelled` even when `src` failed, so the real error is lost.
- **Analysis:** The kernel always uses kind `kSErrCancelled`, but it passes the original reason string (`s->rReason` :211, `d->wReason` :194/:202, or the `\x02`-marked `kWritableClosed` :50). Elm `decodeError` treats kind 1 only as a carrier. It decodes the marked reason, so a resource failure becomes `Failed failure`, an ended/closed reason becomes `Closed`, and only a program reason becomes `Cancelled text` (Stream.elm:610-623). This matches the `pipeTo` documentation (Stream.elm:682-694). The real error is kept.
- **Impact:** None. This is a misreading of the kernel/Elm error encoding.
- **Suggested fix / next step:** None.

### STREAM-05: createPipe accepts a closing dst
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/StreamPipe.cpp:143-159 `createPipe`, :200-207 `streamRunPipe`, :312-355 kernel bodies
- **Original claim:** A `dst` that is already Closing or Closed is accepted, giving a pipe to a dead sink.
- **Analysis:** The pipe is created, but on its first run the `d->w != WState::Open` step (:201-207) fails it at once. `pipeTo` gets `kWritableClosed`, which decodes to `Closed`, or `dst`'s Errored reason, and `src` is cancelled from its reading side. This is exactly the documented contract (Stream.elm:688-691: "or it is already closed or being closed when the pipe starts, the readable side is cancelled ... the Task fails with ... `Closed` for a closed one"). For `pipeThrough`, later failures are documented as unreported (Stream.elm:659-661). The pipe's `pipedIn` and `pipeRefs` are released in `finishPipe`.
- **Impact:** None. This is the documented behaviour.
- **Suggested fix / next step:** None.

### STREAM-06: pipeStreams/pipeThrough succeed for unknown ids
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/StreamPipe.cpp:296-304 `pipeStreams`, :312-330 `streamPipeThroughBody`, :186-254 `streamRunPipe`; erasure rule S/Stream/Stream.cpp:243-253 `maybeErase`
- **Original claim:** No id validation, so a pipe on unknown ids is a silent no-op.
- **Analysis:** It is not a no-op, and a missing id has a defined meaning. A pair is erased only when both sides are Closed, its queues are empty and no pipe refs remain (Stream.cpp:246-249). So a missing id means "ended", and `streamRunPipe` treats it that way. A missing `dst` fails the pipe with Closed and cancels `src` (:201-206). A missing `src` counts as closed-and-drained and closes `dst` (:247-253). The only other source of a stale id is a heap-generation reset, which clears all tables. Elm ids come from opaque `Readable`/`Writable` handles, so arbitrary ids cannot come from well-typed Elm. `pipeThrough` succeeding at once is its documented contract. The C++ caller (HttpStream.cpp:262) checks the read lock and runs this path deliberately.
- **Impact:** None.
- **Suggested fix / next step:** None.

### HTTPS-01: HttpStream unknown stream id not rejected
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpStream/HttpStream.cpp:244-263 (`httpStreamSendBody`); S/Stream/StreamPipe.cpp:296-303 (`pipeStreams`)
- **Original claim:** a stream body whose id names no stream is not validated.
- **Analysis:** `httpStreamSendBody` checks only `src && streamReadLocked(src)` (HttpStream.cpp:245-246). A null `find` falls through to `pipeStreams(streamId, sink)` (:262). `pipeStreams` treats a missing `src` as one that has ended (Stream.hpp:127-130, StreamPipe.cpp:296-303), so the sink is closed and the request goes out with an empty chunked body. Both HttpStream.hpp:315-316 and Stream.hpp say so on purpose. This is reachable from Elm: `Readable` is opaque, but a program can reuse a Readable that has already been drained and erased, or one from a previous heap generation. The send then succeeds with an empty body and nothing reports the mistake.
- **Impact:** the request body is silently empty, e.g. an upload is sent as zero bytes. This matches how `Stream.pipeTo`/`pipeThrough` treat missing ids.
- **Suggested fix / next step:** if this design is kept, nothing to do. Otherwise, when `find(streamId)` is null, resume at once with NetworkError (as the locked case at :246-251 does).

### HTTPS-02: request sent with empty chunked body
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:480-483 (`buildHeaderList`), :420-423 (`readCb` EOF)
- **Original claim:** an empty body is sent with chunked encoding, which some servers may reject.
- **Analysis:** every stream body (bodyKind 2) gets `Transfer-Encoding: chunked`. An empty one (missing id per HTTPS-01, or an empty Readable) becomes the terminating `0\r\n\r\n` chunk. That is a valid HTTP/1.1 message, and over HTTP/2 curl drops the header and sends DATA with END_STREAM. Only HTTP/1.0-only servers would have trouble, and they cannot take any chunked body at all, empty or not. One small related point: a HEAD with a stream body still gets `Transfer-Encoding: chunked` but no body (see HTTPS-09).
- **Impact:** practically none.
- **Suggested fix / next step:** none needed. Optionally leave out the TE header for HEAD.

### HTTPS-03: empty method with body sets CUSTOMREQUEST ""
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:520-537 (`configure`), line 534
- **Original claim:** an empty method with a body gives `CURLOPT_CUSTOMREQUEST ""` and a malformed request line.
- **Analysis:** with `hasBody` and `m != "POST"`, the code calls `curl_easy_setopt(CURLOPT_CUSTOMREQUEST, m.c_str())` even when `m` is empty (:534). The no-body branch guards against this with `!m.empty()` (:535); the body branch does not. libcurl's `Curl_setstropt` stores `""` as non-NULL, and `Curl_http_method` then uses it, giving a request line ` /path HTTP/1.1` (and an empty `:method` on h2, which nghttp2 rejects). Elm can reach this through `Http.Method.UNKNOWN ""` (Http/Method.elm:84-85 `toString (UNKNOWN name) = name`), which Http/Stream.elm:142/348 passes straight to the kernel. The header comment in HttpTransfer.hpp:67-71 says empty is sent "as a POST with that method as its custom request", so the intent was a plain POST.
- **Impact:** the request is malformed; the server answers 400 or curl/h2 errors, which surfaces as BadStatus or NetworkError.
- **Suggested fix / next step:** use `if (m != "POST" && !m.empty())` at :534. A test with `UNKNOWN ""` plus a bytes body against the test server would settle the curl behaviour.

### HTTPS-04: finishTransfer fallback drops response data
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:545-579 (`finishTransfer`, fallback at :559-566); :388-393 (`writeCb`); :360-365 (`headerCb` blank-line test)
- **Original claim:** on the clean-finish-without-posted-head fallback, statusText, headers and body are lost.
- **Analysis:** the fallback runs only when curl finishes with CURLE_OK, `status > 0`, and `headerCb` never posted a head. In that case the event carries `status` and `url` but leaves `statusText` and `headers` empty (:559-566). Every body byte has also already been thrown away: `writeCb` returns `n` without queuing while `!headersPosted` (:393), so readers immediately see EOF. The code does what its comment says (:540-544), so the open question is only how this path is reached. One way is a final 3xx that carries a Location but that curl does not follow: `isFollowedRedirect` (:291-293) treats every 3xx except 304 as followed, while curl does not follow every such code (e.g. 305/306, depending on version). Another is a status line the parser reads as status 0. Both are rare.
- **Impact:** a rare response arrives with no reason phrase, no headers and an empty body.
- **Suggested fix / next step:** buffer body bytes until the head is decided, or post the head from the last parsed `HeaderState` in `finishTransfer` rather than an empty head. A test server that returns `305` with a Location and a body would settle it.

### HTTPS-05: cancel aborts posted transfer but returns false
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:719-733 (`HttpStreamService::cancel`); S/Core/KillHandle.cpp (`killEval`); S/HttpStream/HttpStream.cpp:182-217 (`httpStreamDrain`)
- **Original claim:** cancel ends the streamed body yet reports that it did not cancel, so caller state does not match.
- **Analysis:** returning false is exactly what the `CancelFn` contract (Core.hpp:60-64) requires. False means "the event is or will be queued", so the kill handle does not release the hold and the drain does: `killEval` first calls `takePendingResume(token)`, the drain then finds nil, aborts again (a no-op) and releases the hold through `HoldRelease` (HttpStream.cpp:188-194). Aborting a transfer whose event was posted but not yet drained is correct, because nobody will ever receive its body. The kill handle runs only while the binding is the process's current root, i.e. before the resume is consumed, so it cannot abort a body that Elm already owns as a Readable. Each hold is released exactly once.
- **Impact:** none.
- **Suggested fix / next step:** none.

### HTTPS-06: cancel misses created-not-started transfers
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpStream.cpp:255-265; S/HttpStream/HttpTransfer.cpp:697-717 (`start`), 719-733 (`cancel`)
- **Original claim:** a transfer that has been created but not started is not in `live`, so cancel misses it.
- **Analysis:** `create` and `start` run back to back in the same eco-thread body (HttpStream.cpp:258-264). The kill handle is returned only after `start` (:265), so no kill can happen in between. The only code that runs between them is `pipeStreams`, which may run Elm continuations for other tasks but cannot kill this one, because its handle does not exist yet. If thread creation fails, `start` posts NetworkError itself (:711-715), so the transfer is still resolved.
- **Impact:** none observable.
- **Suggested fix / next step:** none. Optionally insert into `live` in `create`.

### HTTPS-07: live map keyed by token
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:697-717 (`start`), :676 (`Impl::live`); /work/runtime/src/platform/Scheduler.cpp:128-133
- **Original claim:** token collisions; erasing on start failure may remove another transfer's entry.
- **Analysis:** tokens come from `Scheduler::parkResume` → `registerPendingResume`, which uses `nextResumeToken_.fetch_add(1)` (Scheduler.cpp:129). That is a process-wide 64-bit monotonic counter, so two live transfers never share a token. Each transfer is started once (documented at HttpTransfer.hpp:145), so the erase at :706 or :712 always removes the transfer's own entry.
- **Impact:** none.
- **Suggested fix / next step:** none.

### HTTPS-08: empty upload write acked early
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:806-815 (`HttpTransferChannel::requestWrite`); S/Stream/Stream.cpp:755-786 (Write dispatch)
- **Original claim:** an empty write is acknowledged ahead of earlier writes that are still pending, so acks arrive out of order.
- **Analysis:** the out-of-order ack is real: an empty write is answered at once, while earlier non-empty writes queued at or above `kCap` stay unacknowledged. Senders do keep several writes in flight (StreamPipe.cpp:90-96, Stream.cpp:1360-1370, bounded by `writeCap`). It does no harm, though. The Stream dispatch matches each result to its write by token, not by position (Stream.cpp:758-765), and an empty write has no bytes whose order could matter. Writes are already acknowledged before they are sent anyway (`ahead < kCap`, :226-231).
- **Impact:** none observable. In theory, an empty write could report success while an earlier write later fails.
- **Suggested fix / next step:** none needed. Optionally queue empty writes like the others.

### HTTPS-09: close for bodyKind != 2 answered late
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:239-247 (`serviceLocked` close clause), :522-523 (`configure` HEAD branch)
- **Original claim:** an upload close is answered late when the body is not a stream.
- **Analysis:** as worded, the claim cannot happen: an Upload channel is only created when `bodyKind == 2` (HttpStream.cpp:259-263). A real variant exists, though. With method HEAD and a stream body, `configure` sets `CURLOPT_NOBODY` and no `READFUNCTION` (:522-523), so `readCb` never runs and `upEofSent` is never set. The close is then answered only when the transfer finishes (:239 `upDead`), with ECANCELED "the HTTP response ended before the request body was sent". Writes above 256 KiB also block until the end and then fail. Because this happens after `finished`, the Stream layer's `shutdown` (Stream.cpp:776) does not abort the response.
- **Impact:** a HEAD with a stream body has its pipe or close fail with a misleading error at the end of the transfer. The response itself is unaffected.
- **Suggested fix / next step:** when there is no read callback (HEAD), answer upload writes and closes at once (or reject the stream body up front) and leave out the chunked TE header.

### HTTPS-10: ECANCELED with empty reason
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpTransfer.cpp:799-804 (write after close), :833-837 (second upload close); HttpTransfer.hpp:219-224 (`encodeFailure`)
- **Original claim:** some ECANCELED results carry an empty reason, which makes an uninformative error.
- **Analysis:** both sites post ECANCELED with no `reason`. `encodeFailure` replaces an empty reason with "network error: ECANCELED" (hpp:221-223), so callers still get a marked reason. Neither site is reached from the Stream layer in normal use: `Stream.write` refuses once `w != Open` (Stream.cpp:1340-1343), and `closeDst` closes only once. All other ECANCELED sites go through `uploadFailure`, which supplies a reason.
- **Impact:** at most a generic error text on an unreachable path.
- **Suggested fix / next step:** set `r.reason = "the request body was already closed"` for consistency. Optional.

### HTTPSRV-02: bracketed host accepts any reg-name chars
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/Http1.cpp:73-112 (`validHost`), bracket branch :76-86
- **Original claim:** a bracketed Host is not validated as an IP literal.
- **Analysis:** inside `[...]` the code accepts hex digits, `:`, `.`, `%` and every reg-name character, and requires at least one `:` (:80-85). So values like `[zz!$:]` pass. The leniency is deliberate (the comment at :68-72 says so) and accepts IPvFuture and zone-id forms without parsing them. The allowed set contains no `/ ? # @`, whitespace or CR/LF, so this cannot inject anything or break the URL that `absoluteUrl` builds. The only effect is that a malformed Host reaches Elm instead of a 400.
- **Impact:** cosmetic and RFC-strictness only.
- **Suggested fix / next step:** optionally parse IPv6 / IPvFuture strictly (e.g. `inet_pton(AF_INET6)` after removing the zone id).

### HTTPSRV-03: 100 Continue sent to HTTP/1.0
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/Http1.cpp:212-222 (`headersComplete`), line 221
- **Original claim:** `100 Continue` is written without checking the protocol version.
- **Analysis:** `headersComplete` accepts HTTP/1.0 (it only rejects major != 1 or minor > 1, :187) and writes `HTTP/1.1 100 Continue` whenever there is one `Expect: 100-continue` and a body (:221). It never looks at `parser_.http_minor`. RFC 9110 §10.1.1 says a server MUST ignore a 100-continue expectation in an HTTP/1.0 request, and §15.2 says a server MUST NOT send a 1xx to an HTTP/1.0 client. It also sends 417 to a 1.0 client with any other expectation, where it should ignore the header. A 1.0 client may take the 100 for the final response.
- **Impact:** a protocol violation with rare 1.0 clients that send Expect.
- **Suggested fix / next step:** wrap the Expect handling in `if (parser_.http_minor >= 1)`.

### HTTPSRV-04: absolute-form recognised only lower-case
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/Http1.cpp:333-339 (`absoluteUrl`), line 335
- **Original claim:** the absolute-form scheme prefix is matched case-sensitively.
- **Analysis:** `target.rfind("http://", 0)` and `rfind("https://", 0)` are case-sensitive, and llhttp does not normalise the URL. URI schemes are case-insensitive (RFC 3986 §3.1), so `GET HTTP://example.com/x HTTP/1.1` is treated as origin-form and becomes `http://<Host>/HTTP://example.com/x`. Absolute-form is normally sent only to proxies, and upper-case schemes are rarer still.
- **Impact:** a wrong `url` is delivered to Elm for an unusual but legal request.
- **Suggested fix / next step:** compare the prefix case-insensitively (and lower-case the scheme in the URL handed on).

### HTTPSRV-05: output-high flag not updated
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http1.cpp:221 (100 Continue write), :393-401 (`failRequest`), :416 (`respond`), :486-487 (cleared on writable)
- **Original claim:** `outHigh_` is not updated after the 100 Continue write or after error writes.
- **Analysis:** `failRequest` always calls `closeNow` right after its write (:400), so backpressure no longer matters on that connection. The 100 Continue write is 25 bytes, and only one request is in flight. Any earlier response that pushed the queue past `kLowWatermark` already set `outHigh_` in `respond` (:416), so these 25 bytes can practically never be the ones that cross the watermark. Even if they did, the queue is drained normally, and the only cost is that reading does not pause for those few bytes.
- **Impact:** negligible.
- **Suggested fix / next step:** none needed. Optionally re-check the watermark after the 100 Continue write.

### HTTPS-NEW-1: proxy CONNECT response posted as the final response
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** S/HttpStream/HttpTransfer.cpp:331-381 (`headerCb`), :489-538 (`configure`, no `CURLOPT_SUPPRESS_CONNECT_HEADERS` / `CURLOPT_PROXY`)
- **Original claim:** (new) found while checking HTTPS-04.
- **Analysis:** libcurl honours `https_proxy`/`http_proxy`/`ALL_PROXY` from the environment by default. For an https URL through an HTTP proxy it opens a CONNECT tunnel and, unless `CURLOPT_SUPPRESS_CONNECT_HEADERS` is set, passes the proxy's `HTTP/1.1 200 Connection established` block to the header callback. `headerCb` resets on that `HTTP/` line, and at its blank line the status is 200 (not interim, no Location), so `postHeaders` posts GoodStatus 200 with the proxy's reason phrase and an empty header list (:360-364). From then on `headersPosted` is true, so the origin server's real status line and headers are ignored (:337), and `discardNon2xx` is evaluated against 200. The origin's body then streams out as the body of a 200, even when the origin answered 404 or 500. Nothing in eco-system sets any proxy option (grep finds no `CURLOPT_PROXY` or `SUPPRESS`).
- **Impact:** behind a proxy, every streaming https request reports status 200 with no headers, whatever the server actually answered.
- **Suggested fix / next step:** set `CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L` in `configure`. To confirm, run a Http.Stream request with `https_proxy` pointing at a local CONNECT proxy against a server that returns 404.

### HTTPS-NEW-2: method string not validated (request-line injection)
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** S/HttpStream/HttpTransfer.cpp:534-536 (`CURLOPT_CUSTOMREQUEST m.c_str()`); headers are filtered at :472-473 but the method is not
- **Original claim:** (new) found while checking HTTPS-03.
- **Analysis:** `buildHeaderList` drops header names and values that contain CR/LF, but the method from `Http.Method.UNKNOWN name` (Method.elm:84-85) goes to `CURLOPT_CUSTOMREQUEST` unchecked. libcurl copies CUSTOMREQUEST verbatim into the request line, so `UNKNOWN "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /evil"` would smuggle extra header lines or a second request. This is reachable only when a program builds the method from untrusted input (e.g. a proxy written in Eco). The same check is probably missing in the non-stream Http kernel; not checked.
- **Impact:** HTTP request smuggling or header injection through the method.
- **Suggested fix / next step:** reject methods that are not an RFC 9110 token (tchar only, non-empty) with BadUrl or NetworkError before calling `configure`.

### H2-01: maxConcurrentStreams 0 advertised, no cap
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http2.cpp:340-343 (`capped`), :380-384 (`onOpen` SETTINGS); S/HttpServer/Http1.hpp:115 (field comment); system-kernel-cpp/src/Http/Server.elm:191-203, :315-322 (`limit`)
- **Original claim:** With `maxConcurrentStreams = 0` the server advertises SETTINGS_MAX_CONCURRENT_STREAMS 0 but its own cap (`capped`, `> 0` only) enforces nothing.
- **Analysis:** True that `capped()` ignores 0, but the advertised 0 is enforced by nghttp2 itself: `nghttp2_session_on_request_headers_received` (build/_deps/nghttp2-src/lib/nghttp2_session.c:3891-3910) refuses a new stream with REFUSED_STREAM while the setting is pending (`pending_local_max_concurrent_stream`), and with a connection PROTOCOL_ERROR after the SETTINGS ACK. So 0 does refuse every HTTP/2 request, which is exactly what the Elm docs promise (Server.elm:201-203: "A `maxConcurrentStreams` of 0 refuses every HTTP/2 request"). The Elm side sends `max 0 n` for `Just n` and -1 for `Nothing`, so -1 (no SETTINGS, no cap) and 0 are the only non-positive values. The only real defect is the field comment at Http1.hpp:115 ("0 or less sets no limit"), which contradicts Http2.hpp:24 and actual behaviour.
- **Impact:** None at runtime; a misleading comment.
- **Suggested fix / next step:** Fix the Http1.hpp:115 comment ("-1: no limit; 0 refuses every stream (enforced by nghttp2)"); optionally note in `capped` why 0 needs no check.

### H2-02: bindTunnel returns id after head refused
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http2.cpp:927-944 (`bindTunnel`); S/HttpServer/HttpUpgrade.cpp:130-147 (`H2Upgrade::accept`); S/WebSocket/H2StreamPort.cpp:47-59 (`bind`), :93-103 (`streamReset`)
- **Original claim:** When nghttp2 refuses the tunnel's response headers, `bindTunnel` still returns the stream id, leaving a tunnel on a dead stream.
- **Analysis:** Documented behaviour (Http2.hpp:188-189). On refusal it submits RST_STREAM(INTERNAL_ERROR) (:939-941) with the stream already in state Tunnel and owning the handler. The RST closes the stream through `closeStream` (:860-874), which calls `retireTunnel` and so `ServerTunnel::onReset` and then `H2StreamPort::streamReset` (sets `gone_`). If this happens inside `bindTunnel`'s own `afterIo`, i.e. before `port->bind`, `bind` sees `gone_` and calls `core_->portClosed()` (H2StreamPort.cpp:53-57). If it happens later, `streamReset` calls `portClosed` because the port is `bound_`. Either way the WebSocket core learns the stream is closed. The tunnel object outlives the `tunnel->sid = sid` write because `retireTunnel` keeps it alive in a reactor command (:547-553). `nghttp2_submit_response2` fails only on NOMEM or on a stream nghttp2 no longer knows, and `tunnelPending` has just checked that.
- **Impact:** At most an `accept` that reports success for a WebSocket that closes at once. No dead or leaked tunnel.
- **Suggested fix / next step:** None needed; optionally return 0 on refusal so `accept` fails instead.

### H2-03: tunnel onReset reported twice
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http2.cpp:555-587 (`maybeClose`), :589-617 (`fatal`), :682-697 (`onCloseAll`); S/HttpServer/HttpUpgrade.cpp:68 (`~ServerTunnel`); S/WebSocket/H2StreamPort.cpp:93-94
- **Original claim:** `maybeClose`/`fatal` call `tunnel->onReset(CANCEL)` and then `onCloseAll` reports again.
- **Analysis:** Real but intended and harmless. `maybeClose` and `fatal` call `onReset(CANCEL)` but leave the handler bound. The later `onCloseAll` (from the Conn's abort/close) calls `retireTunnel`, which calls `onReset` again, and `~ServerTunnel` calls `streamReset(kCancel)` a third time. The interface explicitly allows this: "It can be called again for the same stream when the connection ends after the first report, so an implementation must tolerate a repeat" (Http2.hpp:128-130). The only implementation, `H2StreamPort::streamReset`, returns at once once `gone_` is set (:94).
- **Impact:** None; the extra reports are no-ops.
- **Suggested fix / next step:** None. Optionally clear `s.tunnel` via `retireTunnel` in `maybeClose`/`fatal` to make the report single.

### H2-04: tunnelConsume has no tunnel check
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http2.cpp:946-950 (`tunnelConsume`); only caller S/HttpServer/HttpUpgrade.cpp:89-92 (`ServerTunnel::tunnelConsume`)
- **Original claim:** `tunnelConsume` does not check that `streamId` is a tunnel, so it could be misused on a regular stream.
- **Analysis:** Unlike `tunnelWrite` and `tunnelEnd` (:952, :971), it does not check `s->st == Tunnel`. The only caller is `ServerTunnel`, using the `sid` that `bindTunnel` returned, and only after `bind`. The port stops calling its tunnel once `gone_` is set (H2StreamPort.hpp:53, `deliver` checks `!gone_`). HTTP/2 stream ids are never reused, so a stale id cannot name another stream. On an unknown stream, `nghttp2_session_consume_stream` does nothing or returns an error, and the result is ignored. It changes only the stream window, not the connection window, which the protocol manages itself through `consumeConnection`.
- **Impact:** None reachable; a defensive gap only.
- **Suggested fix / next step:** Optionally add `Stream* s = find(streamId); if (!s || s->st != Stream::St::Tunnel) return;` for symmetry.

### HTTPSRV-06: every getaddrinfo failure reported ENOTFOUND
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerService.cpp:226-231 (`listenOn`); compare S/Core/SocketUtil.cpp:321-335 (`gaiCode`), S/Socket/Socket.cpp:114-116
- **Original claim:** `listenOn` maps every getaddrinfo failure to ENOTFOUND.
- **Analysis:** `if (gai != 0) { res.code = "ENOTFOUND"; ... }` ignores the actual EAI code, and the header documents it that way (HttpServerService.hpp:60). The socket kernel already has `gaiCode`, which maps EAI_AGAIN to "EAI_AGAIN", EAI_MEMORY to ENOMEM and EAI_SYSTEM to the errno name, and Socket.cpp uses it. The Elm API has a distinct `HostLookupTryAgain` kind for EAI_AGAIN (Http/Server.elm:851, :909). `listenOnHost` (Server.elm:141, `kCreateServer` to `HttpServer.cpp:186` to `listenOn`) can never produce it, so a transient DNS failure shows up as `HostNotFound`. Reachable from ordinary programs that call `listenOnHost` with a host name during a resolver outage. `listen` goes through `tcpListenOn` instead and is not affected.
- **Impact:** Wrong error kind: a retryable lookup failure looks permanent. The message also prints an empty host for `host == ""`.
- **Suggested fix / next step:** Capture errno right after the call, then use `res.code = gaiCode(gai, sysErr); res.message = "getaddrinfo " + res.code + " " + host;`, and update the header comment.

### HTTPSRV-07: Win32 message names listenOnHost for listen
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerServiceWin32.cpp:21-27 (`listenOn`); caller S/HttpServer/HttpServer.cpp:166-193 (`httpServerCreateServerBody`)
- **Original claim:** The Windows stub's message names `Http.Server.listenOnHost` even when `listen` was called.
- **Analysis:** `HttpSrv::listenOn` has one caller, `httpServerCreateServerBody` (HttpServer.cpp:186), which is the kernel of `listenOnHost` (Server.elm:141-143, `kCreateServer`). `listen` uses `kCreateServerWith`, i.e. `httpServerCreateServerWithBody`, which calls `tcpListenOn` (HttpServer.cpp:281), not `listenOn`. So the message's function name is correct for every path that can produce it.
- **Impact:** None. (Separately, on Windows a plain `listen` gets as far as `tcpListenOn` and `makeServerProtocol` returns null, Win32.cpp:39-41. Windows is low priority and that was not investigated here.)
- **Suggested fix / next step:** Close the entry as invalid.

### HTTPSRV-08: socketCloexec failure reported EADDRNOTAVAIL
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerService.cpp:243-249, :280; S/Core/SocketUtil.cpp:103-127 (`socketCloexec`)
- **Original claim:** A `socketCloexec` failure that leaves `sockErr` 0 is reported as EADDRNOTAVAIL.
- **Analysis:** On POSIX, `socketCloexec` always sets `*err` on failure: to `errno` after a failed `socket()` (:107, :113), which is never 0, or to the nonzero `setCloexec`/`setNonBlocking` result (:120). The Windows stub sets ENOTSUP. So `lastErr` cannot be 0 after a socket failure. `lastErr == 0` (:280) happens only when the address list is empty, and getaddrinfo never returns an empty list on success.
- **Impact:** None reachable.
- **Suggested fix / next step:** None; optionally initialise `sockErr = EIO` defensively.

### HTTPSRV-09: EBADF/no-syscall messages
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerService.cpp:240-284 (`listenOn` failure message)
- **Original claim:** The messages for EBADF and "no syscall" cases are imprecise.
- **Analysis:** No EBADF case exists anywhere in S/HttpServer or S/Socket (grep finds none), so the EBADF part has no code to point at. The "no syscall" case is the `lastErr == 0` fallback: `lastSyscall` stays "listen" and the code is EADDRNOTAVAIL even though no syscall ran. As HTTPSRV-08 shows, that needs an empty getaddrinfo result and is unreachable. Bind failures are labelled "listen" on purpose, to match Node (:255).
- **Impact:** Cosmetic at most, and unreachable.
- **Suggested fix / next step:** Close, or merge with HTTPSRV-08.

### HTTPSRV-10: no subscription hold for server started while subscribed
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpTables.cpp:397-417 (`httpTablesStartServer`), :483-507 (`httpTablesSyncSubscriptionHolds`/`httpTablesSubscriptionsChanged`); S/HttpServer/HttpServerManager.cpp:152-180
- **Original claim:** A server started while an onRequest subscription already names it takes no subscription hold, so the program may quiesce early.
- **Analysis:** It is true that `httpTablesStartServer` never syncs holds; holds are synced only in `httpTablesSubscriptionsChanged`, called from `onEffects`. But a subscription cannot name a server before that server exists. `Server` is opaque (Server.elm:2 exposes `Server` without constructors; :120-121). The only way to get one is `toServer` on the kernel's create result, which is built after `httpTablesStartServer` has assigned the id. Ids come from a process-wide counter that is never reused, even across heap resets (`nextServerId`, :168-171). So the sequence is always: start the server, resume the task, the Elm update runs, subscriptions change, `onEffects`, the hold is taken. A request that arrives in between is parked (no subscriber) and delivered once the subscription appears.
- **Impact:** None reachable from well-typed Elm.
- **Suggested fix / next step:** Optionally call `httpTablesSyncSubscriptionHolds()` at the end of `httpTablesStartServer` as a cheap safeguard.

### HTTPSRV-11: null deliver with hasSubscriber drops request
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpTables.cpp:113-116 (`httpManagerDeliver`), :254-257 (`onRequest`), :294-297 (`deliverParked`); hooks installed at S/HttpServer/HttpServerManager.cpp:279-282
- **Original claim:** If `hasSubscriber` is non-null and returns true while `deliver` is null, a request takes its hold and is silently dropped.
- **Analysis:** The code would behave that way, and the header states the precondition (HttpTables.hpp:157-159). But the only `setHttpManagerHooks` call in the tree (HttpServerManager.cpp:279-282, registered by `Eco_System_registerManager_Http_Server`) sets both pointers together. No test installs partial hooks (grep over the repo finds no other caller).
- **Impact:** None reachable; this is an API precondition.
- **Suggested fix / next step:** Optionally make `httpManagerHasSubscriber` return false when `deliver` is null, or assert in `setHttpManagerHooks`.

### HTTPSRV-12: HttpUpgrade EINVAL message incomplete
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpUpgrade.cpp:201-204 (`httpServerTakeUpgradeBody`); S/HttpServer/HttpTables.cpp:463-473 (`httpTablesTakeUpgrade`), :348-350 (ConnGone erases key)
- **Original claim:** The EINVAL message ("answered already or is not an upgrade request") does not cover a parked key or a key erased by ConnGone.
- **Analysis:** `httpTablesTakeUpgrade` also returns false for a key erased by a ConnGone event (the client disconnected before the program called `upgradeRequest`) and for a key from an earlier heap generation. Both are reachable: a client that sends an Upgrade request and drops the connection is ordinary. The program then gets EINVAL with the wrong explanation. In the same function, a connection found gone after the take is reported as ECANCELED "socket closed" (:208), so the two races produce different error kinds. The parked case is unreachable, because Elm only sees delivered keys.
- **Impact:** Misleading error message and kind (EINVAL instead of ECANCELED/socket closed) when the peer disconnects first.
- **Suggested fix / next step:** Distinguish the "key unknown" case (report ECANCELED "socket closed", or say "answered already, connection closed, or not an upgrade request"), e.g. have `httpTablesTakeUpgrade` return a reason enum.

### SOCK-03: Conn second write onError
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Conn.cpp:762-784 (`applyInterest`), :726-735 (`writeFailed`), :737-752 (`flushPending`); contract at S/Socket/Conn.hpp:176-181
- **Original claim:** After an earlier write failure, a failing `setInterest` makes `onError` fire a second time for writes.
- **Analysis:** `applyInterest` reports the read error only when reading was not already over (`readWasDone`), but reports the write error whenever `phase_ == Open` (:781), without checking whether `writeDone_` was already set by `writeFailed` or `flushPending`. So after an earlier "write X" `onError`, a later `setInterest` failure (epoll_ctl ENOMEM/ENOSPC) delivers a second "write X" `onError`. This matches the documented contract ("while the connection is still open, a write error is reported", Conn.hpp:179-180), and every consumer tolerates repeats. `FaceProtocol::onError` handles a "write " code with just `checkDone` (FaceProtocol.cpp:124-127). `Http1Protocol::onError` (Http1.cpp:481-483) and `Http2Protocol::onError` (Http2.cpp:633-635) only abort, and only if the connection is not already aborted. `WsProtocol::onError` forwards to `core_->portError`, not verified to be idempotent, but the connection closes right after (`closeNow`, :783).
- **Impact:** A duplicate callback in a rare failure path; no observed harm.
- **Suggested fix / next step:** Record `bool writeWasDone = writeDone_` and report the write error only if it was false, mirroring the read side, and update Conn.hpp:179-180.

### SOCK-04: failed shutdownWrite leaves writeErr_ 0
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Conn.cpp:574-586 (`shutdownWrite`), :707-724 (`serviceWrites` shutdown branch); callers S/Socket/FaceProtocol.cpp:219, :246
- **Original claim:** A best-effort shutdown (no callback) that fails sets `writeDone_` but leaves `writeErr_` 0, so a later `shutdownWrite(done)` reports success.
- **Analysis:** In `Conn` itself the defect is real: when `rc != 0` and `shutDone_` is empty (:719), `writeDone_ = true` but `writeErr_` stays 0, and a later `shutdownWrite(done)` hits `if (writeDone_) done(writeErr_)`, i.e. `done(0)` (:579-581), against the contract "0 once [the FIN] is sent" (Conn.hpp:301-304). But no caller can reach it. The only callback-less callers are `FaceProtocol::writeFaceShutdown` (:246), which sets `writeFaceDone_ = true` first, and `closeGraceful` (`shutRequested_` directly). After either, `FaceProtocol::reqCloseWrite` is refused by `writeOver(c)` (FaceProtocol.cpp:209, :133), which answers through `lateWrite` with ECANCELED "socket closed". The HTTP protocols never call `shutdownWrite`. `write()` after the failure correctly yields ECANCELED.
- **Impact:** Latent API defect only; no current path reports a false success.
- **Suggested fix / next step:** Always set `writeErr_`/`writeErrReason_` in the failure branch, whether or not callbacks are waiting.

### SOCK-05: close hooks never run for early-aborted client
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Conn.cpp:244-248 (`startConnect` killed before start), :929-934 (`abort` in Idle), :507-513 (`addCloseHook`), :836-842 (`closeNow` runs hooks)
- **Original claim:** A client aborted while Idle, or killed before start, is marked Closed without `closeNow`, so its close hooks never run.
- **Analysis:** Both paths set `phase_ = Closed` without `closeNow`, so any queued hooks would be skipped, and later `addCloseHook` calls run at once because the phase is Closed. But no hook is ever registered on an Idle client. The four `addCloseHook` sites are: Http1.cpp:542 and Http2.cpp:1028 (server protocols on accepted connections); Listener.cpp:123 (accepted connections, created via `makeAccepted`, never Idle); and WsProtocol.cpp:1278 (inside `onOpen`, i.e. Open phase only). There is no fd in Idle, so nothing leaks.
- **Impact:** None reachable today; a latent trap if a future caller adds a hook before `startConnect`.
- **Suggested fix / next step:** Optionally swap and run `closeHooks_` in the Idle/killed branches, or document "hooks are only honoured once the connection has an fd".

### SOCK-06: drainStep ignores flush errors
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Conn.cpp:801-827 `Conn::drainStep` (cf. `flushPending` :737-751, `enterDraining` :788-798)
- **Original claim:** `transport_->flush()` result is ignored in `drainStep`, so a failed flush loses data silently.
- **Analysis:** The result is not ignored. `flush() == 1` keeps write interest. `< 0` leaves `wantW` false, so the conn closes once discarding ends (:804, :821-824). After a failure the TLS transport promises nothing is pending (`TlsTransport.cpp` `flush`, `hasPendingWrite` returns false once broken). Draining is only entered from `afterIo` when `outQ_` is empty and `!shutRequested_` (:780). So every queued write has already had `done(...)` called, and the close_notify/FIN path (`serviceWrites` :706-724) has finished. If `shutdownWrite` returned 0, nothing is pending. On failure the transport is broken and has nothing pending either. In practice the only pending output left in Draining is an alert after a protocol failure. Nobody is waiting to hear that it failed: close hooks take no status (`closeNow` :830-842). Bytes the TLS layer accepted and then could not send are the same as bytes the kernel's send buffer accepted and then dropped on a reset.
- **Impact:** None observable; at most a best-effort alert is not sent.
- **Suggested fix / next step:** None needed. Optionally comment that a flush failure in Draining is intentionally terminal.

### SOCK-07: ListenerClosed posted twice
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Listener.cpp:184-206 `ListenerHandler::close` / `onCloseAll` / `closeNow`
- **Original claim:** Every `closeNow` outside callback mode posts ListenerClosed, so `close()` + `onCloseAll()` posts it twice.
- **Analysis:** It is true that `closeNow(post=true)` posts even when `closed_` is already set (:198-205). But the claimed sequence cannot happen. `close()` removes the handler from the reactor (:194), and `IoReactor::closeAll` skips removed handlers (IoReactor.cpp:287-297). So `onCloseAll` never follows `close()`. `close()` is submitted only once per listener. `socketCloseListenerBody` guards with `e->closing` (Socket.cpp:511). The only other caller is `resetTables` (SocketTables.cpp:52-53), which clears the table. A second post therefore needs a heap reset (test-only `Allocator::reset`) racing a pending close. Even then the duplicate is harmless. It carries the old `gen_` and is dropped by `socketEventsDrain` (SocketEvents.cpp:129-131). If the gen matches, `onListenerClosed` finds no entry (SocketTables.cpp:194-195), because listener ids are never reused (SocketTables.hpp:91-99).
- **Impact:** None in practice.
- **Suggested fix / next step:** Optional hardening: return early in `closeNow` when it was already closed, so the event is posted once by construction.

### SOCK-08: finite credit reserved while unlimited
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Listener.cpp:106-110 `ListenerHandler::acceptLoop`; S/Socket/SocketTables.cpp `serveHeld`, `cancelParkedAccept`
- **Original claim:** Credit is reserved at accept even in unlimited (subscribed) mode, so the accounting does not match.
- **Analysis:** Credit is the number of parked `Socket.accept` tasks (Socket.cpp:486-494 `addCredit(1)`). `serveHeld` always gives the oldest parked accept priority over subscribers. So taking one credit for a connection while credit > 0 is the right accounting, even when `unlimited_` is set: that connection will go to a parked accept. A failed handshake gives the credit back (:145). The real, minor drift runs the other way. A connection accepted with no credit (unlimited mode) can be handed to an accept parked after it, and that accept's `addCredit(1)` then stays outstanding. Once subscribers leave, one extra connection is accepted and kept in the held FIFO. `addCredit` and `cancelParkedAccept` clamp at 0, so nothing goes negative.
- **Impact:** At most one surplus accepted-and-held connection after a subscribe/unsubscribe switch. It is not lost; it waits in `held`.
- **Suggested fix / next step:** None required. If wanted, reconcile credit against `parkedAccepts.size()` when `setUnlimited(false)` is applied.

### SOCK-09: ConnChannel close does not check done_
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/ConnChannel.cpp:50-55 `ConnReadFace::close`, :86-91 `ConnWriteFace::close`
- **Original claim:** `close` does not check `done_`, so a double close is possible and gives a duplicate completion.
- **Analysis:** Each `close(token)` carries its own token and gets exactly one `ChannelResult` for that token. A second close is never a second completion of the same request. On the write face, `FaceProtocol::reqCloseWrite` (FaceProtocol.cpp:208-220) answers a repeat (`closePending_` or `writeOver`) with its own late result. On the read face, `reqCloseRead` (:145-156) posts a close result per call. The stream layer also stops repeats. `streamCloseWritableBody` rejects Closing/Closed (Stream.cpp:~1431). The read-side `close(0)` calls (Stream.cpp:696, 725, 744, 925) are on EOF transitions guarded by `RState`, with token 0, which is uncounted.
- **Impact:** None found.
- **Suggested fix / next step:** None.

### SOCK-10: socketTablesFaceGone keyed only by connId
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/SocketTables.cpp:309-313 `socketTablesFaceGone`
- **Original claim:** The key has no generation, so a speculative collision is possible.
- **Analysis:** `nextConnId` starts at 1, increments per materialized connection, and is never reset, including when the tables are reset (SocketTables.hpp:91-99; SocketTables.cpp:257). A face that outlives a heap reset therefore looks up an id that cannot exist in the new tables, and `findConn` returns null (:310-311). No collision is possible within a process.
- **Impact:** None.
- **Suggested fix / next step:** None.

### SOCK-11: close token parked with null handler
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Socket.cpp:499-534 `socketCloseListenerBody`
- **Original claim:** With a null `e->handler` the close token stays parked forever, so the Task hangs.
- **Analysis:** `ListenerEntry::handler` is set only in `completeListen` (Socket.cpp:301-305), always to a fresh `make_shared<ListenerHandler>`. It is never reset or nulled anywhere (grep for `handler =`, `handler.reset`: only Socket.cpp:303 and Udp.cpp:522). The `if (h)` at :524 is defensive only. If the handler were null the hang would be real, because nothing else posts ListenerClosed. But that state cannot be built.
- **Impact:** None reachable.
- **Suggested fix / next step:** Optional: resume the token at once when `!h`, or assert non-null.

### SOCK-12: pending connect left if makeKillHandle throws
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Socket.cpp:311-321 `socketStartConnect`; Core/Core.cpp:129-142 `asyncFailure`; SocketTables.cpp `onConnected`
- **Original claim:** No cleanup if `makeKillHandle` throws, so the pending entry leaks.
- **Analysis:** The order is wrong. The function calls `parkResume` (counted = true), inserts `pendingConnects[token] = c`, submits `c->startConnect()`, and only then calls `makeKillHandle`, which allocates a closure (KillHandle.cpp:37-46) and can throw `std::bad_alloc` when the heap is exhausted. The guard's `asyncFailure` takes the resume, fails the task and releases the hold (Core.cpp:132-140). It does not touch `pendingConnects`, and it does not cancel the connect, which is already running on the reactor. When the connect finishes, `onConnected` erases the entry and runs `HoldRelease release(ev.token)` again. That is a **second release of the same hold**: in hold-census builds it is `holdFatal("second release of a hold")` (runtime/src/platform/Scheduler.cpp:1102-1117); otherwise `decrementPendingAsync()` runs twice. The connection is then aborted because its resume is gone. The accept path deliberately calls `makeKillHandle` first for exactly this reason (Socket.cpp:487-490 comment).
- **Impact:** Only under kernel OOM: a pending-async counter that is one too low (the scheduler may decide the program is idle while work is still pending), or a fatal in census builds, plus an orphan connect attempt.
- **Suggested fix / next step:** Call `makeKillHandle` before inserting into `pendingConnects` and submitting `startConnect`, keep the handle rooted, and match the accept path.

### SOCK-13: reset skips ListenerClosed for closing listener
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/SocketTables.cpp:41-63 `resetTables`
- **Original claim:** A closing listener's ListenerClosed is not dispatched on reset, so the notification is lost.
- **Analysis:** This is intentional and documented (:39-40, :53). `resetTables` runs only when the heap generation changes. That happens only through `Allocator::reset`/re-`initialize`, which is test-only (callers are all under /work/test). At that point no task of the old heap can resume, so there is nobody to notify. One real side-asymmetry: `parkedAccepts` get `takePendingResume` + `releaseHold` (:46-49), but `closeTokens` (SocketTables.hpp:71) get neither. Their entries stay in `Scheduler::pendingResumes_`, which is an external GC root set (Scheduler.cpp:55-74), and hold stale encoded pointers into the reset heap. Their holds are never released either.
- **Impact:** Lost notification: none. Side issue: test-only. A pending resume and a hold leak per in-flight `closeListener` across a heap reset, and a stale root that the next GC evacuates.
- **Suggested fix / next step:** In `resetTables`, treat `e.closeTokens` like `parkedAccepts` (`takePendingResume` + `releaseHold`).

### WS-08: wsRandomBytes falls back to mt19937_64
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsHandshake.cpp:167-173 `wsRandomBytes`; used by WsProtocol.cpp:35-44 `nextMask`
- **Original claim:** There is a silent non-cryptographic fallback for masking keys.
- **Analysis:** If `RAND_bytes` fails, the function silently uses a thread-local `mt19937_64` seeded with one `random_device` value. On `_WIN32` it always does, because `RAND_bytes` is compiled out. That contrasts with `wsNewKey` (:175-184), which throws on failure. RFC 6455 §5.3 requires masking keys that cannot be predicted. Mitigating factors: `RAND_bytes` practically never fails on a seeded OpenSSL. The Windows client dial already returns ENOTSUP (WebSocket.cpp `wsDialBody`), and only clients mask. Masking also guards against attacker-controlled payloads poisoning proxy caches, which matters little for a non-browser client.
- **Impact:** Masking keys could be predicted only when OpenSSL's RNG fails; there is no practical exposure today.
- **Suggested fix / next step:** Throw or fail the connection as `wsNewKey` does instead of falling back, or use `BCryptGenRandom` on Windows.

### WS-09: serializeRequest writes target unvalidated
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsHandshake.cpp:263-268 `serializeRequest`; caller WebSocket.cpp:~288-289 `wsDialBody`
- **Original claim:** CR/LF in the target is not rejected, so headers can be injected unless Elm validates.
- **Analysis:** It is true that the C++ code concatenates `target` raw. Header pairs are filtered by `httpHeaderValid` (:132), but the target is not. However, the only path is `WebSocket.connectWith` → `Handshake.parseUrl` (system-kernel-cpp/src/WebSocket.elm:1013; WebSocket/Internal/Handshake.elm). That parser rejects any character outside 0x21-0x7E ("invalid character", Handshake.elm:126, :167-177), so CR, LF and space cannot reach the target. Kernel functions cannot be called from user code.
- **Impact:** None reachable today; a latent hazard if another caller is added.
- **Suggested fix / next step:** Optional defense in depth: reject bytes <= 0x20 or 0x7F in `serializeRequest`.

### WS-10: kWatchCap overshoot by one
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsHandshake.hpp:133, :146 `HoldProtocol::wantsRead`
- **Original claim:** There is an off-by-one in the watch cap.
- **Analysis:** `wantsRead` returns `leftover_.size() < kWatchCap`. `Conn::serviceReads` checks it before each read (Conn.cpp:655), so at most one read chunk (`kChunk`) lands past 1 MiB. The header documents this as intended ("one delivery may take it past", :127). It is not an off-by-one, and it is bounded.
- **Impact:** Up to one chunk of extra buffering per parked connection.
- **Suggested fix / next step:** None.

### WS-11: resume path skips default heartbeat timeout
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:685 `WsCore::checkPause` (unpause branch)
- **Original claim:** On resume, `hbDeadline_ = t + cfg_.heartbeatTimeout` skips the default, so the deadline is immediate when the timeout is 0.
- **Analysis:** Line 685 uses `cfg_.heartbeatTimeout` raw. Every other site applies the `kDefaultPingTimeoutMs` (30 s) fallback: the next line, 687, `startPing` :1190, and the heartbeat timer :1227. `heartbeatTimeout` is 0 whenever Elm passes timeout <= 0 (WebSocket.cpp:452), which the Elm docs explicitly allow ("a `timeout` of 0 or less means 30 seconds", WebSocket.elm:716). So with `{interval > 0, timeout = 0}` and a heartbeat ping outstanding when the stream pauses, unpausing sets `hbDeadline_ = now`. `armPongTimer` fires at once, and `portTimer(kTimerPong)` calls `heartbeatTimeout()` unless `rxBytes_ > rxAtPing_` (:1245-1252). That check usually passes, because entering pause needs incoming data, which normally arrives after the ping. That is why this is LOW rather than MEDIUM. The 30 s grace the docs promise is still lost.
- **Impact:** Rare spurious `HeartbeatTimedOut`, which needs a ping outstanding through a pause with no byte received since the ping.
- **Suggested fix / next step:** Use `t + (cfg_.heartbeatTimeout > 0 ? cfg_.heartbeatTimeout : kDefaultPingTimeoutMs)` at :685.

### WS-12: closeFrameWritten ignores err
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/WebSocket/WsProtocol.cpp:1028-1043 `WsCore::closeFrameWritten` (callbacks at :216, :739, :1078)
- **Original claim:** A write error for the Close frame is ignored, which masks the failure.
- **Analysis:** The `int` parameter is unnamed and unused. When the Close frame's write fails (`Conn::writeFailed`/`flushPending` → `failOutbound(err)`), or is cancelled by `closeNow` → `failOutbound(ECANCELED)` (Conn.cpp:604-612, :838), several things happen. `closeWritten_` is set. Every `startClose` op gets a success `OpDone`, and every `closeWritable` waiter gets a success `ChannelResult`. `finishIfDone` may post a clean `Closed` if the peer's Close was received. All of this runs before `onError` → `ended()`. Since `closeWritten_` is already true, `ended()` (:1099) no longer completes the waiters with ECANCELED as it was designed to. The documented contract (writeClose :976, ended :1099-1114) is that close requests whose Close never got out fail with ECANCELED "socket closed".
- **Impact:** `WebSocket.close` / `Stream.closeWritable` on a WebSocket report success when the Close frame was not written (write error or abort). The CloseInfo may also say clean when it was not.
- **Suggested fix / next step:** If `err != 0`, either route to the `ended()` waiter-failure path (ECANCELED, `kSocketClosed`) without setting `closeWritten_` as success, or post the waiters with the error. Settle it with a test that aborts the transport while a Close is queued.

### WS-13: ended sets closeWritten_ without a write
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:1099-1101 `WsCore::ended`; :970-985 `writeClose`; :994-998 `startClose`
- **Original claim:** `ended` sets `closeWritten_` without writing, so a later `writeClose` succeeds without sending anything.
- **Analysis:** When close waiters exist at an abnormal end, `ended` fails them with ECANCELED but sets `closeWritten_ = true` (:1101). A later `writeClose` takes the early branch (:971). Its error is set only when `!clean_ && !closeWritten_` (:976), so it now reports **success**. With no earlier waiters, `closeWritten_` stays false and a later close gets ECANCELED. The answer therefore depends on whether an earlier close was pending. (`startClose` always reports success in that branch, :995-997, whatever the state.) The connection is already gone, so "Close never sent" cannot be helped. The defect is only the inconsistent success result.
- **Impact:** A late `closeWritable` after an abnormal end may succeed or fail depending on history. This is a minor API inconsistency.
- **Suggested fix / next step:** Use a separate flag (for example `closeAttempted_`) in `ended`, or base the `writeClose` early-branch error on `clean_` alone.

### WS-14: ping before attach never sent
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:1184-1196 `WsCore::startPing`, :88-94 `WsCore::attach`; S/WebSocket/WebSocket.cpp:464-531 `wsOpenBody`, :701-719 `wsPingBody`
- **Original claim:** A ping started before the core is attached to a port is never sent and gets no deadline.
- **Analysis:** True as a code fact. With `port_ == nullptr`, `startPing` pushes the Ping, `armPongTimer` returns early (:1205) and `writeControl` drops the frame (:704-706, `done` is null). `attach` (:88-94) arms only the heartbeat and pumps `outQ_`. It never re-sends queued pings and never arms `kTimerPong`. But in the normal flow this cannot happen. Elm learns the wsId only from the `Opened` event (`onOpened`, WsTables.cpp:149-173). Every path posts `Opened` and then attaches in the same reactor command: h1 via `setProtocol` -> `WsProtocol::onOpen` -> `attach` (WebSocket.cpp:529-530, Conn.cpp:485-499); h2 via `H2StreamPort::bind`, which always calls `attach` (H2StreamPort.cpp:48-61), even when `accept`/`bindPort` fail. A ping is submitted only after Elm has seen `Opened`, and reactor commands run in FIFO order, so attach always comes first. The only way to reach this state is WS-NEW-1, where the core is never attached at all.
- **Impact:** Only via WS-NEW-1: the ping task never completes until close (`postClosed` cancels pings, and on that path it never runs either).
- **Suggested fix / next step:** Fix WS-NEW-1. For defence, have `attach` call `armPongTimer()` and re-send pending ping payloads.

### WS-15: Close queued before attach has no deadline
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:994-1026 `startClose`/`queueGracefulClose`, :88-94 `attach`
- **Original claim:** A graceful Close queued before attach arms no close-handshake timer, so it may hang.
- **Analysis:** `queueGracefulClose` sets `kTimerCloseHandshake` only `if (port_ && !transportGone_)` (:1022-1024). `attach` sends the queued Close frame through `pumpWrites` (:93) but never arms the deadline. The reachability is the same as WS-14: `wsCloseBody` needs the wsId, which Elm gets only after `Opened`, and attach runs in the same reactor command that posts it. So in practice it is not reachable, except on the WS-NEW-1 path, where the frame is never sent at all.
- **Impact:** Latent. On the WS-NEW-1 path the `close` task and the `closeHandshake` hold (WsTables.cpp:331-335) never release, so the program never exits.
- **Suggested fix / next step:** In `attach`, arm `kTimerCloseHandshake` when `closeQueued_` is set. The real fix is WS-NEW-1.

### WS-16: failWith no close deadline, may send second Close
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:1062-1085 `WsCore::failWith`, :730-741 `pumpWrites` (isClose branch), :1028-1029 `closeFrameWritten`
- **Original claim:** failWith arms no close deadline and may write a second Close frame.
- **Analysis:** The deadline part is WEAK. `failWith` ends with `portCloseGraceful(kDrainMs)` (:1081-1084), and both ports bound that: `Conn::closeGraceful` has its drain timer, and `H2StreamPort::portCloseGraceful` arms `kTimerDrain` (H2StreamPort.cpp:134-142, fired at :184-186). So nothing hangs. The second-Close part is real. `closeWritten_` becomes true only in the write's completion callback (:1029). Once `pumpWrites` has handed a graceful Close to the port (:736-740) and the Conn is still backpressured, `closeWritten_` is still false. A later `failWith` then calls `writeControl(kOpClose, ...)` again (:1074-1079), because `failQueued` only drops Close items still in `outQ_`. Paths that can reach it after a Close was handed over: the heartbeat pong deadline -> `heartbeatTimeout` (:1245-1252, which does not check `closeQueued_`), `outAbort` of a started stream (:910-913), and a UTF-8 or inflate failure on a message still inflating (:304-307, :361). The peer-Close echo path (:206-217) has the same window.
- **Impact:** Two Close frames go on the wire, which RFC 6455 §5.5.1 forbids. A strict peer logs a protocol error. The connection is ending anyway.
- **Suggested fix / next step:** Add a `closeSent_` flag, set when a Close frame is handed to the port (in `pumpWrites` and `onControl`), and test it in `failWith` instead of `closeWritten_`.

### WS-17: checkPause updates interest only on resume
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsProtocol.cpp:669-692 `WsCore::checkPause`, :101-103 `wantsRead`
- **Original claim:** `updateInterest` is not called when the core pauses.
- **Analysis:** It need not be. `wantsRead()` depends on `paused_`. Both transports test it before each read: `Conn::serviceReads` checks `protocol_->wantsRead()` on every iteration (Conn.cpp:657), and `H2StreamPort::deliver` checks `core_->wantsRead()` per chunk (H2StreamPort.cpp:68). Pausing nearly always happens inside an input callback (`onMessage`/`onDataEnd` from `portData`), so the loop stops at once. A later readiness event finds `wantsRead()` false and reads nothing. On Conn, `updateInterest` means `runIo(true,true)` (Conn.cpp:601-603), which would only start a pointless IO pass. Resume needs the call because reads have to restart. Pause does not.
- **Impact:** None found. At most, level-triggered wakeups go unused while paused.
- **Suggested fix / next step:** None. A comment in `checkPause` saying the asymmetry is deliberate would help readers.

### WS-18: deliverClose marks delivered before deliver
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/WebSocket/WsManager.cpp:188-199 `deliverClose`, :117-139 `deliver`, :243-253 `deliverHeldCloses`
- **Original claim:** `closeDelivered` is set before `deliver`, which can return early, so the close event is lost.
- **Analysis:** `deliverClose` sets `e->closeDelivered = true` (:191) before `deliver` (:198). `deliver` returns without sending anything when `subsOf(wsId)` is null (:124), and it sends zero messages when `closes` is empty. Two callers check `s && !s->closes.empty()` immediately before the call (readerFn :163, `wsManagerOnClosed` :354). `deliverHeldCloses` does not. It snapshots the ids that have close subscriptions (:244-247), then calls `deliverClose` for each in turn (:250), and each call runs Elm code and drains the scheduler (:134-136). If that Elm code runs `onEffects` and drops or changes a later id's `onClose` subscription, the later id is marked delivered without any delivery. A subscription made again afterwards then never gets the close, although the Elm docs promise delivery to the subscriptions present at delivery time (WebSocket.elm:577-584). `routerEnc == 0` cannot coincide with non-empty subs.
- **Impact:** A narrow race: several WebSockets close at once, and their subscriptions churn during delivery. One close event is silently dropped.
- **Suggested fix / next step:** In `deliverHeldCloses`, re-check `subsOf(id)` and `!closes.empty()` before each `deliverClose`. Or set `closeDelivered` only when at least one tagger was found.

### WS-19: close with no subscriber lost after retire
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/WebSocket/WsTables.cpp:71-81 `maybeRetire`; S/WebSocket/WsManager.cpp:206-239 `reconcile`, :243-253 `deliverHeldCloses`
- **Original claim:** A WebSocket that closes with no subscriber retires its entry before the close can be delivered, so a later `onClose` never fires.
- **Analysis:** `maybeRetire` erases the entry once it is closed, both faces are gone, and there are no `closed` waiters and no subscribers (:76-77). After that, `findWs` returns null, so `reconcile`/`deliverHeldCloses` never deliver to an `onClose` made later. While the entry still exists, a late `onClose` does receive the held close (`deliverHeldCloses` at :250, `reconcile` at :233). Whether a late subscriber sees the close therefore depends on when the stream faces (`~WsReadChannel`/`~WsWriteChannel`, WsChannel.cpp:36-39, :70) are destroyed, which is outside the program's control. The docs say a subscription made after delivery receives nothing, but say nothing about a close nobody was subscribed to. `WebSocket.closed` handles the same case consistently through `recentlyClosed` (WebSocket.cpp:663-669). No hang results: with `e == nullptr`, `reconcile` takes no hold.
- **Impact:** A late `onClose` subscription fires or not depending on timing.
- **Suggested fix / next step:** Decide the semantics. Either deliver to late subscribers from `recentlyClosed` (keeping a delivered flag there), or document that a close with no subscriber at that moment is never delivered, and make the held-close path behave the same.

### WS-20: reject/open trust Elm's role
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WebSocket.cpp:382-542 `wsOpenBody` (role at :412, :445, :449), :544-609 `wsRejectBody`; WsTables.hpp `WsHandshakeEntry::server`
- **Original claim:** open/reject use the role passed from Elm and ignore `WsHandshakeEntry::server`.
- **Analysis:** Correct as a code reading: `cfg.server = role == 1` and the response serialization both come from the payload, and `reject` never checks `server`. But the role is fixed by the Elm wrapper, not chosen by the user. `kOpen hsId ... (openParams 0 ...)` is used only in the dial path (WebSocket.elm:1117-1119). `kOpen up.id ... (openParams 1 ...)` is used only in `accept` (:1408-1416). `kReject` takes an `Internal.Upgrade` (:1438-1440), which only server handshakes produce. The kernel functions are not exposed, so well-typed user code cannot cause a mismatch.
- **Impact:** None from user programs. This is defence in depth only.
- **Suggested fix / next step:** Optional: assert `role == (entry.server ? 1 : 0)`, or derive the role from `it->second.server` and drop it from the payload.

### WS-21: failed open may leave WsEntry
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** S/WebSocket/WebSocket.cpp:468-470 (entry emplaced), :474-487 and :495-511 (reactor failure paths), :533-538 (pairs created); S/WebSocket/WsTables.cpp:149-173 `onOpened`, :71-81 `maybeRetire`; S/Stream/Stream.cpp:243-253 `maybeErase`
- **Original claim:** A failed open does not erase its WsEntry, so it leaks.
- **Analysis:** `wsOpenBody` puts the `WsEntry` in place and creates the readable and writable pairs (`createMappedSource`/`createMappedSink`) before the reactor command runs. When that command fails (h2 `describe` false at :480-486; or not a Hold/H2 protocol, or the conn closing or aborted, at :504-510), it calls `core->portClosed()` and posts `Opened` with `failed`. `onOpened` then resumes the task with the failure (:161-162) and never touches the entry or the pairs. The killed-task path (:153-155) behaves the same. `onClosed` marks the entry closed, but `maybeRetire` needs `facesAlive == 0` (:76). The faces die only when their stream pairs are destroyed, and Elm never received the pair ids. `maybeErase` needs both sides `Closed` and no in-flight state (Stream.cpp:246-249). The sink's write side stays `Open`, and the source's read-ahead ends Errored, not Closed. So the entry, the `WsCore`, and both pairs (including the rooted `fromWire`/`toWire` closures in `mapFnEnc`) stay until the next heap reset. Trigger: the peer drops the connection between the handshake and `accept`/`open`, or the open task is killed.
- **Impact:** A long-running server leaks C++ memory and Elm heap closures for each such client.
- **Suggested fix / next step:** On a failed or killed `Opened`, call `discardReadable(rid)` and the matching sink discard, then erase the `WsEntry` (or set `facesAlive = 0` and retire it). Test: a server accepts, the client resets before `accept` runs; check that the stream-table and ws-table sizes return to their baseline.

### WS-22: armTimer drops timer_ on failed add
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/H2StreamPort.cpp:153-168 `H2StreamPort::armTimer`; S/Core/IoReactor.cpp:509-531 `IoReactor::add`
- **Original claim:** When `reactor().add` fails, `timer_` is dropped and no deadline fires until the next arm.
- **Analysis:** The handling is as described (:162-165), but the failure cannot happen. `IoReactor::add` returns 0 only for a null handler or one that already has a key (:511). `timer_` is a freshly made `Timer` with key 0, and fd -1 is accepted. Slots grow without limit (:514-520), so there is no capacity failure.
- **Impact:** None. The branch is unreachable.
- **Suggested fix / next step:** None needed. Optionally replace it with an assert.

### WS-23: cancelClosedWaiter does not release hold
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsTables.cpp:355-364 `cancelClosedWaiter`; S/Core/KillHandle.cpp:26-33 `killEval`; S/WebSocket/WebSocket.cpp:671-675 `wsClosedBody`
- **Original claim:** Killing a `closed` task erases its token but keeps its hold, so the program may not exit.
- **Analysis:** The hold is released by the caller. The `closed` task's kill handle comes from `makeKillHandle(token, &cancelClosedWaiter)` (WebSocket.cpp:675). `killEval` takes the pending resume and then runs `if (cancel && cancel(token)) s.releaseHold(token);` (KillHandle.cpp:30-31). `cancelClosedWaiter` returns true exactly when it erased the token (:360-361), so the hold is released exactly once. When it returns false, the waiter has already been swapped out by `onClosed`, which releases it through `HoldRelease waiterHold(token)` (:214), and its resume is already gone. This matches the `CancelFn` contract (Core.hpp:60-65). A small oddity: after a cancel, `maybeRetire` is not called. That does not matter, because waiters exist only while `!e.closed`.
- **Impact:** None.
- **Suggested fix / next step:** None. Optionally note in a comment that the kill handle releases the hold.

### TERM-01: raw-mode failures silent
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Terminal/Terminal.cpp:152-173 `setRaw`, :113-124 `applyRaw`, :233-239 `terminalSetStdInRawModeBody`
- **Original claim:** Failures to enter raw mode (and read failures) are not reported.
- **Analysis:** True, and intended. `!isatty(0)`, a failing `tcgetattr`, and a failing `tcsetattr` all return silently (:154, :156, :162), and the body always succeeds (:237). The API is `setStdinRawMode : Bool -> Task x ()`, and the module docs say none of the tasks can fail and that it does nothing when stdin is not a terminal (Terminal.elm:16-18, :142-143). This module does no reads, so "read failures" does not apply. One small point: when `addListener` refuses (embed mode, :164-165), raw mode still goes on with no signal restore. The docs also cover that ("unless ... embedded").
- **Impact:** A program cannot tell that raw mode failed on a tty. That case is rare (for example EIO on a revoked tty).
- **Suggested fix / next step:** None, unless the API gains a result. The docs could mention that tcsetattr failures are ignored.

### TERM-02: other SIGINT/SIGTERM listener keeps raw mode
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Terminal/Terminal.cpp:142-148 `rawModeSignal`; S/System/SystemManager.cpp:137
- **Original claim:** When another listener handles the signal, raw mode is not restored.
- **Analysis:** This is the intended and documented behaviour. `listenerCount(signo) > 1` means another listener exists (:144). The only other `addListener` for SIGINT/SIGTERM in eco-system is the program's own subscription in SystemManager.cpp:137 (grep found no other). In that case the program handles the signal and is not ended, and Terminal.elm:153-159 says "the signal does not end it and raw mode stays on". If the program then exits normally, the `atexit` handler restores the mode (:136-138, :158).
- **Impact:** None beyond the documented behaviour. A program that handles SIGINT and then calls `abort`/crashes leaves raw mode on (see TERM-04).
- **Suggested fix / next step:** None.

### TERM-03: raw mode re-entered after survived signal
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Terminal/Terminal.cpp:142-148 `rawModeSignal`; S/Core/SignalService.cpp:281-289 `chainToPrevious`
- **Original claim:** Raw mode is turned back on after the process survives the signal.
- **Analysis:** This is intended, as the file comment says (Terminal.cpp:10-13). `chainToPrevious` puts back the previous disposition and `raise`s synchronously, so a default action kills the process with the mode already restored. If the process survives (the previous disposition was SIG_IGN, as for `cmd &` under a non-interactive shell, or a host handler returned), the program is still running and still asked for raw mode, so `applyRaw` again is correct. No signal masks are used anywhere (grep found no `pthread_sigmask`/`sigprocmask`), so `raise` is delivered at once. With ISIG cleared, keyboard Ctrl-C does not raise SIGINT at all.
- **Impact:** At most a brief cooked-mode blip on an ignored SIGINT/SIGTERM sent from outside.
- **Suggested fix / next step:** None.

### TERM-04: no restore on _exit/abort/SIGHUP/SIGQUIT
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/Terminal/Terminal.cpp:136-138 `restoreAtExit`, :158 `std::atexit`, :164-165 (only SIGINT/SIGTERM listeners); K/KernelExports.h:51-56 `reportFatal`
- **Original claim:** Raw mode is not restored on `_exit`, `abort`, SIGHUP or SIGQUIT.
- **Analysis:** Restoration happens only through `std::atexit` and the SIGINT/SIGTERM listeners. `Eco::Kernel::reportFatal`, used by `ECO_KERNEL_GUARD`, `ECO_SYSTEM_*_GUARD` and signal-dispatch exceptions (SignalService.cpp:299-301), calls `std::abort()` (KernelExports.h:55). That skips `atexit`, so any native fatal error or uncaught kernel exception in a TUI program leaves the user's terminal raw with no echo. SIGHUP/SIGQUIT/SIGABRT/SIGSEGV have no handler either. This limitation is documented (Terminal.elm:149-156: "not when a fatal error stops the program ... any other signal that ends the program leaves raw mode on"). SIGQUIT cannot come from the keyboard while ISIG is off, and on SIGHUP the terminal is usually gone, so the crash and abort path is the one that matters.
- **Impact:** After a crash the user's shell has no echo and no line editing until they type `reset`/`stty sane`.
- **Suggested fix / next step:** Restore in `reportFatal` before `abort()` through an async-signal-safe hook (`tcsetattr` on the saved termios is safe), and optionally in SIGABRT/SIGSEGV/SIGHUP handlers that restore and re-raise.

### WS-NEW-1: open over HTTP/1.1 can report success while the core is never attached (permanent hang)
- **Status:** LIKELY · **Severity:** MEDIUM
- **Where:** S/WebSocket/WebSocket.cpp:495-531 (h1 reactor lambda in `wsOpenBody`); S/Socket/Conn.cpp:485-499 `Conn::setProtocol`, :563-572 `Conn::write`, :727-735 `writeFailed`, :929-978 `abort`, :830-842 `closeNow`; S/WebSocket/WsHandshake.hpp:143-161 `HoldProtocol` (watch mode)
- **Original claim:** (New) The connection state is checked once (:504), then the server's 101 response is written synchronously (:524). Only after that are `Opened` posted (:529) and the protocol installed (:530).
- **Analysis:** `Conn::write` calls `runIo` right away (Conn.cpp:571). If `send` fails (EPIPE/ECONNRESET, because the peer reset in the window since the last poll), `writeFailed` calls `protocol_->onError`. The server handshake's watch-mode `HoldProtocol::onError` -> `goneNow` -> `c.abort(false)` -> `closeNow()` sets `phase_ = Closed` and fires the close hooks synchronously. Back in the lambda, `Opened` is posted as a success, and then `setProtocol(WsProtocol)` returns early because `phase_ != Open` (Conn.cpp:488). So `WsProtocol::onOpen` never runs: there is no `attach`, no close hook, and `portClosed` is never called on the core. Elm gets an open WebSocket whose core has `port_ == nullptr` and `transportGone_ == false`. Writes queue forever (`reqWrite` -> `pumpWrites` returns at :731), reads park forever, and `ping`/`close` hang (WS-14/WS-15). `WebSocket.closed` parks with a hold that never releases (WebSocket.cpp:671-675), so the program never exits. `onClosed` never fires. A TLS transport write error leads to the same thing.
- **Impact:** A peer that resets during the upgrade can leave a server task hung for good and the process unable to exit. The window is narrow but reachable from ordinary programs.
- **Suggested fix / next step:** After `setProtocol`, check `c->phase() == Open && !c->aborted()`. If it fails, call `core->portClosed()` and post `Opened` as failed. Simpler: post `Opened` only after `setProtocol` succeeds, and have `attach` or `onOpen` failing call `portClosed`. Test: inject a failing transport write for the 101 response and check that the open task fails, or that `closed` resolves.

### TERM-05: title filter keeps 0x80-0x9F
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Terminal/Terminal.cpp:80-88 `terminalTitleSequence`; caller `terminalSetTitleBody` :242-257
- **Original claim:** C1 control characters are not stripped from the title, so a 0x9C (ST) could end the OSC sequence early.
- **Analysis:** The filter drops bytes < 0x20 and 0x7F only (:83-84). The input is the UTF-8 encoding from `toStdString` (Core/Core.cpp:33 -> `Eco::Kernel::toString`). So a raw byte 0x9C is almost always a UTF-8 continuation byte (for example in U+011C or U+021C), and stripping bytes 0x80-0x9F as the entry suggests would corrupt any non-ASCII title. The real gap is code points U+0080-U+009F, encoded as C2 80..C2 9F. These pass through. A UTF-8 terminal that honours C1 controls in UTF-8 form (xterm and some others can be set up to) would read U+009C as ST, or U+009B as CSI, and end or hijack the sequence. Reaching this takes an Elm String containing those code points, which an untrusted string passed to `Terminal.setTitle` could contain. Most terminals ignore C1 in UTF-8 mode.
- **Impact:** Mostly cosmetic: a truncated title, or the rest of the title shown or run as escape text on terminals that honour C1. There is a small escape-injection angle if the title comes from untrusted input.
- **Suggested fix / next step:** Strip the two-byte sequences C2 80..C2 9F (code points U+0080-U+009F), not raw bytes 0x80-0x9F. Add a unit test of `terminalTitleSequence("a\u009Cb")`.

### TERM-06: first setStdInRawMode False saves mode
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Terminal/Terminal.cpp:152-174 `setRaw`
- **Original claim:** The first `setStdInRawMode False` saves the tty mode and registers the exit handler for no reason.
- **Analysis:** `setRaw` runs `tcgetattr` + `saved=true` + `std::atexit(&restoreAtExit)` (:155-159) before it looks at `on`. A first call with `on=false` and `raw=false` then does nothing else. `restoreAtExit` restores only when `tty().raw` (:136-138), so the registered handler does nothing. The one subtle effect: the "original" mode is taken at the first False call. If something else (for example `stty`) changes the mode before the first True call, a later restore puts back the older mode.
- **Impact:** No observable effect in practice. In a rare case the restore goes back to a stale mode.
- **Suggested fix / next step:** Return early when `!on && !s.raw`, before the save and registration. This is optional.

### FS-02: failed watch never retried
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/FileSystemManager.cpp:199-213 `onEffectsEval`; S/FileSystem/WatchService.cpp:383-413 `WatchService::add`
- **Original claim:** A watch that failed (watchId 0) is never retried while it stays subscribed, so it delivers no events.
- **Analysis:** True as described. When `add` returns 0 (for example a path that does not exist, :395-398 or :406), the entry is kept with `watchId=0` and no hold (:203-210). Later `onEffects` calls find the key (:201) and only refresh the taggers, so there is no retry until the subscription goes away and comes back. This matches the documented contract, though: FileSystem.elm:965 says "A path that cannot be watched, such as one that does not exist, gives no events and no error." The program is also correctly not kept alive (no hold).
- **Impact:** Watching a path before it is created never starts delivering events. That is documented behaviour, not a defect.
- **Suggested fix / next step:** Leave it, or as a feature retry failed keys on each `onEffects`. If so, document it and keep it consistent with the JS backend.

### FS-03: close erases fd before submit
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/FileSystem/FileSystem.cpp:172-201 `fsPoolSubmit` (erase at :187); `opClose` at S/FileSystem/FileSystemOps.cpp:527-530
- **Original claim:** `close` removes the fd from the open-handle table before the job is submitted, so an exception or failure leaves the fd untracked.
- **Analysis:** For `FsKind::Close` the fd is erased at :187. After that, `parkResume` (:192) and `SysWorkPool::submit` (:195-198) can throw, in practice only `std::bad_alloc`. The `ECO_SYSTEM_ASYNC_GUARD` (Core/Core.hpp:239-255) catches it and fails the Task, but the fd is never closed and is no longer in the table. Any later op on it, including another close, gets EBADF (:184), so the fd leaks. A `close(2)` failure itself is fine: on Linux the descriptor is released even on EIO/EINTR, so erasing first is correct there, and it also stops new ops being queued on a closing fd.
- **Impact:** One fd leak, only on OOM inside the submit path.
- **Suggested fix / next step:** Put the fd back in the table, or call `::close` directly, in the catch path. Or erase only after `submit` returns. Low priority.

### FS-04: out-of-range result kind succeeds with ()
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/FileSystem.cpp:104-131 `fsComplete` (fallback `return succeedUnit();` at :130)
- **Original claim:** An `FsRes::Kind` outside the enum's range is not rejected; it succeeds with `()`.
- **Analysis:** The switch covers all eight enumerators of `enum class Kind : uint8_t { Unit, Int, Str, Bytes, Ints, Dir, ReadStream, WriteStream }` (FileSystem.hpp:71). Every `FsRes` is built by the ops in FileSystemOps.cpp with named enumerators, so an out-of-range value can only come from memory corruption. The trailing return mainly keeps the compiler quiet.
- **Impact:** None reachable.
- **Suggested fix / next step:** Optionally replace it with `reportFatal("bad FsRes kind")` to make it defensive.

### FS-05: opRemove error_code category unchecked
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/FileSystemOps.cpp:398-414 `opRemove` (:408-410)
- **Original claim:** `ec.value()` from `std::filesystem::remove_all` is used as an errno without checking the error category.
- **Analysis:** FileSystemOps.cpp is the POSIX file; Windows has FileSystemOpsWin32.cpp, which has no `remove_all`/`ec.value` use. On POSIX, both libstdc++ and libc++ report filesystem errors as errno values in `generic_category`/`system_category`, so the value is an errno. A zero value already maps to EIO (:410). Using the category check would change nothing on supported platforms.
- **Impact:** None on POSIX.
- **Suggested fix / next step:** Optionally map `ec.category() != generic/system` to EIO for portability. No action needed.

### SOCK-14: parseScope accepts "0"
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SocketUtil.cpp:170-188 `parseScope`; `scopeName` :162-168
- **Original claim:** `addr%0` parses as an unscoped address.
- **Analysis:** A digit scope "0" gives `scopeId=0` (:176-181), which is the same as no scope. glibc `getaddrinfo`/`inet_pton` with a scope and libuv `uv_ip6_addr` treat numeric "%0" the same way (scope id 0). `scopeName(0)` returns "" (:163), so the text form does not round-trip "%0", but the address is the same. This is consistent with platform behaviour.
- **Impact:** At most `fe80::1%0` acts like an unscoped link-local address, which the kernel then rejects or routes as it would without a scope.
- **Suggested fix / next step:** None required. Optionally reject "%0" if node rejects it (it does not appear to).

### CORE-12: ChannelDrain drops results with no dispatcher
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/ChannelDrain.cpp:111-128 `channelDrain` (:116 `if (!fn) continue;`); dispatcher set in S/Stream/Stream.cpp:283-291 `streamTable()`
- **Original claim:** Results that arrive while no dispatcher is set are dropped, their tokens are never completed, and Tasks hang.
- **Analysis:** The only caller of `setChannelDispatch` is `streamTable()` (Stream.cpp:288), which installs `channelDispatch` the first time the table is touched and never clears it. Every channel request with a token comes from Stream code (Stream.cpp:947, 1235, 1369; StreamPipe.cpp:95, 289) on a channel that is in the stream table through `insertChannelPair` (Stream.cpp:261 calls `streamTable()`). So the dispatcher is always set before any result can be posted. The `requestWriteTagged` ENOTSUP path (ChannelDrain.cpp:61-73) is also only called from stream code.
- **Impact:** Not reachable with the current callers. It would only matter if a future non-stream user of `ByteChannel` posts results.
- **Suggested fix / next step:** Replace `continue` with an assert or `reportFatal` so a future misuse shows up loudly instead of hanging.

### WS-24: inflateInit2 failure reported as OOM
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsDeflate.cpp:90-95 `Inflater::ensure`, :136-140 `Inflater::step`
- **Original claim:** Every `inflateInit2` failure is reported as "out of memory".
- **Analysis:** `inflateInit2(&s, -15)` runs on a zero-initialised `z_stream` (default allocators) with a constant valid windowBits. It can only return Z_MEM_ERROR, or Z_VERSION_ERROR if the linked zlib header and library do not match, which is a build defect. Z_STREAM_ERROR cannot happen. So the message is right in every runtime-reachable case. The Deflater side (:43) returns `false` without any message.
- **Impact:** At worst a misleading message on a broken zlib build.
- **Suggested fix / next step:** Optionally include the zlib return code in `err_`. No action needed.

### CORE-13: negative quiesce timeout waits 0 ms
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/IoReactor.cpp:636-645 `IoReactor::quiesce`; contract at S/Core/IoReactor.hpp:140-148
- **Original claim:** A negative quiesce timeout is treated as 0 instead of waiting.
- **Analysis:** The clamp at :643 is the documented contract ("a negative value is taken as 0", IoReactor.hpp:144). The only production caller passes 100 (Tls/TlsContext.cpp:36). This is intended behaviour, unlike `runOnce`, where a negative value means "for ever"; that asymmetry is the only oddity.
- **Impact:** None.
- **Suggested fix / next step:** None. Optionally note the asymmetry with `runOnce` in the header.

### TLS-10: stage-2 entry kept until generation change
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Tls/Tls.cpp:69-124 (`PendingTable`, `pendingConnects`, `connectStage2Body`, `connectPrepared`); file comment :3-7
- **Original claim:** If the Task is killed between stage 1 and stage 2, the pending entry stays until the heap generation changes.
- **Analysis:** `connectPrepared` (:116-124) puts a `PendingConnect` (ConnectSpec + `shared_ptr<TlsClientConfig>`, which holds an SSL_CTX) in the table and returns a stage-2 binding. The entry is removed only when that binding runs (:107-108), or when `currentHeapGeneration()` changes (:86-91). If the process is killed after stage 1 completes but before the scheduler evaluates the binding, the entry is never removed. The file comment admits this (:6-7). "Bounded" is optimistic: the heap generation changes only on a heap reset (tests), so in a normal program each such race leaks one entry for the rest of the process. The race needs a `Process.kill` (or a timeout-style kill) to land in the short window between completion and the next step of that process.
- **Impact:** A small per-occurrence leak of the config, the SSL_CTX reference and the strings. It grows only with repeated kill races (for example a "connect with timeout" loop that often cancels).
- **Suggested fix / next step:** Hook the Task's kill handle or hold release to erase the entry, or give entries an age or count cap. Settle it with a test that kills the connect Task right after stage 1 completes, many times, and checks the table size.


## Robustness

### IO-01: write loops spin on 0-byte writes
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/Console.cpp:54-92 `writeBody` (loop :72-90); K/File.cpp:575-584 (`writeBytesAtomic` loop); S/FileSystem/FileSystemOps.cpp:146-163 `writeAll`
- **Original claim:** The write loops spin forever if `write` returns 0.
- **Analysis:** All three loops handle only `n < 0` and add `n` to the offset, so `n == 0` with bytes left would loop forever. `write`/`pwrite` with a nonzero count on regular files, pipes, sockets and ttys do not return 0 on Linux/macOS: full disk gives ENOSPC, the file-size limit gives EFBIG/SIGXFSZ, non-blocking gives EAGAIN. Only odd character devices could do it. The Terminal title writer already guards with `n <= 0` (S/Terminal/Terminal.cpp:251). A related, more realistic gap: none of these loops handles EAGAIN. If stdout/stderr were inherited as O_NONBLOCK (common when a Node parent shares the tty or pipe), Console.write fails with "console write failed" partway through instead of waiting.
- **Impact:** The hang is theoretical. The EAGAIN case is a reachable partial write plus spurious failure on a non-blocking inherited stdout.
- **Suggested fix / next step:** Treat `n == 0` as EIO in all three loops (cheap). Consider poll-and-retry on EAGAIN in Console `writeBody`.

### CONSOLE-02: log ignores write result
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Console.cpp:165-178 `log`
- **Original claim:** `log` ignores the result of `write`, so a short write, EINTR or an error goes unnoticed.
- **Analysis:** A single `(void)_eco_write(stderr, msg)` (:170-176) with no retry. EINTR before any byte is written loses the whole line. A signal mid-write to a pipe, or a non-blocking stderr (EAGAIN), loses the tail. Large messages to a pipe can be partially written. `log` returns no Task, so the error cannot be reported, but a retry loop is easy to add (`writeBody` has one).
- **Impact:** Lost or truncated debug trace lines (Debug.log-style output). No effect on program results.
- **Suggested fix / next step:** Reuse a write-all loop with EINTR retry, ignoring a final error.

### CONSOLE-03: Windows tag >0x7fffffff truncated
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Console.cpp:170-173 `log` (Windows branch)
- **Original claim:** On Windows, a log tag longer than 0x7fffffff bytes is truncated.
- **Analysis:** The length is clamped to 0x7fffffff for `_write` and there is only one call, so anything past 2 GiB (and any short write) is dropped. `writeBody` loops over the clamp (:72-89); `log` does not. This needs a log tag of more than 2 GiB, and it is Windows-only (low priority by project policy).
- **Impact:** Practically none.
- **Suggested fix / next step:** Fold into the CONSOLE-02 fix (a write-all loop with the per-call clamp).

### CONSOLE-04: readLine/readAll block
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Console.cpp:96-117 (`readLineBody`, `readAllBody`); binding made at K/Console.cpp:149-155
- **Original claim:** `readLine`/`readAll` do blocking reads and stall the event loop.
- **Analysis:** Both bodies call `std::getline(std::cin, ...)` straight from a synchronous `makeBinding` body (Console.cpp:99, 109). Binding bodies run on the eco thread, the one the scheduler runs on, so while the read waits nothing else runs on that thread: no fired TimerService tokens get processed, no Time.every ticks, and no channel or reactor results reach the scheduler. The file header (Console.cpp:8) and K/Console.hpp:30-35 say this on purpose ("The read blocks the thread running the Task"). So the defect is real but documented. It only matters for a program that mixes `Eco.Console.readLine`/`readAll` with concurrent subscriptions or IO. eco/system already offers stdin as an async FdChannel stream (S/System/System.cpp:159, S/Stream/Stream.cpp `createFdSource`).
- **Impact:** While the read waits, timers, subscriptions and socket results all freeze. `readAll` holds the thread until EOF.
- **Suggested fix / next step:** Either keep it as documented and point concurrent programs to the eco/system stdin stream, or reimplement it as `makeAsyncBinding` on a worker thread or FdChannel.

### TIME-08: non-finite intervals reach TimerService
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/time/TimeEffectManager.cpp:116-132 (`scheduleTimerTick`), E/core/ProcessExports.cpp:30-36 (`sleepBindingBody`); runtime/src/platform/TimerService.cpp:24-27 (`schedule`); contract at runtime/src/platform/TimerService.hpp:41-47
- **Original claim:** Infinite, NaN or huge delays are passed to `TimerService::schedule`, which requires finite values whose deadline fits `Clock`.
- **Analysis:** `schedule` does `duration_cast<Clock::duration>(duration<double,milli>(millis))` with no check. For ±inf, NaN or |millis| > ~9.2e12 ms the double-to-int64 conversion is UB, and so is the signed `now + d` overflow after it. `Process.sleep` (ProcessExports.cpp:32-36) passes the Elm Float straight through with no filter at all. `Time.every` drops NaN (TimeEffectManager.cpp:265-267) but not ±inf or huge values. On x86-64 the conversion in practice gives INT64_MIN, so the deadline lands in the past and the timer fires at once. That happens to resemble JS, where `setTimeout(Infinity)` and `setTimeout(NaN)` fire almost at once, but it is still UB, and a sanitizer or another target may differ. For `Time.every (1/0)` the immediate firing turns into the TIME-09 spin. Reachable from well-typed Elm (`Process.sleep (1/0)`, `Process.sleep (0/0)`), though unusual.
- **Impact:** UB, in practice an immediate wake-up. With `Time.every` at infinity, a busy loop.
- **Suggested fix / next step:** In `schedule` (or both callers), map NaN to 0 and clamp to [0, a max that fits, e.g. 2^62 ns], or treat +inf as "never".

### TIME-09: zero/negative intervals busy-loop
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/time/TimeEffectManager.cpp:132 (`schedule(intervalMs, token)`), :164 and :211 (`timerTickEvaluator` re-arming); runtime/src/platform/TimerService.hpp:42-44
- **Original claim:** There is no lower clamp, so `Time.every 0` or a negative interval spins the CPU.
- **Analysis:** `timerTickEvaluator` re-arms with the same interval (line 211). TimerService documents that a delay of zero or less "is not special: the timer fires as soon as the worker sees it" (TimerService.hpp:42-44). So `Time.every 0`, or any negative interval, delivers one tick per scheduler round trip, as fast as the eco thread can go. Each tick runs `sendToApp` and so an `update`. Other work still interleaves because ticks go through the ready queue, so this is a CPU spin, not a hang. JS clamps `setInterval` to at least 1 ms (Node) or 4 ms (browsers). Reachable from ordinary Elm, for example a computed interval that comes out as 0.
- **Impact:** 100% CPU and a message flood while subscribed. A behaviour gap from JS Elm.
- **Suggested fix / next step:** Clamp the interval in `scheduleTimerTick` to at least 1 ms (as Node does). Optionally do the same for sleep re-arm loops.

### ZLIB-01: uInt casts truncate >4 GiB input
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsDeflate.cpp:49 (`Deflater::chunk`); S/Stream/StreamCodec.cpp:114 (`deflateRun`) and :138 (`inflateRun`); fed from S/Stream/StreamCodec.cpp:291 and S/WebSocket/WsProtocol.cpp:758, 817
- **Original claim:** `static_cast<uInt>(n)` silently truncates inputs of 4 GiB or more.
- **Analysis:** `avail_in` is set once to `n mod 2^32`, and the loops end when `avail_in == 0` (WsDeflate.cpp:60; StreamCodec.cpp:126-128 non-finish branch). The rest of the input is silently skipped: the output is valid zlib for a truncated payload, the call reports success, and the next call starts on new input. The Inflater side already guards this, capping at `1u << 30` per call (WsDeflate.cpp:160), which shows the issue is known there. Reaching it takes a single Elm `Bytes` or String chunk of 4 GiB or more written to a deflate or inflate stream codec, or sent as one compressed WebSocket message. That is possible in principle but needs an enormous in-memory value.
- **Impact:** Silent data loss or corruption, with no error, on chunks of 4 GiB or more.
- **Suggested fix / next step:** Feed zlib in slices of at most `UINT_MAX` (or 1 GiB, as the Inflater does) inside the existing loops.

### CORE-14: backendInit partial failure leaks fds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/IoReactor.cpp:308-318 (epoll `backendInit`), :387-397 (kqueue); caller `IoReactor::IoReactor` :477-485
- **Original claim:** On a partial failure `pollFd`/`wakeFd` are leaked.
- **Analysis:** If `eventfd` fails (line 311) or `epoll_ctl` fails (line 317), `pollFd` (and `wakeFd`) stay open, and the ctor just logs and returns with `ok = false`. The kqueue path behaves the same when `kevent` fails. But the reactor is a leaky process-wide singleton (`instance()` :472-475), built once, and this path only runs when the process is out of fds or kernel memory. At most two fds leak, once per process, and they are never used because `ok` is false.
- **Impact:** At most two fds leaked once, in a path that already disables socket IO.
- **Suggested fix / next step:** Close and reset `pollFd`/`wakeFd` on each failure return. Cosmetic.

### CORE-15: IoReactor ctor errno read after return
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/IoReactor.cpp:477-481 (`IoReactor::IoReactor`), :308-318, :387-397
- **Original claim:** The ctor reads `errno` after `backendInit` returns, so the value may have been clobbered.
- **Analysis:** Every `return false` in `backendInit` comes directly after the failing syscall (`epoll_create1`, `eventfd`, `epoll_ctl`, `kqueue`, `kevent`), with no call in between. Returning from a function does not change `errno`. In the kqueue path the `fcntl` calls run only after `kqueue` succeeded, and a failure there does not make `backendInit` return false. The ctor saves `errno` into `e` before calling `fprintf` (line 480). The stub backend returns false without setting errno, but in that build the whole block is compiled out (`#if !defined(ECO_IOR_STUB)`).
- **Impact:** None. At worst a wrong strerror text.
- **Suggested fix / next step:** None needed. Optionally return the errno from `backendInit` explicitly.

### CORE-16: stale epoll entry after dup fd closed
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/IoReactor.cpp:353-358 (`backendCtl` DEL), :556-577 (`remove`); callers S/Socket/Conn.cpp:831-832, S/Socket/Listener.cpp:194-195, S/Socket/Udp.cpp:252, S/WebSocket/H2StreamPort.cpp:38
- **Original claim:** If an fd is closed while a duplicate stays open, its level-triggered epoll entry survives and the loop busy-spins.
- **Analysis:** The mechanism is real for epoll: the entry is tied to the open file description, and `EPOLL_CTL_DEL` on a closed fd fails with EBADF. The comment at :355 acknowledges it, and events on the stale key are dropped by `live(key)` in `dispatchEvent`, so a ready entry would spin. But every reactor user calls `reactor().remove(key())` before `close`: Conn.cpp:831-832, Listener.cpp:194-195, Udp.cpp:252, H2StreamPort.cpp:38. The destructors close only when `key() == 0` (Conn.cpp:206, Listener.cpp:42). `remove` sends the DEL while the fd is still open (:561). The only dup in eco-system is `F_DUPFD_CLOEXEC` in Stream.cpp:1057, and those fds go to FdChannel threads, not the reactor. I found no path that closes before removing.
- **Impact:** None on current call paths. It would become a busy spin if a future handler closed its fd before calling `remove`.
- **Suggested fix / next step:** Optionally assert in `remove` that `fcntl(fd, F_GETFD)` succeeds, to enforce the remove-before-close rule.

### FD-03: PIPE_BUF write can block
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Core/FdChannel.cpp:231-236 (`doWrite`), poll loop :322-352 (`channelThread`)
- **Original claim:** Writing up to PIPE_BUF after POLLOUT can still block on blocking sockets or ttys.
- **Analysis:** FdChannel never sets O_NONBLOCK on the channel fd (the only O_NONBLOCK uses are on the wake pipe, :141/:150). The PIPE_BUF cap is safe for pipes, but for a blocking socket or tty passed as a stream fd, for example stdio under systemd or a socket inherited as fd 1, POLLOUT only promises some space, so a 4096-byte `write` can block. The block happens on the channel's own thread (:305), not the eco thread. The cost is that this channel's thread can't drain its wake pipe, so close or cancel requests for that channel wait until the peer drains. On Linux TCP, POLLOUT needs about a third of sndbuf free, so this rarely triggers.
- **Impact:** One channel thread stalls, and closing or cancelling that stream is delayed while the peer is not reading. The rest of the program is unaffected.
- **Suggested fix / next step:** Set O_NONBLOCK on non-regular channel fds that the channel owns (the code already handles EAGAIN at :240), or use `send(MSG_DONTWAIT)` for sockets.

### FD-04: makeCloexecPipe leaves fds untouched on failure
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/FdChannel.cpp:139-163 (`makeCloexecPipe`); callers S/Core/FdChannel.cpp:398-399, S/ChildProcess/ChildProcess.cpp:117 and :450, S/Core/SignalService.cpp:181-182
- **Original claim:** When `pipe2` fails, `fds` are left uninitialised and garbage fds get used.
- **Analysis:** POSIX leaves `fds` unmodified when `pipe`/`pipe2` fails. The non-Linux fcntl failure path sets them to -1 (:158). Every caller either pre-initialises to `{-1,-1}` (FdChannel.cpp:398, ChildProcess.cpp:117, SignalService.cpp:181) or uses the fds only when the call returned 0. The Windows stub sets -1 (:57-60). No garbage fd can be used.
- **Impact:** None.
- **Suggested fix / next step:** Optionally set `fds[0] = fds[1] = -1` on the Linux failure path for consistency.

### FD-05: fd >= FD_SETSIZE gets misleading EBADF
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/FdChannel.cpp:338-346 (`channelThread` POLLNVAL handling)
- **Original claim:** An open fd at or above FD_SETSIZE that `poll` reports as POLLNVAL fails with EBADF.
- **Analysis:** When `poll` answers POLLNVAL for an fd that is open, which happens with macOS character devices, the select fallback is used only if `st.fd` and `st.wakeR` are below FD_SETSIZE. Otherwise `failPending(st, EBADF)` runs (:345), although the fd is valid. That needs macOS, a device fd, and more than 1024 open fds. The error is wrong but the outcome, failure, is unavoidable either way.
- **Impact:** Only a misleading error code.
- **Suggested fix / next step:** Report ENOTSUP or EMFILE-like for that case. Cosmetic.

### SIG-01: SignalService reader exits on poll error
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:56-71 (`readerThread`)
- **Original claim:** On a poll error the reader thread exits, so the loop is no longer woken and signals are lost.
- **Analysis:** The thread does return on a `poll` error other than EINTR, or on POLLERR/POLLNVAL. But `poll` on one valid fd with infinite timeout can realistically fail only with ENOMEM, and the pipe is never closed, so POLLNVAL can't happen. Signals are also not lost if it does exit: `pollReady` (:97-106) reads the pipe itself on the eco thread whenever the scheduler checks readiness. They would only be delayed until some other event wakes the scheduler.
- **Impact:** In practice never. In theory, signal delivery is delayed while the program is otherwise idle.
- **Suggested fix / next step:** Retry after ENOMEM, sleeping briefly, instead of returning.

### SIG-02: sigtimedwait on unblocked signals
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:147-175 (`takePending`); subscribe at :198-220
- **Original claim:** `sigtimedwait` is called on signals that are not blocked, which relies on Linux behaviour.
- **Analysis:** The claim is true: `subscribe` only installs a handler and nothing calls `sigprocmask`. POSIX leaves `sigtimedwait` on unblocked signals unspecified. But the code is under `#if defined(__linux__)` (:148), where the kernel dequeues pending signals atomically whether or not they are blocked. The comment (:149-154) records the choice, and other platforms rely on the handler's own pipe write. There is no portability bug in what actually gets compiled.
- **Impact:** None on supported platforms.
- **Suggested fix / next step:** None. Keep the `__linux__` guard.

### SIG-03: addListener push_back throw leaks subscription
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:236-242 (`addListener`)
- **Original claim:** If `push_back` throws, the subscription is not rolled back.
- **Analysis:** `subscribe(signo)` increments `counts_[signo]` and may install the handler before `listeners_.push_back` runs (:240). If that `push_back` throws `bad_alloc`, the count is never decremented, so the handler stays installed and the old disposition is never restored. This is only reachable on `bad_alloc`, from which the process is unlikely to recover anyway (callers in SystemManager.cpp:137 and Terminal.cpp:164 are not exception-safe either).
- **Impact:** Theoretical: a leaked subscription after OOM.
- **Suggested fix / next step:** Call `listeners_.reserve`/`push_back` before `subscribe`, or call `unsubscribe` in a catch block.

### SIG-04: chainToPrevious window runs old disposition
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:281-289 (`chainToPrevious`); used by S/Terminal/Terminal.cpp:146
- **Original claim:** While the previous disposition is temporarily restored, signals that arrive run that old disposition.
- **Analysis:** `chainToPrevious` restores `old` with `sigaction`, calls `raise`, and then reinstalls `ours`. A second instance of `signo` arriving in that window, possibly on another thread, is handled by the old disposition, not queued to Eco listeners. The only caller is Terminal's raw-mode SIGINT/SIGTERM listener, where the old disposition is usually SIG_DFL (terminate), which is what `raise` does anyway. The race only matters if a non-default previous handler (or SIG_IGN) is installed and the signal is delivered twice within microseconds.
- **Impact:** Rarely, one extra signal instance bypasses the Eco listeners.
- **Suggested fix / next step:** Block `signo` with `pthread_sigmask` around the swap (raise, unblock to deliver, then restore). This is low priority.

### CORE-17: callClosure1 exception escapes poolDrain
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SysWorkPool.cpp:106-135, `poolDrain` (call at :130, `s.drain()` at :134)
- **Original claim:** if `Scheduler::callClosure1(resume, task)` throws, `poolDrain` exits without `Scheduler::drain`, so tasks stall.
- **Analysis:** `resume` comes from `takePendingResume` (:114). It is a resume closure built by the Scheduler, whose evaluator `resumeEvaluator` (runtime/src/platform/Scheduler.cpp:452-466) only calls `procWithRoot` (allocates) and `enqueue`. It runs no user Elm code, so the only way it can throw is an allocator failure. If it did throw, the exception would not stall anything quietly. `runDrainSources` (S/Core/AsyncSources.cpp:40-47) and `processReadyAsync` (Scheduler.cpp:802-805) have no catch, and neither does `runEventLoop` (Scheduler.cpp:641) or its caller (runtime/src/platform/PlatformRuntime.cpp:843). The exception takes down the whole program. Items still in `ready_` are not lost either: they stay queued, and `HoldRelease` (:113) still releases the current hold during unwinding. Skipping `s.drain()` is also harmless on the normal path, because `runEventLoop` calls `drain()` at the top of every iteration (Scheduler.cpp:643). Every other drain site (Socket.cpp:69, Tls.cpp:54, HttpTables.cpp:310, Core.cpp:138, ...) has the same unguarded shape.
- **Impact:** none beyond the program aborting on an allocator failure inside the resume. No stall.
- **Suggested fix / next step:** none needed. Optionally document that a drain source's exception is fatal by design.

### CORE-18: PoolResult::of throwing in catch -> terminate
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/SysWorkPool.cpp:87-93 and :96-98, `SysWorkPool::workerLoop`
- **Original claim:** a throw inside the worker's catch handler reaches `std::terminate`.
- **Analysis:** the handlers build `PoolException{e.what()}`, which constructs a `std::string` and can throw `std::bad_alloc`. Nothing encloses them, and `workerLoop` is the body of a detached `std::thread` (:36), so an escaping exception calls `std::terminate`. `ready_.push_back` (:97) is also outside any try and can throw `bad_alloc` too. The only trigger is C++ heap exhaustion: there is no input-driven path, and a long `what()` is just a string copy.
- **Impact:** the process aborts under C++ OOM. Without the abort, the dead worker would leave that job's hold unreleased and the program would hang.
- **Suggested fix / next step:** wrap the whole job-to-`ready_` step in a `noexcept` helper. On a failure, push a preallocated or static-message `PoolException`, or call `std::abort` with a clear message.

### WATCH-07: IN_Q_OVERFLOW dropped silently
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/WatchService.cpp:262-267, `Impl::mapInotify`. Documented in S/FileSystem/WatchService.hpp:22.
- **Original claim:** an inotify queue overflow is never reported, so events are lost.
- **Analysis:** an `IN_Q_OVERFLOW` record has `wd == -1`, so `wdUses.find(r.wd)` at :262 fails and the record is dropped at :263, before the explicit `if (r.mask & IN_Q_OVERFLOW) return;` at :267 is even reached. Nothing is delivered to Elm, and the header admits that "changes it stands for are lost". In practice the kernel queue (default `max_queued_events` 16384) overflows rarely. The reader thread (:175-193) copies records straight into an unbounded in-process deque, so overflow needs a burst faster than one `read()` loop can keep up with, for example a mass `rm -rf` or `git checkout`.
- **Impact:** an Elm program that mirrors or rebuilds from watch events silently misses changes after a burst, with no signal that it should rescan.
- **Suggested fix / next step:** on `IN_Q_OVERFLOW`, emit one Moved event with no path for every inotify-mode watch, meaning "rescan". This matches what poll mode reports when the root vanishes.

### WATCH-08: files in new sub-dir before watch added missed
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/FileSystem/WatchService.cpp:281-286 (`mapInotify`) and :214-227 (`addTree`)
- **Original claim:** entries created in a new sub-directory before its inotify watch is added are missed.
- **Analysis:** the watch for a new directory is added only when the `IN_CREATE|IN_ISDIR` record is mapped. Mapping happens in `WatchService::drain` on the eco thread (:439-454), which can be long after the inotify thread queued the record. Anything created inside the directory in between (for example `mkdir -p a/b/c && echo x > a/b/c/f`) produces no event. `addTree` only adds watches for the nested directories it finds. It does not synthesise events for the files or sub-directories already there. Only the top `a` gets a Moved event. Deferring the mapping to the drain makes the window much wider than the inherent inotify race.
- **Impact:** recursive watches miss files in newly created trees, for example extracted archives or `git clone` into a watched directory.
- **Suggested fix / next step:** after `addDir`/`addTree` for a new directory, walk it and emit a Moved event for every entry found, as the ordinary inotify recursive-watch idiom does. A test would `mkdir -p` plus write a file in one shell command and assert the file event.

### REGEX-08: regexTable never freed
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** E/regex/RegexExports.cpp:47-64 (`regexTable`, `registerRegex`), :200 (`never`), :249 (`fromStringWith`)
- **Original claim:** compiled regexes are leaked.
- **Analysis:** this is deliberate (file comment :8-10, :50-53). Every call to `Regex.fromString`, `fromStringWith` or even `Regex.never` does `new srell::regex(...)` and stores it under a fresh id. Entries are never removed or deduplicated (there is no cache: grep finds only the two `new srell::regex` sites). A top-level `Regex.fromString "..."` constant is evaluated once, which is fine. But a regex built inside a function runs per call, which is common in Elm (`Regex.fromString ("^" ++ prefix)`, or patterns from user input). Each such call leaks a compiled automaton, often kilobytes, plus a map node. In a long-running eco/system server this is unbounded growth.
- **Impact:** memory grows without bound in programs that compile regexes dynamically or inside hot functions.
- **Suggested fix / next step:** intern by `(pattern, flags)`: look the key up in a `std::unordered_map<std::pair<std::string,int>, id>` before compiling. Entries stay never-removed, so the GC invariant holds, but growth becomes bounded by the number of distinct patterns. `never` can be a single static entry.

### PROC-06: exception after parkResume leaks job hold
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/ChildProcess/ChildProcess.cpp:592-604 (`childProcessRunBody`) and :489-504 (`startJobWatch`)
- **Original claim:** an exception after `parkResume` but before `WaitService::submit` leaks the job's hold, so the program may not exit.
- **Analysis:** at :595 the token is parked and stored as `j->hold`, and `counted` stays false. Between that line and `WaitService::instance().submit` (:503), several calls can throw:
  - `makeTimerClosure` (:494) allocates on the Elm heap.
  - `parkResume` of the timer (:499) can throw.
  - `TimerService::schedule` (:501) can throw `bad_alloc`.
  - `submit` itself (runtime/src/platform/WaitService.cpp:47-97) catches only `std::system_error` from thread creation. Building the lambda or `std::thread` can still throw `bad_alloc`.

  On a throw, `ECO_SYSTEM_ASYNC_GUARD` (S/Core/Core.hpp:239-255) calls `asyncFailure`, which takes the resume and resumes with a failure, but releases no hold because `counted` is false (S/Core/Core.cpp:140). The job stays in `childJobs()` holding `j->hold`. No wait was submitted, so `exited` never becomes true and `completeRun` never runs. The hold is never released and the child is never reaped (it becomes a zombie). Every trigger is an allocation failure, so this is rare.
- **Impact:** after a C++/Elm-heap OOM during `ChildProcess.run`, the program never exits on quiescence.
- **Suggested fix / next step:** in the catch path, erase the job and release `j->hold`, or move parkResume to after the last throwing step (submit first, then park). Alternatively use a scope guard that hands the hold to the guard until `submit` returns.

### PROC-07: Windows startCollector leaks pipe read ends
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/ChildProcess/ChildProcess.cpp:447-461 (`startCollector`, `#ifndef _WIN32` body). runtime/src/platform/Spawn.cpp:281-285 and :366-367 create the pipes.
- **Original claim:** on Windows, `startCollector` leaks the pipe read ends.
- **Analysis:** with `StdioMode::RunPipes`, the Windows spawn creates real stdout/stderr pipes (Spawn.cpp:284) and hands their read ends back as CRT fds (:366-367). On Windows `startCollector` skips the whole block and overwrites `col->outFd = col->errFd = -1` without closing them (:459). The comment at :446 says this outright. The fds and handles leak for each run. Worse, the read ends stay open but are never read, so a child that writes more than the pipe buffer (CreatePipe with size 0, a few KB) blocks forever in `WriteFile` and never exits. The run then completes only if `runDuration` kills it. The output is always empty on Windows in any case.
- **Impact:** on Windows, `ChildProcess.run` leaks two fds per call, hangs on any child with non-trivial output, and returns empty stdout/stderr. Windows is low priority per project policy.
- **Suggested fix / next step:** at minimum `_close(col->outFd)` and `_close(col->errFd)` on Windows, so the child gets a broken pipe instead of blocking. The real fix is a Windows collector thread doing `ReadFile` on both handles.

### PROC-08: Process.wait not cancellable
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** K/Process.cpp:165-179 (`waitBody`, kill handle `unit`), :120-146 (`waitServiceDrain`)
- **Original claim:** `Eco.Process.wait` has no cancellation, so it hangs on kill.
- **Analysis:** `waitBody` parks under a Task hold and returns `unit()` as the kill handle (:178). When the Elm process is killed, `killBindingBody` (runtime/src/platform/Scheduler.cpp:497-525) finds no kill closure. It marks the process killed, so it is never revived (stale entries are dropped, Scheduler.cpp:874-884). The hold is not released, though, until the child exits and `waitServiceDrain` releases it (:132, :144). Eco.Process exposes no way to kill the child (src/Eco/Process.elm: only `exit`, `spawn`, `spawnProcess`, `wait`). So a killed waiter on a never-exiting child keeps the program alive. This is comparable to Node keeping the loop alive for a live child. A waitpid thread cannot be cancelled anyway.
- **Impact:** a program that kills a task waiting on a long-lived child, for example under a timeout race, does not exit until the child does.
- **Suggested fix / next step:** have the kill handle mark the token "withdrawn" and release the hold early. The drain then ignores the late result, since `takePendingResume` already returns nil and the release would need to become conditional.

### RESET-05: FileSystemManager reset without stopWatch
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/FileSystem/FileSystemManager.cpp:59-73 (`registry`, `state`), :154-160 (`stopWatch`). S/Core/Registry.hpp:103-123 (`ensure` clears `m_`).
- **Original claim:** a heap reset clears the registry without stopping watches, leaking holds and inotify watches.
- **Analysis:** `Registry::ensure` does `m_.clear()` when `heapGeneration` changes, which destroys each `WatchEntry` without calling `stopWatch`. The `WatchService` watch stays alive (inotify wds keep queuing events, which `deliver` now ignores) and the Subscription hold is never released. The trigger is only `Allocator::reset`, reached through `AllocatorTestAccess::reset` (runtime/src/allocator/Allocator.hpp:709-711) from unit tests. `Allocator::initialize` returns early when already initialized. Production programs never reset the heap, and E2E tests run each program in its own spawned child process.
- **Impact:** only for in-process test sequences that reset the heap after a FileSystem watch: a stale hold, a stale inotify watch, and duplicate watches after resubscribing.
- **Suggested fix / next step:** low priority. Give `Registry` an optional on-discard hook, called per entry before `clear()`, and use it to call `stopWatch` here (and for similar holders).

### STREAM-07: maybeErase never erases some pairs
- **Status:** CERTAIN · **Severity:** MEDIUM
- **Where:** S/Stream/Stream.cpp:243-253 (`maybeErase`). The rule is stated in S/Stream/StreamTable.hpp:38-41.
- **Original claim:** Errored, terminated and unreachable Open pairs are never erased, so the table grows without bound.
- **Analysis:** the check at :247 requires both `w == Closed` and `r == Closed`. `errorPair` (:209-223) sets both sides to Errored. `terminatePair` (:228-235) leaves `w = Errored` with `r = Closed`. A ChannelSource or Sink whose channel read or write failed gets the Errored side set in `channelDispatch` (for example :691-697, :720-726). None of these states is ever erased. The channel's OS resource is released by `shutdown`/`close` (ByteChannel contract, S/Core/ByteChannel.hpp:96-105). What stays forever is the `StreamPair`: its `ByteChannel` object, reason strings, and for Custom or mapped pairs the scanned closure words (`mapFnEnc`, the action closure), which keep heap objects alive. An Open pair whose Elm handle became unreachable can never be erased either, because there is no finalization. That part is inherent. Keeping Errored pairs may be deliberate, so that later operations return the stored reason instead of the generic "WritableStream is closed".
- **Impact:** long-running servers (HTTP/WebSocket/socket streams that fail or reset) accumulate one table entry per failed stream, plus any heap it references.
- **Suggested fix / next step:** let `maybeErase` also accept Errored or Closed combinations once nothing is parked or queued. Store the Errored reason in a small LRU or keep a tombstone, or accept the generic reason. Confirm with a stress test that opens and errors N socket streams and checks `streamTable().size()`.

### STREAM-08: streamUncountedToken unbounded
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/Stream.cpp:61 (`g_nextUncountedToken`), :153-157
- **Original claim:** nothing keeps the counter below 2^62, so it can overflow.
- **Analysis:** true and documented (:58-60), but the range holds 2^62 − 2^61 = 2^61 ≈ 2.3e18 tokens. One token per mapped read-ahead or reader kick at 1e9 per second would take about 73 years to exhaust.
- **Impact:** none in practice.
- **Suggested fix / next step:** optionally add an `assert` or `abort` if the counter reaches 2^62. No action needed.

### STREAM-09: withdrawnReads entries never removed
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/Stream.cpp:631-634 (`withdrawnReads`), insertion :650, removal :683
- **Original claim:** entries whose channel result never arrives stay forever.
- **Analysis:** an entry is inserted only when a ChannelSource read with `chanReadTok == token` is withdrawn, and erased when that read's result is dispatched. The ByteChannel contract requires exactly one result per request, including after `shutdown`/`close` (S/Core/ByteChannel.hpp:67-71, :96-105). `FdChannel::~FdChannel` shuts down, which answers pending requests (S/Core/FdChannel.cpp:416-423). A pair with `chanReadTok != 0` is never erased (:249), so the channel outlives the request. There is at most one in-flight channel read per pair. The only lasting entries come from a read blocked forever (for example stdin never sending data), which costs one 8-byte entry per such pair, or from a heap reset (test-only).
- **Impact:** negligible: bounded by the number of pairs with a permanently blocked read.
- **Suggested fix / next step:** none. If wanted, erase entries for a channel id when the pair is erased.

### STREAM-10: mapped-sink value lost
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Stream/StreamPipe.cpp:217-234 (`streamRunPipe`, mapped-sink branch). The callee is `streamMapForSink` at S/Stream/Stream.cpp:950-971.
- **Original claim:** the value popped from src is lost if `streamMapForSink` throws or `dst` leaves Open during the call.
- **Analysis:** the value is popped at :220 before the call, and the write is issued only if `dst` is still Open (:227). `streamMapForSink` calls the pure Elm `toWire` closure (Stream.cpp:954). A pure Elm function performs no Tasks and cannot reach the stream table, so `dst` cannot change state during the call. Only a collection runs, and it moves but does not close. The remaining throw sources are an allocator failure (`toStdString`/`toStdBytes`) or an Elm crash, which is fatal anyway. In both cases the exception propagates out of `drive` (Stream.cpp:599-603) and the pipe is already broken. If `dst` did leave Open, the next loop iteration fails the pipe and cancels src (:198-204), and dropping the in-flight chunk is then consistent with WHATWG pipe-abort semantics.
- **Impact:** none reachable short of OOM.
- **Suggested fix / next step:** none. Optionally peek, map, then pop, so a thrown OOM leaves the value in `readQ`.

### SYS-03: stdioIds caches failed 0
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/System/System.cpp:163-183 (`stdioIds`). The callees are S/Stream/Stream.cpp:1051-1080 (`channelFd`, `createFdSource`/`createFdSink`).
- **Original claim:** a failed creation is cached as id 0, so later calls re-create the pairs and pin them again, leaking them.
- **Analysis:** the 0 return (Stream.cpp:1067, :1076) happens only when `channelFd` returns < 0. For fds 0-2 `channelFd` returns the fd unchanged (`if (owns || fd <= 2) return fd;`, :1056) and never fails. `createChannelSource`/`createChannelSink` return a registry id ≥ 1. Allocation failure throws rather than returning 0. So id 0 is never cached for stdio, and the re-create-and-pin path runs only after a heap reset (test-only). `systemEnvironmentNow` is also called about once per program.
- **Impact:** none reachable.
- **Suggested fix / next step:** none. Optionally treat id 0 as "unavailable" without retrying.

### FS-06: fsComplete leaks FdChannel on throw
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/FileSystem/FileSystem.cpp:103-134 `fsComplete` (ReadStream/WriteStream cases, :119-131); S/Stream/Stream.cpp:261-275 `insertChannelPair`; S/Core/FdChannel.cpp:389-413 ctor
- **Original claim:** `new FdChannel(fd, o)` is leaked, along with its fd, if something throws in `fsComplete`.
- **Analysis:** The raw pointer is never left unowned in a way that leaks it. `createChannelSource`/`createChannelSink` (Stream.cpp:1030, :1042) go straight to `insertChannelPair`, which hands the pointer to `StreamPair::channel` (a `unique_ptr`, `p.channel.reset(channel)` at :265) before anything else. If `t.insert` throws after that, the unique_ptr frees the channel, and `~FdChannel` (FdChannel.cpp:416) shuts it down, which closes the fd. If `channelPairs()[chan] = id` throws, the pair is already in the table. The ctor's own failures (pipe or thread creation) close the fd themselves (:410-412). The only real gap is `std::bad_alloc` from the `new` itself or from `make_shared<State>` in the ctor initialiser. In that case the FdChannel memory is freed by the language, but the fd number in `r.n` is never closed, because `FsRes` has no destructor that closes it. Any exception from `fsComplete` is caught in `poolDrain` (Core/SysWorkPool.cpp:120-126) and turned into a failed Task, so nothing crashes. A throw after the pair exists (`succeedInt` running out of GC memory) leaves an unreachable pair, but that is a fatal-OOM situation anyway.
- **Impact:** One fd leaked, only on `bad_alloc` while opening a file stream.
- **Suggested fix / next step:** Optional: wrap `r.n` in a small fd guard until the FdChannel is built. Not worth a test.

### RESET-06: SocketTables reset keeps holds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/SocketTables.cpp:41-61 `resetTables`, :219-228 `socketTables`; S/Socket/SocketEvents.cpp:129-131 (orphan events)
- **Original claim:** On a heap reset, the holds of close tokens and pending connects are not released.
- **Analysis:** `resetTables` releases the subscription holds and the parked-accept holds (:46-50). It does not release:
  - **`e.closeTokens`.** These are taken in Socket.cpp:508-510 as `parkResume` Task holds. The listener is closed on the reactor, but "its ListenerClosed is not dispatched" (:53). The event carries the old generation and is dropped by `socketEventsDrain` → `releaseOrphan`, which only aborts the conn and releases no hold (SocketEvents.cpp:71-76, :129-131).
  - **Pending connects.** `kv.second->cancelConnect()` (:57) returns true when it wins the race (Conn.cpp:391-397), so no Connected event is ever posted. Per Core.hpp:60-65, only a kill handle releases the hold in that case, and none runs here.
  - **In-flight TCP OpDone holds.** Old-generation OpDone events are likewise orphaned without releasing their hold.

  So `Scheduler::liveHoldCount` stays above 0 forever. Reachability: the heap generation only changes in `Allocator::initialize`/`Allocator::reset` (runtime/src/allocator/Allocator.cpp:222, :1070), and `reset` is only called from tests (`AllocatorTestAccess::reset`, test/allocator/TestHelpers.cpp:51). A normal Elm program never resets its heap. The Scheduler is a leaked singleton with no reset (runtime/src/platform/Scheduler.cpp:47-53). Its pending-resume and root-scanner state does not survive a RootSet reset either, so the Scheduler as a whole is not designed to be reused across heap generations.
- **Impact:** After a reset taken with sockets still in flight, the next event loop in the same process never quiesces (it hangs). Test harnesses only.
- **Suggested fix / next step:** Release `closeTokens` (take the resume, then `releaseHold`) in `resetTables`, and release the hold of every pending connect whose `cancelConnect()` returns true. Or give the Scheduler a generation-aware reset that drops all holds and resumes.

### RESET-07: HttpTables reset keeps holds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpTables.cpp:118-138 `resetTables`, :143-152 `tables`, :333-339 `httpDrain` (generation filter); documented at HttpTables.hpp:36-41
- **Original claim:** On a heap reset, the holds of respond and closeServer tasks are not released.
- **Analysis:** `resetTables` releases the key holds and subscription holds only. Its own comment (:119-120) says that waiting closeServer holds (`ServerEntry::closeTokens`, :79) and RespondDone holds are not released. `httpDrain` drops any event of an earlier generation unread (`if (ev.gen != currentGen()) continue;`, :337). That skips the `HoldRelease release(ev.token)` of RespondDone (:344) and `onServerClosed`'s release of the close tokens (:321-324). Those holds therefore live forever. This is the same reachability as RESET-06: heap resets happen only in tests.
- **Impact:** The event loop cannot quiesce after a reset taken while a respond or closeServer task was in flight. Test-only.
- **Suggested fix / next step:** In `httpDrain`, release `ev.token` for old-generation RespondDone events. In `resetTables`, release `closeTokens`.

### RESET-08: Udp reset keeps in-flight OpDone holds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Udp.cpp:380-394 `resetTables`, :97-109 `postOpDone`; S/Socket/SocketEvents.cpp:71-76, :129-131
- **Original claim:** On a reset, the holds of in-flight send and membership operations (OpDone) are not released.
- **Analysis:** `resetTables` releases the subscription holds and parked-receive holds. It then submits `h->close()`, which posts ECANCELED OpDone events for the queued sends (:251) stamped with the old `gen_`. Membership and send OpDone events already in the queue also carry the old generation. All of them reach `socketEventsDrain`, where `ev.gen != currentHeapGeneration()` sends them to `releaseOrphan` ("no resume, no count"), so their holds (`ev.token`) are never released. Test-only, as in RESET-06.
- **Impact:** The event loop never quiesces after a reset taken with UDP sends in flight. Test-only.
- **Suggested fix / next step:** In `releaseOrphan`, release `ev.token` for an OpDone event (and for Connected), after `takePendingResume`. This one change also fixes the in-flight part of RESET-06.

### RESET-09: WsTables reset keeps holds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsTables.cpp:45-60 `resetTables`; documented at WsTables.hpp:22-26
- **Original claim:** On a reset, the `closeHold`, `closedWaiters` and cancelled-dial holds are not released.
- **Analysis:** The reset releases only the handshake `peerHold` (:47). It does not release:
  - `WsEntry::closeHold`, acquired at :334;
  - `closedWaiters`, the parked `closed` task tokens;
  - the hold of a dial whose `pendingDials` cancel succeeds (:55; no Dialed event follows).

  The header states this deliberately (WsTables.hpp:24-26). Test-only, as in RESET-06.
- **Impact:** The event loop never quiesces after a reset taken with an open or closing WebSocket. Test-only.
- **Suggested fix / next step:** Release these holds in `resetTables`, or fix it generically with a Scheduler-level reset of holds on a generation change.

### RESET-10: WsManager aux() reset keeps subscription holds
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsManager.cpp:85-101 `aux()`
- **Original claim:** On a generation change, `aux()` clears its table without releasing the subscription holds.
- **Analysis:** `t->m.clear()` (:99) discards the `Aux` entries. The code comment at :91 says "The holds of discarded entries are not released." Test-only, as in RESET-06.
- **Impact:** The event loop cannot quiesce after a reset taken while a WebSocket subscription was live. Test-only.
- **Suggested fix / next step:** Release each entry's hold before `clear()`.

### SOCK-15: Udp handler refused by reactor never reads
- **Status:** LIKELY · **Severity:** LOW
- **Where:** S/Socket/Udp.cpp:64-69 `UdpHandler::start`, :511-527 `udpBindComplete`; S/Core/IoReactor.cpp:477-507 (ctor, `submit`), :509-531 `add`
- **Original claim:** If the reactor refuses the UDP handler, the handler never reads, and parked receives wait forever.
- **Analysis:** `start()` returns silently when `reactor().add` returns 0 (:67). That cannot happen in practice: `add` returns 0 only for a null handler or one already keyed (IoReactor.cpp:511), and `start` already checks `key() != 0`. If `epoll_ctl` fails inside `setInterest`, `updateInterest` backs off and `onTimer` retries (:75-82, :269-273), so that path recovers. The reachable variant is a reactor that is not ok. If `backendInit` (epoll_create) fails, or the reactor thread cannot be spawned (IoReactor.cpp:479-496), the reactor only prints a warning and `submit` silently drops every command (:501). The bind runs on the SysWorkPool rather than the reactor, so it still succeeds, and `udpBindComplete` returns success. But `h->start()` never runs, and every later `send`/`membership` lambda is dropped too, so their OpDone holds are never released and receives stay parked. TCP connect, listen and the other socket kernels have the same pattern. On Windows, bind already fails with ENOTSUP (Udp.cpp:368), so the stub reactor cannot trigger this.
- **Impact:** A hang (the holds keep the program alive) when the event loop could not be created, for example on fd exhaustion at the first socket use. Rare.
- **Suggested fix / next step:** Expose `IoReactor::ok()` and fail the bind, connect and listen kernels with EIO/ENOSYS when it is false. A test with a reactor stub forced to `ok=false` would settle it.

### WS-25: WsBodyChannel has no destructor
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/WsChannel.hpp:103-126, S/WebSocket/WsChannel.cpp:106-132; S/Stream/Stream.cpp:242-253 `maybeErase`
- **Original claim:** Destroying a `WsBodyChannel` never calls `bodyCancel`, so the body may leak or stall the socket.
- **Analysis:** Unlike `WsOutChannel` (which has `~WsOutChannel` calling `shutdown`), `WsBodyChannel` has no destructor, and the header says so (WsChannel.hpp:106). The stream layer, though, only destroys a channel by erasing its pair, and `maybeErase` erases only when both sides are Closed and nothing is in flight (Stream.cpp:246-251). The readable side reaches Closed only by EOF, which calls `close(0)` once the body is fully consumed, or through the error and cancel paths, which call `shutdown()` and so `bodyCancel` (Stream.cpp:693, :722, :740, :922, :1475). The remaining destroy-without-shutdown path is the Registry discarding stream pairs on a heap reset, and there `WsTables::resetTables` aborts the WsCore anyway (WsTables.cpp:51-53).
- **Impact:** None found in ordinary programs.
- **Suggested fix / next step:** For symmetry, a destructor `if (!done_) shutdown();` costs nothing.

### HEAP-05: stack root range not restored on exception
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Terminal/TerminalManager.cpp:73-97 `onWinch`; S/FileSystem/FileSystemManager.cpp:85-124 `deliver`
- **Original claim:** Both functions push a stack root range over a local vector and restore it with no RAII, so an exception leaves the range pointing at freed memory.
- **Analysis:** The claim is correct about the code: `pushStackRootRange(taggers.data(), ...)` is followed by `restoreStackRangePoint(saved)` with no RAII. If an exception escaped `callClosure1`, `sendToApp` or `drain`, the range would keep pointing at the destroyed vector `taggers`. Every caller, however, catches and calls `reportFatal`, which is `[[noreturn]]` and `std::abort`s (eco-kernel KernelExports.h:51-56):
  - `onWinch` runs only from `SignalService::dispatch` inside `signalDrain`'s try/catch (S/Core/SignalService.cpp:292-303);
  - `deliver` is wrapped at FileSystemManager.cpp:132-138.

  No GC can run after the throw, so the dangling range is never scanned.
- **Impact:** None: the process aborts first.
- **Suggested fix / next step:** Hygiene only. Use a scoped range guard (RAII restore) so the code stays safe if a caller ever stops aborting.

### HTTPSRV-13: no idle timer when timeouts <= 0
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/Http1.cpp:26 `after`, :273, :300-301, :438; Http2.cpp:398, :625
- **Original claim:** No idle timer is armed when a timeout is 0 or less, which may be unintended.
- **Analysis:** `after(ms)` returns 0, meaning no deadline, for `ms <= 0`. That is the documented API: Http/Server.elm:208-209 says "a value of 0 or less is no timeout". The defaults are 5000, 60000 and 300000 ms (Server.elm:250-252). With a non-positive `headersTimeout`, an idle client can hold a connection open indefinitely (slowloris), but only because the program asked for exactly that.
- **Impact:** As designed.
- **Suggested fix / next step:** None. Possibly mention the slowloris exposure in the doc comment.

### HTTPSRV-14: strerror on worker thread
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerService.cpp:281 `listenOn`, run on a SysWorkPool worker from S/HttpServer/HttpServer.cpp:182-188
- **Original claim:** `listenOn` calls `strerror` on a pool worker, against the eco-thread-only rule at Core.hpp:119-121.
- **Analysis:** `listenOn` runs inside the pool lambda ("runs on a worker", HttpServer.cpp:184) and calls `std::strerror(lastErr)` at :281. That breaks the rule in Core.hpp:119-121 (and the one FileSystem.cpp:60 follows). In practice the musl static build returns constant strings, and glibc ≥ 2.32 makes `strerror` thread-safe, so a real race needs an old glibc and an unknown errno value.
- **Impact:** A theoretically garbled error message. No memory unsafety on current libcs.
- **Suggested fix / next step:** Use `strerror_r`, or carry `lastErr` back and build the message in `createComplete` on the eco thread.

### HTTPSRV-15: pool lambda keeps cert/key
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpServer/HttpServer.cpp:258-280 (lambda capturing `spec = std::move(spec)`); S/Core/SysWorkPool.cpp:84-91 (`job.work = nullptr` on the worker)
- **Original claim:** The pool lambda keeps the certificate and private key, and `spec` is destroyed on the worker thread.
- **Analysis:** The lambda owns the `WithSpec`, including `certificateChain` and `privateKey`, until the worker resets `job.work` right after running it (SysWorkPool.cpp:91). Destroying a `std::string` on another thread is fine: the eco thread never touches it again. The key is not scrubbed before the memory is freed, but the same bytes also sit in the Elm heap as the original String until GC, and OpenSSL keeps its own copy. Scrubbing this one copy would buy nothing. The lambda is not cancellable, so it never lingers in the queue.
- **Impact:** No functional defect. A marginal secret-hygiene point.
- **Suggested fix / next step:** None needed. If wanted, `OPENSSL_cleanse` the key string at the end of the lambda.

### HTTPSRV-16: taggers[serverId] inserts empty vector
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpServerManager.cpp:126 `deliver`
- **Original claim:** `st.taggers[serverId]` uses `operator[]`, which inserts an empty entry for a server with no taggers.
- **Analysis:** `st.taggers` is a `std::map<int64_t, std::vector<uint64_t>>` (:32), so `operator[]` inserts an empty vector when the server has no subscription. This is harmless:
  - the root scanner (:38) iterates an empty vector;
  - `hasSubscribers` checks `!it->second.empty()` (:65-66);
  - the next `onEffects` replaces the whole map (:178).
- **Impact:** None, apart from a stray map node until the next `onEffects`.
- **Suggested fix / next step:** Use `find` and return early, which also skips building `arg` for nothing.

### RESET-11: listener/g_quiescenceRegistered survive reset
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Terminal/TerminalManager.cpp:65-67, :73-77, :134-138; S/System/SystemManager.cpp:66-73, :102-104, :127-130
- **Original claim:** The SIGWINCH, SIGINT and SIGTERM listeners and `g_quiescenceRegistered` survive a heap reset while the tables they serve are emptied.
- **Analysis:** This is deliberate (the file comments at TerminalManager.cpp:7 and SystemManager.cpp:66 say the listeners outlive heaps). After a reset, `onWinch` and `onQuiescent` see empty state and return early (:77, :103). One small wrinkle: a SIGINT or SIGTERM listener that survives a reset with an empty subscription list swallows the signal. `onSignal` → `deliver` delivers nothing, and the default termination is suppressed until the next `onEffects` removes the listener. Test-only, as in RESET-06.
- **Impact:** Harmless in practice. In a test process that resets its heap, Ctrl-C may be ignored until the next `onEffects`.
- **Suggested fix / next step:** None required. Optionally, have `onSignal` chain to the previous handler when its list is empty.

### CORE-19: throwing listener skips rest of pass
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Core/SignalService.cpp:263-275 (`SignalService::dispatch`), :292-304 (`signalDrain`); S/Socket/SocketEvents.cpp:119-145 (`socketEventsDrain`)
- **Original claim:** an exception from one listener/dispatch fn is caught outside the loop, so the remaining listeners/events of that pass are skipped before reportFatal.
- **Analysis:** True as stated: the try/catch wraps the whole `dispatch` call (SignalService.cpp:296-302) and the whole drain loop (SocketEvents.cpp:121-144), so later listeners/queued events in the pass are not run. But the catch handler is `Eco::Kernel::reportFatal`, which is `[[noreturn]]` and ends in `std::abort()` (K/KernelExports.h:51-56). The process dies immediately, so "skipping the rest" has no observable consequence beyond the abort itself; there is no recovery path in which skipped work would be lost.
- **Impact:** None beyond the fatal abort that already happens.
- **Suggested fix / next step:** No change needed. If per-listener isolation were ever wanted (recoverable errors), move the try inside the loops.

### CRASH-01: ::exit(1) with live threads
- **Status:** LIKELY · **Severity:** LOW
- **Where:** K/Crash.cpp:19-31 (`Crash::crash`, `::exit(1)` at :29); same pattern in K/Process.cpp:184-189 (`Process::exit`, `::exit(code)`) and runtime `eco_crash` (runtime/src/allocator/RuntimeExports.h:636-642, "through std::exit")
- **Original claim:** `exit` runs exit handlers/static destructors while other threads (GC helpers, reactor, service threads) are alive, risking shutdown races.
- **Analysis:** On POSIX the runtime is explicitly built for exit-with-live-threads: the Scheduler, WaitService, TimerService, HttpService singletons are leaked on purpose for exactly this reason (runtime/src/platform/Scheduler.cpp:47-53, WaitService.cpp:19-23, HttpService.cpp:22-30), the GC background gang is stopped by an atexit hook (runtime/src/allocator/GCHelperPool.cpp:582), and TLS registers `tlsQuiesce` to quiesce the IoReactor (S/Tls/TlsContext.hpp:34-37, TlsContext.cpp:262). The one difference from normal termination is that `crash` calls `exit` on the mutator thread mid-execution rather than from `main` after `pthread_join` (runtime/src/codegen/eco_entry.cpp:~380), so atexit handlers run while that thread's state is live — acceptable since it never resumes. On Windows, however, eco_entry.cpp:388-399 documents that `exit`/`ExitProcess` with the detached service threads "can hang" (a killed thread holding a lock needed by DLL detach / static destructors) and uses `TerminateProcess` instead; `Crash.crash` and `Process.exit` still call `::exit`, so they take exactly the path the entry code avoids.
- **Impact:** Windows: a `Crash.crash` / `Process.exit` could occasionally hang at exit. POSIX: no concrete race found.
- **Suggested fix / next step:** Route Crash/Process exit through one runtime helper that mirrors eco_entry's Windows path (flush, `TerminateProcess`). Windows is low priority per project policy.

### SOCK-16: Conn onCloseAll calls closeNow again
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/Socket/Conn.cpp:1018-1022 (`Conn::onCloseAll`), :929-978 (`Conn::abort`), :830-842 (`Conn::closeNow`)
- **Original claim:** after `abort(false)`, `onCloseAll` calls `closeNow()` again when `key() != 0`.
- **Analysis:** For Open/Draining, `abort` ends in `closeNow()` (:977), which calls `reactor().remove(key())`, and `IoReactor::remove` clears the handler key (`h->key_ = 0`, S/Core/IoReactor.cpp:574), so the guarded second call is skipped. It only runs when abort left the handler registered (e.g. Phase::Closed/Idle/Connecting branches that return early, :930-955), where it is the intended cleanup. Even when run, `closeNow` is idempotent: `closeFd` ignores fd<0 (:158-163), `fd_` is -1, hooks were swapped out, `failOutbound` only if queues non-empty.
- **Impact:** None; it is a safety net, not a double close.
- **Suggested fix / next step:** None.

### WS-26: Http2Client dtor resets stream again
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/Http2Client.cpp:183-190 (`~Http2ClientProtocol`); S/WebSocket/H2StreamPort.cpp:93-103 (`streamReset`)
- **Original claim:** `port_` is never cleared after the stream is reset (streamGone / close), so the destructor calls `streamReset` a second time.
- **Analysis:** Correct that `streamGone` (:377-390) and the close path (:452-461) call `port->streamReset` without clearing `port_`, and the dtor calls `streamReset(kCancel)` again. But `streamReset` begins `if (gone_) return;` (H2StreamPort.cpp:94) and sets `gone_ = true` (:97), so the second call is a no-op. When no earlier reset happened, the dtor call is the required one (it nulls the port's `tunnel_` back-pointer to the dying protocol, :98).
- **Impact:** None.
- **Suggested fix / next step:** None (optionally `port_.reset()` after resetting, for clarity).

### SYNC-01: GC JSON key list hand-synced
- **Status:** WEAK · **Severity:** LOW
- **Where:** K/GC.cpp:24-53 (`toJson`) vs /work/eco-kernel-cpp/src/Eco/GC.elm:106-133 (`reportDecoder`)
- **Original claim:** the 25 JSON keys emitted by the C++ and decoded by Elm are hand-synced and nothing checks agreement.
- **Analysis:** The two lists currently agree exactly (kind, collected, totalNs ... trimResult, 25 keys, same spelling). The decoder requires every field (`D.field`), and a decode failure maps to `zero` with `kind = "error"` (GC.elm:97-98, 136-140). The E2E test test/eco-kernel/src/GcReportTest.elm checks `minor.kind == "minor"` and `major.kind == "major"` (lines 37-46; header says "A decode failure would surface as kind = \"error\""), so any key renamed/removed on either side fails that test. So there is a check, just indirect. Only an added C++ key that Elm does not decode would go unnoticed (harmless).
- **Impact:** Drift would be caught by GcReportTest; no silent wrong data.
- **Suggested fix / next step:** None required; optionally a comment in GC.cpp pointing at GcReportTest.

### SYNC-02: ECO_KLOG defined three times
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/KernelDebug.hpp:29-34, K/KernelDebug.hpp:26-31, runtime/src/platform/HttpService.cpp:12-17
- **Original claim:** three copies of the macro with no agreement check.
- **Analysis:** Three textually identical definitions exist; E/KernelDebug.hpp:10-13 even says they "must stay identical", and nothing enforces it. Identical redefinitions are legal; a divergent one in a TU that saw two of them would raise a macro-redefinition warning, but no TU appears to include two of them. The macro only formats debug traces in `ECO_KERNEL_DEBUG` builds (dev preset), and compiles to `((void)0)` otherwise.
- **Impact:** At worst inconsistent debug-trace formatting between libraries; no effect on release behaviour.
- **Suggested fix / next step:** Optional: a tiny shared header in runtime/src (already on all three include paths) or a grep check in an existing lint target.

### SYNC-03: kKinds = 9 unchecked
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsEvents.hpp:59-62; table at S/WebSocket/WsEvents.cpp:33, indexed at :95 and :121
- **Original claim:** `kKinds` is not checked against the `Kind` enum.
- **Analysis:** `Kind` currently has 9 enumerators (Dialed ... HandshakeGone) and `kKinds = 9`, so it is correct today; the header comment admits "Nothing checks that the two agree". If an enumerator were added without bumping `kKinds`, `dispatch[static_cast<int>(kind)]` (WsEvents.cpp:95 write, :121 read) would index out of bounds: a latent memory-safety bug, not a present one. The same pattern exists in S/Socket/SocketEvents.hpp:64-68 (`kKinds = 6`, table SocketEvents.cpp:35, indexed :104/:133).
- **Impact:** None today; future edit could silently corrupt memory.
- **Suggested fix / next step:** `static_assert(kKinds == static_cast<int>(Kind::HandshakeGone) + 1);` (and likewise in SocketEvents.hpp), or a trailing `Count` enumerator.

### HTTPS-11: pipeStreams result discarded
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/HttpStream/HttpStream.cpp:259-263 (`httpStreamSendBody`); S/Stream/StreamPipe.cpp:296-304 (`pipeStreams`)
- **Original claim:** `(void)pipeStreams(streamId, sink)` ignores a possible false result.
- **Analysis:** `pipeStreams` returns false only if `src` is read-locked or `dst` is write-locked (StreamPipe.cpp:300). The read lock of `src` is checked earlier in the same body (HttpStream.cpp:244-252), and the intervening calls (`parkResume`, `svc.create`, `createChannelSink` -> `insertChannelPair`, Stream.cpp:1042-1044) run no Elm code and take no stream locks; `sink` is freshly created so cannot be write-locked. A missing `src` is treated as ended and still returns true (Stream.hpp:124-131). So false is unreachable here.
- **Impact:** None.
- **Suggested fix / next step:** Optionally replace `(void)` with an `assert` to document the invariant.


## Dead code & cleanups

### DEAD-02: unused <cstdio>
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/ExportHelpers.hpp:21 (was :22)
- **Original claim:** `<cstdio>` is included but unused.
- **Analysis:** No stdio identifier (printf/snprintf/fwrite/fputs/fflush/FILE/stderr/stdout) appears in ExportHelpers.hpp. I also checked every elm-kernel-cpp file that includes ExportHelpers.hpp and uses stdio: each includes `<cstdio>`/`<stdio.h>` itself, so removing it breaks nothing found in this tree.
- **Impact:** Cleanup only.
- **Suggested fix / next step:** Delete the include; a build confirms.

### DEAD-03: unused/dead Scheduler.hpp and Platform.hpp
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/Scheduler.hpp (whole file), E/core/Platform.hpp (whole file)
- **Original claim:** both forwarding headers are included by nothing.
- **Analysis:** Both only `#include "platform/Scheduler.hpp"`. Every kernel source includes `platform/Scheduler.hpp` directly; the bare `#include "Scheduler.hpp"` lines are all in runtime/src/platform/*.cpp and resolve to that same directory first. No CMake/script/packaging reference to `core/Scheduler.hpp` or `core/Platform.hpp` was found (elm-kernel-cpp/CMakeLists.txt lists only `.cpp` files). Platform.hpp's own doc comment says "no kernel source currently includes it". Also dead and not in the entry: E/core/Process.hpp (another forwarder to platform/Scheduler.hpp; nothing includes `"Process.hpp"`).
- **Impact:** Cleanup only.
- **Suggested fix / next step:** Delete both headers (and core/Process.hpp); rebuild to confirm.

### DEAD-04: DebugExports value_bits unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/DebugExports.cpp:30 (`Elm_Kernel_Debug_log`)
- **Original claim:** local `value_bits` is computed and never used.
- **Analysis:** `uint64_t value_bits = value.toBits();` is never read; the function prints with `eco_print_elm_value(value)` (:35) and returns `value`.
- **Impact:** Cleanup only (an unused-variable warning).
- **Suggested fix / next step:** Delete the line.

### DEAD-05: DebugExports calls exit without <cstdlib>
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/DebugExports.cpp:47 (`Elm_Kernel_Debug_todo`); includes at :6-12
- **Original claim:** uses unqualified `exit` and relies on a transitive include for it.
- **Analysis:** None of the seven includes is `<cstdlib>` (E/KernelExports.h includes only `<cstdint>` and Heap.hpp, :38-39), so `exit` comes in transitively through the allocator headers. It builds today but is fragile.
- **Impact:** Cleanup only.
- **Suggested fix / next step:** Add `#include <cstdlib>` and call `std::exit(1)`.

### DEAD-06: Char.cpp <stdexcept> unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/Char.cpp:3
- **Original claim:** `<stdexcept>` is included but unused.
- **Analysis:** The whole 34-line file has no `throw` and no std exception type; `fromCode` returns U+FFFD for an out-of-range code (:7-12) instead of throwing.
- **Impact:** Cleanup only.
- **Suggested fix / next step:** Delete the include.

### DEAD-07: dead isNil(wrap(a)) in append
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/core/Utils.cpp:797-798 (`Utils::append`, was :855-856)
- **Original claim:** the `alloc::isNil(Allocator::instance().wrap(a))` alternative can never be true.
- **Analysis:** `Utils::append`'s only caller is `Elm_Kernel_Utils_append` (E/core/UtilsExports.cpp:163-172), which turns operands into `void*` with `Export::toPtr`. That returns nullptr for embedded constants (E/ExportHelpers.hpp:56-58), and `[]` is the Empty constant (`isNil` = `isEmptyBits`, runtime/src/allocator/HeapHelpers.hpp:247-249). A null `a` returns at Utils.cpp:787, so by :797 `a` is a real heap object and `wrap(a)` is never the Nil constant. The term is dead (it also costs a needless `wrap`). For the same reason, the `!a && !b` branch at :786 (`return emptyString()`, which would be wrong for `[] ++ []`) is unreachable, because the export returns `a` first (UtilsExports.cpp:169).
- **Impact:** Cleanup only.
- **Suggested fix / next step:** Drop the `isNil(wrap(a))` term. Optionally make the :786 branch an assert, since returning `""` there would be type-wrong if it were ever reached.

### DEAD-08: String foldl/foldr unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/String.cpp:129-162 (`Elm::Kernel::String::foldl`, `foldr`), declared String.hpp:110,115
- **Original claim:** The C++ `String::foldl`/`foldr` helpers have no callers.
- **Analysis:** A grep over elm-kernel-cpp, eco-kernel-cpp, system-kernel-cpp, runtime/src and test finds no call to `String::foldl`/`foldr`. The Elm-facing `Elm_Kernel_String_foldl` export (StringExports.cpp:329) has its own loop: it snapshots the chars, roots closure and acc with `StackRootGuard`, and calls `callFoldClosure`. It does not use these helpers. The test hits in Utf8StringTest.cpp:495-498 call `StringOps::foldl/foldr` in the runtime, which is a different function. The dead helpers also carry the latent STRING-01/02 defects: `resolve(result)` on a value that may be an embedded constant, and `result` left unrooted across `func`.
- **Impact:** None at runtime. Keeping them leaves two latent GC-unsafe functions that someone could start calling later.
- **Suggested fix / next step:** Delete both functions, the `FoldFunc` typedef if nothing else uses it, and the String.hpp declarations and comments (String.hpp:14-17,21,75,110-115). That also closes STRING-01/02.

### DEAD-09: consCellChar unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/String.cpp:41-47 (`static u32 consCellChar`)
- **Original claim:** The helper `consCellChar` is unused.
- **Analysis:** It is a file-static function, and its only occurrence in the repo is the definition. Its own comment says "Nothing calls it". `elemChar` (String.cpp:52) replaced it for the `ListCursor`-based walks.
- **Impact:** None. It may trigger an unused-function warning.
- **Suggested fix / next step:** Delete String.cpp:39-47.

### DEAD-10: words ranges.empty() unreachable
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/String.cpp:310 (UTF-8 branch) and :355 (UTF-16 branch), `words`
- **Original claim:** The `ranges.empty()` branch in `words` is unreachable.
- **Analysis:** `words` first trims with `StringOps::trim` (StringOps.hpp:946-966). That uses the same `isJsWhitespace` set as the scans, and an empty result returns early at String.cpp:282-285. After that, `trimmed` is non-empty and its first unit is not whitespace, so the scan always pushes at least one range. The final `i == len` iteration closes the open word. The UTF-8 branch scans bytes, which is valid because HEAP_032 guarantees UTF-8 forms are all-ASCII, so byte classification equals unit classification. Both `if (ranges.empty()) return alloc::listNil();` lines are therefore unreachable. They are also wrong in spirit: elm/core gives `[""]` for an empty result, not `[]`, but that never happens because of the early return.
- **Impact:** None.
- **Suggested fix / next step:** Replace both checks with `assert(!ranges.empty())`, or delete them.

### DEAD-11: static_assert(true) checks nothing
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/ListExports.cpp:426, `kernelListMapN`
- **Original claim:** `static_assert(true, "n_args ∈ {2,3,4,5}")` is vacuous.
- **Analysis:** It is literally `static_assert(true, ...)`, and `n_args` is a runtime `int`, so a static_assert could never check it. The only callers (ListExports.cpp:574, 585, 597, 611) pass the literals 2, 3, 4 and 5, so the range holds in practice. The doc comment (line 419) says "nothing checks it". An `n_args > 5` would overflow `closureSlotKinds[kMaxArgs]`, but no caller can pass one.
- **Impact:** None today. The line is misleading.
- **Suggested fix / next step:** Replace it with `assert(n_args >= 2 && n_args <= kMaxArgs);` placed after `kMaxArgs`.

### DEAD-12: dead List.cpp helpers
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/List.cpp:15 (`fromArray`), :23 (`sortBy`), :49 (`sortWith`), declared in List.hpp:35,53,69; /work/elm-kernel-cpp/src/core/ListExports.cpp:112 (`listToVector`), :123 (`getConsHead`)
- **Original claim:** `listToVector`, `getConsHead` and `List::sortBy`/`sortWith`/`fromArray` are dead.
- **Analysis:** The entry's location is slightly off: `listToVector` and `getConsHead` are in ListExports.cpp, not List.cpp. A grep finds no caller of either outside its definition; the only similar name in use is `listToVectorU64`, used at :378. No code calls `Elm::Kernel::List::fromArray/sortBy/sortWith`, and List.hpp:12-15 says so. The `Elm_Kernel_List_sortBy/sortWith/fromArray` exports (ListExports.cpp:318, 720, 780) have their own implementations. `listToVector` is also wrong if it were ever used, because it casts unboxed element bits to `void*`. The `ListOps::sortBy/sortWith` functions in runtime are used through this wrapper only, so check them for other users before deleting.
- **Impact:** None at runtime. List.hpp's comment admits the dead `sortBy`/`sortWith` are not stable, unlike Elm's. That is a trap if someone revives them.
- **Suggested fix / next step:** Delete the five functions and their declarations. Then check whether `ListOps::sortBy/sortWith` (runtime/src/allocator/ListOps.cpp:496,521) still have callers.

### DEAD-13: makeEncoder2_pi rooting asymmetric
- **Status:** WEAK · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/bytes/BytesExports.cpp:713-730 (`makeEncoder2_pi`) vs :734-750 (`makeEncoder2_pf`)
- **Original claim:** `_pi` copies `values[1]` from an unrooted Int slot of the roots buffer; this is asymmetric with `_pf` but harmless.
- **Analysis:** `_pi` passes `roots[2]` with mask 0x1. The GC treats only `roots[0]`, the Endianness HPointer, as a pointer root and updates it. `roots[1]` holds the raw Int, which no GC touches, so copying it back at :728 gives the original value. `roots[0]` is memcpy'd into `values[0]` after the allocation, so it is the updated pointer. `_pf` instead passes one root and stores `value` directly. Both are correct. In practice Endianness is a nullary ctor (an embedded constant), so it is not even movable.
- **Impact:** None. This is a style inconsistency only.
- **Suggested fix / next step:** Optionally make `_pi` match `_pf`: one root, and write `value` directly.

### DEAD-14: namespace read_bytes no negative-length check
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/bytes/Bytes.cpp:226-234 (`Elm::Kernel::Bytes::read_bytes`), declared Bytes.hpp:80
- **Original claim:** The namespace `read_bytes` lacks a negative-length check but is unused.
- **Analysis:** No caller exists anywhere; a grep for `read_bytes(` finds only the definition, the declaration and the separate `Elm_Kernel_Bytes_read_bytes` export. The export at BytesExports.cpp:579-588 is the live path and checks `offset < 0 || length < 0 || offset+length > len`. The dead version checks only `offset < 0` and `offset+length > buf_len`. A negative `length` would pass and call `BytesOps::slice` with end < start, and `offset + length` in i64 could also wrap. That latent defect cannot be reached.
- **Impact:** None. It would become a bounds bug if someone revived the function.
- **Suggested fix / next step:** Delete it, together with the rest of the unused `Bytes::` namespace API if that is also dead.

### DEAD-15: Json makeDecoder1i, jsonValueCtor unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/json/JsonExports.cpp:727 (`static u16 jsonValueCtor`), :930 (`static uint64_t makeDecoder1i`)
- **Original claim:** The Json helpers `makeDecoder1i` and `jsonValueCtor` are dead.
- **Analysis:** Both are file-static, and each name occurs once in the repo, at its definition. There are no other references in json/ or elsewhere.
- **Impact:** None, apart from unused-function warnings.
- **Suggested fix / next step:** Delete both.

### DEAD-16: File and Browser namespace APIs unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/file/File.cpp, File.hpp (`Elm::Kernel::File::*`); /work/elm-kernel-cpp/src/browser/Browser.cpp, Browser.hpp (`Elm::Kernel::Browser::*`); compiled via elm-kernel-cpp/CMakeLists.txt:187,216
- **Original claim:** The C++ namespace APIs for File and Browser are unused.
- **Analysis:** No file includes `file/File.hpp` or `browser/Browser.hpp` apart from their own .cpp files. FileExports.cpp and BrowserExports.cpp include only KernelExports.h and ExportHelpers.hpp, and no code references `Kernel::File::` or `Kernel::Browser::`. Browser.hpp:4-17 states that nothing calls them and that they behave differently from the exports, for example by wrapping `element`/`document` in a Custom. File.cpp's accessors assume an alphabetical slot layout that File.cpp:11 says no compiler-built record would have. They are also stubs: `decoder()` returns an empty `DecoderPtr`.
- **Impact:** None at runtime. They add build time, and their behaviour contradicts the real exports, which could mislead.
- **Suggested fix / next step:** Remove File.cpp/.hpp and Browser.cpp/.hpp from the sources and CMake. Keep the *Exports.cpp files.

### DEAD-17: s_streamHandles written never read
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/eco-kernel-cpp/src/eco-kernel/Process.cpp:31 (decl), :105 (only write), `spawnProcess`
- **Original claim:** `s_streamHandles` is dead state.
- **Analysis:** It is referenced only at :31 and :105. Entries are added keyed by the stdin fd and are never read or erased; the comment at :29-30 says so. The map grows by one int pair per piped spawn. It does not own the fd, so the fd lifetime is managed elsewhere.
- **Impact:** A negligible unbounded growth, one entry per `spawn` with stdin "pipe". It also gives no protection when fd numbers are reused.
- **Suggested fix / next step:** Delete the map and the write at :105.

### DEAD-18: redundant POST assignments
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/eco-kernel-cpp/src/eco-kernel/Http.cpp:368-372, the `fetch` body
- **Original claim:** The POST-specific assignments are duplicates.
- **Analysis:** The code is now `if (method == "POST") { req.body = ""; req.contentType = ""; }`, which is not curl setopt calls as the entry said. `HttpService::Request` default-constructs `body` and `contentType` as empty `std::string`s (runtime/src/platform/HttpService.hpp:96-97), and `req` is freshly constructed at :362. The assignments therefore change nothing, and the comment at :369 admits it. The `Content-Length: 0` behaviour comes from HttpService.
- **Impact:** None.
- **Suggested fix / next step:** Delete the `if` block. Keep the comment's point, as a one-line note that HttpService adds Content-Length: 0 for a body-less POST.

### DEAD-19: Runtime scanner unnamed
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/eco-kernel-cpp/src/eco-kernel/Runtime.cpp:91-101 (`registerGcRootScanner`); also /work/eco-kernel-cpp/src/eco-kernel/MVar.cpp:307-308 and /work/elm-kernel-cpp/src/http/HttpExports.cpp:428
- **Original claim:** The Runtime external root scanner is registered with the default name "unnamed".
- **Analysis:** `addExternalRootScanner(ExternalRootScanner, const char* name = "unnamed")` (runtime/src/allocator/RootSet.hpp:349-350). Runtime.cpp passes only the lambda, and so do MVar.cpp and HttpExports.cpp. TimeEffectManager.cpp:106 passes "time-effects". The names feed the per-scanner minor-GC stats and event log (ThreadLocalHeap.cpp:664-668), so several scanners show up as indistinguishable "unnamed" rows.
- **Impact:** Diagnostics only. Per-scanner GC timing cannot be attributed.
- **Suggested fix / next step:** Pass names such as "eco-runtime-state", "eco-mvar" and "http-effects" at the three sites.

### DEAD-20: TaskEffectManager duplicates encodeHP/decodeHP
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/core/TaskEffectManager.cpp:33-45; same copies in http/HttpEffectManager.cpp:58,65, http/HttpExports.cpp:224,230 and time/TimeEffectManager.cpp:57,64
- **Original claim:** TaskEffectManager has local copies of the ExportHelpers encode/decode.
- **Analysis:** The local `encodeHP`/`decodeHP` are byte-for-byte the same union reinterpretation as `Elm::Kernel::Export::encode/decode` (ExportHelpers.hpp:26-38). There are four such duplicate pairs in total, not only in TaskEffectManager. Their behaviour is identical.
- **Impact:** None. This is duplication only.
- **Suggested fix / next step:** Include ../ExportHelpers.hpp and use `Export::encode/decode` in all four files.

### DEAD-21: HttpEffectManager onSelfMsg double-roots
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** /work/elm-kernel-cpp/src/http/HttpEffectManager.cpp:239 (`topRoots(&router, &selfMsg, &state)`), :246 (`msgRoots(&tracker, &progress)`), :250 (`walkRoots(&router, &progress)`), `httpOnSelfMsgEvaluator`
- **Original claim:** `router` and `progress` are rooted twice.
- **Analysis:** `router` is pushed by `topRoots` and again by `walkRoots`, and `progress` by `msgRoots` and again by `walkRoots`, all live at the same time. That is harmless. The region minor GC handles a slot listed twice: its second visit sees a Fill role and returns (NurseryRegion.cpp:587-590, "A root slot can be listed twice ... duplicate stack-map slots"). The nursery `evacuate` path returns early for slots that already point outside from-space. The extra pushes only cost two root-stack entries per call.
- **Impact:** None, apart from a little root-stack use and confusion for readers.
- **Suggested fix / next step:** Delete the `walkRoots` guard at :250. `router` and `progress` stay rooted by `topRoots` and `msgRoots` for the whole loop.

### DEAD-22: kEndedMarker unused, literal hard-coded
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Core/Core.hpp:126 (`kEndedMarker`); S/Stream/Stream.cpp:61,63 (`kWritableClosed`, `kTerminated`); S/Stream/StreamPipe.cpp:50 (`kWritableClosed`)
- **Original claim:** `kEndedMarker` is never used; the `"\x02"` marker is written as a literal instead.
- **Analysis:** A grep across /work finds `kEndedMarker` only at its definition, Core.hpp:126. The ended-reason strings are literals with `"\x02"` written in: `"\x02WritableStream is closed"` (Stream.cpp:61, and again as a duplicate in StreamPipe.cpp:50) and `"\x02TransformStream has been terminated"` (Stream.cpp:63). `isMarkedReason` (Core.hpp:124) is the reader. The literals agree with the protocol described at Core.hpp:105-113, so nothing behaves wrongly.
- **Impact:** None at runtime. The marker byte is defined in two places, and `kWritableClosed` is duplicated across two translation units.
- **Suggested fix / next step:** Build the literals from `kEndedMarker` (e.g. `std::string(kEndedMarker) + "..."`, or a `constexpr` concat) and keep a single shared `kWritableClosed`, or delete `kEndedMarker`.

### DEAD-23: describeErrno unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Stream/Stream.cpp:92-95, `describeErrno` (inside the anonymous namespace opened at :57)
- **Original claim:** `describeErrno` is dead.
- **Analysis:** A grep of system-kernel-cpp finds only the definition. It sits in an anonymous namespace, so no other translation unit can call it. Its job is done by `errnoFailureReason` (Core.hpp:119).
- **Impact:** Dead code; likely triggers a -Wunused-function warning.
- **Suggested fix / next step:** Delete it.

### DEAD-24: Conn isTls never read
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Conn.hpp:147, `ConnectSpec::isTls`; written at S/Tls/Tls.cpp:190 and S/WebSocket/WsHandshake.cpp:440
- **Original claim:** The `isTls` field in Conn is dead.
- **Analysis:** The field's own doc comment says "Informational only: nothing reads it". Conn.cpp never reads `spec_.isTls`, and no reader exists anywhere else. Whether a connection is TLS is decided by the `TransportFactory`. Other fields with the same name are live and are not part of this entry: `ConnEntry::isTls` (SocketTables.hpp:84, read at Tls.cpp:283), `DialSpec::isTls`, and the WsEvents field.
- **Impact:** None.
- **Suggested fix / next step:** Remove `ConnectSpec::isTls` and its two writes, taking care not to touch the live `isTls` fields.

### DEAD-25: hasBufferedRead never called
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Conn.hpp:108 (virtual default); S/Tls/TlsTransport.cpp:216-218 (override)
- **Original claim:** `Transport::hasBufferedRead` is never called.
- **Analysis:** The only matches are the declaration and the override, and the comment at Conn.hpp:106-107 already says "The `Conn` does not call this". I checked whether removing it could hide a stall. Plaintext that TLS has already decrypted is reached in two ways: `setProtocol` sets `again_ = againRead_ = true` (Conn.cpp:497-498), and `updateInterest` runs `runIo(true,true)` (Conn.cpp:601-603), which calls `serviceReads`. So the method's absence does not leave buffered data unread.
- **Impact:** None.
- **Suggested fix / next step:** Delete it, or keep it as a documented debug hook. The choice is cosmetic.

### DEAD-26: Listener openConnections no caller
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Listener.hpp:96, `Listener::openConnections()`
- **Original claim:** `openConnections` has no caller.
- **Analysis:** The getter has no callers. The counter behind it, `open_`, is live: it is incremented at Listener.cpp:121, decremented at :66, and checked against `maxConnections_` at :61. Only the accessor is dead.
- **Impact:** None.
- **Suggested fix / next step:** Delete the getter and keep `open_`.

### DEAD-27: SocketTables resumeToken unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/SocketTables.cpp:65-71, `resumeToken(uint64_t, HPointer&)` (anonymous namespace :26-214)
- **Original claim:** The `resumeToken` helper is unused.
- **Analysis:** No call to `resumeToken(` exists in system-kernel-cpp. Every other match is the unrelated `ChildJob::resumeToken` field in ChildProcess. Because the function is in an anonymous namespace, no other translation unit can use it. Its rooting is correct: `resume` is guarded before `callClosure1`.
- **Impact:** None; dead code (and possibly an unused-function warning).
- **Suggested fix / next step:** Delete it.

### DEAD-28: Socket.cpp carries plan citations
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** S/Socket/Socket.cpp (around :510-525 now, inside `closeListener`)
- **Original claim:** Comments cite plan items such as "G11" and "§3.4".
- **Analysis:** A grep of S/Socket/ for `G1[0-9]`, `§`, `3\.4` and `plan` returns nothing. The comment at the old location now reads "From here on the loop allocates, so `e` is not used again." The citations are gone.
- **Impact:** None.
- **Suggested fix / next step:** Nothing to do; close the entry.

### DEAD-29: socketNotImplementedTask/socketDoneTask unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Socket.hpp:45,49; S/Socket/Socket.cpp:180,182 (with their bodies `notImplementedBody` :35 and `doneBody` :42)
- **Original claim:** The two stub task makers are unused.
- **Analysis:** A grep of system-kernel-cpp shows only their declarations, definitions, and the comments that name the bodies. The kernel export tables do not reference them either, since the grep would have matched.
- **Impact:** None.
- **Suggested fix / next step:** Delete both functions, their bodies, and the header declarations.

### DEAD-30: SocketManager mask constants unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/SocketManager.hpp:48,50,52,54 (`CONN_T_MASK`, `CONN_IDS_MASK`, `CONN_ENDPOINTS_MASK`, `EP_T_MASK`); the literals are at S/Socket/SocketTables.cpp:279 (`0x11`), :295 (`0x5`), :298 (`0`), :299 (`0x1`)
- **Original claim:** Four mask constants are unused while the code writes literals.
- **Analysis:** None of the four is referenced outside SocketManager.hpp. Only `ON_CONNECTION_MASK` is used (SocketManager.cpp:153). I checked each literal against the 2-bit kind encoding (REP_HEAP_002: 01 = Int at bits 2i..2i+1), and all are correct. `0x11` marks slots 0 and 2 of `(Int, String, Int)`. `0x5` marks both slots of `(Int, Int)`. `0` covers the two boxed endpoints. `0x1` marks the connId. The constants and literals hold the same values today, so this is a drift risk, not a bug.
- **Impact:** None now. A future layout change could update only one of each pair.
- **Suggested fix / next step:** Use the named constants in `buildEndpoint` and `buildConnT`.

### DEAD-31: UdpManager masks unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/UdpManager.hpp:48,51 (`DGRAM_T_MASK`, `DGRAM_FROM_MASK`); literals at S/Socket/Udp.cpp:419-420, `buildDgramT`
- **Original claim:** `DGRAM_T_MASK` and `DGRAM_FROM_MASK` are unused; the code writes literals.
- **Analysis:** The header comments themselves say "Nothing reads it; `buildDgramT` writes the literal ...". The literal `0x4` (port in slot 1 = Int) is correct for `(String, Int)`, and `0` is correct for `(Bytes, tuple)`. Rooting in `buildDgramT` is also correct: `data` and `from` are guarded, and `text` goes straight into `tuple2`.
- **Impact:** None.
- **Suggested fix / next step:** Use the constants in `buildDgramT` and drop the "nothing reads it" notes.

### DEAD-32: SPEC_TRIPLE_MASK unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/ChildProcess/ChildProcessManager.hpp:53; mentioned only in a comment at ChildProcessManager.cpp:85
- **Original claim:** `SPEC_TRIPLE_MASK` is a dead constant.
- **Analysis:** The only reference is the comment `// mask SPEC_TRIPLE_MASK` next to `asTuple3(tripleHP)`. The code reads the tuple and never builds one, so it needs no mask. The value 0x14 (slots 1 and 2 = Int) matches the documented layout.
- **Impact:** None.
- **Suggested fix / next step:** Delete the constant, or turn it into a debug assert on the tuple header's kind bits when the spec is read.

### DEAD-33: Windows reportFatal message ends "yet"
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/ChildProcess/ChildProcessManager.cpp:107-110, `handleSpawn` (`#ifdef _WIN32`)
- **Original claim:** The Windows fatal message is cut off and ends in "yet".
- **Analysis:** The message is the complete sentence "eco/system: ChildProcess.spawn is not supported on Windows yet". Nothing is cut off; it only describes a temporary limitation. I also checked whether control can fall through on Windows: `reportFatal` is `[[noreturn]]` (eco-kernel/KernelExports.h:51), so the POSIX path after `#endif` never runs there. That path must still compile on Windows, but Windows work is low priority.
- **Impact:** Wording only.
- **Suggested fix / next step:** Optionally reword (e.g. "... is not supported on Windows"); otherwise close the entry.

### DEAD-34: WsHandshake headDone ok/err unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsHandshake.hpp:222 (declaration); S/WebSocket/WsHandshake.cpp:504 (definition with unnamed `bool, const std::string&`); sole call at :353
- **Original claim:** The `ok` and `err` parameters of `DialJob::headDone` are unused.
- **Analysis:** The definition leaves both parameters unnamed. The one caller (WsHandshake.cpp:353) always passes `true, std::string()`, after it has already handled parse failure through `fail(...)` (:345-347). The failure path never goes through `headDone`, so the parameters carry no information.
- **Impact:** None.
- **Suggested fix / next step:** Drop both parameters from the declaration, the definition and the call.

### DEAD-35: WsHandshakeEntry::server never read
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsTables.hpp:61 (field); written at S/WebSocket/WsTables.cpp:307,317
- **Original claim:** `WsHandshakeEntry::server` is a dead field (cf. WS-20).
- **Analysis:** The field is written only, by the two server-registration functions. Every `.server` read in WebSocket/ belongs to another struct: `WsConfig::server` is read in WsProtocol.cpp:81,697,1050 and set in WebSocket.cpp:449. So the field is dead, but it should not just be deleted. WS-20 says reject/open trust the role that Elm passes; this field is the natural data for that check. The right fix is to read it, not remove it.
- **Impact:** None by itself. Read together with WS-20, it shows the role validation that was meant to exist and is missing.
- **Suggested fix / next step:** Fix WS-20 by checking `entry.server` in reject/open (failing EINVAL on a role mismatch), rather than deleting the field.

### DEAD-36: onClosed resumed unused
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WsTables.cpp:202-231, `onClosed`
- **Original claim:** the local `resumed` in `onClosed` is set but never used.
- **Analysis:** `bool resumed = false;` (:212) is set to true in the waiter loop (:225) and then only cast away with `(void)resumed;` (:229). The function always returns `false` (:230), and its doc comment (:200-201) says so on purpose, because it drains the Scheduler after each resume (:224). The variable has no effect at all.
- **Impact:** None at runtime. It just makes the code harder to read.
- **Suggested fix / next step:** Delete `resumed`, its assignment and the `(void)` cast.

### DEAD-37: Http2Client closeCode_ never read
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/Http2Client.hpp:166 (field), written at Http2Client.cpp:383 (`streamGone`) and :456 (`onCloseAll`)
- **Original claim:** `Http2ClientProtocol::closeCode_` is written but never read.
- **Analysis:** A grep finds only the two writes and the declaration. The header comment itself says "Recorded, and read nowhere". The code is passed straight to `port->streamReset(code)` (:390, :459), so nothing depends on the field. `WsProtocol::closeCode_` is a separate field, and it is read (WsProtocol.cpp:1152).
- **Impact:** None. It is one dead member.
- **Suggested fix / next step:** Remove the field and both writes.

### DEAD-38: Phase::Done DATA appended to held_
- **Status:** WEAK · **Severity:** LOW
- **Where:** S/WebSocket/Http2Client.cpp:127-142, `Cb::dataChunk`; Phase::Done set only at :92
- **Original claim:** DATA that arrives in `Phase::Done` is appended to `held_` and never used.
- **Analysis:** It is true that `dataChunk` does not filter on `Phase::Done` (:131 rejects only `done_` and `Phase::Requested`). But the only place that sets `Phase::Done` is the SETTINGS fallback (:92), and that happens while still in `Phase::Settings`, before `submitRequest` (:368) assigns `sid_`. So `sid_` is still -1. nghttp2 stream ids are positive, so the `sid != p->sid_` test at :131 drops every DATA frame in that state. The only other phases in which DATA can be appended are `Held` (port not yet bound), and there `held_` is used on purpose: `bindPort` hands it to the port (:468-469). `Settings` is covered by the same `sid_ == -1` argument. No data is ever stranded in `held_`.
- **Impact:** None that can be reached.
- **Suggested fix / next step:** No change needed. Optionally add `|| p->phase_ == Phase::Done` at :131 to make the intent explicit.

### DEAD-39: kDefaultDrainMs duplicates WsCore::kDrainMs
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/H2StreamPort.cpp:26 and :140, `H2StreamPort::portCloseGraceful`; S/WebSocket/WsProtocol.hpp:173 `WsCore::kDrainMs`
- **Original claim:** `kDefaultDrainMs` duplicates `WsCore::kDrainMs`.
- **Analysis:** Both constants are 2000. The fallback `drainMs > 0 ? drainMs : kDefaultDrainMs` (:140) cannot be reached: the only callers of `portCloseGraceful` are WsProtocol.cpp:232, 239, 1052 and 1083, and all of them pass `kDrainMs` (2000 > 0). So the constant is both a duplicate and dead in practice. If someone changed one value later, the two would drift apart without anyone noticing, but nothing would break.
- **Impact:** Cosmetic only.
- **Suggested fix / next step:** Drop the fallback, or assert `drainMs > 0`, or reference `WsCore::kDrainMs`.

### DEAD-40: wsNotImplementedBody dead
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/WebSocket/WebSocket.cpp:233-237; declared at WebSocket.hpp:50
- **Original claim:** `wsNotImplementedBody` is dead.
- **Analysis:** A grep of /work (system, eco and elm kernels, and the compiler) finds only its definition and declaration, and no `makeBinding<wsNotImplementedBody>`. The header comment says "No export in this module binds it". It is a stub left over from before WebSocket was implemented.
- **Impact:** None. It is dead code in a public header.
- **Suggested fix / next step:** Remove the definition and the declaration.

### DEAD-41: httpServerNotImplementedBody dead
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/HttpServer/HttpServer.cpp:371-375; declared at HttpServer.hpp:79
- **Original claim:** `httpServerNotImplementedBody` is dead.
- **Analysis:** Same pattern as DEAD-40: there are no references beyond the definition and declaration, and the header says "Nothing in the project binds this body".
- **Impact:** None.
- **Suggested fix / next step:** Remove both.

### DEAD-42: KillHandle.cpp plan citations
- **Status:** RESOLVED · **Severity:** LOW
- **Where:** S/Core/KillHandle.cpp (49 lines)
- **Original claim:** the comments in KillHandle.cpp cite plan documents.
- **Analysis:** The current file's comments (:1-16, :24-25, :39) describe how the kill handle and the drain split the hold release, with no reference to `plans/`, step or phase numbers, or any `.md` document. A grep for "plan", "plans/" and "§" in Core/ finds nothing. The citations seem to have been removed during the re-comment.
- **Impact:** None.
- **Suggested fix / next step:** Nothing to do.

### DEAD-43: writeFaceShutdown branch unreachable
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/FaceProtocol.cpp:236-249, `FaceProtocol::writeFaceShutdown` (the `if (closePending_)` branch at :241-244)
- **Original claim:** the "defensive" `closePending_` branch after `cancelWrites` can never run.
- **Analysis:** `closePending_` is set only in `reqCloseWrite` (:215), right before `c.shutdownWrite(cb)` (:219). There are two cases:
  - `Conn::shutdownWrite` (Conn.cpp:574-586) calls `cb` synchronously. Then `closeDone` clears `closePending_` (:224).
  - Otherwise the callback is pushed onto `shutDone_` (:583). In this case `c.cancelWrites(ECANCELED)` (:239) leads to `failOutbound` and then to `finishShutdown(err)` (Conn.cpp:605-620), which calls every `shutDone_` callback, so `closeDone` clears `closePending_` while `cancelling_` is still true. That path posts ECANCELED (:228-229).

  Either way `closePending_` is false by the time :241 runs. The only other completion path, the shutdown at Conn.cpp:707-722, also clears `shutDone_` by calling it. The comment at :241 already admits the branch is defensive.
- **Impact:** None. The branch is harmless dead code.
- **Suggested fix / next step:** Replace it with `assert(!closePending_)`, or keep it as documented defence.

### DEAD-44: CTOR_TIME_EVERY defined twice
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** E/time/TimeExports.cpp:48 and E/time/TimeEffectManager.cpp:54 (both `static constexpr u16 CTOR_TIME_EVERY = 0;`)
- **Original claim:** `CTOR_TIME_EVERY` is defined twice.
- **Analysis:** There are two independent TU-local definitions. Both are 0 today, so the producer (TimeExports.cpp:279) and the consumers (TimeEffectManager.cpp:251, 376, 398) agree. The comment at TimeExports.cpp:47 admits "nothing checks the two agree".
- **Impact:** None today. If one copy were changed and the other not, `Time.every` subscriptions would be silently ignored or misrouted.
- **Suggested fix / next step:** Move the constant into a shared time header used by both TUs.

### DEAD-45: 0xFFFD shared by CONSTANT_TAG and CTOR_Router
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** runtime/src/allocator/Heap.hpp:388 (`#define CONSTANT_TAG 0xFFFD`); runtime/src/allocator/HeapHelpers.hpp:1940 (`CTOR_Router = 0xFFFD`); noted in E/core/Utils.cpp:36-37
- **Original claim:** `CONSTANT_TAG` and `CTOR_Router` use the same value, 0xFFFD.
- **Analysis:** The collision is real and documented in both places. `eco_get_tag` (RuntimeExports.cpp:~4250) returns `CONSTANT_TAG` for the Empty constant, and a router Custom (PlatformRuntime.cpp:195) would report the same value. That would only matter if some code had to tell a router apart from Empty by tag. In fact the only use of `CTOR_Router` is its construction (PlatformRuntime.cpp:195). Effect managers read its fields positionally and never switch on its ctor, and Elm code cannot case-match on a router. So the collision has no observable effect. Compiler ctor tags are small indices, so they do not reach 0xFFFD.
- **Impact:** None today. It is a latent trap if someone ever dispatches on the tag.
- **Suggested fix / next step:** Optionally move `CTOR_Router` to another reserved value (for example 0xFFFC) and record the reserved range in one place.

### DEAD-NEW-1: socketNotImplementedTask / notImplementedBody dead
- **Status:** CERTAIN · **Severity:** LOW
- **Where:** S/Socket/Socket.cpp:34-35 (`notImplementedBody`), :180 (`socketNotImplementedTask`); declared at S/Socket/Socket.hpp:45
- **Original claim:** (new) this is the same kind of leftover stub as DEAD-40/41.
- **Analysis:** A grep across /work (excluding build trees) finds no caller of `socketNotImplementedTask`, only its definition and declaration.
- **Impact:** None.
- **Suggested fix / next step:** Remove it together with DEAD-40/41.
