# Code Style Guide

This document defines the coding conventions for the eco-runtime project.

## Language Standard

- **C++20** is the target language standard
- Use modern C++ features where appropriate (concepts, ranges, etc.)
- Avoid C-style constructs unless interfacing with system APIs

## File Organization

### Header Files

- Use `#ifndef` include guards with format: `ECO_<FILENAME>_H`
- Example: `#ifndef ECO_GARBAGECOLLECTOR_H`
- Place include guards on lines 1 and last line
- Organize includes in this order:
  1. Standard library headers (`<memory>`, `<mutex>`, etc.)
  2. Project headers (`"AllocatorCommon.hpp"`, etc.)
- All code within `namespace Elm { }`

### Source Files

- `.cpp` files for implementations, `.hpp` for headers
- Include corresponding header first in `.cpp` files
- Then system headers, then project headers

### Naming Conventions

- **Files**: PascalCase (e.g., `GarbageCollector.hpp`, `NurserySpace.cpp`)
- **Classes**: PascalCase (e.g., `GarbageCollector`, `NurserySpace`)
- **Functions/Methods**: camelCase (e.g., `allocate`, `minorGC`, `getHeapBase`)
- **Member variables**: snake_case (e.g., `heap_base`, `alloc_ptr`, `next_nursery_offset`)
- **Local variables**: snake_case
- **Constants**: PascalCase for enums (e.g., `Tag_Int`, `Const_Unit`)
- **Type aliases**: snake_case with suffix (e.g., `u64`, `i64`, `f64`)

### Types

#### Primitive Type Aliases

Use project-defined fixed-width types from `Heap.hpp`:

```cpp
u64   // unsigned long long int (64-bit)
u32   // unsigned int (32-bit)
u16   // unsigned short (16-bit)
i64   // long long int (signed 64-bit)
f64   // double (64-bit float)
```

#### Standard Library Types

Use standard library types appropriately:
- `size_t` for sizes and capacities
- `std::thread::id` for thread identifiers
- `std::unique_ptr<T>` for owned heap allocations
- `std::vector<T>`, `std::unordered_map<K,V>` for containers

### Enumerations

- Use C-style `typedef enum` for heap tags and constants
- Prefix enum values with type name: `Tag_Int`, `Const_Unit`
- Place on separate lines for readability

```cpp
typedef enum {
    Tag_Int,
    Tag_Float,
    Tag_Char,
    // ...
} Tag;
```

### Structures

- Use C-style `typedef struct` for POD heap objects
- PascalCase for struct names
- Prefix member names with type hints where appropriate (e.g., `n_values`, `max_values`)
- Use bitfields for compact representation
- Always include `static_assert` for size validation:

```cpp
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2;
    // ...
    u32 size;
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");
```

### Classes

#### Member Ordering

1. Public interface first
2. Private implementation details last
3. Within each section:
   - Static methods
   - Constructors/destructors
   - Regular methods
   - Member variables

#### Access Specifiers

```cpp
class Example {
public:
    // Public interface

private:
    // Private implementation
};
```

### Comments

#### Block Comments

Use C-style block comments for multi-line documentation:

```cpp
/** Headers are always 64-bits in size, and every heap element always has a
header at its start. The first 5-bits contain a tag, denoting which kind of
heap element it is.
*/
```

#### Inline Comments

Use C++ style `//` for single-line comments and inline annotations:

```cpp
// Main GC controller
char *heap_base; // Base pointer for entire heap
```

#### Section Separators

Use decorative separators in test/generator files:

```cpp
// ============================================================================
// Data Structures - Describe heap objects without side effects
// ============================================================================
```

### Code Formatting

#### Indentation

- **4 spaces** per indentation level (no tabs)
- Continuation lines aligned appropriately

#### Braces

- Opening brace on same line for functions, control structures, and classes
- Closing brace on its own line

```cpp
void function() {
    if (condition) {
        // code
    }
}
```

#### Line Length

- Soft limit: 120 characters
- Hard limit: Avoid exceeding 140 characters
- Break long parameter lists across multiple lines

#### Spacing

- Space after keywords: `if (`, `while (`, `for (`
- Space around binary operators: `a + b`, `x = y`
- No space after unary operators: `!flag`, `++i`
- No space inside parentheses: `(expr)` not `( expr )`
- Space after commas: `foo(a, b, c)`

#### Initialization

Use constructor initialization lists:

```cpp
GarbageCollector::GarbageCollector() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0),
    nursery_offset(0), next_nursery_offset(0), initialized(false) {
    // Constructor body
}
```

### Control Flow

#### Conditionals

Always use braces, even for single statements:

```cpp
if (condition) {
    statement();
}
```

Multi-line conditions align naturally:

```cpp
if (condition1 &&
    condition2) {
    // code
}
```

#### Early Returns

Prefer early returns for error conditions:

```cpp
void function() {
    if (!initialized)
        return;

    // Main logic
}
```

#### Switch Statements

```cpp
switch (tag) {
    case Tag_String:
        // Handle string
        break;
    case Tag_Custom:
        // Handle custom
        break;
    default:
        // Default case
        break;
}
```

### Memory Management

#### Allocation

- Use system `mmap` for large memory regions
- Use `std::make_unique` for unique ownership
- Use raw pointers for GC-managed heap objects

#### Thread Safety

- Use `std::mutex` and `std::lock_guard<std::mutex>` for synchronization
- Use `thread_local` for thread-local storage
- Document locking requirements in comments

```cpp
std::lock_guard<std::mutex> lock(nursery_mutex);
```

### Modern C++ Features

#### Auto

Use `auto` when type is obvious from context:

```cpp
auto it = nurseries.find(tid);  // Iterator type obvious
auto nursery = std::make_unique<NurserySpace>();  // Type in initializer
```

Avoid `auto` when type clarity is important:

```cpp
size_t byte_offset = calculate();  // Not: auto byte_offset = calculate();
```

#### Range-Based Loops

Prefer range-based for loops:

```cpp
for (size_t &idx: graph.root_indices) {
    idx = idx % graph.nodes.size();
}
```

#### Nullptr

Always use `nullptr`, never `NULL` or `0` for pointers:

```cpp
if (ptr == nullptr) { }
```

### Const Correctness

- Mark methods `const` when they don't modify state
- Use `const &` for read-only parameters of non-trivial types
- Use `const` for local variables that won't change

```cpp
bool contains(void *ptr) const;
size_t bytesAllocated() const { return alloc_ptr - from_space; }
```

### Template Usage

#### RapidCheck Generators

When defining RapidCheck generators:

```cpp
template<>
struct Arbitrary<Elm::TypeName> {
    static Gen<Elm::TypeName> arbitrary() {
        return gen::build<Elm::TypeName>(
            gen::set(&Elm::TypeName::field, gen::arbitrary<Type>())
        );
    }
};
```

### Preprocessor

#### Macros

- Minimize macro usage
- Use `constexpr` instead of `#define` for constants
- Use `inline` functions instead of function macros

Acceptable macro uses:
- Include guards
- Conditional compilation (`#if ENABLE_GC_STATS`)
- Alignment attributes (`#define ALIGN(X) __attribute__((aligned(X)))`)

#### Conditional Compilation

```cpp
#if ENABLE_GC_STATS
    GCStats stats;
#endif
```

### Error Handling

- Use exceptions for allocation failures (`std::bad_alloc`)
- Use assertions for internal invariants (`assert`, `static_assert`)
- Return `nullptr` or early return for recoverable errors

### Documentation

#### Class Documentation

Brief comment above class definition:

```cpp
// Main GC controller
class GarbageCollector {
```

#### Method Documentation

Comment significant methods:

```cpp
// Initialize GC with max heap size (default 1GB)
void initialize(size_t max_heap_size = 1ULL * 1024 * 1024 * 1024);
```

#### Implementation Comments

Explain non-obvious logic:

```cpp
// Prevent recursive GC calls
if (gc_in_progress) {
    return;
}
```

### Project-Specific Conventions

#### Heap Objects

- All heap objects start with `Header`
- All heap objects must be 8-byte aligned
- Use `static_assert` to validate object sizes

#### Logical Pointers

- Use `HPointer` for heap references
- Convert with `fromPointer()` and `toPointer()` helpers
- Pointers are 40-bit offsets, not absolute addresses

#### GC Integration

- Use `GarbageCollector::instance()` singleton
- Thread-local nurseries via `getNursery()`
- Root set management via `getRootSet()`

#### Statistics

- Wrap stats code in `#if ENABLE_GC_STATS`
- Use `RECORD_` macros from `GCStats.hpp`

### Testing Conventions

#### Property-Based Tests

- Use RapidCheck for property testing
- Separate descriptions from allocation (`HeapObjectDesc` vs actual objects)
- Use generators to create random test data
- Document test properties clearly

```cpp
RC_GTEST_PROP(GarbageCollector, PreservesReachableObjects, (const HeapGraphDesc &graph_desc)) {
    // Test implementation
}
```

## Tools

### Recommended

- **clang-format**: Automatic code formatting (configuration to be added)
- **clang-tidy**: Static analysis and linting
- **cmake**: Build system (see CLAUDE.md for build commands)

## References

- See `CLAUDE.md` for project architecture and build instructions
- See design documents in `design_docs/gc/` for GC algorithms
