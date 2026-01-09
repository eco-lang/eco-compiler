# Code Style and Conventions

## Style Definition Files

- **`/work/STYLE.md`** - Root level style guide (C++/runtime)
- **`/work/compiler/STYLE.md`** - Compiler style guide (Elm)

## C++ Style (Runtime)

### Language Standard
- **C++20** with modern features (concepts, ranges, etc.)
- Clang compiler with LLD linker

### Naming Conventions
- **Files**: PascalCase (`GarbageCollector.hpp`)
- **Classes**: PascalCase (`NurserySpace`)
- **Functions/Methods**: camelCase (`minorGC`, `allocate`)
- **Member variables**: snake_case (`heap_base`, `alloc_ptr`)
- **Local variables**: snake_case
- **Constants/Enums**: PascalCase (`Tag_Int`, `Const_Unit`)
- **Type aliases**: snake_case (`u64`, `i64`, `f64`)

### Types
Use project-defined fixed-width types from `Heap.hpp`:
- `u64` - unsigned 64-bit
- `u32` - unsigned 32-bit
- `i64` - signed 64-bit
- `f64` - double

### Formatting
- 4 spaces indentation (no tabs)
- 120 char soft limit, 140 hard limit
- Opening braces on same line
- Always use braces for conditionals
- `.clang-format` file provided for automatic formatting

### Comments
- Proper English sentences ending with periods
- `/** */` for class/struct documentation
- `//` for method comments (before method)
- Inline `//` for field comments (after field)
- `// ========== Section ==========` for section headings
- Document pre-conditions ("Caller must hold mutex.")

### Include Order
1. Standard library headers (`<memory>`, `<mutex>`)
2. Project headers (`"Heap.hpp"`)

### Header Guards
```cpp
#ifndef ECO_FILENAME_H
#define ECO_FILENAME_H
// ...
#endif
```

### Namespace
All code within `namespace Elm { }`

### Memory Management
- Use `mmap` for large regions
- `std::unique_ptr` for owned allocations
- Raw pointers for GC-managed objects

### Thread Safety
- `std::mutex` with `std::lock_guard`
- `thread_local` for TLS
- Recursive mutexes where GC can trigger allocation

## Elm Style (Compiler)

### Formatting
- Use `elm-format` for all Elm files
- Run `npm run elm-format` before commits

### Linting
- ESLint for JavaScript
- elm-review for Elm code

### Module Exposure
- Only expose public API functions
- Keep internal helpers private

## General Guidelines

- Avoid over-engineering; make minimal changes
- Don't add features beyond what was asked
- Keep solutions simple and focused
- Test changes before committing
- Avoid security vulnerabilities (injection, XSS, etc.)
