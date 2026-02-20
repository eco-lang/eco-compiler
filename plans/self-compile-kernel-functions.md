# Elm Kernel C++ Implementation Plan

## Overview

This plan covers the **complete implementation** of all C++ kernel functions for the Elm packages used by the Eco runtime. The goal is full compatibility with Elm's standard library, not just what the compiler needs for self-compilation.

### Package Status

| Package | Implemented | Stub/Missing | Completion |
|---------|-------------|--------------|------------|
| elm/core | 114 | 0 | 95% |
| elm/bytes | 20 | 10 | 70% |
| elm/json | 3 | 29 | 5% |
| elm/regex | 1 | 6 | 15% |
| elm/time | 0 | 4 | 0% |
| elm/url | 2 | 0 | 100% |
| elm/http | 0 | 8 | 0% |

**Total: 57 functions to implement**

## Library Choices (DECIDED)

| Component | Library | Type | Source |
|-----------|---------|------|--------|
| JSON | nlohmann/json | Header-only | https://github.com/nlohmann/json |
| Regex | SRELL | Header-only | https://www.akenotsuki.com/misc/srell/en/ |
| HTTP | libcurl + OpenSSL | System library | https://curl.se/libcurl/ |

JSON and Regex are header-only (vendored). HTTP uses system libcurl with OpenSSL for HTTPS.

## Resolved Decisions

| Question | Decision |
|----------|----------|
| JSON library | nlohmann/json |
| Regex library | SRELL |
| HTTP library | libcurl (with OpenSSL) |
| HTTPS support | **Mandatory** (OpenSSL required) |
| Vendor location | `elm-kernel-cpp/vendor/` |
| Scope | **All** kernel functions, not just compiler requirements |

---

## Phase 1: elm/json (CRITICAL PATH)

**Location:** `elm-kernel-cpp/src/json/`

The JSON package is the largest blocker. The compiler uses JSON for reading `elm.json`, parsing artifacts, and tooling interfaces.

### 1.1 JSON Value Representation

Using **nlohmann/json** as the parsing backend. The approach:
- Parse JSON string → `nlohmann::json` object
- Decoders traverse the `nlohmann::json` tree
- Results are converted to Elm heap types on extraction

The `nlohmann::json` object itself can be wrapped in a heap type for `Json.Decode.Value`.

### 1.2 Functions to Implement

#### Primitive Decoders (10 functions)
```
Elm.Kernel.Json.decodeString    -- Decoder String
Elm.Kernel.Json.decodeBool      -- Decoder Bool
Elm.Kernel.Json.decodeInt       -- Decoder Int
Elm.Kernel.Json.decodeFloat     -- Decoder Float
Elm.Kernel.Json.decodeNull      -- a -> Decoder a
Elm.Kernel.Json.decodeList      -- Decoder a -> Decoder (List a)
Elm.Kernel.Json.decodeArray     -- Decoder a -> Decoder (Array a)
Elm.Kernel.Json.decodeField     -- String -> Decoder a -> Decoder a
Elm.Kernel.Json.decodeIndex     -- Int -> Decoder a -> Decoder a
Elm.Kernel.Json.decodeKeyValuePairs  -- Decoder a -> Decoder (List (String, a))
Elm.Kernel.Json.decodeValue     -- Decoder Value
```

#### Decoder Combinators (4 functions)
```
Elm.Kernel.Json.succeed   -- a -> Decoder a
Elm.Kernel.Json.fail      -- String -> Decoder a
Elm.Kernel.Json.andThen   -- (a -> Decoder b) -> Decoder a -> Decoder b
Elm.Kernel.Json.oneOf     -- List (Decoder a) -> Decoder a
```

#### Map Functions (8 functions)
```
Elm.Kernel.Json.map1 through Elm.Kernel.Json.map8
```

#### Running Decoders (2 functions)
```
Elm.Kernel.Json.run          -- Decoder a -> Value -> Result Error a
Elm.Kernel.Json.runOnString  -- Decoder a -> String -> Result Error a
```

#### Encoding (5 functions)
```
Elm.Kernel.Json.encode      -- Int -> Value -> String
Elm.Kernel.Json.emptyArray  -- Value
Elm.Kernel.Json.addEntry    -- Value -> Value -> Value
Elm.Kernel.Json.addField    -- String -> Value -> Value -> Value
```

### 1.3 Implementation Strategy

**Step 1:** Add nlohmann/json header to the project
```cpp
#include <nlohmann/json.hpp>
using json = nlohmann::json;
```

**Step 2:** Create JsonValue heap type wrapper
```cpp
struct ElmJsonValue : Header {
    // Pointer to heap-allocated nlohmann::json
    json* value;
};
```

**Step 3:** Define Decoder representation
- Decoders are Elm closures: `(JsonValue, List String) -> Result Error a`
- Path (List String) tracks location for error messages
- Result is `Ok value` or `Err (JsonError path message)`

**Step 4:** Implementation order:
1. `runOnString` — parse JSON string via `json::parse()`
2. Primitive decoders — extract from `json` object
3. Structural decoders — navigate `json` tree
4. Combinators — compose decoders
5. Map functions — apply transformations
6. Encoder functions — build `json` objects and serialize

---

## Phase 2: elm/regex

**Location:** `elm-kernel-cpp/src/regex/`

### 2.1 Functions to Implement (6 functions)

```
Elm.Kernel.Regex.never          -- Regex (matches nothing)
Elm.Kernel.Regex.fromStringWith -- Options -> String -> Maybe Regex
Elm.Kernel.Regex.contains       -- Regex -> String -> Bool
Elm.Kernel.Regex.findAtMost     -- Int -> Regex -> String -> List Match
Elm.Kernel.Regex.replaceAtMost  -- Int -> Regex -> (Match -> String) -> String -> String
Elm.Kernel.Regex.splitAtMost    -- Int -> Regex -> String -> List String
```

### 2.2 Implementation Strategy

Using **SRELL** (header-only, std::regex API-compatible):
```cpp
#include <srell.hpp>
using srell::regex;
using srell::smatch;
using srell::regex_search;
using srell::regex_replace;
```

SRELL advantages:
- Drop-in std::regex replacement (same API)
- Better Unicode support
- Faster than std::regex
- Header-only, no build complexity

### 2.3 Regex Heap Representation

Need a new heap type to store compiled regex:
```cpp
struct ElmRegex : Header {
    // Flags from Options record
    bool caseInsensitive;
    bool multiline;
    // Compiled regex (std::regex* or RE2*)
    void* compiledPattern;
};
```

### 2.4 Match Representation

The Match type is a record:
```elm
type alias Match =
    { match : String
    , index : Int
    , number : Int
    , submatches : List (Maybe String)
    }
```

---

## Phase 3: elm/time

**Location:** `elm-kernel-cpp/src/time/`

### 3.1 Functions to Implement (4 functions)

```
Elm.Kernel.Time.now         -- Task x Posix
Elm.Kernel.Time.here        -- Task x Zone
Elm.Kernel.Time.getZoneName -- Task x ZoneName
Elm.Kernel.Time.setInterval -- Float -> Task Never () -> Sub msg
```

### 3.2 Implementation Notes

**now** — Return current POSIX milliseconds as Task.succeed
```cpp
auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
    std::chrono::system_clock::now().time_since_epoch()
).count();
return taskSucceed(allocInt(ms));
```

**here** — Return local timezone offset as Task.succeed
```cpp
// Zone is represented as minutes offset from UTC
time_t now = time(nullptr);
struct tm local_tm;
localtime_r(&now, &local_tm);
int offset_minutes = local_tm.tm_gmtoff / 60;
return taskSucceed(allocZone(offset_minutes));
```

**getZoneName** — Return IANA timezone name
```cpp
// Linux: read /etc/localtime symlink or TZ env var
// Returns ZoneName (Name String | Offset Int)
```

**setInterval** — Subscription for periodic events
```cpp
// Creates a Sub that fires every N milliseconds
// Requires subscription manager integration:
// - Register interval with platform runtime
// - On each tick, send msg to app
// - Return kill handle for cleanup
```

### 3.3 Dependencies

```cpp
#include <chrono>
#include <ctime>
#include <thread>
#include <atomic>
```

Platform-specific for timezone name resolution.

### 3.4 Subscription Infrastructure for setInterval

`Time.setInterval` requires integration with the subscription system. The pattern:

```
                    ┌─────────────────────────────────────────┐
                    │            PlatformRuntime              │
                    │                                         │
    Time.every ────►│  registerManager("Time", {              │
                    │    init: Task state,                    │
                    │    onEffects: router->cmds->subs->...   │
                    │    onSelfMsg: router->msg->state->...   │
                    │  })                                     │
                    │                                         │
                    └──────────────┬──────────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────────────┐
                    │           setInterval impl              │
                    │                                         │
                    │  1. Spawn timer thread                  │
                    │  2. Thread sleeps for interval ms       │
                    │  3. On wake: sendToSelf(router, Tick)   │
                    │  4. onSelfMsg handles Tick:             │
                    │     - Calls tagger to produce msg       │
                    │     - sendToApp(router, msg)            │
                    │  5. Loop back to step 2                 │
                    │  6. Return kill handle to stop thread   │
                    │                                         │
                    └─────────────────────────────────────────┘
```

**Implementation skeleton:**

```cpp
uint64_t Elm_Kernel_Time_setInterval(double intervalMs, uint64_t tagger) {
    // This returns a Sub, not a Task.
    // Subs are effect descriptions processed by the effect manager.
    // The actual timer is started by the Time effect manager's onEffects.

    // Create a Sub descriptor: Custom { interval: Float, tagger: Closure }
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    Custom* sub = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    sub->header.size = 2;
    sub->ctor = 0;  // Time.Every
    sub->unboxed = 1;  // first field unboxed (interval)
    sub->values[0].f = intervalMs;
    sub->values[1].p = Export::decode(tagger);

    return Export::encode(allocator.wrap(sub));
}
```

**Timer thread pattern (in effect manager):**

```cpp
// Called by onEffects when processing Time subscriptions
void startIntervalTimer(double intervalMs, HPointer router, HPointer tagger,
                        std::shared_ptr<std::atomic<bool>> cancelled) {
    std::thread([=]() {
        while (!cancelled->load()) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(static_cast<int64_t>(intervalMs)));

            if (cancelled->load()) break;

            // Get current time
            auto now = std::chrono::system_clock::now();
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                now.time_since_epoch()).count();
            HPointer posix = alloc::allocInt(ms);

            // Call tagger(posix) to get the user's msg
            HPointer msg = Scheduler::callClosure1(tagger, posix);

            // Send to app
            PlatformRuntime::instance().sendToApp(router, msg);
        }
    }).detach();
}
```

---

## Phase 4: elm/bytes (Complete Write Functions)

**Location:** `elm-kernel-cpp/src/bytes/`

### 4.1 Functions to Implement (10 functions)

```
Elm.Kernel.Bytes.write_i8      -- Int -> Encoder
Elm.Kernel.Bytes.write_i16     -- Endianness -> Int -> Encoder
Elm.Kernel.Bytes.write_i32     -- Endianness -> Int -> Encoder
Elm.Kernel.Bytes.write_u8      -- Int -> Encoder
Elm.Kernel.Bytes.write_u16     -- Endianness -> Int -> Encoder
Elm.Kernel.Bytes.write_u32     -- Endianness -> Int -> Encoder
Elm.Kernel.Bytes.write_f32     -- Endianness -> Float -> Encoder
Elm.Kernel.Bytes.write_f64     -- Endianness -> Float -> Encoder
Elm.Kernel.Bytes.write_bytes   -- Bytes -> Encoder
Elm.Kernel.Bytes.write_string  -- String -> Encoder
```

### 4.2 ABI Signature Fix Required

**IMPORTANT:** The current `KernelExports.h` declarations use `bool isBigEndian` which violates **REP_ABI_001** (Bool must cross ABI as `!eco.value`, not `i1`).

**Current (WRONG):**
```cpp
uint64_t Elm_Kernel_Bytes_write_i16(int64_t value, bool isBigEndian);
```

**Correct:**
```cpp
uint64_t Elm_Kernel_Bytes_write_i16(uint64_t endianness, int64_t value);
// endianness is boxed LE/BE Custom constant (eco.value)
```

Must update both `KernelExports.h` and `BytesExports.cpp` signatures.

### 4.3 Implementation Notes

The current implementation uses a tree-walker approach in `Elm_Kernel_Bytes_encode` that handles encoders as Custom types. The write functions create encoder tree nodes:

```cpp
// Encoder tags (already defined in BytesExports.cpp)
enum EncoderTag : u16 {
    ENC_I8 = 0, ENC_I16 = 1, ENC_I32 = 2,
    ENC_U8 = 3, ENC_U16 = 4, ENC_U32 = 5,
    ENC_F32 = 6, ENC_F64 = 7,
    ENC_SEQ = 8, ENC_UTF8 = 9, ENC_BYTES = 10,
};
```

Each write function should create a Custom with the appropriate tag and captured values.

### 4.4 Endianness Detection

```cpp
// Endianness is a Custom type: LE = ctor 0, BE = ctor 1
static bool isBigEndian(uint64_t endianness) {
    HPointer h = Export::decode(endianness);
    Custom* c = static_cast<Custom*>(Allocator::instance().resolve(h));
    return c->ctor == 1;  // BE = 1
}
```

---

## Phase 5: elm/http

**Location:** `elm-kernel-cpp/src/http/`

**Required for:** Package fetching from package.elm-lang.org (HTTPS required).

### 5.1 Functions to Implement (8 functions)

```
Elm.Kernel.Http.emptyBody    -- Body
Elm.Kernel.Http.pair         -- String -> String -> Header
Elm.Kernel.Http.toTask       -- Request a -> Task Error a
Elm.Kernel.Http.expect       -- (Response String -> Result Error a) -> Expect a
Elm.Kernel.Http.mapExpect    -- (a -> b) -> Expect a -> Expect b
Elm.Kernel.Http.bytesToBlob  -- Bytes -> String -> Body
Elm.Kernel.Http.toDataView   -- Bytes -> Body
Elm.Kernel.Http.toFormData   -- List Part -> Body
```

### 5.2 Implementation Strategy

Using **libcurl** with **OpenSSL** for HTTPS:
```cpp
#include <curl/curl.h>
```

libcurl features:
- Mature, battle-tested HTTP client
- Full HTTPS support via OpenSSL
- Async via multi interface or thread pool
- Supports GET, POST, multipart forms, redirects, cookies
- Handles connection pooling, timeouts, retries

### 5.3 System Dependencies

```bash
# Ubuntu/Debian
sudo apt-get install libcurl4-openssl-dev

# macOS
brew install curl openssl
```

### 5.4 CMake Integration

```cmake
find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)
target_link_libraries(elm-kernel-cpp PRIVATE CURL::libcurl OpenSSL::SSL OpenSSL::Crypto)
```

### 5.5 Task Integration

HTTP requests integrate with the Elm Task system:
- `toTask` creates a Binding task
- The binding callback spawns a thread for the HTTP request
- Use `curl_easy_perform()` in the worker thread
- On completion, calls the resume closure with the result
- Similar pattern to `Process.sleep` implementation

### 5.6 Implementation Pattern

```cpp
// Worker thread for HTTP request
static void* httpWorker(void* args) {
    CURL* curl = curl_easy_init();
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);

    CURLcode res = curl_easy_perform(curl);

    if (res == CURLE_OK) {
        // Call resume with Ok response
    } else {
        // Call resume with Err (NetworkError or similar)
    }

    curl_easy_cleanup(curl);
    return nullptr;
}
```

---

## Implementation Order

All packages will be fully implemented. Suggested order based on dependencies:

### Phase 1: Foundation
1. **elm/json** (29 functions) — Most complex, many other packages may use JSON
2. **elm/regex** (6 functions) — Self-contained, used by parsers

### Phase 2: Utilities
3. **elm/bytes** (10 write functions) — Complete existing partial implementation
4. **elm/time** (4 functions) — Requires subscription infrastructure for setInterval

### Phase 3: Network
5. **elm/http** (8 functions) — Depends on Task system, requires OpenSSL

---

## ABI Compliance Requirements

All kernel implementations must comply with these invariants from `design_docs/invariants.csv`:

### REP_ABI_001: Value Passing
> At all function call boundaries (kernel or compiled), only Int, Float, and Char are passed and returned as pass-by-value MLIR types; all other Elm values including Bool cross the ABI as !eco.value regardless of their heap field representation.

**Implications:**
- Use `uint64_t` (encoded HPointer) for all non-primitive arguments
- Bool must be boxed True/False constants, NOT `bool` or `i1`
- Return `uint64_t` for all heap-allocated results

### CGEN_038: Kernel ABI Consistency
> All calls to the same kernel function name use exactly the same MLIR argument and result types across the whole module.

**Implications:**
- Single declaration in `KernelExports.h` defines the ABI
- No function overloading
- Argument order must match Elm's curried parameter order

### HEAP_016: Return Value Encoding
> All eco_alloc_* runtime functions return uint64_t representing HPointer.

**Implications:**
- Use `Export::encode(hpointer)` for return values
- Use `Export::decode(uint64_t)` for input values
- Use `Export::encodeBoxedBool(bool)` for Bool returns

### Pattern Examples

```cpp
// CORRECT: Bool as eco.value
uint64_t Elm_Kernel_Foo_isValid(uint64_t value) {
    bool result = /* computation */;
    return Export::encodeBoxedBool(result);  // Returns boxed True/False
}

// WRONG: Bool as primitive
bool Elm_Kernel_Foo_isValid(uint64_t value);  // VIOLATES REP_ABI_001

// CORRECT: Endianness as eco.value
uint64_t Elm_Kernel_Bytes_write_i16(uint64_t endianness, int64_t value);

// WRONG: Endianness as bool
uint64_t Elm_Kernel_Bytes_write_i16(int64_t value, bool isBigEndian);  // VIOLATES REP_ABI_001
```

---

## Files to Create/Modify

### New Files
```
elm-kernel-cpp/vendor/
├── nlohmann/json.hpp      # Vendored header
└── srell.hpp              # Vendored header

elm-kernel-cpp/src/json/
├── JsonValue.hpp          # ElmJsonValue heap type
└── JsonHelpers.hpp        # Conversion helpers (json ↔ Elm types)

elm-kernel-cpp/src/regex/
└── RegexHelpers.hpp       # SRELL wrappers, Match construction

elm-kernel-cpp/src/http/
└── HttpHelpers.hpp        # libcurl wrappers, response handling
```

### Modified Files
```
elm-kernel-cpp/CMakeLists.txt              # Add vendor include path, link libcurl/OpenSSL
elm-kernel-cpp/src/KernelExports.h         # Fix Bytes write_* signatures (bool → uint64_t)
elm-kernel-cpp/src/json/JsonExports.cpp    # Full implementation
elm-kernel-cpp/src/regex/RegexExports.cpp  # Full implementation
elm-kernel-cpp/src/time/TimeExports.cpp    # Full implementation
elm-kernel-cpp/src/bytes/BytesExports.cpp  # Fix signatures + add write_* functions
elm-kernel-cpp/src/http/HttpExports.cpp    # Full implementation
```

---

## Complete Function Checklist

### elm/json (29 functions)

#### Primitive Decoders
- [ ] `Elm_Kernel_Json_decodeString`
- [ ] `Elm_Kernel_Json_decodeBool`
- [ ] `Elm_Kernel_Json_decodeInt`
- [ ] `Elm_Kernel_Json_decodeFloat`
- [ ] `Elm_Kernel_Json_decodeNull`
- [ ] `Elm_Kernel_Json_decodeValue`

#### Structural Decoders
- [ ] `Elm_Kernel_Json_decodeList`
- [ ] `Elm_Kernel_Json_decodeArray`
- [ ] `Elm_Kernel_Json_decodeField`
- [ ] `Elm_Kernel_Json_decodeIndex`
- [ ] `Elm_Kernel_Json_decodeKeyValuePairs`

#### Combinators
- [ ] `Elm_Kernel_Json_succeed`
- [ ] `Elm_Kernel_Json_fail`
- [ ] `Elm_Kernel_Json_andThen`
- [ ] `Elm_Kernel_Json_oneOf`

#### Map Functions
- [ ] `Elm_Kernel_Json_map1`
- [ ] `Elm_Kernel_Json_map2`
- [ ] `Elm_Kernel_Json_map3`
- [ ] `Elm_Kernel_Json_map4`
- [ ] `Elm_Kernel_Json_map5`
- [ ] `Elm_Kernel_Json_map6`
- [ ] `Elm_Kernel_Json_map7`
- [ ] `Elm_Kernel_Json_map8`

#### Runners
- [ ] `Elm_Kernel_Json_run`
- [ ] `Elm_Kernel_Json_runOnString`

#### Encoding
- [ ] `Elm_Kernel_Json_encode`
- [ ] `Elm_Kernel_Json_emptyArray`
- [ ] `Elm_Kernel_Json_addEntry`
- [ ] `Elm_Kernel_Json_addField`

#### Already Implemented
- [x] `Elm_Kernel_Json_wrap`
- [x] `Elm_Kernel_Json_encodeNull`
- [x] `Elm_Kernel_Json_emptyObject`

### elm/regex (6 functions)

- [ ] `Elm_Kernel_Regex_never`
- [ ] `Elm_Kernel_Regex_fromStringWith`
- [ ] `Elm_Kernel_Regex_contains`
- [ ] `Elm_Kernel_Regex_findAtMost`
- [ ] `Elm_Kernel_Regex_replaceAtMost`
- [ ] `Elm_Kernel_Regex_splitAtMost`

#### Already Implemented
- [x] `Elm_Kernel_Regex_infinity`

### elm/bytes (10 write functions)

**NOTE:** Signatures in `KernelExports.h` must be fixed first (see Phase 4.2).

- [ ] Fix `KernelExports.h` signatures (bool → uint64_t endianness)
- [ ] `Elm_Kernel_Bytes_write_i8`
- [ ] `Elm_Kernel_Bytes_write_i16`
- [ ] `Elm_Kernel_Bytes_write_i32`
- [ ] `Elm_Kernel_Bytes_write_u8`
- [ ] `Elm_Kernel_Bytes_write_u16`
- [ ] `Elm_Kernel_Bytes_write_u32`
- [ ] `Elm_Kernel_Bytes_write_f32`
- [ ] `Elm_Kernel_Bytes_write_f64`
- [ ] `Elm_Kernel_Bytes_write_bytes`
- [ ] `Elm_Kernel_Bytes_write_string`

#### Already Implemented (20 functions)
- [x] `Elm_Kernel_Bytes_width`
- [x] `Elm_Kernel_Bytes_encode`
- [x] `Elm_Kernel_Bytes_decode`
- [x] `Elm_Kernel_Bytes_decodeFailure`
- [x] `Elm_Kernel_Bytes_getHostEndianness`
- [x] `Elm_Kernel_Bytes_getStringWidth`
- [x] `Elm_Kernel_Bytes_read_i8` / `read_u8`
- [x] `Elm_Kernel_Bytes_read_i16` / `read_u16`
- [x] `Elm_Kernel_Bytes_read_i32` / `read_u32`
- [x] `Elm_Kernel_Bytes_read_f32` / `read_f64`
- [x] `Elm_Kernel_Bytes_read_bytes` / `read_string`

### elm/time (4 functions)

- [ ] `Elm_Kernel_Time_now`
- [ ] `Elm_Kernel_Time_here`
- [ ] `Elm_Kernel_Time_getZoneName`
- [ ] `Elm_Kernel_Time_setInterval`

### elm/http (8 functions)

- [ ] `Elm_Kernel_Http_emptyBody`
- [ ] `Elm_Kernel_Http_pair`
- [ ] `Elm_Kernel_Http_toTask`
- [ ] `Elm_Kernel_Http_expect`
- [ ] `Elm_Kernel_Http_mapExpect`
- [ ] `Elm_Kernel_Http_bytesToBlob`
- [ ] `Elm_Kernel_Http_toDataView`
- [ ] `Elm_Kernel_Http_toFormData`

### elm/url (COMPLETE)

- [x] `Elm_Kernel_Url_percentEncode`
- [x] `Elm_Kernel_Url_percentDecode`

---

## Testing Strategy

1. **Unit tests** for each kernel function
2. **Integration tests** using small Elm programs that exercise each function
3. **Self-compilation test** — compile the compiler with itself

---

## Estimated Effort

| Phase | Package | Functions | Complexity | Notes |
|-------|---------|-----------|------------|-------|
| 1 | elm/json | 29 | High | JSON parser, decoder combinators, encoder |
| 1 | elm/regex | 6 | Medium | SRELL integration, Match construction |
| 2 | elm/bytes | 10 + sig fix | Low | Fix ABI signatures, create encoder tree nodes |
| 2 | elm/time | 4 | Medium | Subscription infra for setInterval |
| 3 | elm/http | 8 | High | libcurl async, Task integration, package fetching |

**Total: 57 functions + 1 signature fix task**

---

## Dependencies to Add

### Header-Only Libraries (Vendored)

Location: `elm-kernel-cpp/vendor/`

```
elm-kernel-cpp/vendor/
├── nlohmann/
│   └── json.hpp           # Single-header version
└── srell.hpp              # Single header
```

### Download Commands
```bash
mkdir -p elm-kernel-cpp/vendor/nlohmann

# nlohmann/json (single header)
curl -L https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp \
  -o elm-kernel-cpp/vendor/nlohmann/json.hpp

# SRELL
curl -L https://www.akenotsuki.com/misc/srell/srell.hpp \
  -o elm-kernel-cpp/vendor/srell.hpp
```

### System Dependencies

**libcurl + OpenSSL** — Required for HTTP/HTTPS support (mandatory)
```bash
# Ubuntu/Debian
sudo apt-get install libcurl4-openssl-dev libssl-dev

# macOS
brew install curl openssl
```

### CMakeLists.txt Addition
```cmake
# Add vendor directory to include path
target_include_directories(elm-kernel-cpp PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/vendor
)

# libcurl and OpenSSL are REQUIRED
find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)
target_link_libraries(elm-kernel-cpp PRIVATE
  CURL::libcurl
  OpenSSL::SSL
  OpenSSL::Crypto
)
```
