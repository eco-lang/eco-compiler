# Elm Kernel Functions Implementation Status
## elm/core package in elm-kernel-cpp/src/core/

### Summary

| Module    | Expected | Implemented | Stubbed | Missing | Status |
|-----------|----------|-------------|---------|---------|--------|
| Basics    | 29       | 29          | 0       | 0       | ✅ Complete |
| Bitwise   | 7        | 7           | 0       | 0       | ✅ Complete |
| Char      | 6        | 6           | 0       | 0       | ✅ Complete |
| Debug     | 3        | 3           | 0       | 0       | ✅ Complete |
| Debugger  | 8        | 4           | 4       | 0       | ⚠️ Partial |
| JsArray   | 15       | 8           | 6       | 1       | ⚠️ Partial |
| List      | 9        | 3           | 6       | 0       | ⚠️ Partial |
| Platform  | 5        | 5           | 0       | 0       | ✅ Complete |
| Process   | 1        | 1           | 0       | 0       | ✅ Complete |
| Scheduler | 6        | 6           | 0       | 0       | ✅ Complete |
| String    | 29       | 29          | 0       | 0       | ✅ Complete |
| Utils     | 8        | 8           | 0       | 0       | ✅ Complete |
| **Total** | **126**  | **109**     | **16**  | **1**   | **87%** |

### Detailed Status

| Module | Function | Status | Notes |
|--------|----------|--------|-------|
| Basics | acos | ✅ | |
| Basics | add | ✅ | Polymorphic (examines heap tags) |
| Basics | and | ✅ | |
| Basics | asin | ✅ | |
| Basics | atan | ✅ | |
| Basics | atan2 | ✅ | |
| Basics | ceiling | ✅ | |
| Basics | cos | ✅ | |
| Basics | e | ✅ | |
| Basics | fdiv | ✅ | |
| Basics | floor | ✅ | |
| Basics | idiv | ✅ | |
| Basics | isInfinite | ✅ | |
| Basics | isNaN | ✅ | |
| Basics | log | ✅ | |
| Basics | modBy | ✅ | |
| Basics | mul | ✅ | Polymorphic (examines heap tags) |
| Basics | not | ✅ | |
| Basics | or | ✅ | |
| Basics | pi | ✅ | |
| Basics | pow | ✅ | Polymorphic (examines heap tags) |
| Basics | remainderBy | ✅ | |
| Basics | round | ✅ | |
| Basics | sin | ✅ | |
| Basics | sqrt | ✅ | |
| Basics | sub | ✅ | Polymorphic (examines heap tags) |
| Basics | tan | ✅ | |
| Basics | toFloat | ✅ | |
| Basics | truncate | ✅ | |
| Basics | xor | ✅ | |
| Bitwise | and | ✅ | |
| Bitwise | complement | ✅ | |
| Bitwise | or | ✅ | |
| Bitwise | shiftLeftBy | ✅ | |
| Bitwise | shiftRightBy | ✅ | |
| Bitwise | shiftRightZfBy | ✅ | |
| Bitwise | xor | ✅ | |
| Char | fromCode | ✅ | |
| Char | toCode | ✅ | |
| Char | toLocaleLower | ✅ | |
| Char | toLocaleUpper | ✅ | |
| Char | toLower | ✅ | ASCII only (TODO: Unicode) |
| Char | toUpper | ✅ | ASCII only (TODO: Unicode) |
| Debug | log | ✅ | |
| Debug | todo | ✅ | |
| Debug | toString | ✅ | |
| Debugger | download | ❌ | Stubbed — requires browser |
| Debugger | init | ✅ | |
| Debugger | isOpen | ✅ | Always returns false |
| Debugger | messageToString | ✅ | Delegates to Debug.toString |
| Debugger | open | ❌ | Stubbed — requires browser |
| Debugger | scroll | ❌ | Stubbed — requires browser |
| Debugger | unsafeCoerce | ✅ | |
| Debugger | upload | ❌ | Stubbed — requires browser |
| JsArray | appendN | ✅ | |
| JsArray | empty | ✅ | |
| JsArray | equals | ❌ | Missing entirely |
| JsArray | foldl | ❌ | Stubbed — requires closure support |
| JsArray | foldr | ❌ | Stubbed — requires closure support |
| JsArray | indexedMap | ❌ | Stubbed — requires closure support |
| JsArray | initialize | ❌ | Stubbed — requires closure support |
| JsArray | initializeFromList | ❌ | Stubbed — requires closure support |
| JsArray | length | ✅ | |
| JsArray | map | ❌ | Stubbed — requires closure support |
| JsArray | push | ✅ | |
| JsArray | singleton | ✅ | |
| JsArray | slice | ✅ | |
| JsArray | unsafeGet | ✅ | |
| JsArray | unsafeSet | ✅ | |
| List | cons | ✅ | |
| List | fromArray | ✅ | |
| List | map2 | ❌ | Stubbed — requires closure support |
| List | map3 | ❌ | Stubbed — requires closure support |
| List | map4 | ❌ | Stubbed — requires closure support |
| List | map5 | ❌ | Stubbed — requires closure support |
| List | sortBy | ❌ | Stubbed — requires closure support |
| List | sortWith | ❌ | Stubbed — requires closure support |
| List | toArray | ✅ | |
| Platform | batch | ✅ | Creates Fx_Node Custom heap object |
| Platform | map | ✅ | Creates Fx_Map Custom heap object |
| Platform | sendToApp | ✅ | Routes via PlatformRuntime |
| Platform | sendToSelf | ✅ | Sends to manager self-process |
| Platform | worker | ✅ | TEA init loop, GC-rooted model, effect dispatch |
| Process | sleep | ✅ | Binding task with std::thread timer |
| Scheduler | andThen | ✅ | Allocates heap Task (ctor=AndThen) |
| Scheduler | fail | ✅ | Allocates heap Task (ctor=Fail) |
| Scheduler | kill | ✅ | Kills process, invokes kill handle |
| Scheduler | onError | ✅ | Allocates heap Task (ctor=OnError) |
| Scheduler | spawn | ✅ | Creates process, enqueues, returns Task.succeed(proc) |
| Scheduler | succeed | ✅ | Allocates heap Task (ctor=Succeed) |
| String | all | ✅ | Has closure support |
| String | any | ✅ | Has closure support |
| String | append | ✅ | |
| String | cons | ✅ | |
| String | contains | ✅ | |
| String | endsWith | ✅ | |
| String | filter | ✅ | Has closure support |
| String | foldl | ✅ | Has closure support |
| String | foldr | ✅ | Has closure support |
| String | fromList | ✅ | |
| String | fromNumber | ✅ | |
| String | indexes | ✅ | |
| String | join | ✅ | |
| String | length | ✅ | |
| String | lines | ✅ | |
| String | map | ✅ | Has closure support |
| String | reverse | ✅ | |
| String | slice | ✅ | |
| String | split | ✅ | |
| String | startsWith | ✅ | |
| String | toFloat | ✅ | |
| String | toInt | ✅ | |
| String | toLower | ✅ | |
| String | toUpper | ✅ | |
| String | trim | ✅ | |
| String | trimLeft | ✅ | |
| String | trimRight | ✅ | |
| String | uncons | ✅ | |
| String | words | ✅ | |
| Utils | append | ✅ | |
| Utils | compare | ✅ | |
| Utils | equal | ✅ | |
| Utils | ge | ✅ | |
| Utils | gt | ✅ | |
| Utils | le | ✅ | |
| Utils | lt | ✅ | |
| Utils | notEqual | ✅ | |

### Architecture Notes

**Scheduler/Platform runtime** — Heap-native implementation in `runtime/src/platform/`:
- `Scheduler.hpp/.cpp` — Cooperative task execution with GC-managed Task/Process objects
- `PlatformRuntime.hpp/.cpp` — Effect manager registry, Cmd/Sub dispatch, Platform.worker init
- Tasks are heap-allocated objects (Tag_Task) with ctor tags: Succeed=0, Fail=1, Binding=2, AndThen=3, OnError=4, Receive=5
- Processes are heap-allocated (Tag_Process) with root task, stack (linked list of StackFrame Custom objects), and mailbox (Elm List)
- Old std::shared_ptr-based Scheduler retired to `design_docs/reference/Scheduler_old.cpp`

### Key Findings

1. **Pure computational functions are complete** — Basics, Bitwise, Char, String, Utils fully implemented.

2. **Higher-order functions are the main gap** — JsArray and List stubs all involve closures (map, fold, sort).

3. **Scheduler/Platform/Process now implemented** — Full heap-native cooperative scheduler with task constructors, step loop, effect manager dispatch, and Platform.worker TEA initialization.

4. **Working closure patterns exist** — StringExports.cpp has closure-calling helpers. Scheduler uses `eco_apply_closure` for calling Elm closures from C++.

5. **One function missing entirely** — JsArray.equals not in implementation.

6. **Browser-dependent stubs remain** — Debugger's open/scroll/download/upload require browser APIs not available in the native runtime.
