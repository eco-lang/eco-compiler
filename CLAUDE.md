# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **eco-runtime**, a generational garbage collector runtime for Elm, written in C++20. It implements a two-generation GC with minor (nursery) and major (old generation) collection strategies optimized for Elm's immutable, purely functional semantics.

## Build Commands

### Initial Setup
```bash
# Configure build (release)
cmake --preset ninja-clang-lld-linux

# Configure build (debug)
cmake --preset ninja-clang-lld-linux-debug
```

### Building
```bash
# Build all targets
cmake --build build

# Build specific target
cmake --build build --target test
cmake --build build --target ecor
```

### Running Tests
```bash
# Run full test suite (default: 100 tests)
./build/test/test

# Run with specific number of tests
./build/test/test -n 1000

# Run with specific seed (for reproducibility)
./build/test/test --seed 42

# Control test complexity with max-size (default: 100)
./build/test/test --max-size 500

# Filter tests by name
./build/test/test --filter preserve

# Reproduce a specific failing test
./build/test/test --reproduce <reproduction_string>

# Run tests multiple times
./build/test/test --repeat 10

# Enable GC statistics output
# (requires recompiling with ENABLE_GC_STATS defined)
```

The test suite uses RapidCheck for property-based testing. When a test fails, it will provide a reproduction string that can be used to reliably reproduce the failure.

**Test complexity scaling**: The `--max-size` parameter controls the complexity of generated test inputs. Tests use size-sensitive generators that create larger heap graphs, more GC cycles, and more allocations at higher sizes:
- `--max-size 1-10`: Minimal tests, ~30s for 10 iterations
- `--max-size 100`: Default, moderate complexity, ~30s for 10 iterations
- `--max-size 500`: Thorough testing, ~100s for 10 iterations
- `--max-size 1000+`: Not recommended (excessive runtime)

## Core Architecture

### Memory Model
- **Logical pointers**: 40-bit offsets into a unified heap, allowing 8TB address space
- **Unified heap**: Single reserved address space (1GB default) split between old generation and thread-local nurseries
- **Lazy commitment**: Address space reserved upfront, physical memory committed on demand via mmap
- **Unboxed values**: Primitives (Int, Float, Char) stored inline when possible, not as heap objects
- **Embedded constants**: Common values (Nil, True, False, Unit) embedded directly in pointer representation

### Garbage Collection Strategy

**Two-generation design** based on generational hypothesis:

1. **Minor GC (NurserySpace)** - `runtime/src/allocator.cpp:~400-600`
   - Thread-local semi-space copying collector (4MB per thread)
   - Cheney's algorithm for breadth-first evacuation
   - Bump pointer allocation (fast O(1) path)
   - Objects promoted to old gen after surviving `PROMOTION_AGE` collections (currently 1)
   - No synchronization needed on allocation fast path

2. **Major GC (OldGenSpace)** - `runtime/src/allocator.cpp:~600-800`
   - Mark-and-sweep collector with free-list allocation
   - Tri-color marking (White/Grey/Black) for incremental/concurrent collection
   - Uses recursive mutexes for thread safety (allows re-entrant allocation during GC)
   - Can grow dynamically within reserved address space

**Key optimization**: No write barriers needed because Elm's immutability guarantees no old→young pointers can exist.

### Object Representation

All heap objects defined in `runtime/include/heap.hpp`:
- **64-bit header**: tag (16 bits), color (2 bits), age (2 bits), refcount (28 bits), flags
- **8-byte alignment**: All objects aligned to 8 bytes for performance
- **Type hierarchy**: Int, Float, Char, String, Tuple2, Tuple3, Cons (lists), Custom, Record, DynRecord, FieldGroup, Closure, Process, Task

### Forwarding Pointers
During copying collection, evacuated objects leave behind a 16-byte forwarding pointer structure at their original location to redirect subsequent references. This is critical to Cheney's algorithm implementation.

### Test Infrastructure

Property-based testing with RapidCheck (`test/main.cpp`):
- **Generators** (`test/generators.hpp`, `test/generators.cpp`): Create random heap graphs with controlled properties
- **HeapSnapshot**: Captures heap state before/after GC to validate correctness
- **Three core properties tested**:
  1. GC preserves all reachable objects (values unchanged)
  2. GC collects unreachable objects (memory reclaimed)
  3. Multiple GC cycles maintain correctness (no corruption over time)

When debugging test failures, use the `--reproduce` parameter with the provided reproduction string to get deterministic replay.

### Thread Safety Model
- **Nurseries**: Thread-local, no synchronization on fast path
- **Old generation**: Protected by recursive mutexes (allows GC to trigger during GC)
- **Root set**: Global lock for registration/updates
- **GarbageCollector singleton**: Single instance manages all spaces

### Statistics System

`runtime/include/gc_stats.hpp` provides comprehensive GC telemetry:
- **Zero overhead when disabled**: All macros compile to nothing when `ENABLE_GC_STATS` is not defined
- **Tracks**: Allocations, GC cycles, timing histograms, survival/promotion rates
- **Output**: Pretty-printed with Unicode bar charts at program end

To enable statistics, define `ENABLE_GC_STATS` before including `gc_stats.hpp` or add it as a compile definition.

## Key Files

- `runtime/include/allocator.hpp` (325 lines): GC system interface - NurserySpace, OldGenSpace, GarbageCollector classes
- `runtime/src/allocator.cpp` (908 lines): Complete GC implementation including Cheney's algorithm and mark-sweep
- `runtime/include/heap.hpp` (231 lines): All Elm value type definitions and object layouts
- `test/main.cpp` (816 lines): Property-based test runner with heap validation
- `test/generators.hpp` (260 lines): RapidCheck generators for creating random heap structures

## Important Constants

- `PROMOTION_AGE`: Currently set to 1 in `runtime/include/allocator.hpp` - objects promoted after surviving 1 minor GC
- Default nursery size: 4MB per thread
- Default heap reservation: 1GB total address space
- Object alignment: 8 bytes

## Git Workflow

When developing features or fixes, follow this branch-based workflow:

### Starting Work

1. **Create a feature branch** with a descriptive name:
   ```bash
   git checkout -b <descriptive-branch-name>
   ```
   Name branches after the task: `fix-nursery-overflow`, `add-tlab-support`, `refactor-gc-stats`

2. **Rebase onto master** to ensure you're starting from the latest code:
   ```bash
   git rebase master
   ```

### During Development

- Make incremental changes
- Test that changes work before committing

### Completing Work

1. **Ask user for confirmation** before committing - do not commit automatically
2. **Commit with a concise, well-written message** describing the change
3. **Rebase onto master again** in case it has changed:
   ```bash
   git rebase master
   ```
4. **Resolve any conflicts** if they occur
5. **Merge to master**:
   ```bash
   git checkout master
   git merge <branch-name>
   ```

### Important

- Never commit without user confirmation
- Never push to remote without user confirmation
- Keep commit messages concise but descriptive
- One logical change per commit

## Development Notes

When modifying the GC:
- Locking must use recursive mutexes because GC can trigger allocation (e.g., when expanding old gen)
- Object scanning in `scanObject()` must handle all types defined in `heap.hpp`
- Size calculation in `objectSize()` must match object layout exactly (8-byte aligned)
- Forwarding pointers are 16 bytes and must be recognizable by their tag
- Remember that Elm values are immutable - no write barriers or remembered sets needed
