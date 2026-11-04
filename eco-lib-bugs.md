# Eco kernel C++: suspected bugs

Source: the `cpp-doc-comments` run of 2026-11-03 (baseline commit `3e736b6`), section 4 of
`icm-agents/workspaces/cpp-doc-comments/stages/04-review/output/review-report.md`
(the two wrap-up items plus groups A to D). These are suspicions found by reading the code
while re-commenting it. None has been fixed or tested. Line numbers refer to the post-recomment
sources; "orig :N" marks a pre-recomment line number taken from the log. Where the report bundled
several distinct defects into one item they are split into separate entries here.

Excluded on purpose: review item (B)1, kernel `modBy 0` throwing while the CGEN_084 inline
lowering yields 0. That divergence is deliberate. The separate wrap-up item about `modBy`'s
exception escaping an `extern "C"` export without `ECO_KERNEL_GUARD` is kept (ABI-01).

Path abbreviations: `E/` = `/work/elm-kernel-cpp/src/`, `K/` = `/work/eco-kernel-cpp/src/eco-kernel/`,
`S/` = `/work/system-kernel-cpp/src/eco-system/`.

Entries marked **FIXED on master** were fixed by code that landed on master (found while rebasing,
2026-11-04); they are kept so the numbering stays stable.

Each entry has three lines: where, what is wrong, and consequence plus confidence.

| Prefix | Entries |
|---|---|
| ABI | 5 |
| ARRAY | 6 |
| BASICS | 3 |
| BROWSER | 1 |
| BYTES | 5 |
| CONSOLE | 4 |
| CORE | 19 |
| CRASH | 1 |
| DEAD | 45 |
| DEBUG | 1 |
| FD | 5 |
| FILE | 12 |
| FS | 6 |
| H2 | 4 |
| HASH | 1 |
| HEAP | 5 |
| HTML | 1 |
| HTTP | 12 |
| HTTPS | 11 |
| HTTPSRV | 16 |
| IO | 1 |
| JSON | 11 |
| LIST | 8 |
| MVAR | 2 |
| PARSE | 6 |
| PLATFORM | 1 |
| PROC | 8 |
| REGEX | 8 |
| RESET | 11 |
| RUNTIME | 1 |
| SIG | 4 |
| SOCK | 16 |
| STREAM | 10 |
| STRING | 2 |
| SYNC | 3 |
| SYS | 3 |
| TASK | 3 |
| TERM | 6 |
| TIME | 9 |
| TLS | 10 |
| URL | 4 |
| UTILS | 7 |
| WATCH | 8 |
| WS | 26 |
| ZLIB | 1 |
| **Total** | **332** |


## Memory safety & GC

### ARRAY-01: unsafeSet range check truncates the index to 32 bits
Where: `E/core/JsArrayExports.cpp:238-243, 882, 892, 902`, `unsafeSet` and `unsafeSet_Int/_Float/_Char`.
What: the bound check uses `static_cast<uint32_t>(idx)` but the write uses the full 64-bit `elements[idx]`.
Impact: an index >= 2^32 or <= -2^32 whose low 32 bits are in range writes out of bounds; reported at wrap-up, not reproduced.

### ABI-01: modBy throws across an extern "C" export
Where: `E/core/BasicsExports.cpp:181-183`, `Elm_Kernel_Basics_modBy`.
What: `std::runtime_error` can escape an `extern "C"` export that has no `ECO_KERNEL_GUARD`.
Impact: unwinding through C linkage (UB / terminate) when `modBy 0` reaches the kernel; the throw itself is intended, the missing guard is the suspect; wrap-up finding.

### REGEX-01: createMatch kind mask swaps String and Int slots — **FIXED on master**: createMatch writes fields in layout order (the mask was right, the order was wrong)
Where: `E/regex/RegexExports.cpp` `createMatch` (map ref :111-122).
What: mask `0b0101` marks the match String slot as Int and the `number` Int slot as boxed.
Impact: GC would treat an integer as a pointer and skip a live string; known issue, high confidence.

### REGEX-02: Regex custom built with 2-bit kind mask 0b111 — **FIXED on master**: never uses kind mask 0x15
Where: `E/regex/RegexExports.cpp` `Elm_Kernel_Regex_never`, `fromStringWith` (`custom(CTOR_REGEX, values, 0b111)`).
What: with 2-bit kinds the mask reads as slot 0 Char, slot 1 Int, slot 2 boxed while slot 2 holds a raw 0/1.
Impact: GC may dereference raw 0/1 as a pointer; reviewer finding, unverified at runtime.

### REGEX-03: replaceAtMost/splitAtMost catch paths use unrooted strings
Where: `E/regex/RegexExports.cpp` catch paths of `replaceAtMost`/`splitAtMost`.
What: return or decode `str`/`strEnc` that are not rooted across allocations made in the loop.
Impact: stale pointer after a GC during the loop when the regex throws; known issue.

### REGEX-04: getCompiledRegex does not check the object tag
Where: `E/regex/RegexExports.cpp` `getCompiledRegex`.
What: reads `ctor` from the object without checking it is a `Tag_Custom`.
Impact: misread memory on a malformed value; probably unreachable from well-typed Elm.

### TIME-01: tagger/router encodings decoded after an allocation
Where: `E/time/TimeEffectManager.cpp:~177-178`.
What: `taggerEnc`/`routerEnc` are copied under `g_timerMutex`, then `Scheduler::taskSucceed` allocates before they are decoded and rooted.
Impact: a GC in between leaves stale pointers; reviewer finding, unconfirmed.

### TIME-02: subMap kind bitmap marks a Float field as Int — **FIXED on master**: subMap uses kind mask 0b10 (Float)
Where: `E/time/TimeEffectManager.cpp:397`, `subMap`.
What: kind bitmap `0b01` while field 0 holds a Float.
Impact: field misclassified for GC/equality; known issue.

### TIME-03: setInterval writes Int kind for a Float field — **FIXED on master**: setInterval uses kind mask 0b10 (Float)
Where: `E/time/TimeExports.cpp:281`, `setInterval`.
What: mask `0b01` (Int) is written for a Float field.
Impact: same misclassification as TIME-02; known issue.

### TIME-04: setInterval skips capture when the binding callback does not resolve
Where: `E/time/TimeExports.cpp:251-253`.
What: if `resolve(bindingCB)` is null the capture is skipped, but the evaluator then reads uncaptured `rawArgs[0]`.
Impact: garbage read in the evaluator; trigger unclear, unverified.

### TASK-01: task effect manager closures unrooted at registration
Where: `E/core/TaskEffectManager.cpp:200-206`, `eco_register_task_effect_manager`.
What: holds `initCl`/`onEffectsCl`/`onSelfMsgCl` unrooted across later `allocClosure` calls.
Impact: stale closure pointers if GC runs during registration; known issue.

### TASK-02: taskOnEffectsEvaluator reads state unrooted after allocations
Where: `E/core/TaskEffectManager.cpp:125` (allocations at :93, :117-118).
What: reads state from `args[3]` after `allocClosure`/`taskAndThen`/`rawSpawn` without rooting it.
Impact: stale state pointer after a GC; reviewer finding, unconfirmed.

### TASK-03: resolve on a constant command asserts
Where: `E/core/TaskEffectManager.cpp:111, 164`.
What: calls `resolve` on a command that may be an embedded constant.
Impact: assertion under `ECO_HEAP_VALIDATE`; garbage in other builds if reached.

### ARRAY-02: boxed unsafeSet marks Float/Char sources Int-kind
Where: `E/core/JsArrayExports.cpp:247`, boxed `unsafeSet`.
What: Float/Char sources are marked Int kind and read via `unboxInt`.
Impact: wrong element kind/value for Float/Char arrays; known issue.

### ARRAY-03: push reads Char padding as part of a 64-bit value
Where: `E/core/JsArrayExports.cpp:296`, `push`.
What: marks Float/Char sources Int-kind and reads 64 bits including `ElmChar::padding`.
Impact: uninitialised padding bits in stored chars; known issue.

### ARRAY-04: unsafeSet_* force the result kind regardless of source
Where: `E/core/JsArrayExports.cpp:886, 897, 909`, `unsafeSet_Int/_Float/_Char`.
What: result kind is forced unboxed even when the source array is boxed-kind.
Impact: the source's HPointers are reinterpreted as raw values; reviewer finding.

### ARRAY-05: elm_array_push_* writes raw words into a boxed array
Where: `E/core/JsArrayExports.cpp`, `elm_array_push_*`.
What: on a non-empty boxed (kind 0) array, writes an unboxed raw word.
Impact: GC treats the raw word as a pointer; reviewer finding, trigger path unverified.

### LIST-01: List.fromArray conses Float/Char as Int-kind cells
Where: `E/core/ListExports.cpp:343, 354`.
What: unboxed Float/Char arrays are consed into Int-kind cells.
Impact: wrong kind on list cells (comparison/printing/GC metadata); reviewer finding.

### LIST-02: element kind differing from closure kind delivered unconverted
Where: `E/core/ListExports.cpp:477-500`.
What: an unboxed element whose kind differs from the closure kind is passed in its own kind.
Impact: `eco_apply_closure_eval` asserts (`RuntimeExports.h:592-596`); probably unreachable.

### LIST-03: dead sortWith resolves raw bits after a boxed first node
Where: `E/core/List.cpp` (dead code) `sortWith`.
What: decides boxedness from the first node, then resolves raw bits of later nodes.
Impact: bad pointer deref if revived; currently dead.

### LIST-04: dead List.cpp sorts resolve embedded constants
Where: `E/core/List.cpp` (dead) sort functions.
What: call `resolve` on elements that may be embedded constants.
Impact: assert/garbage if revived; dead code.

### LIST-05: dead sortBy boxes unboxed elements as Int
Where: `E/core/List.cpp:33, 40` (dead) `sortBy`.
What: boxes unboxed elements as Int and reads keys as `ElmInt`.
Impact: wrong ordering for Float/Char keys if revived; dead code.

### STRING-01: String foldl/foldr resolve a possibly-constant accumulator
Where: `E/core/String.cpp` foldl/foldr (no callers).
What: `resolve` on an accumulator that may be an embedded constant.
Impact: assert under `ECO_HEAP_VALIDATE`; dead code, latent.

### STRING-02: String foldl/foldr leave the accumulator unrooted across func
Where: `E/core/String.cpp` foldl/foldr (no callers).
What: result held unrooted across the call to `func`.
Impact: stale pointer after GC; dead code, latent.

### HEAP-01: listToStringVector resolves the empty-string constant
Where: `K/KernelHelpers.hpp:~216-218`, `listToStringVector`.
What: calls `Allocator::resolve` on every element, including the empty-string constant, against `Allocator.hpp:101`.
Impact: `ChildProcess` `decodeProgram` may misread an empty-string argument (`KernelHelpers.hpp:212`); Tls ALPN `""` element possibly affected (unverified).

### HEAP-02: NativeDriver resolves Bytes without the empty-Bytes check
Where: `K/NativeDriver.cpp:68-71`, `lowerAndLinkBytesBody`.
What: `resolve(bytesHP)` without the empty-Bytes constant check (`resolveBytesOrNull`, `HeapHelpers.hpp:2110`; cf. `File.cpp:522`).
Impact: empty Bytes input misread/asserts; known issue.

### HEAP-03: eco ExportHelpers toPtr(0) reads address 0
Where: `K/ExportHelpers.hpp`, `toPtr`.
What: `toPtr(0)` reaches `resolveFast` and dereferences address 0.
Impact: crash on a null word; reviewer finding.

### HEAP-04: eco toPtr sends PermanentSpace words through resolveFast
Where: `K/ExportHelpers.hpp`, `toPtr`.
What: PermanentSpace words go through `resolveFast`, whereas the elm-kernel version returns them unchanged.
Impact: divergence between the two helpers; possible misresolution, unverified.

### PROC-01: spawnProcessBody holds stdinMaybe unrooted
Where: `K/Process.cpp`, `spawnProcessBody`.
What: `stdinMaybe` is unrooted across a `tuple2` allocation.
Impact: possible stale pointer; reviewer marked it unchecked.

### RESET-01: Runtime root scanner not re-registered after reset
Where: `K/Runtime.cpp:87-97`.
What: scanner registered once; a root-set reset clears it while `s_hasState`/`s_savedState` survive.
Impact: stale HPointer in saved state after heap reset; reviewer finding.

### RESET-02: Time root scanner not re-registered after reset
Where: `E/time/TimeEffectManager.cpp:95-106` (reset clears scanners at `RootSet.cpp:163`).
What: scanner registered via `call_once`, never re-registered; `g_intervals` not cleared.
Impact: interval closures unrooted after a heap reset; reviewer finding.

### RESET-03: MVar root scanner has no once guard and no re-registration
Where: `K/MVar.cpp`, `registerGcRootScanner`.
What: no once guard (possible double registration) and not re-registered after reset.
Impact: MVar contents unrooted after reset, or scanned twice; reviewer finding.

### MVAR-01: MVar read/take/put skip capture when the callback does not resolve
Where: `K/MVar.cpp` read/take/put.
What: when `resolve(cb)` is null, capture is skipped silently and a Binding is built over an uncaptured closure.
Impact: garbage resume closure; trigger unclear, unverified.

### MVAR-02: unordered_map iterator held across callClosure1
Where: `K/MVar.cpp`.
What: an iterator into the MVar map is held across `callClosure1`.
Impact: invalidated if the resume re-enters `newEmpty`/`drop`; unconfirmed.

### UTILS-01: two different constants in a boxed slot pair hit unreachable
Where: `E/core/Utils.cpp:211-214`.
What: the case of two distinct constants falls into `__builtin_unreachable()`.
Impact: UB with asserts off; reachability uncertain.

### BASICS-01: Int arithmetic relies on signed overflow
Where: `E/core/BasicsExports.cpp` `_Int` add/sub/mul/pow.
What: signed `int64_t` overflow is UB, while Elm semantics wrap.
Impact: compiler may miscompile overflowing arithmetic; reviewer finding.

### BASICS-02: pow_Int overflows even when the result fits
Where: `E/core/BasicsExports.cpp` `pow_Int`.
What: squares `b` once past the last needed bit.
Impact: UB overflow for e.g. `pow 2 62`; reviewer finding.

### BASICS-03: boxed arithmetic reads b with a's kind
Where: `E/core/BasicsExports.cpp` boxed add/sub/mul/pow.
What: `b` is read as `a`'s kind without checking `b`'s tag.
Impact: misread on mixed Int/Float boxed operands; likely unreachable if types agree.

### BYTES-01: getHostEndianness returns raw 0/1 words — **FIXED on master**: returns the LE/BE value passed in, wrapped in a Task
Where: `E/bytes/BytesExports.cpp`, `Elm_Kernel_Bytes_getHostEndianness`.
What: returns raw words 0/1 (0 is the null word), not `nullConsWordFor` constants.
Impact: invalid Elm value; known issue.

### BYTES-02: getHostEndianness arity mismatch with Elm — **FIXED on master**: takes (le, be) and returns a Task
Where: `E/bytes/BytesExports.cpp`, `Elm_Kernel_Bytes_getHostEndianness`.
What: export has arity 0 while Elm passes LE and BE and expects a Task.
Impact: ABI mismatch on call; known issue.

### BYTES-03: read_string length 0 skips the bounds check
Where: `E/bytes/BytesExports.cpp`, `read_string`.
What: `length == 0` skips the bounds check at any offset, including negative or past end.
Impact: decoder succeeds where it should fail; reviewer finding.

### BYTES-04: encoder size narrowed size_t to u32 unchecked
Where: `E/bytes/BytesExports.cpp`, `elm_encoder_size`/`elm_encoder_write_into`.
What: unchecked `size_t` -> `uint32_t` narrowing.
Impact: buffer overflow/truncation for encodings >4 GiB; unlikely in practice.

### PARSE-01: long UTF-16 ropes reach flatStringView unflattened
Where: `E/parser/ParserExports.cpp:81` (`StringOps.hpp:219-222`, `HeapHelpers.hpp:2174-2176`).
What: ropes/slices above `string_flatten_limit` are not flattened before `flatStringView`.
Impact: assert or misread on long source strings; reviewer finding.

### PARSE-02: number chompers lack an offset < 0 check
Where: `E/parser/ParserExports.cpp` `chompBase10`/`consumeBase`/`consumeBase16`.
What: no `offset < 0` check before `s.at(offset)`.
Impact: out-of-range access/throw on a negative offset; probably unreachable from elm/parser.

### PARSE-03: consumeBase accumulation overflows int64
Where: `E/parser/ParserExports.cpp` `consumeBase`/`consumeBase16`.
What: i64 accumulation overflows (UB); JS uses doubles.
Impact: wrong results/UB on long digit runs; reviewer finding.

### HTTP-01: Bytes/File bodies read as Strings — **FIXED on master**: bodyBytes reads Bytes bodies and parts as raw bytes (File gives ""; no File reaches the native kernel)
Where: `E/http/HttpExports.cpp:644, 654`.
What: Bytes/File bodies and parts are read via `elmStringToUTF8`/`toStdString` on non-String objects.
Impact: memory misread / wrong body sent; reviewer finding.

### HTTP-02: headers Dict built with Unit colour and unbalanced tree — **FIXED on master**: buildHeadersTree builds a balanced red-black tree with real colours
Where: `E/http/HttpExports.cpp:281, 295`.
What: the Dict colour slot is Unit and the tree unbalanced.
Impact: `Dict.insert/remove` would pattern-match a non-colour value; reviewer finding.

### HTTP-03: HttpEffectManager unchecked casts
Where: `E/http/HttpEffectManager.cpp:192, 246, 263`.
What: unchecked casts to Record/Tuple2/Custom.
Impact: misread on unexpected values; probably unreachable.

### HTTP-04: HttpEffectManager onEffects resolves a possibly-constant command
Where: `E/http/HttpEffectManager.cpp`, `onEffects`.
What: `resolve(cmdHP)` without a ptr/constant check.
Impact: assert in validating builds on a constant command; reviewer finding.

### HTML-01: HtmlWriter reads node fields without kind/tag checks
Where: `E/virtual-dom/HtmlWriter` `writeHtml` / `str()`.
What: field kinds read unchecked and any non-null object passed to `toStdString` without a string-tag check.
Impact: malformed input misreads memory (contrary to VDOM_005 "total"); unreachable from well-typed Elm.

### FILE-01: dead File accessors use alphabetical slot numbers
Where: `E/file/File.cpp:12-16`.
What: namespace accessors index record slots alphabetically, not by compiler layout.
Impact: wrong fields if ever used; dead code.

### FILE-02: dead File accessors treat void* as Record* without decoding
Where: `E/file/File.cpp:38`.
What: treats `void*` as a raw `Record*` without HPointer decoding.
Impact: bad deref if used; dead code.

### BROWSER-01: Browser stubs return word 0 under NDEBUG
Where: `E/browser/BrowserExports.cpp:28-195`.
What: asserting stubs return word 0 when asserts are off.
Impact: invalid Elm value that later code may dereference; only if Browser APIs are called.

### PLATFORM-01: port registration passes a null name to resolve
Where: `E/core/PlatformExports.cpp` `registerIncomingPort`/`registerOutgoingPort`.
What: a null (word 0) name reaches `resolve`/`toStdString`.
Impact: crash; probably unreachable.

### SYS-01: SystemManager uses resolve results without null checks
Where: `S/System/SystemManager.cpp:230-232, 196-197`, `subMapEval`/`onEffectsEval`.
What: `resolve` results dereferenced without null checks.
Impact: crash on a constant/null value; fragility, unverified.

### HTTPSRV-01: HttpServerManager onEffectsEval unchecked
Where: `S/HttpServer/HttpServerManager.cpp:191-192`.
What: checks neither ctor tag nor a null `resolve`.
Impact: fragility; probably unreachable.

### SYS-02: payloadInt casts unchecked to ElmInt
Where: `S/System/System.cpp`, `payloadInt`.
What: casts `resolve(captured)` to `ElmInt*` unchecked.
Impact: misread if payload is not a boxed Int; probably unreachable.

### SOCK-01: socketAcceptBody re-lookup not null-checked
Where: `S/Socket/Socket.cpp:~507/518`, `socketAcceptBody`.
What: `findListener(id)` re-looked-up after `makeKillHandle` is dereferenced without a null check.
Impact: null deref if the listener vanished meanwhile; reviewer finding.

### STREAM-01: mappedReadResult dereferences p without a null check
Where: `S/Stream/Stream.cpp:898-903`.
What: dereferences `p` relying on `channelDispatch` having validated it.
Impact: crash if that invariant breaks; low likelihood.

### CORE-01: SysWorkPool partial thread start use-after-free
Where: `S/Core/SysWorkPool.cpp:35-37`.
What: on partial thread start failure, detached workers use freed state and a retry creates a second pool.
Impact: UAF / duplicate pool when thread creation fails; rare trigger.

### FD-01: FdChannel closes a possibly reused fd after POLLNVAL
Where: `S/Core/FdChannel.cpp:316-327, 368-371`.
What: after POLLNVAL on an already-closed fd the thread later `::close`s the same number.
Impact: closes an unrelated fd that reused the number; reviewer finding.

### FD-02: closeQuietly retries close on EINTR
Where: `S/Core/SocketUtil.cpp:100`.
What: retries `close()` after EINTR.
Impact: may close a reused fd on non-Linux platforms; Linux is fine.

### SOCK-02: mapIPv4ToIPv6 copies without a length check
Where: `S/Core/SocketUtil` `mapIPv4ToIPv6`.
What: copies address bytes without checking the length.
Impact: possible overread on a short address; unverified.

### FS-01: stale FileHandle accepted after fd reuse
Where: `S/FileSystem/FileSystem.cpp:140, 187`.
What: handle table is keyed by fd number only, so a stale handle matches a later `open` that reused the fd.
Impact: I/O on the wrong file; reviewer finding.

### RESET-04: FileSystem handle table never cleared on reset
Where: `S/FileSystem/FileSystem.cpp`.
What: table not keyed by heap generation and never cleared on heap reset.
Impact: leaked fds and stale entries across resets.

### PROC-02: killJob can signal a reused pid
Where: `S/ChildProcess/ChildProcess` `killJob`.
What: can SIGTERM a pid between WaitService reap and `waitDrain`.
Impact: signals an unrelated process that reused the pid; narrow race.

### TLS-01: TlsTransport copyable while owning SSL*
Where: `S/Tls/TlsTransport`.
What: implicitly copyable class owning a raw `SSL*`.
Impact: double free if ever copied; latent.

### WATCH-01: WatchService implicitly copyable
Where: `S/FileSystem/WatchService`.
What: copy shares `impl_`.
Impact: harmless today (ctor private); latent.

### ABI-02: C++ helpers declared inside extern "C" in ListExports
Where: `E/core/ListExports.cpp:425, 659, 705`.
What: `kernelListMapN`, `listToKindedVectors`, `listFromPermutation` sit inside `extern "C"`; `kernelListMapN` has C linkage with a C++ signature and an unprefixed name.
Impact: symbol-clash/ABI hazard; no observed failure.

### CORE-02: IoHandler::key() non-atomic cross-thread read
Where: `S/Core/IoReactor` `IoHandler::key()`; `S/Socket/Udp` `~UdpHandler`.
What: non-atomic field read from other threads; `~UdpHandler` reads it off the reactor thread.
Impact: data race; reviewer finding.

### TLS-02: ensureTlsInit uses an unsynchronised static flag
Where: `S/Tls/TlsContext.cpp:249`.
What: plain static flag guards OpenSSL init.
Impact: race if two threads init at once; single-thread assumption.

### CORE-03: Runtime statics unsynchronised
Where: `K/Runtime.cpp` statics.
What: plain statics accessed without synchronisation.
Impact: data race only if the single-thread assumption breaks.

### CORE-04: getenv races concurrent setenv
Where: `K/Env.cpp:26`.
What: `getenv` with possible concurrent `setenv`.
Impact: data race if environment is mutated from another thread.

### CORE-05: AsyncSources drain list unsynchronised
Where: `S/Core/AsyncSources.cpp`.
What: drain list is added to inside `call_once` from SysWorkPool/ChannelDrain; the eco-thread-only rule is not enforced.
Impact: data race if called off the eco thread.

### CORE-06: SignalService readFd_ plain int read from any thread
Where: `S/Core/SignalService`.
What: `readFd_` is a plain int while `takeFromPipe` can run on any thread.
Impact: race at first start.

### ABI-03: eco exports not under ECO_KERNEL_GUARD
Where: `K/CrashExports.cpp:9-11` and Crash/Env/Http/NativeDriver/Runtime/MVar/Hash exports.
What: not wrapped in `ECO_KERNEL_GUARD`.
Impact: `bad_alloc` or other exceptions unwind through C linkage.

### ABI-04: filesystem_error thrown outside the guard
Where: `K/File.cpp:279, 363`, `listBody`/`canonicalizeBody`.
What: `std::filesystem` throwing overloads used outside `ECO_KERNEL_GUARD`.
Impact: exception across C boundary on e.g. permission errors; reviewer finding.

### JSON-01: Json.encode throws on invalid UTF-8
Where: `E/json/Json`, `Json.encode`.
What: `json::dump` throws `type_error` on invalid UTF-8 across the C boundary.
Impact: terminate/UB for strings with invalid UTF-8 (e.g. lone surrogates); reviewer finding.

### FILE-03: readStringBody has no size cap
Where: `K/File.cpp:118, 132`, `readStringBody`.
What: >4 GiB size passed to `allocByteBufferBlank` and cast to u32 for `makeUtf8View`.
Impact: truncation/overflow on huge files; rare.

### HTTP-05: zip_stat_index result unchecked
Where: `K/Http.cpp` (orig :224).
What: `zip_stat_index` failure ignored; uninitialised `st.size` used for `resize`/`zip_fread`.
Impact: huge allocation or garbage read on a corrupt archive; reviewer finding.

### TLS-03: fill() ignores BIO_write result
Where: `S/Tls/TlsTransport.cpp:317`, `fill()`.
What: `BIO_write` return value ignored.
Impact: ciphertext silently dropped, session desync; reviewer finding.

## Correctness

### JSON-02: makeErr builds the wrong Error ctor — **FIXED on master**: makeErr is gone; failures are Failure (ctor 3)
Where: `E/json/JsonExports.cpp`, `makeErr`.
What: builds ctor 0 (`Field msg Nil`) where elm/json `Failure` is ctor 3.
Impact: decode errors render as Field errors; reviewer finding.

### JSON-03: DEC_ARRAY picks element kind from the decoder's top ctor — **FIXED on master**: DEC_ARRAY takes the element kind from the decoded value
Where: `E/json/JsonExports.cpp`, `DEC_ARRAY`.
What: element kind chosen from the element decoder's top constructor.
Impact: wrong kind for e.g. `array (field "v" int)`; reviewer finding.

### JSON-04: Json.wrap renders a boxed Char as null
Where: `E/json/Json` generic `Json.wrap`.
What: boxed Char passed through and rendered as null.
Impact: wrong JSON output for Char values; reviewer finding.

### JSON-05: JSON ints above INT64_MAX wrap
Where: `E/json/Json` `jsonToHeap`.
What: integers above INT64_MAX wrap.
Impact: silent wrong values; JS would give a float.

### JSON-06: Decode.int rejects 1.0
Where: `E/json/Json` `jsonToHeap` / `Decode.int`.
What: a float-typed integral value such as `1.0` is rejected (also `Encode.float 1` via `Json.run`).
Impact: divergence from elm/json JS, which accepts it.

### JSON-07: DEC_INDEX/DEC_FIELD errors lack context — **FIXED on master**: DEC_FIELD/DEC_INDEX failures are wrapped in Field/Index
Where: `E/json/Json` error construction.
What: `DEC_INDEX`/`DEC_FIELD` failures carry no Index/Field wrapper.
Impact: less informative error messages than stock.

### JSON-08: oneOf drops alternatives' errors — **FIXED on master**: oneOf collects every alternative's error into OneOf
Where: `E/json/Json` `oneOf`.
What: the OneOf error does not collect every alternative's error.
Impact: error message divergence.

### JSON-09: duplicate keys in Encode.object may resolve differently — **FIXED on master**: repeated keys keep their first position and take the last value, as in JS
Where: `E/json/Json` `Encode.object`.
What: possible first-vs-last divergence for duplicate keys.
Impact: different output from JS; reviewer marked "possible".

### JSON-10: jsToString false for Number/Bool
Where: `E/json/JsonRead.cpp`, `jsToString`.
What: returns false for Number/Bool where JS `String(v)` gives text.
Impact: divergence wherever this is used.

### JSON-11: jsToString Int above 2^53 loses precision
Where: `E/json/JsonRead.cpp`, `jsToString`.
What: large ints lose precision.
Impact: matches JS; probably intended, listed for completeness.

### URL-01: percentEncode escapes !*'()
Where: `E/url/UrlExports.cpp`.
What: escapes `!*'()` which `encodeURIComponent` leaves alone.
Impact: different URLs than elm/url JS.

### URL-02: percentDecode decodes + as space
Where: `E/url/UrlExports.cpp`.
What: `+` decoded as space.
Impact: divergence from `decodeURIComponent`.

### URL-03: percentDecode returns Just on invalid UTF-8
Where: `E/url/UrlExports.cpp`.
What: returns `Just` for sequences that decode to invalid UTF-8.
Impact: JS returns Nothing.

### URL-04: dead percentEncode encodes lone surrogates
Where: `E/url/UrlExports.cpp` namespace `percentEncode` (dead).
What: encodes lone surrogates instead of failing.
Impact: dead code.

### UTILS-02: mixed boxed/unboxed Float comparison uses raw operators
Where: `E/core/Utils.cpp:259-263`.
What: raw `<`/`==` used instead of `compareFloat`.
Impact: NaN ordering differs between paths.

### UTILS-03: compare and == disagree on tuples with one boxed slot
Where: `E/core/Utils.cpp:371, 379, 393` vs `:131-147`.
What: `cmp` orders by kind when one side's slot is boxed, `equal` compares by value.
Impact: `compare` may be non-EQ for `==` values; reviewer finding.

### UTILS-04: boxed constant list element orders above unboxed one
Where: `E/core/Utils.cpp:248`.
What: ordering decided by representation, not value.
Impact: wrong comparison result in mixed lists; reachability unclear.

### UTILS-05: eqHelp assumes equal past depth 100
Where: `E/core/Utils.cpp:561-563`.
What: returns equal when recursion depth exceeds 100.
Impact: deep unequal structures compare equal; reviewer finding.

### UTILS-06: function equality returns false
Where: `E/core/Utils.cpp:727-729`.
What: returns false where elm/core JS throws.
Impact: divergence; maybe intended.

### UTILS-07: empty Bytes constant vs zero-length ByteBuffer unequal
Where: `E/core/Utils` equality.
What: two representations of empty Bytes compare unequal.
Impact: `==` false for equal values; reviewer finding.

### HASH-01: negative seed gives negative narrow hash
Where: `K/Hash.cpp:28`.
What: truncating `%` with a negative seed yields a negative value, breaking [0, 2^26) packing.
Impact: latent; no negative seeds known.

### PARSE-04: isHighSurrogate accepts low surrogates
Where: `E/parser/ParserExports.cpp:166-171`.
What: range check admits low surrogates.
Impact: two lows decode to >= 0x110000; reviewer finding.

### PARSE-05: findSubString with empty target and negative offset
Where: `E/parser/ParserExports.cpp:257-258`.
What: returns a negative index.
Impact: probably unreachable from elm/parser.

### PARSE-06: consumeBase accepts :..@ as digits for base > 10
Where: `E/parser/ParserExports.cpp:305`.
What: digit range check spans the ASCII gap between '9' and 'A'.
Impact: wrong parse of e.g. hex-like input; reviewer finding.

### REGEX-05: Regex.never returns Nothing if compile throws
Where: `E/regex/RegexExports.cpp`, `Regex.never`.
What: a compile failure surfaces as Nothing.
Impact: violates `never` contract; unlikely trigger.

### REGEX-06: regex engine is byte-wise over UTF-8
Where: `E/regex/RegexExports.cpp` (`srell::regex`).
What: `.`, case-insensitivity and classes operate on bytes.
Impact: wrong matches on non-ASCII text vs JS.

### REGEX-07: Match.index counts code points, not UTF-16 units — **FIXED on master**: Utf16Index converts offsets to UTF-16 code units
Where: `E/regex/RegexExports.cpp` match construction.
What: index measured in code points over UTF-8.
Impact: differs from JS for astral characters.

### BYTES-05: byte swaps ignore host endianness
Where: `E/bytes/BytesExports.cpp` read/write paths.
What: swaps conditioned only on requested order.
Impact: wrong on a big-endian host; latent.

### HTTP-06: BadUrl_ string always empty
Where: `E/http/HttpExports.cpp:345-346` (`HttpService.hpp:126`).
What: HttpService fills only token/error, so the URL is never reported.
Impact: empty BadUrl message.

### HTTP-07: bytesToBlob parameter order swapped — **FIXED on master**: parameters are now (mimeType, bytes), and multipart serialisation reads BODY_BLOB
Where: `E/http/HttpExports.cpp:967`, `KernelExports.h:752`.
What: `(bytes, mimeType)` vs stock mime-first.
Impact: nothing reads BODY_BLOB today; known.

### HTTP-08: unresolved request returns Unit and never resumes
Where: `E/http/HttpExports.cpp:742-745`.
What: when record/expect does not resolve, returns Unit.
Impact: Task hangs forever; probably unreachable.

### HTTP-09: HttpEffectManager uses unchecked field literals
Where: `E/http/HttpEffectManager`.
What: `values[6]`, `kReqExpect = 2` duplicated rather than using REQ_* from HttpExports.cpp.
Impact: silent breakage if the record layout changes.

### LIST-06: List.toArray accepts any heap object
Where: `E/core/ListExports.cpp:367-404`.
What: non-list objects yield a 0-length Array.
Impact: masks bugs; unreachable when typed.

### LIST-07: sortBy constant keys all compare equal
Where: `E/core/ListExports` `sortBy`.
What: constant keys treated as null/equal.
Impact: wrong order for constant keys; low risk.

### LIST-08: dead sortWith narrows i64 to int
Where: `E/core/List.cpp:81` (dead).
What: comparison result narrowed to `int`.
Impact: values differing by 2^32 read equal; dead code.

### ARRAY-06: appendN with negative n copies whole source
Where: `E/core/JsArray` `appendN`/`elm_array_append_n`.
What: negative n cast to `uint32_t`.
Impact: copies everything; caller probably never passes negative.

### RUNTIME-01: loadState returns Nothing for a non-Maybe type — **FIXED on master**: loadStateBody returns JSON null when nothing is saved
Where: `K/Runtime.cpp:59-62`.
What: no saved state returns the `Nothing` constant.
Impact: type-confused value if Elm type is not Maybe.

### FILE-04: Task Never wrappers over failing kernels
Where: `K/KernelExports` wrappers; `File.getCwd`/`appDataDir` (`File.cpp:333, 383, 392`), `Runtime.dirname`, `MVar.read/take/put` (`MVar.cpp:129-137`).
What: declared `Task Never` although the kernel can fail ("MVar not found" etc.).
Impact: a failure violates the type; reviewer finding.

### FILE-05: appDataDir fails with a plain String
Where: `K/File.cpp` `appDataDir`.
What: failure value is a raw String with no mapError.
Impact: wrong error type reaches Elm.

### CONSOLE-01: readAllBody drops leading empty lines
Where: `K/Console.cpp` `readAllBody`; `KernelExports.h:210`.
What: `"\n\nx"` becomes `"x"`; documented contract wrong for that input.
Impact: data loss on stdin; reviewer finding.

### FILE-06: touch ignores open failure
Where: `K/File.cpp:436-450`.
What: only the time-set failure is reported.
Impact: misleading error.

### FILE-07: write functions ignore write errors
Where: `K/File.cpp:507, 534, 651`.
What: writeString/writeBytes ignore errors; `hWriteString` does one `write` and ignores short writes.
Impact: silent data loss.

### PROC-03: spawnProcess ignores stdout_/stderr_
Where: `K/Process.cpp:95-106`.
What: 'pipe' request silently inherits.
Impact: caller expecting a pipe gets none.

### FILE-08: readStringBody uses errno after ifstream failure
Where: `K/File.cpp:97-122`.
What: no EIO fallback; errno may be 0.
Impact: error tag built from 0.

### FILE-09: findExecutable matches directories
Where: `K/File.cpp:210` (POSIX).
What: `access(X_OK)` true for directories.
Impact: returns a directory as an executable.

### FILE-10: empty PATH entry tests the name against cwd
Where: `K/File.cpp:234-236`.
What: empty entry treated as current directory.
Impact: POSIX-conventional, but may be unintended; low.

### FILE-11: appDataDir accepts empty HOME on POSIX
Where: `K/File.cpp:378-389`.
What: produces `/.<name>`; Windows rejects the equivalent.
Impact: writes under `/`; platform inconsistency.

### FILE-12: Windows strerror on non-errno codes
Where: `K/File.cpp:270-277`.
What: `strerror(ec.value())` for Win32 codes.
Impact: wrong messages on Windows.

### HTTP-10: archive short read zero-padded
Where: `K/Http.cpp` (orig :236-242).
What: short read logged and zero-padded content returned.
Impact: corrupt file contents; known.

### HTTP-11: getArchive ignores HTTP status
Where: `K/Http.cpp` (orig :153).
What: 404 body fed to libzip.
Impact: confusing archive errors.

### HTTP-12: Windows SHA-1 shim limited to 4 GiB
Where: `K/Http.cpp` (orig :55).
What: hashes only first 0xffffffff bytes.
Impact: wrong hash for huge inputs; rare.

### TIME-05: Windows _timezone ignores DST
Where: `E/time/TimeExports.cpp:89`.
What: no `_tzset`, DST ignored.
Impact: wrong offset on Windows in summer.

### TIME-06: any non-empty TZ becomes a Name
Where: `E/time/TimeExports.cpp:104-110`.
What: POSIX TZ strings like `EST5EDT` treated as zone names.
Impact: wrong zone name reported.

### TIME-07: duplicate intervals with different taggers
Where: `E/time/TimeEffectManager`.
What: last tagger wins, one message per tick.
Impact: divergence from JS which delivers to each.

### DEBUG-01: Debug.todo exits without stderr/eco_crash
Where: `E/core/DebugExports.cpp:69`.
What: writes to a possibly captured stream and calls `exit(1)`.
Impact: message may be lost; reviewer finding.

### ABI-05: Browser_reload takes a C bool
Where: `E/browser/BrowserExports.cpp:34`.
What: contrary to REP_ABI_001 (Bool is `!eco.value`).
Impact: latent; stub asserts.

### DEAD-01: dead namespace APIs divergent from exports
Where: `E/browser/` `Elm::Kernel::Browser`, `E/core/` `Debug::`, `Char::fromCode/toCode`.
What: unused namespace APIs behave differently from the exports.
Impact: trap for future callers; dead.

### PROC-04: ChildProcessManager does not reverse the command list
Where: `S/ChildProcess/ChildProcessManager` `onEffectsEval` (cf. `ChildProcess.elm:593-596`).
What: no reversal unlike Elm/JS `onEffects`.
Impact: batch spawn order differs.

### PROC-05: kill on exited run with open output does nothing
Where: `S/ChildProcess/ChildProcess`.
What: `Process.kill` waits until EOF/timer.
Impact: kill appears ineffective; maybe intended.

### CORE-07: failureFor(RunErr) drops the message
Where: `S/Core/Core.cpp:126`.
What: exception message discarded.
Impact: less useful errors.

### CORE-08: asyncFailure may complete a Task twice
Where: `S/Core/Core.cpp:142`.
What: body may have resumed before throwing.
Impact: double completion; reviewer finding, unconfirmed.

### CORE-09: failureReason does not escape \x1f
Where: `S/Core/Core.cpp:153-164`.
What: origin/code not escaped for the separator.
Impact: corrupt failure-field parsing.

### WS-01: binary body announcement flagged as text
Where: `S/Core/ByteChannel`, `S/WebSocket/WsProtocol.cpp:602`.
What: sets `text` true for tag 4.
Impact: binary messages marked text; reviewer finding.

### CORE-10: Registry insert of a mapped id keeps old entry
Where: `S/Core/Registry.hpp:80-82`.
What: returns the id while keeping the old entry.
Impact: caller believes insert succeeded.

### CORE-11: re-adding a drain keeps the first ready
Where: `S/Core/AsyncSources.cpp:55-57`.
What: silently keeps the first `ready` callback.
Impact: new callback ignored.

### WATCH-02: renamed sub-dir keeps stale relative path
Where: `S/FileSystem/WatchService`.
What: paths not updated after directory rename.
Impact: wrong event paths.

### WATCH-03: directory moved out keeps reporting
Where: `S/FileSystem/WatchService`.
What: watch not dropped when dir leaves the tree.
Impact: spurious events.

### WATCH-04: inotify vs poll disagree on symlinked root
Where: `S/FileSystem/WatchService`.
What: inotify follows a symlinked root while poll `lstat`s it.
Impact: backend-dependent behaviour.

### WATCH-05: poll-mode vanished root events
Where: `S/FileSystem/WatchService` poll mode.
What: one pathless Moved on vanish, every entry Moved on reappearance.
Impact: noisy/confusing events.

### WATCH-06: failed inotify add consumes an id
Where: `S/FileSystem/WatchService`.
What: id allocated before add succeeds.
Impact: id gaps; minor.

### WS-02: abandonMessage drops window under context takeover
Where: `S/WebSocket/WsDeflate.cpp:133`.
What: window discarded even with context takeover.
Impact: later messages decompress wrongly.

### WS-03: deflate stream never reset after failure
Where: `S/WebSocket/WsDeflate`.
What: no reset after a deflate failure.
Impact: subsequent compressions broken.

### WS-04: resetStream drops window on inflateGetDictionary failure
Where: `S/WebSocket/WsDeflate`, `resetStream`.
What: window lost when dictionary fetch fails.
Impact: desync; rare.

### WS-05: setDiscardData mid-message leaves state
Where: `S/WebSocket/WsFrame.cpp:174-180, 265-271, 316-323`.
What: `inMessage_`/`utf8_` left set.
Impact: truncated message or unmatched `onDataEnd`.

### WS-06: setAllowRsv1 without raw mode delivers compressed
Where: `S/WebSocket/WsFrame.cpp` (`WsProtocol.cpp:84-85`).
What: compressed payload passed through.
Impact: unreachable today.

### WS-07: non-positive message limit rejects all messages
Where: `S/WebSocket/WsFrame.cpp:234`, `WebSocket.cpp:449`.
What: `maxMessage = 0`.
Impact: every non-empty message fails with 1009; known.

### STREAM-02: input after flush lost
Where: `S/Stream/StreamCodec.cpp:288-293, 315-318`.
What: Z_BUF_ERROR reported as success.
Impact: silent data loss.

### STREAM-03: concatenated gzip members rejected
Where: `S/Stream/StreamCodec.cpp:142`.
What: stops after first member.
Impact: multi-member gzip fails; maybe intended.

### TLS-04: bad SSL_CERT_FILE disables good SSL_CERT_DIR
Where: `S/Tls/TlsContext.cpp:142-154`.
What: failure in file load aborts dir load.
Impact: TLS verification fails unexpectedly.

### TLS-05: ERR_SSL_NO_CERTIFICATES likely unreachable
Where: `S/Tls/TlsContext.cpp:150`.
What: code path probably never taken.
Impact: dead error path; low.

### TLS-06: ERR_SSL_ prefix on all libraries' errors
Where: `S/Tls/TlsContext.cpp:262`.
What: non-SSL errors labelled ERR_SSL_.
Impact: misleading codes.

### TLS-07: unknown verify modes treated as 0
Where: `S/Tls/TlsContext.cpp:321`.
What: no rejection of unknown modes.
Impact: possibly weaker verification than requested; unverified.

### TLS-08: failed send error overwritten by reads
Where: `S/Tls/TlsTransport`.
What: later reads overwrite the stored error.
Impact: wrong error reported.

### TLS-09: failing flush ends shutdown without SHUT_WR
Where: `S/Tls/TlsTransport`.
What: shutdown path skips `SHUT_WR`.
Impact: peer never sees EOF.

### STREAM-04: pipe failures always report Cancelled
Where: `S/Stream/StreamPipe`.
What: `pipeTo` completes with `Cancelled` even when `src` failed.
Impact: real error lost.

### STREAM-05: createPipe accepts a closing dst
Where: `S/Stream/StreamPipe`.
What: `dst` already Closing/Closed accepted.
Impact: pipe to a dead sink.

### STREAM-06: pipeStreams/pipeThrough succeed for unknown ids
Where: `S/Stream/StreamPipe`.
What: no id validation.
Impact: silent no-op.

### HTTPS-01: HttpStream unknown stream id not rejected
Where: `S/HttpStream/HttpStream`.
What: no validation of stream id.
Impact: silent misbehaviour.

### HTTPS-02: request sent with empty chunked body
Where: `S/HttpStream/HttpStream`.
What: empty body uses chunked encoding.
Impact: some servers may reject; minor.

### HTTPS-03: empty method with body sets CUSTOMREQUEST ""
Where: `S/HttpStream/HttpTransfer.cpp:534`.
What: `CURLOPT_CUSTOMREQUEST ""`.
Impact: malformed request line.

### HTTPS-04: finishTransfer fallback drops response data
Where: `S/HttpStream/HttpTransfer.cpp:551-560, 388`.
What: empty statusText/headers and body dropped.
Impact: response lost on fallback path.

### HTTPS-05: cancel aborts posted transfer but returns false
Where: `S/HttpStream/HttpTransfer.cpp:694, 713-727`.
What: ends streamed body yet reports not cancelled.
Impact: caller state mismatch.

### HTTPS-06: cancel misses created-not-started transfers
Where: `S/HttpStream/HttpTransfer.cpp:713-727`.
What: such transfers not found.
Impact: cancel ineffective.

### HTTPS-07: live map keyed by token
Where: `S/HttpStream/HttpTransfer.cpp`.
What: token collisions; start-failure erase may remove another entry.
Impact: lost transfer tracking; unverified.

### HTTPS-08: empty upload write acked early
Where: `S/HttpStream/HttpTransfer`.
What: acked ahead of pending writes.
Impact: out-of-order acks.

### HTTPS-09: close for bodyKind != 2 answered late
Where: `S/HttpStream/HttpTransfer.cpp:234`.
What: reply delayed.
Impact: latency; minor.

### HTTPS-10: ECANCELED with empty reason
Where: `S/HttpStream/HttpTransfer.cpp:795-797, 823-826`.
What: empty reason string.
Impact: uninformative error.

### HTTPSRV-02: bracketed host accepts any reg-name chars
Where: `S/HttpServer/Http1.cpp:78-83`.
What: no IP-literal validation.
Impact: lax Host parsing.

### HTTPSRV-03: 100 Continue sent to HTTP/1.0
Where: `S/HttpServer/Http1.cpp:212-219`.
What: no version check.
Impact: protocol violation.

### HTTPSRV-04: absolute-form recognised only lower-case
Where: `S/HttpServer/Http1.cpp:334`.
What: case-sensitive scheme prefix.
Impact: `HTTP://` targets mishandled.

### HTTPSRV-05: output-high flag not updated
Where: `S/HttpServer/Http1.cpp:221, 399`.
What: not updated after 100 Continue / error writes.
Impact: backpressure state wrong.

### H2-01: maxConcurrentStreams 0 advertised, no cap
Where: `S/HttpServer/Http2.cpp:357` vs `:318`.
What: SETTINGS 0 sent but no cap enforced.
Impact: inconsistent behaviour.

### H2-02: bindTunnel returns id after head refused
Where: `S/HttpServer/Http2.cpp:923-927`.
What: id returned despite nghttp2 refusal.
Impact: tunnel on a dead stream.

### H2-03: tunnel onReset reported twice
Where: `S/HttpServer/Http2.cpp` `maybeClose`/`fatal`.
What: `onReset(CANCEL)` then `onCloseAll` reports again.
Impact: double notification; known.

### H2-04: tunnelConsume has no tunnel check
Where: `S/HttpServer/Http2.cpp:948`.
What: no check stream is a tunnel.
Impact: misuse on regular streams; unverified.

### HTTPSRV-06: every getaddrinfo failure reported ENOTFOUND
Where: `S/HttpServer/HttpServerService`.
What: error collapsed.
Impact: misleading errors.

### HTTPSRV-07: Win32 message names listenOnHost for listen
Where: `S/HttpServer/HttpServerService`.
What: wrong function name in message.
Impact: cosmetic.

### HTTPSRV-08: socketCloexec failure reported EADDRNOTAVAIL
Where: `S/HttpServer/HttpServerService`.
What: `sockErr` 0 maps to EADDRNOTAVAIL.
Impact: misleading error.

### HTTPSRV-09: EBADF/no-syscall messages
Where: `S/HttpServer/HttpServerService`.
What: messages for these cases are imprecise.
Impact: cosmetic.

### HTTPSRV-10: no subscription hold for server started while subscribed
Where: `S/HttpServer/HttpTables`.
What: hold not taken.
Impact: program may quiesce early.

### HTTPSRV-11: null deliver with hasSubscriber drops request
Where: `S/HttpServer/HttpTables`.
What: takes a hold and drops the request.
Impact: request lost, hold leaked.

### HTTPSRV-12: HttpUpgrade EINVAL message incomplete
Where: `S/HttpServer/HttpUpgrade`.
What: does not cover parked key or ConnGone-erased key.
Impact: misleading message.

### SOCK-03: Conn second write onError
Where: `S/Socket/Conn`.
What: possible after earlier failure when `setInterest` fails.
Impact: duplicate error callback.

### SOCK-04: failed shutdownWrite leaves writeErr_ 0
Where: `S/Socket/Conn`.
What: later `shutdownWrite(done)` reports success.
Impact: masked failure.

### SOCK-05: close hooks never run for early-aborted client
Where: `S/Socket/Conn`.
What: client aborted in Idle/killed before start.
Impact: leaked hooks/resources.

### SOCK-06: drainStep ignores flush errors
Where: `S/Socket/Conn` `drainStep`.
What: `flush()` result ignored.
Impact: silent loss.

### SOCK-07: ListenerClosed posted twice
Where: `S/Socket/Listener.cpp:196-217`.
What: on every `closeNow` outside callback mode (`close()` + `onCloseAll()`).
Impact: duplicate events.

### SOCK-08: finite credit reserved while unlimited
Where: `S/Socket/Listener.cpp:112`.
What: credit reserved at accept in unlimited mode.
Impact: accounting mismatch.

### SOCK-09: ConnChannel close does not check done_
Where: `S/Socket/ConnChannel.cpp:140-145`.
What: double close possible.
Impact: duplicate completion; unverified.

### SOCK-10: socketTablesFaceGone keyed only by connId
Where: `S/Socket/ConnChannel.cpp:176-181`.
What: no generation in key.
Impact: speculative collision.

### SOCK-11: close token parked with null handler
Where: `S/Socket/Socket` `socketCloseListenerBody`.
What: null handler leaves token parked.
Impact: Task hangs.

### SOCK-12: pending connect left if makeKillHandle throws
Where: `S/Socket/Socket` `socketStartConnect`.
What: no cleanup on throw.
Impact: leaked pending entry.

### SOCK-13: reset skips ListenerClosed for closing listener
Where: `S/Socket/SocketTables.cpp:50-53`.
What: not dispatched on reset.
Impact: lost notification.

### WS-08: wsRandomBytes falls back to mt19937_64
Where: `S/WebSocket/WsHandshake.cpp:167-179`.
What: silent non-cryptographic fallback for masking keys.
Impact: weak masking when entropy source fails.

### WS-09: serializeRequest writes target unvalidated
Where: `S/WebSocket/WsHandshake`.
What: CR/LF not rejected.
Impact: header injection unless Elm validates; unverified.

### WS-10: kWatchCap overshoot by one
Where: `S/WebSocket/WsProtocol.cpp:44`.
What: off-by-one in cap.
Impact: minor.

### WS-11: resume path skips default heartbeat timeout
Where: `S/WebSocket/WsProtocol.cpp:685`.
What: immediate deadline at 0.
Impact: premature timeout or none; reviewer finding.

### WS-12: closeFrameWritten ignores err
Where: `S/WebSocket/WsProtocol`.
What: write error ignored.
Impact: masked failure.

### WS-13: ended sets closeWritten_ without a write
Where: `S/WebSocket/WsProtocol`.
What: later `writeClose` succeeds without sending.
Impact: Close never sent.

### WS-14: ping before attach never sent
Where: `S/WebSocket/WsProtocol`.
What: no send, no deadline.
Impact: ping lost.

### WS-15: Close queued before attach has no deadline
Where: `S/WebSocket/WsProtocol`.
What: no timer armed.
Impact: possible hang.

### WS-16: failWith no close deadline, may send second Close
Where: `S/WebSocket/WsProtocol` `failWith`.
What: no deadline; possibly duplicate Close.
Impact: unconfirmed.

### WS-17: checkPause updates interest only on resume
Where: `S/WebSocket/WsProtocol` `checkPause`.
What: `updateInterest` not called on pause.
Impact: unverified.

### WS-18: deliverClose marks delivered before deliver
Where: `S/WebSocket/WsManager.cpp:130, 189-190`.
What: `deliver` can return early after flag set.
Impact: close event lost.

### WS-19: close with no subscriber lost after retire
Where: `S/WebSocket/WsManager.cpp`.
What: entry retires before delivery.
Impact: lost close event.

### WS-20: reject/open trust Elm's role
Where: `S/WebSocket/WebSocket`.
What: ignore `WsHandshakeEntry::server`.
Impact: wrong-role call accepted.

### WS-21: failed open may leave WsEntry
Where: `S/WebSocket/WebSocket`.
What: entry not erased.
Impact: leak.

### WS-22: armTimer drops timer_ on failed add
Where: `S/WebSocket/H2StreamPort.cpp:164-167`.
What: no deadline until retry.
Impact: missed timeout.

### WS-23: cancelClosedWaiter does not release hold
Where: `S/WebSocket/WsTables`.
What: token erased, hold kept.
Impact: program may not exit; kill path unchecked.

### TERM-01: raw-mode failures silent
Where: `S/Terminal/Terminal`.
What: raw-mode entry/read failures not reported.
Impact: silent misbehaviour.

### TERM-02: other SIGINT/SIGTERM listener keeps raw mode
Where: `S/Terminal/Terminal`.
What: raw mode not restored if another listener handles the signal.
Impact: broken terminal.

### TERM-03: raw mode re-entered after survived signal
Where: `S/Terminal/Terminal`.
What: re-entry after signal survival.
Impact: unexpected mode changes.

### TERM-04: no restore on _exit/abort/SIGHUP/SIGQUIT
Where: `S/Terminal/Terminal`.
What: no handler for those paths.
Impact: terminal left raw.

### TERM-05: title filter keeps 0x80-0x9F
Where: `S/Terminal/Terminal`.
What: C1 controls not stripped.
Impact: 0x9C may terminate the title sequence early.

### TERM-06: first setStdInRawMode False saves mode
Where: `S/Terminal/Terminal`.
What: saves mode and registers exit handler needlessly.
Impact: minor.

### FS-02: failed watch never retried
Where: `S/FileSystem/FileSystemManager`.
What: watchId 0 not retried while subscribed.
Impact: no events.

### FS-03: close erases fd before submit
Where: `S/FileSystem/FileSystem` `close`.
What: exception/failure leaves fd untracked.
Impact: fd leak/unusable.

### FS-04: out-of-range result kind succeeds with ()
Where: `S/FileSystem/FileSystem`.
What: no rejection.
Impact: masked bug.

### FS-05: opRemove error_code category unchecked
Where: `S/FileSystem/FileSystemOps` `opRemove`.
What: value used as errno.
Impact: wrong errors.

### SOCK-14: parseScope accepts "0"
Where: `S/Core/SocketUtil.cpp:181-186`.
What: `addr%0` parses unscoped.
Impact: minor.

### CORE-12: ChannelDrain drops results with no dispatcher
Where: `S/Core/ChannelDrain.cpp:109`.
What: tokens never completed.
Impact: Tasks hang.

### WS-24: inflateInit2 failure reported as OOM
Where: `S/WebSocket/WsDeflate.cpp:137-139`.
What: all failures "out of memory".
Impact: misleading message.

### CORE-13: negative quiesce timeout waits 0 ms
Where: `S/Core/IoReactor`.
What: negative treated as 0.
Impact: maybe intended.

### TLS-10: stage-2 entry kept until generation change
Where: `S/Tls/Tls`.
What: killed between stages leaves entry.
Impact: bounded leak.

## Robustness

### IO-01: write loops spin on 0-byte writes
Where: `K/Console.cpp` writeBody; `K/File.cpp:577-585`; `S/FileSystem/FileSystemOps.cpp:130-146`.
What: loop forever if write returns 0.
Impact: hang; rare.

### CONSOLE-02: log ignores write result
Where: `K/Console.cpp` `log`.
What: short write/EINTR/error ignored.
Impact: lost trace.

### CONSOLE-03: Windows tag >0x7fffffff truncated
Where: `K/Console.cpp` `log`.
What: tag truncated.
Impact: minor.

### CONSOLE-04: readLine/readAll block
Where: `K/Console.cpp:105`.
What: blocking reads.
Impact: event loop stall.

### TIME-08: non-finite intervals reach TimerService
Where: `E/time/TimeEffectManager.cpp:132`, `E/core/ProcessExports` `millis`.
What: infinite/NaN/huge values passed despite `TimerService.hpp:45`.
Impact: precondition violation.

### TIME-09: zero/negative intervals busy-loop
Where: `E/time/TimeEffectManager.cpp:132`, `E/core/ProcessExports` `millis`.
What: no lower clamp.
Impact: CPU spin.

### ZLIB-01: uInt casts truncate >4 GiB input
Where: `S/WebSocket/WsDeflate.cpp:49`, `S/Stream/StreamCodec.cpp:114, 138`.
What: silent truncation.
Impact: data corruption on huge chunks.

### CORE-14: backendInit partial failure leaks fds
Where: `S/Core/IoReactor.cpp` `backendInit`.
What: `pollFd`/`wakeFd` leaked.
Impact: minor leak.

### CORE-15: IoReactor ctor errno read after return
Where: `S/Core/IoReactor.cpp`.
What: errno may be clobbered.
Impact: cosmetic, disputed.

### CORE-16: stale epoll entry after dup fd closed
Where: `S/Core/IoReactor`.
What: level-triggered entry remains.
Impact: busy spin.

### FD-03: PIPE_BUF write can block
Where: `S/Core/FdChannel.cpp:220`.
What: blocking sockets/ttys.
Impact: thread stall.

### FD-04: makeCloexecPipe leaves fds untouched on failure
Where: `S/Core/FdChannel.cpp:136-158`.
What: fds uninitialised on `pipe2` failure.
Impact: garbage fds used.

### FD-05: fd >= FD_SETSIZE gets misleading EBADF
Where: `S/Core/FdChannel`.
What: misleading error.
Impact: cosmetic.

### SIG-01: SignalService reader exits on poll error
Where: `S/Core/SignalService.cpp:62-66`.
What: thread exits; loop no longer woken.
Impact: signals lost.

### SIG-02: sigtimedwait on unblocked signals
Where: `S/Core/SignalService.cpp:166`.
What: relies on Linux behaviour.
Impact: non-portable.

### SIG-03: addListener push_back throw leaks subscription
Where: `S/Core/SignalService` `addListener`.
What: no rollback.
Impact: leak on bad_alloc.

### SIG-04: chainToPrevious window runs old disposition
Where: `S/Core/SignalService`.
What: race window.
Impact: rare.

### CORE-17: callClosure1 exception escapes poolDrain
Where: `S/Core/SysWorkPool.cpp:130`.
What: skips `Scheduler::drain`.
Impact: stalled tasks.

### CORE-18: PoolResult::of throwing in catch -> terminate
Where: `S/Core/SysWorkPool.cpp:90, 92`.
What: throw in worker catch handler.
Impact: `std::terminate`.

### WATCH-07: IN_Q_OVERFLOW dropped silently
Where: `S/FileSystem/WatchService`.
What: overflow not reported.
Impact: lost events.

### WATCH-08: files in new sub-dir before watch added missed
Where: `S/FileSystem/WatchService`.
What: race before watch add.
Impact: missing events.

### REGEX-08: regexTable never freed
Where: `E/regex/RegexExports.cpp` `regexTable`.
What: compiled regexes leaked.
Impact: memory growth.

### PROC-06: exception after parkResume leaks job hold
Where: `S/ChildProcess/ChildProcess`.
What: before `WaitService::submit`.
Impact: program may not exit.

### PROC-07: Windows startCollector leaks pipe read ends
Where: `S/ChildProcess/Spawn.cpp:366`.
What: read ends leaked.
Impact: chatty child may block.

### PROC-08: Process.wait not cancellable
Where: `K/Process.cpp` `wait`.
What: no cancellation.
Impact: hang on kill.

### RESET-05: FileSystemManager reset without stopWatch
Where: `S/FileSystem/FileSystemManager`.
What: Registry cleared without stopping watches.
Impact: leaked holds; program may never exit; duplicate watches.

### STREAM-07: maybeErase never erases some pairs
Where: `S/Stream/Stream.cpp:233-252`.
What: Errored, terminated, unreachable open pairs kept.
Impact: unbounded growth.

### STREAM-08: streamUncountedToken unbounded
Where: `S/Stream/Stream.cpp:153`.
What: nothing keeps it below 2^62 (resume tokens 2^61).
Impact: theoretical overflow.

### STREAM-09: withdrawnReads entries never removed
Where: `S/Stream/Stream.cpp`.
What: entries whose result never arrives stay.
Impact: leak.

### STREAM-10: mapped-sink value lost
Where: `S/Stream/StreamPipe.cpp:228-232`.
What: lost if `streamMapForSink` throws or `dst` leaves Open.
Impact: data loss.

### SYS-03: stdioIds caches failed 0
Where: `S/System/System.cpp` `stdioIds`.
What: later calls re-create and pin pairs.
Impact: leak.

### FS-06: fsComplete leaks FdChannel on throw
Where: `S/FileSystem/FileSystem.cpp` `fsComplete`.
What: `new FdChannel` leaked with fd.
Impact: fd leak.

### RESET-06: SocketTables reset keeps holds
Where: `S/Socket/SocketTables.cpp:39-59` `resetTables`.
What: close-token, pending-connect holds not released.
Impact: program cannot quiesce (Scheduler has no reset).

### RESET-07: HttpTables reset keeps holds
Where: `S/HttpServer/HttpTables`.
What: respond/closeServer holds not released.
Impact: same.

### RESET-08: Udp reset keeps in-flight OpDone holds
Where: `S/Socket/Udp`.
What: holds not released.
Impact: same.

### RESET-09: WsTables reset keeps holds
Where: `S/WebSocket/WsTables.cpp:58-61`.
What: `closeHold`/`closedWaiters`/cancelled-dial holds.
Impact: same.

### RESET-10: WsManager aux() reset keeps subscription holds
Where: `S/WebSocket/WsManager.cpp:96-101`.
What: subscription holds not released.
Impact: same.

### SOCK-15: Udp handler refused by reactor never reads
Where: `S/Socket/Udp`.
What: parked receives wait forever.
Impact: hang.

### WS-25: WsBodyChannel has no destructor
Where: `S/WebSocket/WsChannel.cpp:139-141`.
What: never calls `bodyCancel`.
Impact: unverified leak.

### HEAP-05: stack root range not restored on exception
Where: `S/Terminal/TerminalManager` `onWinch`, `S/FileSystem/FileSystemManager` `deliver`.
What: no RAII restore.
Impact: bounded by reportFatal.

### HTTPSRV-13: no idle timer when timeouts <= 0
Where: `S/HttpServer/Http1.cpp:31, 271, 438`.
What: disabled timers.
Impact: maybe intended.

### HTTPSRV-14: strerror on worker thread
Where: `S/HttpServer/HttpServerService`.
What: against `Core.hpp:119-121`.
Impact: thread-safety.

### HTTPSRV-15: pool lambda keeps cert/key
Where: `S/HttpServer/HttpServer`.
What: `spec` destroyed on worker.
Impact: secret lifetime.

### HTTPSRV-16: taggers[serverId] inserts empty vector
Where: `S/HttpServer/HttpServerManager` `deliver`.
What: operator[] inserts.
Impact: harmless.

### RESET-11: listener/g_quiescenceRegistered survive reset
Where: `S/Terminal/TerminalManager`, `S/System/SystemManager`.
What: state survives with empty tables.
Impact: harmless.

### CORE-19: throwing listener skips rest of pass
Where: `S/Core/SignalService`, `S/Socket/SocketEvents`.
What: before reportFatal.
Impact: harmless.

### CRASH-01: ::exit(1) with live threads
Where: `K/Crash`.
What: exit handlers run while threads live.
Impact: possible shutdown races.

### SOCK-16: Conn onCloseAll calls closeNow again
Where: `S/Socket/Conn`.
What: after abort when `key() != 0`.
Impact: harmless.

### WS-26: Http2Client dtor resets stream again
Where: `S/WebSocket/Http2Client` (`H2StreamPort.cpp:94`).
What: `port_` never cleared.
Impact: harmless.

### SYNC-01: GC JSON key list hand-synced
Where: `K/GC.cpp:26-47` vs `Eco/GC.elm`.
What: nothing checks agreement.
Impact: drift.

### SYNC-02: ECO_KLOG defined three times
Where: `E/KernelDebug.hpp`, `K/KernelDebug.hpp`, `runtime/src/platform/HttpService.cpp:14`.
What: no agreement check.
Impact: drift.

### SYNC-03: kKinds = 9 unchecked
Where: `S/WebSocket/WsEvents.hpp`.
What: not checked against `Kind`.
Impact: drift.

### HTTPS-11: pipeStreams result discarded
Where: `S/HttpStream/HttpStream`.
What: `(void)` cast.
Impact: cannot fail for fresh sink.

## Dead code & cleanups

### DEAD-02: unused <cstdio>
Where: `E/ExportHelpers.hpp:22`.
What: include unused.
Impact: cleanup.

### DEAD-03: unused/dead Scheduler.hpp and Platform.hpp
Where: `E/core/Scheduler.hpp`, `E/core/Platform.hpp`.
What: included by nothing.
Impact: cleanup only; from review report group D.

### DEAD-04: DebugExports value_bits unused
Where: `E/core/DebugExports.cpp:51`.
What: `value_bits` unused.
Impact: cleanup only; from review report group D.

### DEAD-05: DebugExports calls exit without <cstdlib>
Where: `E/core/DebugExports.cpp`.
What: relies on a transitive include.
Impact: cleanup only; from review report group D.

### DEAD-06: Char.cpp <stdexcept> unused
Where: `E/core/Char.cpp`.
What: include unused.
Impact: cleanup only; from review report group D.

### DEAD-07: dead isNil(wrap(a)) in append
Where: `E/core/Utils.cpp:855-856`.
What: dead check.
Impact: cleanup only; from review report group D.

### DEAD-08: String foldl/foldr unused
Where: `E/core/String.cpp`.
What: no callers (see STRING-01/02).
Impact: cleanup only; from review report group D.

### DEAD-09: consCellChar unused
Where: `E/core/String.cpp`.
What: helper unused.
Impact: cleanup only; from review report group D.

### DEAD-10: words ranges.empty() unreachable
Where: `E/core/String.cpp` `words`.
What: branch unreachable.
Impact: cleanup only; from review report group D.

### DEAD-11: static_assert(true) checks nothing
Where: `E/core/ListExports.cpp:427`.
What: vacuous assertion.
Impact: cleanup only; from review report group D.

### DEAD-12: dead List.cpp helpers
Where: `E/core/List.cpp:111, 124`, `sortBy`/`sortWith`/`fromArray`.
What: `listToVector`, `getConsHead` and the sorts are dead.
Impact: cleanup only; from review report group D.

### DEAD-13: makeEncoder2_pi rooting asymmetric
Where: `E/bytes/BytesExports.cpp` `makeEncoder2_pi` vs `_pf`.
What: copies `values[1]` from unrooted Int slot; harmless.
Impact: cleanup only; from review report group D.

### DEAD-14: namespace read_bytes no negative-length check
Where: `E/bytes/BytesExports.cpp` `read_bytes`.
What: unused function.
Impact: cleanup only; from review report group D.

### DEAD-15: Json makeDecoder1i, jsonValueCtor unused
Where: `E/json/`.
What: dead helpers.
Impact: cleanup only; from review report group D.

### DEAD-16: File and Browser namespace APIs unused
Where: `E/file/File.cpp`, `E/browser/`.
What: dead APIs.
Impact: cleanup only; from review report group D.

### DEAD-17: s_streamHandles written never read
Where: `K/Process.cpp:105-106`.
What: dead state.
Impact: cleanup only; from review report group D.

### DEAD-18: redundant POST assignments
Where: `K/Http.cpp` (orig :380-383).
What: duplicate setopt.
Impact: cleanup only; from review report group D.

### DEAD-19: Runtime scanner unnamed
Where: `K/Runtime.cpp`.
What: registered as "unnamed".
Impact: cleanup only; from review report group D.

### DEAD-20: TaskEffectManager duplicates encodeHP/decodeHP
Where: `E/core/TaskEffectManager.cpp`.
What: local copies of ExportHelpers.
Impact: cleanup only; from review report group D.

### DEAD-21: HttpEffectManager onSelfMsg double-roots
Where: `E/http/HttpEffectManager.cpp` `onSelfMsg`.
What: router/progress rooted twice.
Impact: cleanup only; from review report group D.

### DEAD-22: kEndedMarker unused, literal hard-coded
Where: `S/Core/Core.hpp`; `S/Stream/Stream.cpp:63-64`, `StreamPipe.cpp:59`.
What: `"\x02"` hard-coded.
Impact: cleanup only; from review report group D.

### DEAD-23: describeErrno unused
Where: `S/Stream/Stream.cpp:91-95`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-24: Conn isTls never read
Where: `S/Socket/Conn`.
What: dead field.
Impact: cleanup only; from review report group D.

### DEAD-25: hasBufferedRead never called
Where: `S/Tls/TlsTransport`.
What: dead method.
Impact: cleanup only; from review report group D.

### DEAD-26: Listener openConnections no caller
Where: `S/Socket/Listener`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-27: SocketTables resumeToken unused
Where: `S/Socket/SocketTables.cpp:63`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-28: Socket.cpp carries plan citations
Where: `S/Socket/Socket.cpp:518`.
What: G11/§3.4 citations in comments.
Impact: cleanup only; from review report group D.

### DEAD-29: socketNotImplementedTask/socketDoneTask unused
Where: `S/Socket/Socket.cpp`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-30: SocketManager mask constants unused
Where: `S/Socket/SocketManager`; `SocketTables.cpp:280, 295, 299`.
What: four constants unused while literals used.
Impact: cleanup only; from review report group D.

### DEAD-31: UdpManager masks unused
Where: `S/Socket/UdpManager`; `Udp.cpp:417-418`.
What: `DGRAM_T_MASK`/`DGRAM_FROM_MASK` unused, literals used.
Impact: cleanup only; from review report group D.

### DEAD-32: SPEC_TRIPLE_MASK unused
Where: `S/ChildProcess/ChildProcessManager`.
What: dead constant.
Impact: cleanup only; from review report group D.

### DEAD-33: Windows reportFatal message ends "yet"
Where: `S/ChildProcess/ChildProcessManager`.
What: truncated wording.
Impact: cleanup only; from review report group D.

### DEAD-34: WsHandshake headDone ok/err unused
Where: `S/WebSocket/WsHandshake`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-35: WsHandshakeEntry::server never read
Where: `S/WebSocket/WsTables`.
What: dead field (cf. WS-20).
Impact: cleanup only; from review report group D.

### DEAD-36: onClosed resumed unused
Where: `S/WebSocket/WsTables.cpp:208, 226`.
What: dead variable.
Impact: cleanup only; from review report group D.

### DEAD-37: Http2Client closeCode_ never read
Where: `S/WebSocket/Http2Client`.
What: dead field.
Impact: cleanup only; from review report group D.

### DEAD-38: Phase::Done DATA appended to held_
Where: `S/WebSocket/Http2Client`.
What: buffered data unused.
Impact: cleanup only; from review report group D.

### DEAD-39: kDefaultDrainMs duplicates WsCore::kDrainMs
Where: `S/WebSocket/H2StreamPort`.
What: duplicate constant.
Impact: cleanup only; from review report group D.

### DEAD-40: wsNotImplementedBody dead
Where: `S/WebSocket/WebSocket`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-41: httpServerNotImplementedBody dead
Where: `S/HttpServer/HttpServer`.
What: dead.
Impact: cleanup only; from review report group D.

### DEAD-42: KillHandle.cpp plan citations
Where: `S/Core/KillHandle.cpp`.
What: plan citations in comments.
Impact: cleanup only; from review report group D.

### DEAD-43: writeFaceShutdown branch unreachable
Where: `S/Socket/FaceProtocol`.
What: defensive branch.
Impact: cleanup only; from review report group D.

### DEAD-44: CTOR_TIME_EVERY defined twice
Where: `E/time/`.
What: duplicate definition.
Impact: cleanup only; from review report group D.

### DEAD-45: 0xFFFD shared by CONSTANT_TAG and CTOR_Router
Where: `E/core/Utils` (runtime owner).
What: value collision.
Impact: cleanup only; from review report group D.
