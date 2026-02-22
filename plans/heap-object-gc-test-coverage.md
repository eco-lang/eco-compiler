# Plan: Full GC Test Coverage for All Heap Object Types

## Problem

Many heap object types lack GC survival and tracing tests. The current test suite has strong coverage for Cons, ElmArray, String, and ByteBuffer, but weak or absent coverage for Custom, Record, Closure, Tuple3, DynRecord, FieldGroup, Process, Task, ElmFloat, and ElmChar.

## Scope

Add tests to `test/allocator/HeapHelpersTest.cpp` to fill every gap in the coverage matrix. Each type needs:
- **Allocation test**: create the object, verify fields
- **Minor GC survival**: root it, run `minorGC()`, verify fields intact
- **GC tracing**: for types with child pointers, verify children (only reachable through this object) survive GC
- **Unboxed field correctness**: for types with unboxed bitmaps, verify both boxed and unboxed fields are handled correctly across GC

Types that contain no pointers (ElmFloat, ElmChar, FieldGroup) don't need tracing tests. Types already fully covered (Cons, ElmArray, String, ByteBuffer, ElmInt) are skipped.

## Existing allocation helpers available

| Type | Helper | Notes |
|------|--------|-------|
| ElmFloat | `allocFloat(f64)` | exists |
| ElmChar | `allocChar(u16)` | exists |
| Tuple3 | `tuple3(a, b, c, unboxed_mask)` | exists |
| Custom | `custom(ctor, values, unboxed_mask)` | exists |
| Record | `record(values, unboxed_mask)` | exists |
| Closure | `allocClosure(evaluator, max_values)` | exists |
| Process | `allocProcess(id, root, stack, mailbox)` | exists |
| Task | `allocTask(ctor, value, callback, kill, task)` | exists |
| DynRecord | none | need to allocate manually |
| FieldGroup | none | need to allocate manually |

## Tests to add

### Group A: ElmFloat (no child pointers)

**A1. `testAllocatedFloatSurvivesMinorGC`**
- Create ElmFloat with a random finite value, root it, run `minorGC()`
- Verify tag is `Tag_Float`, value preserved

### Group B: ElmChar (no child pointers)

**B1. `testAllocatedCharSurvivesMinorGC`**
- Create ElmChar with random u16, root it, run `minorGC()`
- Verify tag is `Tag_Char`, value preserved

### Group C: Tuple3

**C1. `testTuple3BoxedSurvivesMinorGC`**
- Create Tuple3 with 3 boxed ElmInt children (unboxed_mask=0)
- Root only the Tuple3
- Run `minorGC()`
- Verify all 3 children survive and have correct values
- This tests GC tracing of Tuple3's `a`, `b`, `c` fields

**C2. `testTuple3UnboxedSurvivesMinorGC`**
- Create Tuple3 with 3 unboxed i64 values (unboxed_mask=7)
- Root it, run `minorGC()`
- Verify all 3 unboxed values preserved
- Verify `header.unboxed == 7` after GC

**C3. `testTuple3MixedSurvivesMinorGC`**
- Create Tuple3 with field `a` boxed (ElmInt), fields `b` and `c` unboxed (unboxed_mask=0b110=6)
- Root only the Tuple3
- Run `minorGC()`
- Verify boxed child `a` survives (GC traced it), unboxed `b`/`c` values preserved

### Group D: Custom (with unboxed bitmap)

**D1. `testCustomBoxedFieldsSurviveMinorGC`**
- Create Custom with ctor=0, 4 boxed ElmInt fields (unboxed_mask=0)
- Root only the Custom
- Run `minorGC()`
- Verify all 4 child ElmInts survive with correct values
- This is the key test: exercises the Custom unboxed bitmap scanning path for all-boxed

**D2. `testCustomUnboxedFieldsSurviveMinorGC`**
- Create Custom with ctor=0, 3 unboxed i64 fields (unboxed_mask=0x7)
- Root it, run `minorGC()`
- Verify all 3 values preserved, no crash from GC tracing integers

**D3. `testCustomMixedFieldsSurviveMinorGC`**
- Create Custom with 4 fields: fields 0,2 boxed (ElmInt), fields 1,3 unboxed int (unboxed_mask=0b1010=0xA)
- Root only the Custom
- Run `minorGC()`
- Verify boxed fields survive (GC traced), unboxed fields preserved

### Group E: Record (with unboxed bitmap)

**E1. `testRecordBoxedFieldsSurviveMinorGC`**
- Create Record with 3 boxed ElmInt fields (unboxed_mask=0)
- Root only the Record
- Run `minorGC()`
- Verify all 3 children survive with correct values

**E2. `testRecordMixedFieldsSurviveMinorGC`**
- Create Record with 4 fields: fields 0,2 boxed, fields 1,3 unboxed (unboxed_mask=0xA)
- Root only the Record
- Run `minorGC()`
- Verify boxed fields traced, unboxed fields preserved

### Group F: Closure (with unboxed bitmap)

**F1. `testClosureBoxedCapturesSurviveMinorGC`**
- Create Closure with `max_values=3`, push 3 boxed ElmInt captures
- Root only the Closure
- Run `minorGC()`
- Verify all 3 captured values survive
- Note: Need to set `n_values`, `unboxed` bitmap, and `values[]` manually since `allocClosure` doesn't populate captures

**F2. `testClosureMixedCapturesSurviveMinorGC`**
- Create Closure with 3 captures: capture 0 boxed, captures 1,2 unboxed (unboxed=0b110)
- Root only the Closure
- Run `minorGC()`
- Verify boxed capture survives, unboxed captures preserved

### Group G: Process (3 HPointer children)

**G1. `testProcessChildrenSurviveMinorGC`**
- Create 3 ElmInt objects as `root`, `stack`, `mailbox`
- Create Process pointing to all 3
- Root only the Process
- Run `minorGC()`
- Verify all 3 children survive (tests GC tracing of `root`, `stack`, `mailbox` fields)

### Group H: Task (4 HPointer children)

**H1. `testTaskChildrenSurviveMinorGC`**
- Create 4 ElmInt objects as `value`, `callback`, `kill`, `innerTask`
- Create Task pointing to all 4
- Root only the Task
- Run `minorGC()`
- Verify all 4 children survive (tests GC tracing of `value`, `callback`, `kill`, `task` fields)

### Group I: DynRecord (fieldgroup + values)

**I1. `testDynRecordSurvivesMinorGC`**
- Manually allocate a FieldGroup with 2 field IDs
- Manually allocate a DynRecord with 2 boxed value fields and the fieldgroup pointer
- Root only the DynRecord
- Run `minorGC()`
- Verify both value children and the FieldGroup survive
- Note: Must use raw allocation since no HeapHelpers function exists

### Group J: FieldGroup (no child pointers)

**J1. `testFieldGroupSurvivesMinorGC`**
- Manually allocate a FieldGroup with some field IDs
- Root it, run `minorGC()`
- Verify field count and field IDs are preserved
- Note: FieldGroup has no pointers (only u32 field IDs), so this just tests evacuation/copy correctness

## Implementation approach

All tests go in `test/allocator/HeapHelpersTest.cpp`:
- Groups A-C: insert after existing Tuple2 tests / before ByteBuffer tests
- Groups D-E: new "Custom GC" and "Record GC" sections
- Group F: new "Closure GC" section
- Groups G-H: new "Process/Task GC" section
- Groups I-J: new "DynRecord/FieldGroup GC" section

Register all new tests in `registerHeapHelpersTests()`.

For DynRecord and FieldGroup (Group I, J), allocate manually using `Allocator::instance().allocate()` since no helper functions exist.

For Closure tests (Group F), use `allocClosure()` then manually fill in `n_values`, `unboxed`, and `values[]`.

## Test count

| Group | Tests | Purpose |
|-------|-------|---------|
| A | 1 | ElmFloat GC |
| B | 1 | ElmChar GC |
| C | 3 | Tuple3 GC (boxed, unboxed, mixed) |
| D | 3 | Custom GC (boxed, unboxed, mixed) |
| E | 2 | Record GC (boxed, mixed) |
| F | 2 | Closure GC (boxed, mixed) |
| G | 1 | Process GC |
| H | 1 | Task GC |
| I | 1 | DynRecord GC |
| J | 1 | FieldGroup GC |
| **Total** | **16** | |

## After implementation

After this plan, every cell in the coverage matrix will be filled:

| Type | Alloc | Minor GC | Unboxed | GC Tracing |
|------|-------|----------|---------|------------|
| ElmInt | ✓ | ✓ | ✓ | ✓ |
| ElmFloat | ✓ | **A1** | ✓ | N/A |
| ElmChar | ✓ | **B1** | ✓ | N/A |
| ElmString | ✓ | ✓ | N/A | N/A |
| Tuple2 | ✓ | ✓ | ✓ | ✓ |
| Tuple3 | ✓ | **C1/C2** | **C2/C3** | **C1/C3** |
| Cons | ✓ | ✓ | ✓ | ✓ |
| Custom | ✓ | **D1** | **D2/D3** | **D1/D3** |
| Record | ✓ | **E1** | **E2** | **E1/E2** |
| DynRecord | **I1** | **I1** | N/A | **I1** |
| FieldGroup | **J1** | **J1** | N/A | N/A |
| Closure | ✓ | **F1** | **F2** | **F1/F2** |
| Process | ✓ | **G1** | N/A | **G1** |
| Task | ✓ | **H1** | N/A | **H1** |
| ByteBuffer | ✓ | ✓ | N/A | N/A |
| ElmArray | ✓ | ✓ | ✓ | ✓ |

## Running tests

```bash
cmake --build build && ./build/test/test
```
