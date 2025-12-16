# Elm Kernel C++ Implementation Status

This document tracks the implementation status of Elm kernel functions in the C++ implementation.

## Stub Modules (Entire Module is Stub)

These modules have function signatures but return stub/placeholder values. They require external libraries for full implementation.

| Module | Current Behavior | Library Needed |
|--------|------------------|----------------|
| **Regex** | Returns empty lists/original strings | PCRE2 |
| **Http** | Always returns NetworkError | HTTP client (curl/libhttp) |
| **File** | Returns empty strings/Nothing | Platform file dialogs |
| **Browser** | Returns stub values (always visible, etc.) | Platform browser APIs |
| **VirtualDom** | Creates stub VNode structures | Platform rendering |
| **Json** | Creates decoder structures but no actual parsing | JSON parser (nlohmann/rapidjson) |
| **Debugger** | Returns stub Expando values | Platform UI |

### Regex (`src/regex/Regex.cpp`)
- `contains` - stub
- `findAtMost` - returns empty list
- `replaceAtMost` - returns original string
- `splitAtMost` - returns list with single element (original)

### Http (`src/http/Http.cpp`)
- `toTask` - always fails with NetworkError
- `mapExpect` - returns expectVal unchanged
- `toDataView` - returns stub DataView
- `toFormData` - returns stub FormData

### File (`src/file/File.cpp`)
- `toString` - returns empty string
- `toBytes` - returns empty bytes
- `toUrl` - returns empty data URL
- `uploadOne` - returns Nothing
- `uploadOneOrMore` - returns Nothing
- `download` - returns unit (no-op)
- `downloadUrl` - returns unit (no-op)

### Browser (`src/browser/Browser.cpp`)
- `application` - stub
- `document` - stub
- `element` - stub
- `visibilityInfo` - always returns Visible
- Navigation functions - stubs

### VirtualDom (`src/virtual-dom/VirtualDom.cpp`)
- `node` - creates stub VNode
- `keyedNode` - creates stub VNode
- `text` - creates stub VNode
- `map` - stub
- `lazy*` functions - stubs

### Json (`src/json/Json.cpp`)
- All decoders create Decoder objects but `run`/`runOnString` don't actually parse
- Encoders create JsonValue objects but don't serialize to strings

### Debugger (`src/core/Debugger.cpp`)
- `init` - returns stub Expando
- `isOpen` - always returns false
- `messageToString` - returns "<message>"

## Partially Implemented Modules

These modules have some functions implemented and some that throw or return stubs.

### Platform (`src/core/Platform.cpp`)

| Function | Status | Error |
|----------|--------|-------|
| `batch` | Throws | "needs type integration" |
| `map` | Throws | "needs type integration" |
| `sendToApp` | Throws | "needs type integration" |
| `sendToSelf` | Throws | "needs type integration" |
| `worker` | Throws | "needs type integration" |

Missing functions (documented but not implemented):
- `_Platform_initialize`
- `_Platform_setupEffects`
- `_Platform_createManager`
- `_Platform_instantiateManager`
- `_Platform_enqueueEffects`
- `_Platform_dispatchEffects`
- `_Platform_gatherEffects`
- `_Platform_outgoingPort`
- `_Platform_incomingPort`
- `_Platform_leaf`

### Process (`src/core/Process.cpp`)

| Function | Status | Error |
|----------|--------|-------|
| `sleep` | Throws | "needs async timer implementation" |

### Bytes (`src/bytes/Bytes.cpp`)

| Function | Status | Notes |
|----------|--------|-------|
| `decode` | Stub | Returns Nothing |
| Read/write functions | Implemented | Working |

### Char (`src/core/Char.cpp`)

| Function | Status | Notes |
|----------|--------|-------|
| `toLower` | Partial | ASCII only, TODO for full Unicode (needs ICU) |
| `toUpper` | Partial | ASCII only, TODO for full Unicode (needs ICU) |
| `toLocaleLower` | Partial | ASCII only, TODO for locale-aware (needs ICU) |
| `toLocaleUpper` | Partial | ASCII only, TODO for locale-aware (needs ICU) |
| `fromCode` | Implemented | Working |
| `toCode` | Implemented | Working |

## Fully Implemented Modules

These modules appear to be fully functional.

### Basics (`src/core/Basics.cpp`)
- All math functions: `add`, `sub`, `mul`, `fdiv`, `idiv`, `pow`, `sqrt`, etc.
- Trigonometric: `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`
- Rounding: `floor`, `ceiling`, `round`, `truncate`
- Comparison: `modBy`, `remainderBy`
- Constants: `pi`, `e`
- Checks: `isNaN`, `isInfinite`

### Bitwise (`src/core/Bitwise.cpp`)
- `and_`, `or_`, `xor_`
- `complement`
- `shiftLeftBy`, `shiftRightBy`, `shiftRightZfBy`

### String (`src/core/String.cpp`)
Delegates to `StringOps` helpers:
- `append`, `length`, `reverse`
- `split`, `join`, `words`, `lines`
- `slice`, `trim`, `trimLeft`, `trimRight`
- `toLower`, `toUpper`
- `cons`, `uncons`
- `map`, `filter`, `foldl`, `foldr`
- `any`, `all`
- `contains`, `startsWith`, `endsWith`, `indexes`
- `toInt`, `toFloat`, `fromNumber`
- `fromList`

### List (`src/core/List.cpp`)
Delegates to `ListOps` helpers:
- `cons`, `empty`
- `map`, `map2`, `map3`, `map4`, `map5`
- `sortBy`, `sortWith`

### Utils (`src/core/Utils.cpp`)
- `equal`, `notEqual`
- `compare`
- `lt`, `le`, `gt`, `ge`
- Tuple utilities

### JsArray (`src/core/JsArray.cpp`)
- `empty`, `singleton`, `push`
- `length`, `unsafeGet`, `unsafeSet`
- `map`, `indexedMap`
- `foldl`, `foldr`
- `slice`, `appendN`
- `initialize`, `initializeFromList`
- `toArray`, `fromArray`, `fromList`

### Scheduler (`src/core/Scheduler.cpp`)
- `succeed`, `fail`
- `binding`
- `andThen`, `onError`
- `spawn`, `kill`
- `send`, `receive`
- `rawSpawn`, `rawSend`
- `enqueue`, `step`, `drain`

### Time (`src/time/Time.cpp`)
- `now` - uses `<chrono>`
- `here` - returns timezone
- `getZoneName` - returns zone name
- `setInterval` - timer implementation

### Url (`src/url/Url.cpp`)
- `percentEncode`
- `percentDecode`

### Parser (`src/parser/Parser.cpp`)
- `isSubString`, `findSubString`
- `isSubChar`
- `isAsciiCode`
- `chompBase10`, `consumeBase`, `consumeBase16`
- `getStringWidth`

## Priority Order for Implementation

### High Priority (needed for basic programs)
1. **Json** - Almost every Elm app uses JSON
2. **Platform** - Core effect system
3. **Process.sleep** - Timer-based effects

### Medium Priority (needed for web apps)
4. **Http** - Network requests
5. **VirtualDom** - UI rendering
6. **Browser** - Browser integration

### Lower Priority (specialized use cases)
7. **File** - File operations
8. **Regex** - Pattern matching
9. **Debugger** - Development tooling
10. **Char Unicode** - Full Unicode support

## External Library Dependencies

| Feature | Recommended Library |
|---------|---------------------|
| JSON parsing | nlohmann/json or rapidjson |
| HTTP client | libcurl or cpp-httplib |
| Regex | PCRE2 |
| Unicode | ICU |
| Platform rendering | SDL2, Qt, or native APIs |
