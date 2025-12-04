# Elm Kernel C++ Library Dependencies

This document summarizes the external C++ library dependencies required to implement the Elm kernel functions.

## Chosen Libraries

| Category | Library | Rationale |
|----------|---------|-----------|
| **JSON** | RapidJSON | Fast, full read/write support, DOM and SAX APIs |
| **Regex** | PCRE2 | Full JavaScript regex compatibility, JIT compilation |
| **HTTP** | Boost.Beast | Modern C++, async via Asio, WebSocket support |
| **Async** | std::jthread | No external dependencies, C++20 standard |
| **GUI/Browser** | WebAssembly (Emscripten) | Native DOM access, real browser environment |

---

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

| Module | Functions | Standard Library | Libraries Used |
|--------|-----------|------------------|----------------|
| **Platform** | 8 | None | WebAssembly for rendering |
| **Process** | 3 | `<chrono>`, `<thread>` | std::jthread |
| **Scheduler** | 22 | `<queue>`, `<functional>` | std::jthread |

### Data Modules

| Module | Functions | Standard Library | Libraries Used |
|--------|-----------|------------------|----------------|
| **Json** | 28 | None | RapidJSON |
| **Bytes** | 26 | `<bit>` (C++20), `<cstring>` | None |
| **Parser** | 7 | None | None |
| **Regex** | 6 | None | PCRE2 |
| **Url** | 2 | None | None |

### I/O Modules

| Module | Functions | Standard Library | Libraries Used |
|--------|-----------|------------------|----------------|
| **Time** | 4 | `<chrono>`, `<thread>` | std::jthread |
| **Http** | 8 | None | Boost.Beast |
| **File** | 12 | `<filesystem>` (C++17) | WebAssembly File API |

### Browser/DOM Modules (BROWSER_FUNCTION)

| Module | Functions | Libraries Used |
|--------|-----------|----------------|
| **Browser** | 20 | WebAssembly + Emscripten |
| **VirtualDom** | 25 | WebAssembly + Emscripten |

---

## Library Details

### 1. RapidJSON (JSON Processing)

**Version:** 1.1.0+
**License:** MIT
**Website:** https://rapidjson.org/

**Features used:**
- DOM API for parsing and building JSON
- SAX API for streaming large documents
- In-situ parsing for zero-copy performance
- UTF-8/UTF-16 transcoding

**Elm JSON Requirements:**
- Decode: primitives, objects, arrays, null
- Custom decoders with combinators (map, andThen, oneOf)
- Error messages with path tracking
- Encode: value construction and serialization

**Integration notes:**
- Header-only library
- No external dependencies
- Thread-safe for read operations

### 2. PCRE2 (Regular Expressions)

**Version:** 10.40+
**License:** BSD
**Website:** https://www.pcre.org/

**Features used:**
- Full Perl/JavaScript regex compatibility
- JIT compilation for performance
- Named capture groups
- Unicode support (UTF-8 and UTF-16)
- Global matching with `pcre2_match` iteration

**Elm Regex Requirements:**
- find/findAll with Match structure
- replace/replaceAll with substitutions
- contains check
- Match: { match, index, number, submatches }

**Integration notes:**
- Requires linking against `libpcre2-8` or `libpcre2-16`
- JIT requires additional `libpcre2-jit`
- Thread-safe when compiled patterns are not modified

### 3. Boost.Beast (HTTP Client)

**Version:** Boost 1.70+
**License:** Boost Software License
**Website:** https://www.boost.org/doc/libs/release/libs/beast/

**Features used:**
- HTTP/1.1 client with async support
- Request/response message types
- Body types: string, dynamic buffer, file
- Timeout handling via Asio
- SSL/TLS via Boost.Asio SSL

**Elm HTTP Requirements:**
- GET, POST, PUT, DELETE, etc.
- Request headers and body
- Response: status, headers, body (text/json/bytes)
- Timeout and progress tracking
- Multipart form data

**Integration notes:**
- Header-only (mostly)
- Requires Boost.Asio and Boost.System
- For SSL: requires OpenSSL

**Dependencies:**
- Boost.Asio (for async I/O)
- Boost.System (for error codes)
- OpenSSL (optional, for HTTPS)

### 4. std::jthread (Async/Event Loop)

**Version:** C++20
**License:** N/A (standard library)

**Features used:**
- `std::jthread` for cooperative cancellation
- `std::stop_token` for cancellation signaling
- `std::condition_variable_any` for waiting with stop tokens
- `std::chrono` for timing

**Elm Scheduler Requirements:**
- Task queuing and execution
- Process spawning and killing
- Timer (sleep, interval)
- Effect manager integration

**Implementation approach:**
- Single-threaded event loop with task queue
- `std::jthread` for background timers
- `std::condition_variable` for blocking waits
- Manual event loop rather than external library

### 5. WebAssembly + Emscripten (Browser/GUI)

**Version:** Emscripten 3.0+
**License:** MIT (Emscripten), various (browser APIs)
**Website:** https://emscripten.org/

**Features used:**
- Native DOM manipulation via `emscripten::val`
- JavaScript interop for browser APIs
- requestAnimationFrame binding
- Event listener registration
- History/URL APIs
- File API (upload/download)

**Elm Browser Requirements:**
- sandboxed, element, document, application
- requestAnimationFrame equivalent
- DOM manipulation
- Event handling
- Focus/blur management
- URL/History API (for navigation)

**Integration notes:**
- Compile with `emcc` instead of `clang++`
- Use `-s WASM=1` for WebAssembly output
- Use `-s MODULARIZE=1` for module pattern
- Browser APIs accessed via `EM_JS` or `emscripten::val`

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
- `std::jthread` - Cooperative threading
- `std::stop_token` - Cancellation
- `<format>` - String formatting (optional)
- Concepts (optional, for type constraints)

---

## Build System Integration

### CMake Configuration

```cmake
cmake_minimum_required(VERSION 3.16)
project(elm-kernel LANGUAGES CXX)

# Require C++20
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# RapidJSON (header-only)
find_package(RapidJSON REQUIRED)
target_include_directories(elm-kernel PRIVATE ${RAPIDJSON_INCLUDE_DIRS})

# PCRE2
find_package(PkgConfig REQUIRED)
pkg_check_modules(PCRE2 REQUIRED libpcre2-8)
target_include_directories(elm-kernel PRIVATE ${PCRE2_INCLUDE_DIRS})
target_link_libraries(elm-kernel PRIVATE ${PCRE2_LIBRARIES})

# Boost.Beast (requires Boost.Asio, Boost.System)
find_package(Boost 1.70 REQUIRED COMPONENTS system)
target_link_libraries(elm-kernel PRIVATE Boost::system)

# OpenSSL (for HTTPS)
find_package(OpenSSL REQUIRED)
target_link_libraries(elm-kernel PRIVATE OpenSSL::SSL OpenSSL::Crypto)

# Threading
find_package(Threads REQUIRED)
target_link_libraries(elm-kernel PRIVATE Threads::Threads)
```

### Emscripten Build

```cmake
if(EMSCRIPTEN)
    set(CMAKE_EXECUTABLE_SUFFIX ".js")
    target_link_options(elm-kernel PRIVATE
        -s WASM=1
        -s MODULARIZE=1
        -s EXPORT_NAME="ElmKernel"
        -s ALLOW_MEMORY_GROWTH=1
        -s NO_EXIT_RUNTIME=1
    )
endif()
```

### Package Installation (Ubuntu/Debian)

```bash
# RapidJSON
sudo apt-get install rapidjson-dev

# PCRE2
sudo apt-get install libpcre2-dev

# Boost
sudo apt-get install libboost-system-dev libboost-dev

# OpenSSL
sudo apt-get install libssl-dev

# Emscripten (via emsdk)
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk && ./emsdk install latest && ./emsdk activate latest
```

---

## Function Count by Category

| Category | Modules | Functions | External Deps |
|----------|---------|-----------|---------------|
| Core | 9 | 105 | None |
| Data | 5 | 69 | RapidJSON, PCRE2 |
| I/O | 3 | 24 | Boost.Beast |
| Browser/DOM | 2 | 45 | Emscripten |
| **Total** | **19** | **243** | |

---

## BROWSER_FUNCTION Summary

Functions marked as `BROWSER_FUNCTION` require browser/DOM APIs. With WebAssembly + Emscripten, these map directly to browser APIs:

### Browser.cpp (20 functions)
- All program initialization (element, document, application)
- Animation frame handling → `requestAnimationFrame`
- URL/navigation management → History API
- DOM event coordination → `addEventListener`

### VirtualDom.cpp (25 functions)
- Node creation and rendering → `document.createElement`
- Event handler attachment → `addEventListener`
- DOM diffing and patching → Direct DOM manipulation
- Focus/blur management → `element.focus()`, `element.blur()`
- Custom element integration → Custom Elements API

### File.cpp (partial - 8 functions)
- File upload dialogs → `<input type="file">`
- File download triggers → `<a download>`, `URL.createObjectURL`
- File content reading → FileReader API
- File decoder for events → `event.target.files`

---

## Architecture Notes

### Threading Model

With `std::jthread` for async:
- Main thread runs the Elm event loop
- Background threads for timers and I/O
- Task queue protected by mutex
- Condition variable for waking main thread

```
┌─────────────────────────────────────────┐
│            Main Thread                  │
│  ┌─────────────────────────────────┐   │
│  │     Elm Scheduler Loop          │   │
│  │  - Process task queue           │   │
│  │  - Run effects                  │   │
│  │  - Update model                 │   │
│  │  - Render view                  │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
         ▲                    ▲
         │                    │
    ┌────┴────┐          ┌────┴────┐
    │ Timer   │          │  HTTP   │
    │ Thread  │          │ Thread  │
    └─────────┘          └─────────┘
```

### WebAssembly Integration

```
┌─────────────────────────────────────────┐
│              Browser                    │
│  ┌─────────────────────────────────┐   │
│  │         JavaScript              │   │
│  │  - Event dispatch               │   │
│  │  - requestAnimationFrame        │   │
│  │  - DOM API wrappers             │   │
│  └──────────────┬──────────────────┘   │
│                 │ Emscripten bindings  │
│  ┌──────────────▼──────────────────┐   │
│  │      WebAssembly Module         │   │
│  │  - Elm Kernel (C++)             │   │
│  │  - Virtual DOM diffing          │   │
│  │  - Scheduler                    │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```
