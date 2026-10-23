# Elm Kernel C++ Library Dependencies

This document summarizes the external C++ library dependencies used by the Elm kernel functions.
`CMakeLists.txt` in this directory is the authoritative source.

## Chosen Libraries

| Category | Library | Notes |
|----------|---------|-------|
| **JSON** | nlohmann/json 3.11.3 | Header-only, vendored at `vendor/nlohmann/json.hpp` |
| **Regex** | SRELL 4.140 | Header-only std::regex-like library with ECMAScript syntax, vendored at `vendor/srell.hpp` |
| **HTTP** | libcurl + OpenSSL | IO runs on the runtime's `HttpService` worker thread (Windows: vendored libcurl with schannel, no OpenSSL) |
| **Async** | Runtime services | `Scheduler`, `TimerService`, `HttpService` in `runtime/src/platform/` |
| **Browser/DOM** | None | Native kernels; there is no WebAssembly/Emscripten build |

---

## Summary by Module

### Core Modules (No External Dependencies)

These modules use only the C++ standard library and the Eco runtime:

| Module | Functions | Notes |
|--------|-----------|-------|
| **Basics** | 31 | Math operations, comparisons, string conversion |
| **Bitwise** | 7 | Bit manipulation (standard operators) |
| **Char** | 7 | Character classification and case conversion |
| **String** | 26 | UTF-16 string operations |
| **List** | 8 | Cons-cell list operations |
| **JsArray** | 12 | Dynamic array |
| **Utils** | 10 | Equality, comparison, value creation |
| **Debug** | 2 | Logging, crash handling |
| **Debugger** | 2 | Browser-specific (stub in C++) |

### Platform/Scheduler Modules

| Module | Functions | Libraries Used |
|--------|-----------|----------------|
| **Platform** | 8 | Runtime `PlatformRuntime` / `Scheduler` |
| **Process** | 3 | Runtime `Scheduler`, `TimerService` |
| **Scheduler** | 22 | Runtime `Scheduler` |

### Data Modules

| Module | Functions | Standard Library | Libraries Used |
|--------|-----------|------------------|----------------|
| **Json** | 28 | None | nlohmann/json |
| **Bytes** | 26 | `<bit>` (C++20), `<cstring>` | None |
| **Parser** | 7 | None | None |
| **Regex** | 6 | None | SRELL |
| **Url** | 2 | None | None |

### I/O Modules

| Module | Functions | Libraries Used |
|--------|-----------|----------------|
| **Time** | 4 | Runtime `TimerService` |
| **Http** | 8 | libcurl + OpenSSL via runtime `HttpService` |
| **File** | 12 | None |

### Browser/DOM Modules (BROWSER_FUNCTION)

| Module | Functions | Libraries Used |
|--------|-----------|----------------|
| **Browser** | 20 | None (program constructors; navigation functions are not implemented in the native runtime) |
| **VirtualDom** | 25 | None (native heap DOM model, XSS filters and HTML writer; plans/elm-html-native-kernel.md) |

---

## Library Details

### 1. nlohmann/json (JSON Processing)

**Version:** 3.11.3 (vendored)
**License:** MIT
**Website:** https://github.com/nlohmann/json

`json/JsonExports.cpp` parses JSON text into `nlohmann::json` and converts it to the heap-resident
`Json.Value` ADT (and back for encoding). `json/JsonRead.cpp` is a read-only view of the heap forms
and uses no external library.

### 2. SRELL (Regular Expressions)

**Version:** 4.140 (vendored)
**License:** BSD-2-Clause
**Website:** https://www.akenotsuki.com/misc/srell/en/

`regex/Regex.cpp` and `regex/RegexExports.cpp` implement `Regex.fromStringWith`, `find`, `replace`,
`split` and `contains` with SRELL, which follows ECMAScript regex semantics (matching the JS kernel).
Header-only; no link dependency.

### 3. libcurl + OpenSSL (HTTP Client)

`http/HttpExports.cpp` and `http/HttpEffectManager.cpp` never perform network IO themselves: they
submit POD requests to `Elm::Platform::HttpService` (`runtime/src/platform/HttpService.hpp`), whose
single worker thread runs libcurl and posts results back to the scheduler thread.

**Integration notes:**
- Under `ECO_STATIC` the vendored `libcurl_static` target is used; otherwise `find_package(CURL)`.
- Linux/macOS link OpenSSL (`OpenSSL::SSL`, `OpenSSL::Crypto`).
- Windows uses the vendored libcurl with the schannel TLS backend; OpenSSL is not used
  (plans/build-on-windows.md).

### 4. Runtime services (Async/Event Loop)

There is no external async library. The Eco runtime provides:
- `Scheduler`: single-threaded Elm process scheduler and event loop (the only thread that touches
  the heap).
- `TimerService`: a timer worker thread that delivers expirations as plain tokens to the scheduler
  thread (used by Time and Process.sleep).
- `HttpService`: the HTTP worker thread described above.

Workers hold only POD state and never touch the GC heap; all heap interaction happens on the
scheduler thread.

---

## C++ Standard Library Requirements

All modules are built as C++20 (`cxx_std_20`). Notable features used:
- `<bit>` - `std::bit_cast` for type punning, `std::endian`
- `<filesystem>`, `std::optional`, `std::variant`, `std::string_view`
- `<thread>`, `<mutex>`, `<condition_variable>` (in the runtime services)

---

## Build System Integration

Each module is a static library (`ElmKernel_<Module>`) defined in `CMakeLists.txt`. Include
directories are the module sources, `runtime/src` (and `runtime/src/platform` for the
platform modules) and `vendor/` (nlohmann/json, SRELL). Only `ElmKernel_Http` has external link
dependencies (libcurl, and OpenSSL off Windows).

---

## Function Count by Category

| Category | Modules | Functions | External Deps |
|----------|---------|-----------|---------------|
| Core | 9 | 105 | None |
| Data | 5 | 69 | nlohmann/json, SRELL (both vendored, header-only) |
| I/O | 3 | 24 | libcurl + OpenSSL |
| Browser/DOM | 2 | 45 | None |
| **Total** | **19** | **243** | |

---

## Architecture Notes

### Threading Model

- The scheduler thread runs the Elm event loop and owns every GC heap interaction.
- Background worker threads (`TimerService`, `HttpService`) hold only POD state.
- Workers post completions as tokens/results to queues; the scheduler drains them.

```
┌─────────────────────────────────────────┐
│          Scheduler Thread               │
│  ┌─────────────────────────────────┐   │
│  │     Elm Scheduler Loop          │   │
│  │  - Process run queue            │   │
│  │  - Run effects                  │   │
│  │  - Update model                 │   │
│  │  - Drain worker results         │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
         ▲                    ▲
         │                    │
    ┌────┴────┐          ┌────┴────┐
    │ Timer   │          │  HTTP   │
    │ Worker  │          │ Worker  │
    └─────────┘          └─────────┘
```
