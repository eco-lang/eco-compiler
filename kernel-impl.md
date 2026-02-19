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
| Platform  | 5        | 2*          | 3       | 0       | ⚠️ Partial |
| Process   | 1        | 0           | 1       | 0       | ❌ Stubbed |
| Scheduler | 6        | 0           | 6       | 0       | ❌ Stubbed |
| String    | 29       | 29          | 0       | 0       | ✅ Complete |
| Utils     | 8        | 8           | 0       | 0       | ✅ Complete |
| **Total** | **126**  | **99**      | **26**  | **1**   | **78%** |

*\* Platform: sendToApp is no-op, worker returns input unchanged*

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
| Debugger | download | ❌ | Requires Task type |
| Debugger | init | ✅ | |
| Debugger | isOpen | ✅ | Always returns false |
| Debugger | messageToString | ✅ | Delegates to Debug.toString |
| Debugger | open | ❌ | Requires Task type |
| Debugger | scroll | ❌ | Requires Task type |
| Debugger | unsafeCoerce | ✅ | |
| Debugger | upload | ❌ | Requires Task type |
| JsArray | appendN | ✅ | |
| JsArray | empty | ✅ | |
| JsArray | equals | ❌ | Missing entirely |
| JsArray | foldl | ❌ | Requires closure support |
| JsArray | foldr | ❌ | Requires closure support |
| JsArray | indexedMap | ❌ | Requires closure support |
| JsArray | initialize | ❌ | Requires closure support |
| JsArray | initializeFromList | ❌ | Requires closure support |
| JsArray | length | ✅ | |
| JsArray | map | ❌ | Requires closure support |
| JsArray | push | ✅ | |
| JsArray | singleton | ✅ | |
| JsArray | slice | ✅ | |
| JsArray | unsafeGet | ✅ | |
| JsArray | unsafeSet | ✅ | |
| List | cons | ✅ | |
| List | fromArray | ✅ | |
| List | map2 | ❌ | Requires closure support |
| List | map3 | ❌ | Requires closure support |
| List | map4 | ❌ | Requires closure support |
| List | map5 | ❌ | Requires closure support |
| List | sortBy | ❌ | Requires closure support |
| List | sortWith | ❌ | Requires closure support |
| List | toArray | ✅ | |
| Platform | batch | ❌ | Requires Cmd support |
| Platform | map | ❌ | Requires Cmd support |
| Platform | sendToApp | ⚠️ | No-op stub |
| Platform | sendToSelf | ❌ | Requires Task support |
| Platform | worker | ⚠️ | Returns input unchanged |
| Process | sleep | ❌ | Requires platform runtime |
| Scheduler | andThen | ❌ | Requires Task type |
| Scheduler | fail | ❌ | Requires Task type |
| Scheduler | kill | ❌ | Requires Task type |
| Scheduler | onError | ❌ | Requires Task type |
| Scheduler | spawn | ❌ | Requires Task type |
| Scheduler | succeed | ❌ | Requires Task type |
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

### Key Findings

1. **Pure computational functions are complete** — Basics, Bitwise, Char, String, Utils fully implemented.

2. **Higher-order functions are the main gap** — JsArray and List stubs all involve closures (map, fold, sort).

3. **Task/Cmd runtime not implemented** — Scheduler, Process, Platform stubs require a Task type.

4. **Working closure patterns exist** — StringExports.cpp has closure-calling helpers that could be reused.

5. **One function missing entirely** — JsArray.equals not in implementation.
