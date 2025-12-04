# Plan: Elm Kernel C++ Pseudocode Documentation

## Overview

This plan describes the work to document each C++ kernel stub function with pseudocode derived from the corresponding JavaScript implementation, identify helper functions, and catalog required C++ library dependencies.

## Scope

- **271 stub functions** across 22 source files in 11 packages
- **~27 JavaScript kernel files** to analyze
- Output: Pseudocode comments in each C++ stub + library dependency catalog

## Work Breakdown

### Phase 1: Core Package (Priority: Highest)

The core package is foundational - other packages depend on it.

| Module | Stubs | JS Source | Complexity | Notes |
|--------|-------|-----------|------------|-------|
| Basics | 30 | `core/src/Elm/Kernel/Basics.js` | Low | Mostly math, direct mappings |
| Bitwise | 7 | `core/src/Elm/Kernel/Bitwise.js` | Low | Bit operations |
| Char | 6 | `core/src/Elm/Kernel/Char.js` | Low | Unicode char handling |
| String | 29 | `core/src/Elm/Kernel/String.js` | Medium | UTF-16 surrogate pair handling |
| List | 9 | `core/src/Elm/Kernel/List.js` | Medium | Linked list operations |
| JsArray | 14 | `core/src/Elm/Kernel/JsArray.js` | Medium | Array operations for RRB trees |
| Utils | 8 | `core/src/Elm/Kernel/Utils.js` | Medium | Comparison, equality |
| Debug | 3 | `core/src/Elm/Kernel/Debug.js` | Low | Logging, crash |
| Debugger | 8 | `core/src/Elm/Kernel/Debugger.js` | High | BROWSER_FUNCTION - time travel debugger |
| Platform | 5 | `core/src/Elm/Kernel/Platform.js` | High | Effect system core |
| Process | 1 | `core/src/Elm/Kernel/Process.js` | Medium | Sleep task |
| Scheduler | 6 | `core/src/Elm/Kernel/Scheduler.js` | High | Task execution engine |

**Estimated effort**: 126 functions, ~3-4 hours

### Phase 2: Data Packages (Priority: High)

| Module | Stubs | JS Source | Complexity | Notes |
|--------|-------|-----------|------------|-------|
| Json | 32 | `json/src/Elm/Kernel/Json.js` | High | JSON parsing/encoding |
| Bytes | 26 | `bytes/src/Elm/Kernel/Bytes.js` | Medium | Binary data, endianness |
| Parser | 7 | `parser/src/Elm/Kernel/Parser.js` | Medium | Parser combinator primitives |
| Regex | 6 | `regex/src/Elm/Kernel/Regex.js` | Medium | Regex wrapper |
| Url | 2 | `url/src/Elm/Kernel/Url.js` | Low | URL encode/decode |

**Estimated effort**: 73 functions, ~2 hours

### Phase 3: I/O Packages (Priority: Medium)

| Module | Stubs | JS Source | Complexity | Notes |
|--------|-------|-----------|------------|-------|
| Time | 4 | `time/src/Elm/Kernel/Time.js` | Low | System time, timers |
| Http | 8 | `http/src/Elm/Kernel/Http.js` | High | HTTP client - needs library |
| File | 13 | `file/src/Elm/Kernel/File.js` | Medium | File I/O - needs library |

**Estimated effort**: 25 functions, ~1.5 hours

### Phase 4: Browser/DOM Packages (Priority: Low for native)

| Module | Stubs | JS Source | Complexity | Notes |
|--------|-------|-----------|------------|-------|
| Browser | 22 | `browser/src/Elm/Kernel/Browser.js` | High | Mostly BROWSER_FUNCTION |
| VirtualDom | 25 | `virtual-dom/src/Elm/Kernel/VirtualDom.js` | Very High | DOM rendering - BROWSER_FUNCTION |

**Estimated effort**: 47 functions, ~2 hours (mostly marking as BROWSER_FUNCTION)

## Output Format

Each C++ stub function will be updated with a comment block:

```cpp
double add(double a, double b) {
    /*
     * JS: var _Basics_add = F2(function(a, b) { return a + b; });
     *
     * PSEUDOCODE:
     * - Return a + b
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Basics.add not implemented");
}
```

For browser-specific functions:

```cpp
Value* element(Value* impl) {
    /*
     * BROWSER_FUNCTION
     *
     * JS: var _Browser_element = F4(function(impl, flagDecoder, debugMetadata, args) { ... });
     *
     * This function initializes an Elm program attached to a DOM node.
     * It requires browser DOM APIs (document, requestAnimationFrame, etc.)
     * and is not applicable for native/server-side execution.
     *
     * PSEUDOCODE:
     * - Initialize Platform with decoder, args, init, update, subscriptions
     * - Get DOM node from args
     * - Virtualize existing DOM
     * - Create animator that diffs and patches DOM on each model update
     * - Return program handle
     *
     * HELPERS:
     * - _Browser_makeAnimator
     * - _VirtualDom_virtualize
     * - __VirtualDom_diff
     * - __VirtualDom_applyPatches
     *
     * LIBRARIES: DOM API (not applicable for C++)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.element not implemented");
}
```

## Library Dependencies Catalog

As we process each function, we'll build a catalog grouped by area:

### 1. Standard C++ (no external libs)
- Math functions (cmath)
- String operations (std::string, std::u16string)
- Containers (std::vector, std::unordered_map)
- Memory (smart pointers)
- Threading (std::thread, std::mutex)

### 2. Unicode/Text Processing
- UTF-16 surrogate pair handling
- Case conversion (locale-aware)
- Options: ICU, utf8cpp, or custom

### 3. JSON
- Parsing and serialization
- Options: nlohmann/json, rapidjson, simdjson

### 4. Regular Expressions
- PCRE-compatible regex
- Options: std::regex, RE2, PCRE2

### 5. HTTP Client
- Async HTTP requests
- Options: libcurl, cpp-httplib, Boost.Beast

### 6. File I/O
- File reading/writing
- MIME type detection
- Options: std::filesystem + custom, or platform-specific

### 7. Time
- System time, monotonic time
- Timezone handling
- Options: std::chrono, date.h (Howard Hinnant)

### 8. Concurrency/Async
- Task scheduling
- Event loop
- Options: libuv, Boost.Asio, custom

## Execution Steps

For each package in priority order:

1. **Read JS source file** - Understand the implementation
2. **For each exported function**:
   - Find corresponding C++ stub
   - Write JS source snippet in comment
   - Write pseudocode translation
   - List helper functions used (recursively if needed)
   - Note library dependencies
3. **Update library catalog** with any new dependencies found
4. **Commit changes** after each package

## Success Criteria

- [ ] All 271 stub functions have pseudocode comments
- [ ] BROWSER_FUNCTION markers on DOM-dependent functions
- [ ] Complete helper function inventory per module
- [ ] Library dependency catalog with options for each area
- [ ] Clear indication of which functions are implementable vs browser-only

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Complex JS patterns hard to translate | Focus on semantics, not syntax |
| Hidden dependencies in helpers | Recursively trace helper functions |
| Browser-specific code pervasive | Mark clearly, document what would be needed for headless |
| Time estimate too low | Start with simpler modules, adjust as needed |

## Next Steps After This Plan

1. Review library options and make selections
2. Implement core data types (List, Array representations)
3. Implement Basics and Utils first (no external deps)
4. Build up from there based on dependency order
