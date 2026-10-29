# Suspected C++ code issues from the runtime re-commenting pass

These findings were logged during a comments-only re-commenting pass over `runtime/src`. They come from `stages/03-comment/output/commenting-log.md` and `stages/04-review/output/review-notes.md` (plus the project map) under `icm-agents/workspaces/cpp-doc-comments/`. None of them has been fixed. Line numbers are as of 2026-10-29. Each verdict is a triage call, not proof: likely-bug, possible, cleanup, not-a-bug or already-fixed. "Checked in code" means an extractor or this merge read the current code. Duplicates across the five extract files are merged, and reviewer disputes are folded into the matching entry.

## Summary

| verdict | high | medium | low | - | total |
|---|---|---|---|---|---|
| likely-bug | 4 | 5 | 15 | - | 24 |
| possible | 9 | 22 | 67 | - | 98 |
| cleanup | - | - | - | 38 | 38 |
| not-a-bug | - | - | - | 16 | 16 |
| already-fixed | - | - | - | 1 | 1 |

## High severity

### Likely bugs

### eco_list_pos_view classified as gc-leaf but allocates
- where: `runtime/src/codegen/Passes/EcoMarkerFacts.h:62 (isCursorMarker)`; runtime side `runtime/src/allocator/RuntimeExports.cpp:4119 (eco_list_pos_view)`
- verdict: likely-bug (checked in code; author and reviewer agree)
- severity: high
- `isCursorMarker` includes `eco_list_pos_view`, so capacity hoisting, gc-free propagation and BF mayCollect (BFToLLVM.cpp:318 leafCallee) all treat it as unable to collect. When idx > 0 it calls `alloc::consChunkView`, which allocates through `eco_alloc_with_roots` and can collect. A capacity-hoisted region with pre-reserved unchecked bumps, a gc-free-stamped caller, or a BF buffer that is live across the call is then wrong after a GC.

### FoldExtractValue: UndefValue::get(nullptr) sentinel dereferences null
- where: `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp:349 (FoldExtractValuePass::traceMatchingInsert)`
- verdict: likely-bug (checked in code; reviewers confirmed)
- severity: high
- `UndefValue::get(Type*)` calls `Ty->getContext()`, so a null type crashes before `run` can replace the sentinel. The compiler crashes on any `extractvalue` whose insertvalue chain ends at undef or poison without the wanted field. The fix is `UndefValue::get(EV->getType())` or a distinct sentinel.

### String slice copies from a movable nursery string across an allocation
- where: `runtime/src/allocator/StringOps.cpp:324,344 (slice -> tinyFromU16 -> alloc::allocString)`
- verdict: likely-bug (the code now carries a "Known defect" comment)
- severity: high
- For a short slice of a Tag_String, or a StringSlice over a UTF-16 leaf, `p` points into the nursery object. If the range is non-ASCII, longer than 512 units, or UTF-8 is off, `allocString` allocates first, which can run a minor GC that moves the source, and then memcpys from the stale `p`. The result holds garbage, and the source `str` is not rooted either.

### evacuateJitPtr promotion skips promoteLargeHeader and the colour reset
- where: `runtime/src/allocator/NurserySpace.cpp:1337 (NurserySpace::evacuateJitPtr)`
- verdict: likely-bug (checked in code; reviewer re-emphasised it)
- severity: high
- When a JIT global root points at a from-space LargeStringHeader or LargeByteHeader at promotion age, the header is copied to old gen but its body stays nursery-owned, because only `evacuate` (cpp:1252-1258) calls `oldgen.promoteLargeHeader`. The minor sweep can then free a body that the promoted header still uses. The copy's colour is also not reset to white, and evacuateListSpine has the same colour gap.

### Possible

### FoldExtractValue may use a freed queued extractvalue
- where: `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp:383-400 (FoldExtractValuePass::run)`
- verdict: possible (checked in code)
- severity: high
- `work` holds raw `ExtractValueInst*`. `RecursivelyDeleteTriviallyDeadInstructions(originalAgg)` can delete a queued extract that fed only the dead chain, for example with nested aggregates or a dominating block that comes later in layout order. The loop then dereferences freed memory. Using WeakTrackingVH, as the second loop already does, fixes it.

### FoldExtractValue skips prefix-index inserts and reads the wrong field
- where: `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp:342-346 (traceMatchingInsert)`
- verdict: possible (checked in code)
- severity: high
- An `insertvalue` at [0] that writes a whole sub-aggregate is passed over when looking for [0,1], because only exact index equality is tested. The fold then returns an older value from further down the chain, which is a silent miscompile once nested-aggregate inserts reach this pass.

### Closure eval layout labels new args PK_Boxed but primitives are stored raw
- where: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:2677-2694 (PapExtendOpLowering::matchAndRewrite)`, ~2853; vs `emitInlineClosureCall` ~2360-2375
- verdict: possible (checked in code; a code comment admits the mismatch)
- severity: high
- For papExtend with `_capture_abi` but no `_fast_evaluator`, the layout is the capture kinds followed by one PK_Boxed per new argument, but primitive new args are stored raw and the call passes only the new-argument count. A GC or the runtime reading that layout would treat raw Int/Float bits as pointers, or read capture kinds as new-arg kinds. `preMaterializeApplyLayouts` mints the same layout. The runtime consumer has not been traced.

### Two-alternative `str` case lowered by constructor tag
- where: `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp:228-313 (CaseToScfIfPattern)`
- verdict: possible (checked in code: the `isStringCase` guard that the >2-alternative pattern has at :416 is absent here)
- severity: high
- A two-alternative yield-form `str` case outside scf or a joinpoint reaches the final `else` branch, which compares `eco.get_tag` of the string with `tags[1]`, so it picks the wrong alternative. It is unknown whether the front end emits this shape, and E2E would probably have caught it if it were common.

### JoinpointToScfWhile assumes an !eco.value scrutinee and drops returns
- where: `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp:1006-1142 (JoinpointToScfWhilePattern)`
- verdict: possible
- severity: high
- The pattern calls GetTagOp whatever the case_kind. It drops entry-block ops before the case, continuation ops after the first jump, and the exit `eco.return` operands, and its own comment admits valued returns are unhandled. With more than two alternatives it loops on any non-exit tag. It is a miscompile if JoinpointNormalization ever lets a non-conforming joinpoint through.

### eco_apply_closure_eval roots no args when args_layout is null
- where: `runtime/src/allocator/RuntimeExports.cpp:2188 (eco_apply_closure_eval)`
- verdict: possible (checked in code)
- severity: high
- Arguments are rooted only `if (args_layout)`. On an over-applied call with a null layout, trailing boxed args in `typed_args` stay unrooted while the first stage's evaluator runs and may collect, so any nursery arg is stale afterwards. This is safe only if codegen never passes a null layout together with boxed args.

### make.closure keeps an env aggregate with GC pointers live across the allocation
- where: `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp:818-889 (make.closure lowering)`
- verdict: possible
- severity: high
- `envAgg` is an LLVM struct that can hold `ptr addrspace(1)` captures, and on the out-of-line path its fields are extracted only after `emitAllocWithSafepoint`. RS4GC does not relocate first-class aggregates, so this is correct only if FoldExtractValue or SROA scalarizes it first. The only check, FcaScan, runs under `ECO_FCA_SCAN` only. If the struct is not scalarized, a boxed capture is stale after a GC.

### __eco_init_globals runs before the JIT stack map is parsed
- where: `runtime/src/codegen/ecoc.cpp:417-441 (JIT run path)`; also `runtime/src/codegen/EcoRunner.cpp:255-271 (executeJIT)`
- verdict: possible (checked in code: the init call precedes `globalStackMap().parse` in both files)
- severity: high
- If global initialisation allocates enough to trigger a GC, the collector walks JIT frames that have no stack-map records yet. Their roots are neither found nor relocated.

### OldGen forget-block loop recycles large-body ids the nursery list may still name
- where: `runtime/src/allocator/OldGenSpace.cpp:~6028 (forget-block loop, nursery_owned_bodies_)`
- verdict: possible
- severity: high
- Kind-0/1 ids are recycled directly. If such an id is still in `nursery_owned_bodies_` and `registerLargeBody` reuses it before the next minor sweep, the stale entry names the new body, and the sweep can free a live body.

## Allocator / GC

### Likely bugs

### Allocator::reset drops page_work_ before validating the new config
- where: `runtime/src/allocator/Allocator.cpp:1082-1088 (Allocator::reset)`
- verdict: likely-bug (checked in code)
- severity: low
- `page_work_.reset()` runs before `resolveNurseryRegions()` and `validate()`, which can throw. A rejected config leaves the allocator in mode 1 or 2 with no PageWork until the next reset.

### UB shift in the ECO_GC_DEBUG stack-range print
- where: `runtime/src/allocator/ThreadLocalHeap.cpp:1427 (majorGC debug print)`
- verdict: likely-bug (checked in code)
- severity: low
- `1ULL << j` with j up to `range.count` is undefined for j >= 64, which happens when a root range has more than 64 slots. This is a diagnostics-only path.

### Possible

### Windows unwinder: a leaf frame ends the root walk
- where: `runtime/src/allocator/StackUnwind.cpp:105-111,141-144 (step)`
- verdict: possible
- severity: medium
- Win64 `step` stops at a frame with no RUNTIME_FUNCTION instead of popping the return address from Rsp, as Windows does for leaf frames, and the `RtlVirtualUnwind` outcome is ignored. A leaf frame on the path cuts the GC root walk short, so JIT roots above it are missed. Callers cannot tell an unwind failure from the end of the stack, and the arm64 DWARF identity register map has no `#if` guard.

### BlockTable credits stale live counts to recycled ids
- where: `runtime/src/allocator/BlockTable.hpp (LiveBytesAccumulator::mergeInto/sum, storageBase, posOf/swapRemove)`
- verdict: possible
- severity: medium
- A count left on an id released before the merge is credited to that id's next incarnation. The snapshot-cycle rule (no release during a cycle) probably excludes this, but nothing checks it. `storageBase` accepts negative k, and the order ops silently corrupt on a non-live id.

### RootedSlots push writes through a possibly dead record
- where: `runtime/src/allocator/RootedSlots.hpp (push)`
- verdict: possible
- severity: medium
- `push` patches `rec_` without checking that the record is still live. If LIFO scoping is broken and the range stack has been restored below it, the write corrupts a different root record. `RootedElems::push` also treats any kind above 3 as unboxed.

### NurserySpace destructor relies on tenureTeardown without asserting
- where: `runtime/src/allocator/NurserySpace.cpp:112-121 (~NurserySpace)`
- verdict: possible
- severity: medium
- If an owner skips tenureTeardown, `rg_.reset()` destroys a GCBackgroundGang that may still be running, which can crash or hang at heap destruction.

### Release-build OOM paths return or dereference null
- where: `runtime/src/allocator/ThreadLocalHeap.cpp:336 (eco_alloc_inline_slow), ~476 (allocLargeString), allocate*, allocatePermanent, ensureNursery`
- verdict: possible
- severity: medium
- Out-of-memory is handled only by assert. With NDEBUG (release preset), allocateYoungLarge charges debt and returns null, allocLargeString dereferences it, and eco_alloc_inline_slow callers dereference null. The result is a crash instead of a clean OOM abort.

### GCGang goIdle borrows from the epoch bits if called uncounted
- where: `runtime/src/allocator/ GC gang (goIdle)`
- verdict: possible
- severity: medium
- `goIdle` is a plain fetch_sub. A participant that is not in the count (for example an Assist run with joined=false) borrows from the epoch bits, and on a done word with count 0 it clears kDone. Only the calling contract prevents this.

### StackMap parsing trusts blob bounds via assert only
- where: `runtime/src/allocator/StackMap.cpp:150-225 (StackMap::parse)`
- verdict: possible
- severity: low
- A truncated or corrupt stack-map section reads past `data+size` in NDEBUG builds. The input is compiler-produced, so this needs a corrupt binary.

### TenureWork scanYlos skips the young-elsewhere check
- where: `runtime/src/allocator/TenureWork.hpp:614 (scanYlos)`
- verdict: possible
- severity: low
- Unlike childOfCopy and markTarget, a YLOS child that is young outside the tenuring extent is not reported through `abortYoungChild`. If the invariant is ever broken, that child dangles silently instead of aborting.

### HeapConfigJson numeric parsing overflows
- where: `runtime/src/allocator/HeapConfigJson.cpp:42-49,67,101,141,304-307,519,626`
- verdict: possible
- severity: low
- `std::stoull` throws `out_of_range` on over-long digit strings, and callers catch only `invalid_argument`. `magnitude*multiplier` wraps silently, so "20000000000000000000K" gives a small size. `jitter_us` is reset to 0 when unset, unlike the other variables, and ECO_TENURE_COLLECTORS accepts "+" and whitespace.

### Allocator accounting and trace errors
- where: `runtime/src/allocator/Allocator.cpp (growNurserySliceSet, acquireOldGenRegion, out-of-space path)`
- verdict: possible
- severity: low
- In region mode all commits count as "low" nursery bytes. `acquireOldGenRegion` does not bump `page_supply_.fresh_bytes`, and `dumpHeapState` on out-of-space ignores `heapTraceEnabled()`. These are stats and trace errors only.

### PageWork epoch wrap, null commit, stall misattribution
- where: `runtime/src/allocator/PageWork.cpp (syncPoint, topUpWindow, drainAll, onReuse)`
- verdict: possible
- severity: low
- In `syncPoint`, `epoch - recorded` wraps if epoch is lower, which ages every extent at once. `topUpWindow` calls `ops_.commit` without a null check, so a PageOps with populate but no commit crashes. Stall and reuse stats are misattributed.

### P1Census diagnostics: fork child checks parent tables, unlocked setters
- where: `runtime/src/allocator/P1Census.cpp (verifyOldGen, onMinorStart, forget, setMode, noteWrite)`
- verdict: possible
- severity: low
- In mode 2 a forked child can verify tables inherited from the parent and abort. setMode and the builder-path `w_calls++` are unlocked, and noteWrite from a heap-less thread miscounts. This affects census builds only.

### PermanentSpace resolves non-heap static words
- where: `runtime/src/allocator/PermanentSpace.cpp:110, ~139, ~177`
- verdict: possible
- severity: low
- `alloc.resolve` is called on static words that may be embedded constants or null, which trips Allocator::resolve's asserts under ECO_HEAP_VALIDATE. Release builds fall harmlessly into the values_constant branch. `used + bytes` overflow is unchecked.

### LargeObjectSpace bin and alignment waste
- where: `runtime/src/allocator/LargeObjectSpace.cpp:~131-138`
- verdict: possible
- severity: low
- An aligned request can miss every bin even though a suitable run exists, so a new block is grown (memory overhead only). Bin 11 is never used, and `heads_` is uninitialised before init.

### selectEvacuationSet reads the pin bit of a possibly header-less first cell
- where: `runtime/src/allocator/OldGenSpace.cpp:6363-6367 (selectEvacuationSet)`
- verdict: possible (a reviewer rated it medium; kept low because evacuateSlice re-checks pins per object)
- severity: low
- In bitmap mode a one-class block's first cell may be free with no valid header, so `first_hdr->pin` reads stale bits. The worst case is a wrong evacuation-candidate decision, which costs fragmentation only.

### OldGen fragmentation stats under-count
- where: `runtime/src/allocator/OldGenSpace.cpp (splitter, free_list_sentinel_count_)`
- verdict: possible
- severity: low
- Sentinel cells left by the splitter remainder are not counted in garbage_bytes, so `frag_stats_.total_free_bytes` is low. This is a stats error only.

### OldGen initialize continues with an empty bag if acquireOldGenRegion fails
- where: `runtime/src/allocator/OldGenSpace.cpp:~360 (initialize)`
- verdict: possible
- severity: low
- The metadata path aborts on failure, but the bag path continues silently, so the heap later fails somewhere less obvious.

### roleOf treats the stale builder area as a live role
- where: `runtime/src/allocator/NurseryRegion.cpp (roleOf; TV7 check ~308-325)`
- verdict: possible
- severity: low
- A stray pointer into the stale builder area of an Age, Aged or Hand extent is classed as a live reference of that role, and only ECO_HEAP_VALIDATE would notice. This may be intended.

### GCStats accounting errors
- where: `runtime/src/allocator/GCStats.cpp`, `OldGenSpace.cpp:~7713`
- verdict: possible
- severity: low
- LOS allocations are missing from the old-gen histogram, reset does not clear wall_time_ns, a clock reading and point-in-time LOS values are summed, and addStall kind 3 collides with the pause kind. These are diagnostics only.

### collectAtSafepoint runs a STW majorGC in mark-cycle mode
- where: `runtime/src/allocator/ThreadLocalHeap.cpp:~600 (collectAtSafepoint)`
- verdict: possible
- severity: low
- The trigger path calls stop-the-world majorGC even when `useMarkCycle()` is true, unlike the minorGC trigger. It is a performance and consistency issue unless it interacts with an in-flight mark cycle, which has not been checked.

### allocatePermanent skips debt accounting and the large-alloc note
- where: `runtime/src/allocator/ThreadLocalHeap.cpp (allocatePermanent)`
- verdict: possible
- severity: low
- It is not counted toward HEAP_079 direct-allocation debt, does not call noteLargeAlloc, and has no major-GC retry on failure. Permanent allocations are rare.

### majorGC trace dumps are not gated by the runtime switch
- where: `runtime/src/allocator/ThreadLocalHeap.cpp:~984 (majorGC)`
- verdict: possible
- severity: low
- Unlike the minorGC dumps, the major begin/end dumps do not check that tracing is enabled at runtime, so a debug-trace build prints them and spends time on them without the switch.

### Shadow-root push after thread detach gives a misleading abort
- where: `runtime/src/allocator/ shadow root stack push`
- verdict: possible
- severity: low
- A push after the TLS words are cleared aborts in checked builds with "shadow root stack overflow at depth 0" instead of reporting a thread that is not attached.

### alloc_buffer_size is not required to be a page multiple
- where: `runtime/src/allocator/HeapConfig (validate, resolveNurseryRegions)`; `AllocatorCommon.hpp (validate)`
- verdict: possible
- severity: low
- Old-gen pages and nursery blocks are cut in `alloc_buffer_size` units, but validation does not require it to be a multiple of OS_PAGE_SIZE, which is a compile-time constant never checked at runtime (16K-page hosts). The validate messages ("x86-64", "legacy") misstate the checks.

### POSIX reserveAddressSpaceBelow TSan loop ignores the limit
- where: `runtime/src/allocator/PlatformVirtualMemory_posix.cpp:42-48`
- verdict: possible
- severity: low
- Under `__SANITIZE_THREAD__` the probe loop is bounded by 512 GB, not min(limit, 512 GB). This breaks the contract, but is harmless for the only caller (limit 2^43).

### win32 commitAt returns the rounded base for an unaligned addr
- where: `runtime/src/allocator/PlatformVirtualMemory_win32.cpp (commitAt)`
- verdict: possible
- severity: low
- A caller that compares the result with `addr` sees a failure when `addr` is not page-aligned.

## Strings, bytes and lists

### Likely bugs

### Float payloads in Just are tagged with the Int slot kind
- where: `runtime/src/allocator/BytesOps.hpp:288,309 (decodeFloat32/64)`; `runtime/src/allocator/StringOps.hpp:1255,1275 (String.toFloat)`
- verdict: likely-bug (checked in code)
- severity: medium
- `alloc::just(unboxedFloat(..), false)` maps to `justKind(...,1)`, which is Int, but Float is kind 2. Debug.toString and generic compare and equality then read the double's bits as an Int.

### UTF-8 and base64 decoders accept invalid input
- where: `runtime/src/allocator/BytesOps.cpp (decodeUtf8, encodeUtf8, fromBase64)`; `ElmBytesRuntime.cpp (elm_utf8_width/copy)`
- verdict: likely-bug
- severity: low
- The decoder accepts overlong forms, surrogates and F5-F7 lead bytes, and values above 0x10FFFF produce broken surrogate pairs. Encoders emit lone surrogates as 3-byte sequences. fromBase64 accepts a misplaced `=` and produces a wrong second byte, where Elm/JS would reject or substitute U+FFFD.

### Possible

### StringOps behaviour diverges from elm/core JS
- where: `runtime/src/allocator/StringOps.cpp:~700-725 (indexes)`; `StringOps.hpp (toInt/toFloat ~1208-1238, trim ~951, padLeft/padRight, repeat ~1018)`
- verdict: possible
- severity: medium
- `indexes ""` returns 0..len where JS returns []. `toInt` rejects a leading `+`. `toFloat` accepts whitespace, hex and locale forms and rejects ERANGE. `trim` misses NBSP, FEFF, FF and VT, the pad char cannot be astral, and `repeat` does not check `srcLen*n` against u32. Nobody traced whether each routine is the one programs actually reach.

### elm_utf8_decode has no bounds check
- where: `runtime/src/allocator/ElmBytesRuntime.cpp:203 (elm_utf8_decode)`
- verdict: possible
- severity: medium
- Nothing checks that offset+len stays in the buffer, so a bad offset reads out of bounds, and `elm_bytebuffer_data` may be null for an embedded-constant buffer. It is safe if the generated decoder always bounds-checks first, which the Elm Bytes decoder normally does.

### ListOps sort/maximum/minimum/sum/product ignore the element kind
- where: `runtime/src/allocator/ListOps.cpp:489-560`
- verdict: possible
- severity: low
- Every element is treated as Int, so Floats compare and sum by bit pattern and boxed values by address, and sort returns kind Int. No caller outside ListOps was found (the kernel exports do their own work), so this is latent.

### ListOps::sortBy/sortWith use an unstable std::sort
- where: `runtime/src/allocator/ListOps.cpp:507,530`
- verdict: possible
- severity: low
- Elm's sortBy and sortWith are stable. The exported Elm_Kernel_List_sortBy/sortWith use std::stable_sort, and the unstable path is reached only through Elm::Kernel::List in List.cpp.

### ListOps misc: kind collapse, range INT64_MIN, unrooted foldr element
- where: `runtime/src/allocator/ListOps.cpp (map/indexedMap/intersperse/singleton/repeat, last, range, foldr:434, unzip)`
- verdict: possible
- severity: low
- A Float or Char passed through `bool is_boxed` gets kind Int. `range` with low == INT64_MIN overflows `--i` (UB). foldr does not root the current element across `fold`. `last` on a malformed list returns Just null, and unzip casts unchecked. There are no external callers, so all of this is latent.

### HeapHelpers kind, zeroing and bounds inconsistencies
- where: `runtime/src/allocator/HeapHelpers.hpp (bool-is_boxed overloads, kindFromBoxedFlag, arrayPush, allocByteBuffer, makeByteBufferSlice, arrayGet)`
- verdict: possible
- severity: low
- `bool is_boxed` helpers map every unboxed value to Int. `allocByteBuffer(nullptr, n)` zeroes on the large path but not the small one. arrayPush does not check kinds after the first push, and makeByteBufferSlice and arrayGet are unchecked.

### StringOps dropLeft/dropRight on a null string
- where: `runtime/src/allocator/StringOps.hpp:609-620`
- verdict: possible
- severity: low
- The `n <= 0` check comes before the null check, so a null `str` (a resolved empty constant) hits Allocator::wrap's non-null assert. No kernel caller was found.

### builder_begin on a pinned large ByteBuffer
- where: `runtime/src/allocator/ElmBytesRuntime.cpp:80 (elm_bytebuffer_builder_begin)`
- verdict: possible (checked in code)
- severity: low
- A buffer at or above the LOT threshold is pinned, not young, yet mark_as_builder sets builder=1 and age=0 on it. clear_builder then asserts under ECO_HEAP_VALIDATE. The effect looks benign in normal builds.

### caseMapGeneral(null or empty) with UTF-8 asserts
- where: `runtime/src/allocator/ strings caseMapGeneral / allocAsciiOut`
- verdict: possible
- severity: low
- The assert in allocAsciiOut fires for that input, but no current caller reaches it.

## Runtime exports

### Likely bugs

### eco_int_pow signed overflow is UB
- where: `runtime/src/allocator/RuntimeExports.cpp:4452 (eco_int_pow)`
- verdict: likely-bug (checked in code)
- severity: low
- Signed `*=` overflows for large results, and the trailing `base *= base` overflows even when the result fits (e.g. 3^33). The optimizer may miscompile it. It should multiply as uint64.

### Printer prints unboxed floats with %g
- where: `runtime/src/allocator/RuntimeExports.cpp:~2980-3840 (printer)`
- verdict: likely-bug
- severity: low
- Floats inside containers print with `%g` instead of print_float, so they lose precision and spell inf/nan differently. An empty-String label prints `<null>`, and a boxed word below 0x10000 prints as an int.

### Possible

### _fast allocators ignore the large-object threshold
- where: `runtime/src/allocator/RuntimeExports.cpp (eco_*_fast, eco_gc_alloc_region_fast)`
- verdict: possible
- severity: medium
- These bump the nursery whatever the size, unlike eco_alloc_with_roots. They are harmless if codegen calls them only for fixed small sizes, which has not been fully checked.

### eco_store_field on a Closure writes an untraced slot in release builds
- where: `runtime/src/allocator/RuntimeExports.cpp:1922 (eco_store_field)`
- verdict: possible
- severity: medium
- Debug builds assert against a Closure target, but release builds still write the slot with no barrier or kind update. Only buggy codegen reaches this.

### Type table: short attribute arrays emitted as zeros, reader bound assert-only
- where: `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp:333-356`; `runtime/src/allocator/RuntimeExports.cpp:~3764/3818/3846`
- verdict: possible
- severity: low
- The Tuple, Record, Custom and Function arms emit zeroed type info for a short `typeArr` instead of rejecting it. The reader indexes `types[...]` after an assert-only bounds check, so a bad id reads out of bounds in release builds. Only corrupt compiler metadata triggers this.

### eco_alloc_tuple3 stores unboxed_mask unmasked
- where: `runtime/src/allocator/RuntimeExports.cpp:454 (eco_alloc_tuple3)`
- verdict: possible (checked in code)
- severity: low
- Every other tuple3 path masks with `& 0x3F`. If codegen ever sets bits 6-7, they corrupt the adjacent header bits.

### eco_alloc_cons root mask vs stored kind
- where: `runtime/src/allocator/RuntimeExports.cpp:417 (eco_alloc_cons*)`
- verdict: possible (checked in code)
- severity: low
- Rooting tests `head_kind != 0`, but the stored kind is `head_kind & 3`, so a kind of 4 or 8 is stored boxed but not rooted. Codegen emits only 0-3.

### CTOR_Router equals CONSTANT_TAG (0xFFFD)
- where: `runtime/src/allocator/HeapHelpers.hpp:2188`, `Heap.hpp:402-408`
- verdict: possible
- severity: low
- `eco_get_tag` returns 0xFFFD both for a router (a heap Custom) and for embedded constants. `eco_get_header_tag` and `eco_get_custom_ctor` return 0 for constants, which collides with Tag_Int and ctor 0.

### eco_enable_list_chunks is missing from the JIT symbol map
- where: `runtime/src/jit/ (runtime symbol map)`
- verdict: possible
- severity: low
- Generated code calls it, but it resolves only through process symbol search, so the JIT fails if the host does not export it. `registerRuntimeSymbols(mlir::ExecutionEngine&)` has no caller.

## Platform, scheduler and services

### Likely bugs

### WaitService waitpid(-1) steals children and can spin forever
- where: `runtime/src/platform/WaitService.cpp:135-143`
- verdict: likely-bug
- severity: medium
- Reaping every child breaks any other code that waits on its own children: it gets ECHILD, and the status sits in `unclaimed_` forever. A pid that is never a reapable child makes the worker poll every 10 ms forever without answering. On Windows an OpenProcess failure looks like exit code 1.

### HttpService: redirect headers accumulate, GET-with-body becomes POST
- where: `runtime/src/platform/HttpService.cpp (perform, headerCb ~153)`
- verdict: likely-bug
- severity: low
- With FOLLOWLOCATION, the 3xx response's headers are merged into the final response's headers, and a GET with a body is sent as POST. `std::tolower` gets a signed char (UB), statusText is always "", and there is no curl_global_init.

### Possible

### Spawn: Windows shell quoting, POSIX pid reuse, handle leak
- where: `runtime/src/platform/Spawn.cpp (Windows spawnChild, POSIX killChild, registerProcessHandle)`
- verdict: possible
- severity: medium
- Shell-mode commands containing `"` reach `cmd /s /c` with `\"` escapes and run with the wrong argument text. POSIX `killChild` on an already-reaped pid can signal an unrelated reused pid. `g_handles[pid]=` leaks the old handle.

### Windows spawn ignores ResumeThread, job and _open_osfhandle failures
- where: `runtime/src/platform/Spawn.cpp:343-359,393 (spawnChild, waitChild)`
- verdict: possible
- severity: medium
- A failed ResumeThread leaves the child suspended forever, and a failed job setup silently loses kill-tree semantics. A failed `_open_osfhandle` leaks the pipe and returns fd -1 with err 0, and a failed wait in waitChild is ignored.

### Windows process handle closed twice
- where: `runtime/src/platform/Process.cpp:56`; `Spawn.cpp (releaseChild)`
- verdict: possible
- severity: medium
- `child.process` is registered with WaitService while the SpawnedChild keeps the same handle. Both close it, and the second CloseHandle can close an unrelated reused handle.

### Duplicate POSIX wait submit leaves a Pending entry forever
- where: `runtime/src/platform/WaitService.cpp (POSIX submit)`
- verdict: possible
- severity: medium
- Submitting the same pid twice leaves one `Pending` that is never erased. The worker keeps reaping, gets ECHILD and wakes every 10 ms for the life of the process.

### Scheduler rawSend uses the caller's possibly stale snapshot
- where: `runtime/src/platform/Scheduler.cpp:471 (Scheduler::rawSend)`
- verdict: possible (checked in code)
- severity: medium
- mailboxPushBack builds the new process from the given HPointer, not `latestProcessById`. A stale handle registers an old snapshot as the latest version, so the newer state is lost and the old root is re-stepped.

### Scheduler: Binding re-step, dropped mailbox, wrong latest version
- where: `runtime/src/platform/Scheduler.cpp:~946-979 (stepping Binding, resumeEvaluator)`
- verdict: possible
- severity: medium
- Enqueuing a process parked on a Binding re-runs the bind callback, so its effect repeats. The resume closure restores the pre-park mailbox, so messages that arrived while parked are dropped. On synchronous resume setRoot registers the parked copy as latest, so killTask can hit the wrong version. elm/core usage may never reach these.

### PlatformRuntime dispatchEffects overwrites state set during drain
- where: `runtime/src/platform/PlatformRuntime.cpp:~380-395 (dispatchEffects)`
- verdict: possible
- severity: medium
- A manager state written by handleSelfMsg during `sched.drain()` is overwritten by onEffects' older result, which loses the self-message update. sendToSelf sends even when the Task is never run, and a second setupEffects leaves the old handlers registered.

### Windows exit codes >= 0x80000000 become negative
- where: `runtime/src/platform/ wait/process cpp:115-116`
- verdict: possible
- severity: low
- A DWORD exit code is cast to int, so NTSTATUS crash codes are reported as negative exit codes.

### TaskBinding null callback still yields a Binding
- where: `runtime/src/platform/TaskBinding.hpp:147-150,175-178`
- verdict: possible
- severity: low
- If `resolve(cb)` is null, a Binding with an empty slot 0 is returned, and stepping it later calls a null callback.

### TimerService double-schedule of a token; NaN millis
- where: `runtime/src/platform/TimerService.cpp (schedule)`
- verdict: possible
- severity: low
- Re-scheduling a token overwrites `byToken_`, so cancel misses the earlier timer, which still fires. This violates a stated precondition. `duration_cast` of NaN or huge millis is UB.

### StackMapSection PE/ELF parsing gaps
- where: `runtime/src/platform/StackMapSection.hpp`
- verdict: possible
- severity: low
- The parser misses `/NN` long PE section names, overreads a non-NUL-terminated shstrtab in strcmp, mishandles a size-0 shstrtab, ignores e_shnum == 0 and SHN_XINDEX, and assumes 64-bit images. It reads only the program's own image.

### Windows currentExecutablePath returns a truncated path
- where: `runtime/src/platform/PlatformPaths.hpp:60-66`
- verdict: possible
- severity: low
- If GetModuleFileNameW fills the 32768-unit buffer, the `len >= size+1` test never fires and a truncated path is returned as complete. An exe directly under "/" gives "", which is also the failure value.

## Embed

### Likely bugs

### Node addon keepalive leaks hold the event loop open
- where: `runtime/src/embed/ node addon cpp:212-448 (portSend, elmInit, portSubscribe, appStop)`
- verdict: likely-bug
- severity: medium
- portSend after stop references `g_keepalive` and nothing unreferences it, so Node never exits on its own. After a failed start, a retried elmInit overwrites `g_keepalive` with a new referenced TSFN and leaks the first. portSubscribe leaks a SubEntry on an N-API error, and appStop blocks Node's main thread in join.

### eco_embed: failed thread start leaves started=true
- where: `runtime/src/embed/eco_embed.cpp:213-326`
- verdict: likely-bug
- severity: low
- If thread creation fails, every later start returns ALREADY_STARTED and join returns 0. A stop from another thread during start leaks the Host hold, and setting idleHook after start is a data race.

### Possible

### PortRuntime: concurrent-subscribe split, silent wrong-name or wrong-direction subscribe
- where: `runtime/src/platform/PortRuntime.cpp:292-340,398-408,426,479-492`
- verdict: possible
- severity: low
- Two concurrent first subscribers each take part of the buffered payloads. A misspelt name creates a silent permanent entry and eco_port_subscribe reports success, and subscribeOutgoing on an incoming port also succeeds silently. The duplicate-name crash branches are unreachable.

## Codegen and passes

### Likely bugs

### Float `/=` is false on NaN
- where: `runtime/src/codegen/Passes/EcoToLLVMArith.cpp:844 (FloatNeOpLowering)`
- verdict: likely-bug (checked in code)
- severity: medium
- The lowering uses `CmpFPredicate::ONE`, so `nan /= nan` is False where Elm/JS gives True. The fix is `UNE`.

### Float round rounds halves away from zero
- where: `runtime/src/codegen/Passes/EcoToLLVMArith.cpp:601 (FloatRoundOpLowering)`
- verdict: likely-bug (checked in code)
- severity: medium
- `llvm.intr.round` gives `round -2.5 == -3`, while elm/core (`Math.round`) gives -2. The float-to-int conversion is also poison for NaN, inf and out-of-range values, and floor, ceiling and truncate share that.

### Float min/max drop NaN
- where: `runtime/src/codegen/Passes/EcoToLLVMArith.cpp:890,904 (FloatMin/MaxOpLowering)`
- verdict: likely-bug (checked in code)
- severity: low
- `minnum`/`maxnum` return the non-NaN operand (`min 1 NaN == 1`), but elm/core's comparison-based min/max can return NaN. Relatedly, FloatCmpOrder maps a NaN `compare` to EQ.

### capHoistMaxBytes strtoul truncation
- where: `runtime/src/codegen/Passes/EcoCapHoistCore.cpp:52`
- verdict: likely-bug
- severity: low
- `(unsigned)strtoul` wraps values above UINT_MAX before the clamp, so 4294967304 becomes 8 instead of 4096. This is an env-var edge case.

### Possible

### Closure kind mapping: only i16 is Char; large layouts keyed by hash
- where: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp (mlirTypeToParamKind, evalLayoutName, PapCreateGroupOpLowering)`
- verdict: possible
- severity: medium
- An i8 or i32 parameter is recorded as boxed but read raw by the wrapper. Two different kind lists of more than 64 entries with equal FNV hashes share one layout. PapCreateGroup derives kinds without the `wrapperWillBeTypedNewargs` check, so an args-array evaluator gets its kinds from a `(ptr)` signature.

### SretFuncOpLowering keeps arg_attrs unshifted
- where: `runtime/src/codegen/Passes/EcoToLLVMFunc.cpp:~175-185 (SretFuncOpLowering)`
- verdict: possible
- severity: medium
- Per-argument attributes are copied onto a function that has an extra leading sret parameter, so noalias or nonnull lands on the wrong argument and can miscompile, if arg_attrs are ever set. The pattern also returns failure() after it has moved the body, which misuses the conversion framework.

### EcoCapHoistPlan counts a non-constant alloc size as 0 bytes
- where: `runtime/src/codegen/Passes/EcoCapHoistPlan.cpp (alloc budget scan)`
- verdict: possible
- severity: medium
- An `__eco_alloc_inline` with a non-constant size adds 0 to the budget, so a covered function can reserve too little capacity and its unchecked bumps overflow it.

### Primitive-result closure calls emit an unmatched __eco_sat_begin
- where: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp (emitInlineClosureCall)`
- verdict: possible
- severity: low
- A begin marker is emitted with no end, and the backend drops it, so these sites lose the saturated fast path. This costs performance, not correctness.

### Boxed-store validator call can be a statepoint
- where: `runtime/src/codegen/Passes/EcoBoxedStoreVerify.cpp:65 (eco_validate_nursery_hptr_bits declaration)`
- verdict: possible
- severity: low
- Without gc-leaf, ECO_LOWERING_VALIDATION builds get a statepoint between a fresh allocation and its field stores, and between array.set's clone and its store, which the alloc-store invariant forbids. Release builds are unaffected.

### EcoListTemplate debug vectors survive across runs
- where: `runtime/src/codegen/Passes/EcoListTemplate.cpp:491-514 (debugOtherOps/debugBaseUseOwners)`
- verdict: possible
- severity: low
- They are never cleared, so a second run with ECO_LIST_TEMPLATE_DEBUG dereferences possibly erased ops from the first run. This affects debug only.

### EcoOps verifiers cast attributes without type checks
- where: `runtime/src/codegen/EcoOps.cpp (PapCreateGroupOp::verify, JoinpointOp::print, ListMapOp::verify)`
- verdict: possible
- severity: low
- `cast<IntegerAttr>` asserts on malformed IR instead of emitting a diagnostic, and `JoinpointOp::print` crashes on an empty body.

### String case lowering does not validate string_patterns
- where: `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp (buildStringIfChain)`, and the string case LLVM lowering
- verdict: possible
- severity: low
- Neither checks `string_patterns.size() == alts.size() - 1`, and `cast<StringAttr>` asserts on a non-string entry, so malformed input crashes the compiler.

### EcoToLLVMValueAgg cons head_kind vs head type
- where: `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp:~564-590`
- verdict: possible
- severity: low
- The header kind comes from `head_kind`, but the stored word follows the head type, so only the verifier catches a mismatch.

### EcoToLLVMErrorDebug stores narrow operands into i64 slots
- where: `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp (typed dbg loop, valueToI64)`
- verdict: possible
- severity: low
- An i16 or i1 stored into an i64 slot leaves the upper bytes uninitialised, so debug printing shows garbage.

### EcoToLLVMGlobals strings array skips non-StringAttr entries but counts them
- where: `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp:~198`
- verdict: possible
- severity: low
- A skipped entry shifts the later pointers down and leaves a trailing undef with an overstated `string_count`. A second `eco.type_table` is dropped silently. All of this needs malformed input.

### EcoToLLVMTypes NDEBUG end() deref on an un-premade literal
- where: `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp:~155-176`
- verdict: possible
- severity: low
- The missing-index check is assert-only, so a release build dereferences `end()` if a literal was not pre-materialized.

### EcoToLLVM symCache can create duplicate symbols
- where: `runtime/src/codegen/Passes/EcoToLLVMInternal.h (ensureSymCache)`; `EcoToLLVMRuntime.cpp:133-140 (getOrCreateFunc)`
- verdict: possible
- severity: low
- A `cacheSymbol` call before the first lookup after `clear()` leaves the cache incomplete, so a later lookup misses an existing func and creates a duplicate. `getOrCreateFunc` also duplicates if a non-llvm.func holds the name.

### EcoBackend: empty object path, swallowed filler errors
- where: `runtime/src/codegen/EcoBackend.cpp:~4421, ~815-828`
- verdict: possible
- severity: low
- An empty objectFilePath gives `objectFiles = {""}`. When SplitModule makes fewer parts, filler-object errors and a null TM are skipped silently, which leaves an expected file unwritten and causes a later link failure.

### EcoGcFreePropagation unrowed-marker check is not exhaustive
- where: `runtime/src/codegen/Passes/EcoGcFreePropagation.cpp:~213-288, :335`
- verdict: possible
- severity: low
- The walk stops at the first poisoning call, so later unrowed `__eco_` markers go unreported. A trusted definition that already has gc-leaf keeps it when poisoned.

### isTrustedLeafDecl trusts any eco_/Elm_Kernel_ prefix
- where: `runtime/src/codegen/Passes/EcoMarkerFacts.h:~174`
- verdict: possible
- severity: low
- A generated function with such a prefix would bypass the leaf check. None has been seen.

### Control-flow and joinpoint analysis imprecision
- where: `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp (int/str case use rewrite)`; `JoinpointNormalization.cpp:59,123-138`
- verdict: possible
- severity: low
- Int and string case lowering rewrites scrutinee uses only in caseBlocks, so nested multi-block alternatives can keep old uses and fail verification. `isSingleExitJoinpoint` counts nested and unreachable returns, and `hasSimpleCaseDispatch` checks only the first block.

### EcoReachability: duplicate flag, unused addressof drops its target
- where: `runtime/src/codegen/Passes/EcoReachability.cpp`; `EcoSymbolGraph.h:20-21,85`
- verdict: possible
- severity: low
- Running the pass twice appends a duplicate `eco-reach` flag. An unused `llvm.mlir.addressof @g` adds no edge, so `@g` is erased and the verifier rejects the module (a compile error, not a miscompile).

### EcoSymbolGraph ignores llvm.invoke callees
- where: `runtime/src/codegen/Passes/EcoSymbolGraph.cpp:61,119,196-209`
- verdict: possible
- severity: low
- An invoke callee would be classed as an address-taken use. Nothing emits invoke today.

### EcoPAPSimplify fused extend loses attributes
- where: `runtime/src/codegen/Passes/EcoPAPSimplify.cpp (P2 fusion, usesArgsArrayConvention)`
- verdict: possible
- severity: low
- The fused typed extend drops the second extend's `_result_kind`, and `func.func` args-array functions are not excluded. A typed papExtend whose `arg_type_ids` has the wrong length silently falls back instead of being rejected.

### EcoFoldProject creates arith ops without declaring the dialect
- where: `runtime/src/codegen/Passes/EcoFoldProject.cpp`
- verdict: possible
- severity: low
- There is no arith in `getDependentDialects`, so running the pass standalone loads arith mid-pass from worker threads. The pipeline preloads arith, so it is safe there. It also calls getenv per op from threads.

### UndefinedFunction misses nested and llvm.func definitions
- where: `runtime/src/codegen/Passes/UndefinedFunction.cpp:61,72 (runOnOperation)`
- verdict: possible (checked in code)
- severity: low
- Definitions are scanned at top level as func.func only, while calls are walked recursively, so a callee defined as llvm.func or in a nested module is falsely reported as undefined.

### EcoTailConversions partial-conversion edge cases
- where: `runtime/src/codegen/Passes/EcoTailConversions.cpp (runOnOperation)`
- verdict: possible
- severity: low
- `cf.assert` passes through until LLVM translation fails, and arith or scf inside global initializer regions is not converted.

### Compare+case rewrite can raise the compare's execution count
- where: `runtime/src/codegen/Passes/EcoCompareCaseRewrite.cpp:226-275 (tryRewrite/emitTests)`
- verdict: possible
- severity: low
- The tests are emitted right before the case, so a producer outside a joinpoint loop gets its string or boxed three-way compare re-run on every iteration. The results stay correct, but it is slower.

### EcoSplit inline list vs MAX_INSTS=0
- where: `runtime/src/codegen/EcoSplit.cpp`; `EcoBackend.cpp:~3896`
- verdict: possible
- severity: low
- With ECO_CAP_INLINE_MAX_INSTS=0 and ECO_CAP_INLINE_LIST set, the backend marks the listed functions but EcoSplit makes no import copies, so the knobs disagree. Only the first partition error is reported.

### BFToLLVM: read.bytes ok always true, i32 UTF-8 offset
- where: `runtime/src/codegen/Passes/BFToLLVM.cpp:~694-815, ~1482, ~1514`
- verdict: possible
- severity: low
- An allocation failure in bf.read.bytes is never reported because `ok` is always true. The UTF-8 offset is truncated to i32, which breaks buffers above 2 GiB. The writes assume a little-endian target, which every supported target is.

### LoweringStats short writes and init order
- where: `runtime/src/codegen/LoweringStats.cpp:31,49-51`
- verdict: possible
- severity: low
- A short `write` silently truncates a line, and the dynamically initialised `kProcessEpoch` makes a static-init `timelineMark` from another TU measure from 0.

## Driver and tools

### Likely bugs

### findElmProjectRoot fails for relative paths
- where: `runtime/src/codegen/eco-boot.cpp:311-329 (findElmProjectRoot)`
- verdict: likely-bug
- severity: low
- Every relative path misses the cwd: `src/Main.elm` and bare `Main.elm` fail without --workdir, while `./src/Main.elm` works. Calling `make_absolute` first fixes it.

### ecogen banner on stdout corrupts the default -o - output
- where: `runtime/src/codegen/ecogen.cpp:111-117`
- verdict: likely-bug
- severity: low
- "Verification successful!" goes to `llvm::outs()`, so the default stdout .mlir output is invalid. Diagnostics also lack source context because no SourceMgrDiagnosticHandler is installed.

### dumpLLVMIR leaves an Expected error unconsumed
- where: `runtime/src/codegen/ dumpLLVMIR (detectHost/createTargetMachine failure)`
- verdict: likely-bug
- severity: low
- With LLVM ABI-breaking checks on, the process aborts instead of returning 1.

### ECO_RUNTIME_DIR="" counts as set
- where: `runtime/src/codegen/EcoBootConfig.cpp (resolveFile, runtimeDir, hasGlibcOutputProfile)`
- verdict: likely-bug
- severity: low
- An empty value resolves files to `/<subdir>/<basename>` and probes `/glibc` instead of falling back to the default, which gives confusing "file not found" errors.

### Windows TerminateProcess skips atexit; unchecked setstacksize
- where: `runtime/src/codegen/eco_entry.cpp:362,392-405`
- verdict: likely-bug
- severity: low
- GC stats are never printed on Windows. If pthread_attr_setstacksize fails, the thread silently runs with the default stack and can overflow on deep recursion.

### EcoRunner output capture does not nest
- where: `runtime/src/codegen/EcoRunner.cpp (startOutputCapture/stopOutputCapture, executeJIT)`
- verdict: likely-bug
- severity: low
- A nested capture ends the outer one and loses its text. __eco_init_globals runs before the module's initializers, and a moved-from runner crashes if used.

### Possible

### Windows __eco_init_globals / gc-roots check is always true
- where: `runtime/src/codegen/eco_entry.cpp:94-98,152`; `EcoRunner.cpp (executeJIT)`
- verdict: possible
- severity: medium
- On Windows the declarations are not weak, so `if (sym)` is always true. A module with no globals defines no `__eco_init_globals`, so it either fails to link or calls null, unless a stub exists elsewhere (none was found).

### JIT: cantFail on fallible paths
- where: `runtime/src/jit/EcoJIT.cpp (create, invokePacked, initialize, registerSymbols)`
- verdict: possible
- severity: medium
- In release builds `cantFail` on a failure is UB. A duplicate symbol in `registerSymbols` is a plausible user-triggered failure, and `create` aborts on transformer and addIRModule errors even though it returns Expected.

### JIT EH-frame walk misreads extended-length records
- where: `runtime/src/jit/EcoJIT.cpp:148-175 (registerEHFrames/deregisterEHFrames, undoProcessFdeShift)`
- verdict: possible
- severity: low
- For a 64-bit-length record the CIE pointer is read at P+4 instead of P+12, and no read is bounds-checked against End. LLVM does not emit extended records for JIT objects of this size.

### EcoNativeDriver: unconditional debug print, racy init, skipped checks
- where: `runtime/src/codegen/EcoNativeDriver.cpp (~375 llvm::errs; initializeLLVMNativeTarget; checkAddressTaken)`
- verdict: possible
- severity: low
- "runEcoBackend begin" goes to stderr on every non-split build. The non-atomic static init flag races on a concurrent first call. ECO_REACH_VALIDATE is skipped on the split route, a .node shim write failure is ignored, and temp files leak on backend failure.

### eco-boot CLI edge cases
- where: `runtime/src/codegen/eco-boot.cpp (main, getOutputPath)`
- verdict: possible
- severity: low
- `--emit=mlir` on a .mlir input links an executable to `-`. `--emit=llvm` passes an unclamped -O level, and temp files leak on several error paths.

### Eco_Kernel_Order_register_gc_roots called twice per run
- where: `runtime/src/codegen/ecoc.cpp:~414`
- verdict: possible
- severity: low
- When the eco-kernel aggregate hook is linked, the function is called twice and can register roots twice.

## Other

### Possible

### Trace: late nameThread no-op; wants() reads g_keep unlocked
- where: `runtime/src/ trace cpp:76,156 (nameThread, wants)`
- verdict: possible
- severity: low
- `nameThread` silently does nothing once any event has been logged. `wants()` reads `g_keep` while `begin()` rewrites it, which is safe only under begin's "no other thread logs" contract.

## Cleanups

- GCFork.cpp:56 registerForkLayer: no assert that `layer < kForkLayers`.
- BitmapScan / StackMap.cpp: no little-endian static_assert; nextFreeCell has no assert that cell starts are below 2^16.
- Heap.hpp nullConsWordFor: no `idx <= NULL_CONS_MAX` assert; closureWellFormed skips unboxed bits past max_values; `_pad_sa` and the misleading `Header.refcount` name.
- TlaTrace: double evaluation, `g_binds` never cleared, plain globals (trace-only).
- LoweringStats: unmatched timeline line on a failed pass, hard-coded banner, 44-byte cut can split UTF-8.
- EcoToLLVM.cpp registerEcoPasses registers only EcoToLLVMPass.
- eco_order_weak_stub_win32.cpp: always-true guard; registrar name overstates what it does.
- EcoCapHoistCore: inconsistent 0/1 env parsing; gcFreeValidate accepts any non-"0".
- EcoParallel.h:45 parallelFor divides by zero for minPerChunk 0 (no caller passes it).
- EcoJIT: jitCodeGenOptLevel set on an unused `jtmb`; const `lookup` mutates `stackMapData_`.
- eco_native_stub.cpp does not include EcoNativeAPI.h, so signature drift is not caught.
- GCHelperPool: stopAllForFork relies on the caller's lock; jitter range inconsistency; `joinLocked` `stopping` is always false.
- MinorWork fwdWord masks addresses at 2^43 or above (heap reserved below by design); plan citation in a runtime string.
- StackMapRoots point/restore have no callers.
- AllocatorCommon: hard-coded size literals, unknown tags sized 8, unused Grey colour, unread rope_* fields.
- Child-walk tag lists (NurseryChildWalk.hpp x2, NurseryParallel.cpp:46) are hand-maintained with no agreement check.
- ReservedArray: unchecked size overflow and non-pow2 granule asserts missing.
- RootSet: empty ranges pushed; `%lx` format on non-Windows only.
- EcoToLLVMClosures: dead papHisto counters, unreachable `stageArity > 16`, sat-entry cache never filled.
- eco_array_set_fix_kind is not declared gc-leaf (checked in code: the callee does not allocate, so only a needless statepoint), and RuntimeExports.cpp:4503 masks its 2-bit kind with 0x3F.
- __eco_alloc_inline marker is declared gc-leaf with no check that it is expanded before RS4GC.
- Misc codegen: inconsistent env parsers, unused includes/params, literal 7 for Tag_Custom, dead i1 arms, always-true verifier predicates, dead useIndexFailed/i64ToValue/utf16PatternCache.
- EcoControlFlowToSCF: Elm_Kernel_Utils_equal declared for every str case even if unused; redundant re-mapping.
- EcoGCPrepare: dead isGroupBarrier body, redundant branches, winHardBarrier never incremented.
- EcoListCursor / EcoToLLVM / EcoGCLivenessAudit: unused state and misleading description strings; purity-verifier message and description are wrong.
- EcoBackend: ECO_CAP_INLINE_LIST re-read per partition worker; unreachable available_externally error; unused TarjanNode.
- EcoPAPSimplify kClosureMaxArity duplicates 2047 instead of using `Elm::CLOSURE_MAX_ARITY`.
- OldGenSpace: dead stores, duplicated sequences, plan-citation strings, misindented `if`, never-read fields (capacity_ns, shrink_*, current_epoch, NO_BLOCK); releaseUnassignedBlockToAllocator keeps a heap-base page.
- OldGenSpace sweepNurseryLargeBodies: the `compact_phase_ != Idle` branch is reachable only in NDEBUG builds.
- majorRedirect / zapDeadAfterMajor dereference `rg_` unchecked (region-mode precondition).
- Minor GC: dead `col`, shared static tick, `healed` counts skipped slots, `drain_ns_sum += 0`, `MinorWorker::priv` dead atomic store, stale docs on tenureJoin and mergeJob.
- NurserySpace validate-build checks report and continue; strict mode is dead; ThreadLocalHeap `force_gc_` is never set.
- Allocator no-wait fallback trace records the wrong extent (stats only); idleUntilWorkOrDone spins with no backoff.
- Bytes/ElmBytesRuntime: little-endian host assumed; memcpy(nullptr, 0); typedefs in extern "C" header.
- StringOps: dead store in makeUtf8View; equalSlow precondition; `int(la)-int(lb)` overflow above 2^31.
- eco_alloc_custom(0 fields) is only assert-guarded (release would build a heap nullary ctor).
- Scheduler: drains every pass, unlocked runQueue_ empty() read, getenv per call, dead fields.
- TimerService dead `s_instance`, needlessly mutable mutex; ecoc unused `-o`/-verify-diagnostics flags; N-API portSubscribe reads argv[0] before the argc check.

## Checked and not bugs

- PlatformVirtualMemory Darwin/Win notes: extra syscalls only; the Darwin discardPages zero-assumption is unaudited.
- StackMap::parse replaces rather than appends: each driver parses once and `stackMapData_` accumulates every blob.
- StackMap dwarfRegNum "truncation": the v3 format is u16 + u16 reserved, so a u32 read cast to u16 is exact on LE (the reviewer disputed the log).
- hostHolds_ never decremented for resume-keyed Host holds: documented at Scheduler.hpp:207, and no caller passes HoldKind::Host to parkResume (a latent trap).
- Utf8 length counters wrap at 2^32: callers cap lengths at u32 (StringOps.cpp:186).
- MarkWork epoch carry, kAbort collision, sleepMicros: these need 2^31 reactivations or a 2^43 array; jitter is capped at 100000.
- Shadow-slot reload uses bare inttoptr: REP_LLVM_002 exempts the shadow-root frame.
- CheckEcoClosureCaptures indexes paramTypes unchecked: the op verifier runs first.
- parseStamp result dereferenced in EcoBackend: EcoBackend.cpp:4070-4086 rejects a malformed stamp first (checked in code by an extractor).
- ListChainReverseWriter with n == 0: the only caller returns early when n <= 1.
- allocTaskUnboxed with kind 0: Scheduler::taskSucceedKind routes kind 0 to the boxed path.
- procWithMailbox does not root its locals: allocProcess roots all three through eco_alloc_with_roots (reviewer dispute resolved as safe).
- GCHelperPool drain/post read mode_ unsynchronised: it is ordered by the release store of `configured_`.
- ReservedArray base_ read cross-thread: ordered by `committed_` release/acquire.
- GCFork layer replaced during prepare runs the old hooks: correct for the locks taken.
- Equality accepts a zero-length heap string as equal to Empty: a defensive exception, and the result is correct.
- Already fixed: buildIntIfChain base case and multi-result replacement (EcoControlFlowToSCF.cpp:642-690) now always builds an else region and replaces all results.
