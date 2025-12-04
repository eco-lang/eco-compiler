# Elm Kernel C++ Library Dependencies

This document summarizes the external C++ library dependencies required to implement the Elm kernel functions.

## Summary by Module

### Core Modules (No External Dependencies)

These modules can be implemented using only C++ standard library features:

| Module | Functions | Notes |
|--------|-----------|-------|
| **Basics** | 31 | Math operations, comparisons, string conversion |
| **Bitwise** | 7 | Bit manipulation (standard operators) |
| **Char** | 7 | Unicode handling, uses `<locale>` or manual tables |
| **String** | 26 | UTF-16 string operations |
| **List** | 8 | Cons-cell list operations |
| **JsArray** | 12 | Dynamic array (std::vector equivalent) |
| **Utils** | 10 | Equality, comparison, value creation |
| **Debug** | 2 | Logging, crash handling |
| **Debugger** | 2 | Browser-specific (stub in C++) |

### Platform/Scheduler Modules

| Module | Functions | Standard Library | Optional Libraries |
|--------|-----------|------------------|-------------------|
| **Platform** | 8 | None | GUI framework for rendering |
| **Process** | 3 | `<chrono>` | libuv, Boost.Asio for async |
| **Scheduler** | 22 | `<queue>`, `<functional>` | libuv, Boost.Asio for event loop |

### Data Modules

| Module | Functions | Standard Library | Recommended Libraries |
|--------|-----------|------------------|----------------------|
| **Json** | 28 | None | RapidJSON, nlohmann/json, simdjson |
| **Bytes** | 26 | `<bit>` (C++20), `<cstring>` | None |
| **Parser** | 7 | None | None |
| **Regex** | 6 | `<regex>` | RE2, PCRE2, Boost.Regex |
| **Url** | 2 | None | None |

### I/O Modules

| Module | Functions | Standard Library | Required Libraries |
|--------|-----------|------------------|-------------------|
| **Time** | 4 | `<chrono>` | libuv, Boost.Asio (timers) |
| **Http** | 8 | None | libcurl, cpp-httplib, Boost.Beast |
| **File** | 12 | `<filesystem>` (C++17) | Platform file dialogs |

### Browser/DOM Modules (BROWSER_FUNCTION)

| Module | Functions | Notes |
|--------|-----------|-------|
| **Browser** | 20 | Requires GUI framework or WebAssembly |
| **VirtualDom** | 25 | Requires DOM-like API |

---

## Detailed Library Recommendations

### 1. JSON Processing

**Options (in order of recommendation):**

1. **simdjson** - Fastest JSON parser
   - Pros: Exceptional performance, SIMD-accelerated
   - Cons: Read-only, no serialization
   - Use for: Decoding only

2. **RapidJSON** - Fast and full-featured
   - Pros: Very fast, read/write, DOM and SAX APIs
   - Cons: More complex API
   - Use for: Full JSON support

3. **nlohmann/json** - Modern C++ API
   - Pros: Beautiful API, easy to use
   - Cons: Slower than alternatives
   - Use for: Developer productivity

**Elm JSON Requirements:**
- Decode: primitives, objects, arrays, null
- Custom decoders with combinators (map, andThen, oneOf)
- Error messages with path tracking

### 2. Regular Expressions

**Options (in order of recommendation):**

1. **RE2** - Google's regex library
   - Pros: Linear time guarantee, thread-safe
   - Cons: No backreferences, no lookahead
   - Use for: Performance-critical, safe patterns

2. **PCRE2** - Perl Compatible Regular Expressions
   - Pros: Full regex features, JIT compilation
   - Cons: Potential exponential blowup on pathological patterns
   - Use for: Full JS regex compatibility

3. **Boost.Regex** - Part of Boost
   - Pros: Full-featured, well-tested
   - Cons: Boost dependency
   - Use for: Projects already using Boost

4. **std::regex** - Standard library
   - Pros: No external dependency
   - Cons: Poor performance, limited features
   - Use for: Simple patterns only

**Elm Regex Requirements:**
- find/findAll with Match structure
- replace/replaceAll with substitutions
- contains check
- Match: { match, index, number, submatches }

### 3. HTTP Client

**Options (in order of recommendation):**

1. **libcurl** - The de facto standard
   - Pros: Extremely mature, all protocols, async support
   - Cons: C API, requires careful memory management
   - Use for: Production systems

2. **cpp-httplib** - Header-only simplicity
   - Pros: Single header, easy to use, modern C++
   - Cons: Fewer features, sync by default
   - Use for: Simple HTTP needs

3. **Boost.Beast** - Boost's HTTP/WebSocket
   - Pros: Modern C++, async via Asio, WebSocket support
   - Cons: Boost dependency, steeper learning curve
   - Use for: High-performance async needs

**Elm HTTP Requirements:**
- GET, POST, PUT, DELETE, etc.
- Request headers and body
- Response: status, headers, body (text/json/bytes)
- Timeout and progress tracking
- Multipart form data

### 4. Async/Event Loop

**Options (in order of recommendation):**

1. **libuv** - Node.js's event loop
   - Pros: Battle-tested, cross-platform, full-featured
   - Cons: C API
   - Use for: Full async runtime

2. **Boost.Asio** - Boost's async I/O
   - Pros: Modern C++, networking + timers
   - Cons: Boost dependency
   - Use for: Networking-focused apps

3. **std::jthread + std::condition_variable** - Standard only
   - Pros: No dependencies
   - Cons: Manual event loop implementation
   - Use for: Simple cases

**Elm Scheduler Requirements:**
- Task queuing and execution
- Process spawning and killing
- Timer (sleep, interval)
- Effect manager integration

### 5. GUI Framework (for Browser module)

**Options:**

1. **WebAssembly + Emscripten**
   - Pros: Real browser, native DOM
   - Cons: Browser-only deployment
   - Use for: Web target

2. **Qt** - Cross-platform GUI
   - Pros: Mature, full-featured, QtWebEngine for HTML
   - Cons: Large, licensing considerations
   - Use for: Desktop apps

3. **GTK** - Linux-native GUI
   - Pros: Open source, WebKitGTK for HTML
   - Cons: Less portable
   - Use for: Linux-focused apps

4. **Custom Virtual DOM** - Headless rendering
   - Pros: No GUI dependency, testable
   - Cons: No visual output
   - Use for: Server-side or testing

**Elm Browser Requirements:**
- sandboxed, element, document, application
- requestAnimationFrame equivalent
- DOM manipulation
- Event handling
- Focus/blur management
- URL/History API (for navigation)

---

## C++ Standard Library Requirements

### C++17 Features Used
- `<filesystem>` - File operations
- `std::optional` - Maybe type
- `std::variant` - Sum types
- `std::string_view` - Efficient string passing
- Structured bindings

### C++20 Features Used
- `<bit>` - `std::bit_cast` for type punning
- `std::endian` - Endianness detection
- `<format>` - String formatting (optional)
- Concepts (optional, for type constraints)
- Ranges (optional, for list operations)

---

## Minimal Dependency Configuration

For a minimal implementation with fewest dependencies:

```
Core modules:        C++ standard library only
JSON:               nlohmann/json (header-only)
Regex:              std::regex (limited but no deps)
HTTP:               cpp-httplib (header-only)
Async:              std::thread + std::chrono
File:               std::filesystem
Browser:            WebAssembly/Emscripten
```

## Full-Featured Configuration

For maximum performance and compatibility:

```
Core modules:        C++ standard library only
JSON:               RapidJSON or simdjson
Regex:              PCRE2 (full JS regex compat)
HTTP:               libcurl
Async:              libuv
File:               std::filesystem + platform dialogs
Browser:            Qt with QtWebEngine
```

---

## Build System Integration

### CMake Find Modules

```cmake
# JSON (example with nlohmann/json)
find_package(nlohmann_json REQUIRED)
target_link_libraries(elm-kernel PRIVATE nlohmann_json::nlohmann_json)

# Regex with PCRE2
find_package(PkgConfig REQUIRED)
pkg_check_modules(PCRE2 REQUIRED libpcre2-8)
target_link_libraries(elm-kernel PRIVATE ${PCRE2_LIBRARIES})

# HTTP with libcurl
find_package(CURL REQUIRED)
target_link_libraries(elm-kernel PRIVATE CURL::libcurl)

# Async with libuv
find_package(libuv REQUIRED)
target_link_libraries(elm-kernel PRIVATE uv)
```

---

## Function Count by Category

| Category | Modules | Functions | External Deps Required |
|----------|---------|-----------|----------------------|
| Core | 9 | 105 | No |
| Data | 5 | 69 | JSON lib, Regex lib |
| I/O | 3 | 24 | HTTP lib, Timer lib |
| Browser/DOM | 2 | 45 | GUI framework |
| **Total** | **19** | **243** | |

Note: Some functions overlap or have been consolidated from the original 271 count.

---

## BROWSER_FUNCTION Summary

Functions marked as `BROWSER_FUNCTION` require browser/DOM APIs and need alternative implementations for native C++:

### Browser.cpp (20 functions)
- All program initialization (element, document, application)
- Animation frame handling
- URL/navigation management
- DOM event coordination

### VirtualDom.cpp (25 functions)
- Node creation and rendering
- Event handler attachment
- DOM diffing and patching
- Focus/blur management
- Custom element integration

### File.cpp (partial - 8 functions)
- File upload dialogs (uploadOne, uploadOneOrMore)
- File download triggers (download, downloadUrl)
- File content reading (toString, toBytes, toUrl)
- File decoder for events

**Native alternatives:**
- Qt: `QFileDialog`, `QWebEngineView`
- GTK: `GtkFileChooserDialog`, `WebKitGTK`
- Headless: In-memory DOM representation for testing
