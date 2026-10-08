# Plan: Native `elm/html`: a heap-resident VirtualDom kernel, the `Http.Dom` side door, and HTML serialization

> **Status: v7, implemented (2026-10-08).** All phases P0–P8 are in the tree; §14 lists what
> implementation changed or found. (v6 was the implementation-ready plan, rebased on the merged
> eco/system in `system-kernel-cpp/`.)
> - It has been adversarially reviewed (§1 lists what the review found and fixed), and all
>   questions (Q1–Q7) are answered. §1.1 lists what changed to fit the merged eco/system.
> - **When to start.** Now. The eco/system gate (Q1) is gone: every phase, P0–P8, lands in this
>   repository. P0–P4 touch `runtime/`, `elm-kernel-cpp/` and `test/`; P5–P7 touch
>   `system-kernel-cpp/` and its tests.
> - **Citations.** Facts marked *(verified)* were checked in this checkout and cite
>   `file:line`. eco/system paths are relative to the repository root
>   (`system-kernel-cpp/...`); the lines cited in §7.3 were re-checked against the merged tree.
> - **Code.** Appendices A–D hold the reference code (Elm `Http.Dom` module, C++ skeletons, JS
>   twin) and the golden test corpus.

## 0. What this plan delivers

1. **`elm/html` and `elm/svg` work natively, unchanged.** Every function in `Html`,
   `Html.Attributes`, `Html.Events`, `Html.Keyed` and `Html.Lazy` (and `elm/svg`) compiles,
   links and runs under the native backend. We use the stock registry packages unmodified, so
   the API matches by construction. The work is a from-scratch C++ `Elm.Kernel.VirtualDom`.
2. **The in-memory DOM model is ordinary Elm data on the eco heap.** Every `VirtualDom.Node msg`
   (and so every `Html msg` and `Svg msg`) is a value of an ordinary Elm custom type. C++ builds
   it with the existing allocation helpers and the GC traces it like any other value. There is
   no off-heap state.
3. **The side door: module `Http.Dom`** (in eco/system). It declares that custom type transparently.
   `Http.Dom.fromNode : VirtualDom.Node msg -> Http.Dom.Node` is a **zero-copy identity** natively. On JS
   it is a conversion that relies on privileged knowledge of stock VirtualDom's JS objects.
4. **HTML serialization:**
   - `Http.Dom.toString : VirtualDom.Node msg -> String`, for convenience.
   - `Http.Server.Response.setBodyAsHtml : VirtualDom.Node msg -> Response -> Response`. Natively
     it serializes straight into the response's off-heap buffer: no `String` or `Bytes` is put
     on the heap.

   A C++ writer and an Elm reference implementation produce identical bytes, and neither can
   crash on any input.

---

## 1. Adversarial review of v4: findings and fixes

| # | v4 said | What is true *(verified)* | Fix in v5 |
|---|---|---|---|
| F1 | `Debug.toString` on `Html` "should print `<internals>`" (P0 check only) | It **crashes**. The type-graph printer asserts that the heap object is a `Tag_Custom` whose ctor id and field count match the declared type (`runtime/src/allocator/RuntimeExports.cpp:4093-4125`). `type Node msg = Node` declares one 0-field ctor, so every kernel-built node fails the assert (asserts are on in non-Release builds, `elm-kernel-cpp/CMakeLists.txt:327-337`). The same applies to `Json.Value` fields and to `Http.Dom.Tagger`/`Http.Dom.Handler` fields (closures, foreign ctors). | P0.1: the printer prints `<internals>` on any shape mismatch, as JS does. |
| F2 | The JSON read API "iterates arrays" | Encoder arrays (`Json.Encode.list`) are stored **reversed**. `addEntry` prepends, and `elmToJson` reverses back (`elm-kernel-cpp/src/json/JsonExports.cpp:1380-1389`, `:1886-1925`). | `JsonRead::arrayElements` reverses `ENC_ARRAY` lists. |
| F3 | Re-pin the license manifest after moving constants out of `JsonExports.cpp` | `JsonExports.cpp` and `ExportHelpers.hpp` are LSS_022-pinned. Any edit requires re-auditing every licensed Json row and advancing its `audited:` date (`test/scripts/check-kernel-license-manifest.sh:22-33`). | **No edits to pinned files.** The new `JsonRead.cpp` mirrors the constants, and a unit test cross-checks them through the exported kernels. The XSS replacement value is built by calling the exported `Elm_Kernel_Json_wrap`. |
| F4 | Kernel arguments are heap `HPointer`s | They may also be **raw pointers to global string literals** in the data segment. `Export::toPtr` handles both (`ExportHelpers.hpp:47-70`); `Allocator::resolve` does not. | Rule R3: read every field through `Export::toPtr`. |
| F5 | `eraseMsg` coercion for `HtmlBody` | It is unnecessary. | `HtmlBody Http.Dom.Node`, stored via `Http.Dom.fromNode`. |
| F6 | Pin VirtualDom's JS field letters from compiled output | eco renames kernel `__fields` **per kernel file** (memory note on eco JS pitfalls), so stock elm's letters are not eco's. | The JS twin **self-calibrates**: it builds probe vnodes with the imported VirtualDom kernel functions and reads the keys and `$` codes off them (Appendix C). This works for any version and any renaming. |
| F7 | `attributes : List Fact -> …` | `setAttribute` **lowercases** names on HTML elements (not SVG), and `textarea`/`select` treat `value` specially, so resolution needs the element context. | `attributes : Node -> List ( String, Maybe String )`, with the resolver taking namespace and tag. |
| F8 | Merge all class sources; lower-case unknown properties | Not browser-faithful. `class "a"` + `attribute "class" "b"` gives `class="b"` in a browser (last write wins in apply order), and unknown properties never reach an attribute. | §8 now **emulates** `_VirtualDom_organizeFacts` + `_VirtualDom_applyFacts` exactly, with a closed reflection table. Unknown properties are dropped. |
| F9 | Lone surrogates → U+FFFD | The runtime's UTF-16→UTF-8 transcoding writes the 3-byte form of a lone surrogate (`StringOps.cpp` `toStdString`, `elm-kernel-cpp/src/bytes/Bytes.cpp:74-100`). | Follow the runtime, so HTML bodies and `StringBody` bytes agree. |
| F10 | Floats use "JS shortest round-trip" | Native `String.fromFloat` is `std::to_chars` shortest (`runtime/src/allocator/StringOps.hpp:1197-1216`). That is not JS-exact (for example `1e-7` vs `1e-07`). | Both native serializers share one formatter, extracted from `fromFloat`. JS-target number text may differ (accepted, like attribute order). |
| F11 | Elm `render` must "not overflow" | Elm only optimizes **self** tail calls, and JS stacks hold about 10k frames. | `render` is one self-tail-recursive loop over an explicit work list, and the JS twin converts iteratively (D17: no crash). |
| F12 | A debug assert checks the GC epoch across the writer walk | No such counter API exists. | Dropped. The guarantee is structural (R8) and checked in review. |
| F13 | `noJavaScriptOrHtmlJson` stringifies a bounded 64-unit prefix | **Wrong.** `\s*` runs are unbounded, so `"<100 spaces>javascript:"` would slip past a prefix. | Stringify fully. |
| F14 | Rewrite `</` "in any case" inside `<style>` | `</` contains no letters, so "any case" means nothing. | Replace `</` with `<\/`. |
| F15 | `Dom` is a safe module name | Elm reports an ambiguous import when an application module and a dependency both define `Dom`, so a server app with its own `src/Dom.elm` could not import a top-level `Dom`. | **Renamed to `Http.Dom`** (user, 2026-10-08). The kernel home stays `Eco.Kernel.Dom`. |
| F16 | — | `DomExports.o` sits in a static archive and is only pulled in when referenced. The JIT looks symbols up in the process (`runtime/src/jit/EcoJIT.cpp:438`) and through `KERNEL_SYM` (`runtime/src/codegen/RuntimeSymbols.cpp:591-596`). | Register the new `Elm_Kernel_*` symbols with `KERNEL_SYM`; this also anchors the objects. (v6: the `Eco_Kernel_Dom_*` symbols moved to eco/system, which needs no `KERNEL_SYM`, §1.1 E4.) |
| F17 | — | The JS target uses whichever `elm/virtual-dom` the app resolved. 1.0.3 does not filter `outerHTML` or JSON arrays; native follows 1.0.5. | Documented as a cross-target difference (§8.8). |
| F18 | Delete the `Json.hpp` stub with the VirtualDom stub | `Json.hpp` is also included by `file/File.hpp:13` and `browser/Browser.hpp:6`. | Leave `Json.hpp` alone (out of scope). Only the VirtualDom stub is deleted. |
| F19 | — | `elm/svg` is not in the package cache (`~/.eco/0.2.0/packages/elm/`). | v6: the SVG cases use `VirtualDom.nodeNS`/`attributeNS` directly, which is all `elm/svg` does, so no registry fetch is needed (§1.1 E7). |

Checked and **confirmed** (no change):
- `eco_apply_closure` is the sanctioned boxed-args entry for C++ (`RuntimeExports.cpp:2229-2246`). It is right for `lazy*`, whose type-variable arguments arrive boxed.
- `alloc::custom` roots its `values` across the allocation (`HeapHelpers.hpp:1436-1468`).
- `Json.Encode.string ""` is a proper `ENC_STRING` (`JsonExports.cpp:1735-1748`).
- Kernel JS importing the Elm module that imports it has precedent: `VirtualDom.js` imports `VirtualDom exposing (toHandlerInt)`.
- `elm/html` 1.0.0 and 1.0.1, and `elm/virtual-dom` 1.0.3 and 1.0.5, reference the same 19 kernel names, so one native kernel serves all of them.
- eco/system's native `respond` already copies the response out of the heap into a POD `ResponseData { status, headers, std::string body }` inside a no-allocation scope (`system-kernel-cpp/src/eco-system/HttpServer/HttpServer.cpp:282-313`, `HttpServerService.hpp:45-49`). `HtmlWriter` drops straight into that scope.

### 1.1 Fit to the merged eco/system (v6)

The installed copy that v5 was lowered against has the same sources as the merged
`system-kernel-cpp/src`, so the Elm and C++ code cited in §7.3 still holds. What the merge adds
is the build, test and rule machinery around that code. Checking the plan against it found
these:

| # | v5 said | What is true *(verified)* | Fix in v6 |
|---|---|---|---|
| E1 | `Eco_Kernel_Dom_*` live in `elm-kernel-cpp/src/virtual-dom/DomExports.cpp` | `full` first runs `test/scripts/check-kernel-homes.sh` (`CMakeLists.txt:1444`). It collects every `(Elm\|Eco)_Kernel_<Home>_` prefix under `elm-kernel-cpp/src` and fails if an eco/system JS kernel file has the same home (`check-kernel-homes.sh:26-41`). `Eco_Kernel_Dom_*` in elm-kernel-cpp plus `system-kernel-cpp/src/Eco/Kernel/Dom.js` is such a clash, so `full` would fail at its first command. | The three `Eco_Kernel_Dom_*` exports move into a new eco/system module **`Dom`**: `system-kernel-cpp/src/eco-system/Dom/DomExports.cpp`, library `EcoSystem_Dom`, added to `ECO_SYSTEM_MODS`. eco/system's convention is one library per kernel home. The serializer stays in `ElmKernel_VirtualDom` as the C++ function `Elm::Kernel::VirtualDom::writeHtml`, which has no `_Kernel_` C symbol, so the home check never sees it. |
| E2 | — | eco/system's boundary rules forbid package ADTs across a kernel boundary (B1, `plans/eco-system-library.md:146-150`). B5 (`:172-174`) allows only two pure kernels. `Eco.Kernel.Dom.*` are pure and take `VirtualDom` values, and `respondHtml` takes an `Http.Dom.Node`. | P5 adds rule **B1b**, the VirtualDom side door, to `plans/eco-system-library.md`. It is modelled on B1a (the one foreign ADT HttpStream reads) and pinned by VDOM_001 and `DomLayoutTest`. P5 also extends B5's list with `Dom.fromNode`, `Dom.fromAttribute` and `Dom.toString`. |
| E3 | `respondHtml` body used `Elm::Kernel::Export::decodeBoxedBool(Export::encode(…))` | Every eco/system C++ file is in namespace `Eco::System` and starts with `#include "eco-system/Core/Core.hpp"`. There, `Export` is `Eco::Kernel::Export`, and exports take and return `uint64_t` through `enc`/`dec` (`plans/eco-system-library.md` §3.3.2; `Core.hpp:20-22`). elm-kernel-cpp's `ExportHelpers.hpp` is not on eco/system's include path, so v5's snippet would not compile. eco/system reads a Bool field as `::Elm::hpBits(x) == ::Elm::hpBits(alloc::elmTrue())` (`HttpServer.cpp:210`). | §7.3 and B.4 now use eco/system idioms. `HtmlWriter.hpp` includes only `<cstdint>` and `<string>`, and eco/system includes it as `"virtual-dom/HtmlWriter.hpp"`, so no elm-kernel-cpp helper header leaks into eco/system. |
| E4 | `KERNEL_SYM` for `Eco_Kernel_Dom_*` and `respondHtml` | eco/system symbols are never `KERNEL_SYM`-registered: `RuntimeSymbols.cpp` names none of them. The `test` binary whole-archives every `EcoSystem_*` library, so the JIT finds them by `dlsym` (`test/CMakeLists.txt:236-270`). The AOT driver links every library in `ECO_SYSTEM_MODS` (`EcoNativeDriver.cpp:593`, `:734`, `:1059`). | P1 registers only `Elm_Kernel_VirtualDom_noJavaScriptUri` (F16). Adding `Dom` to `ECO_SYSTEM_MODS` is the whole registration for the Dom kernels. |
| E5 | "Check that the AOT driver puts eco/system libs before the elm kernel libs" | This is already settled. On ELF, the elm-kernel and eco/system archives sit in one `--start-group … --end-group` (`EcoNativeDriver.cpp:1063-1102`). ld64 rescans archives, so order does not matter on macOS (`compiler/CMakeLists.txt:836-839`). The Windows AOT link is still a stub (`EcoNativeDriver.cpp:656`, `linkExecutableWindows`). | The order check is dropped. The only link edits are CMake target dependencies: `EcoSystem_Dom` and `EcoSystem_HttpServer` link `ElmKernel_VirtualDom`. That gives them the include path and pulls the library into `eco-system-core-test`. |
| E6 | — | An application's `elm.json` must list every transitive dependency. Once eco/system depends on `elm/virtual-dom`, every application that uses eco/system must list it too: `test/eco-system/elm.json` and `examples/system/elm.json`, which `full` builds through `eco-system-examples` (`CMakeLists.txt:1447`). `test/stress-elm/elm.json` already lists `elm/virtual-dom 1.0.3`. `system-kernel-cpp/tests/elm.json` (elm-test) compiles only the modules its tests reach, and none of them imports `Http.Dom`. | P5 step 2 edits both `elm.json` files. |
| E7 | SVG cases need `elm/svg` from the registry (F19) | `elm/svg`'s `Svg.node` is `VirtualDom.nodeNS "http://www.w3.org/2000/svg"`, its plain attributes are `VirtualDom.attribute`, and `xlinkHref` is `VirtualDom.attributeNS "http://www.w3.org/1999/xlink" "xlink:href"` (elm/svg 1.0.1 source; it is not in the cache, so this is not re-checked here). `elm/virtual-dom 1.0.3` and `elm/html 1.0.0` are in the package cache. | The tests make `elm/virtual-dom` a direct dependency and build SVG through `VirtualDom.nodeNS`/`attributeNS`, which reaches exactly the kernels `elm/svg` uses. Golden case D.1 #26 is rewritten that way. |
| E8 | Each phase ends with one `full` run | eco/system C++ has three more gates (`plans/eco-system-library.md` §3.3.3): the `ECO_HEAP_VALIDATE` tree filtered to `eco-system`, `stress-test --filter EcoSystem`, and `check-root-bounded.py`, which already scans `system-kernel-cpp/src` and `elm-kernel-cpp/src` (`check-root-bounded.py:22`). | P2–P6 add the validate-tree run, and P6 adds the stress scenario `test/stress-elm/src/EcoSystemHttpServerHtml.elm`. |
| E9 | Tests go "in eco/system's E2E tree" | This is now concrete. Both the native suite (`test/eco-system/EcoSystemTest.hpp`, compiled with `--local-package eco/system=<repo>/system-kernel-cpp`) and `run-js-e2e` pick up every `test/eco-system/src/*.elm` that has a `main`, so no wiring is needed. HTTP tests use `HttpServerTestHelp.program`, whose `get` reports `<status> <content-type> <body>` (`HttpServerTestHelp.elm:70-123`). | P5–P7 tests are lowered onto that harness (§9). |
| E10 | — | The JS `respondHtml` builds its body with `Buffer.from(…, 'utf8')`, which writes a lone surrogate as `EF BF BD`. Native writes the 3-byte surrogate form (F9). | Added to D16 as an accepted cross-target difference. |
| E12 | P7 (JS twin) came after P5/P6 | `full` runs `run-js-e2e` (`CMakeLists.txt:1437-1453`). A missing kernel `.js` is not a build error: the package crawl treats it as a foreign kernel (`compiler/src/Builder/Elm/Details.elm:1810-1819`). The failure therefore shows up at run time on JS. Without `Dom.js`, `_Dom_*` is undefined and P5's tests fail under `run-js-e2e`. Without `_HttpServer_respondHtml`, `Response.elm`'s top-level `kRespondHtml = Eco.Kernel.HttpServer.respondHtml` throws a `ReferenceError` when any JS program that sends a response loads, which would break the existing JS HTTP server tests. | The JS twin lands in P5 and the JS `respondHtml` in P6. P7 is now the JS-target rules that apply inside them. |
| E11 | — | `system-kernel-cpp/README.md` lists the modules. `scripts/make-docs-package.js` strips every `import Eco.Kernel.*` and kernel call generically, so the stock-Elm docs build needs no script change for `Http.Dom`. | P8 adds `Http.Dom` to the README module list and runs `pnpm docs:check`. |

---

## 2. Decisions

- **D1 — Stock Elm sources; only the kernel changes.** Native semantics follow elm/virtual-dom
  **1.0.5** JS (PROD arms).
- **D2 — The VirtualDom stub is deleted and rewritten** (user). The C symbol names stay, because
  the compiler derives them.
- **D3 — Heap layout = layout of the transparent Elm types `Http.Dom.Node`/`Http.Dom.Fact`** (§3). This
  works because constructor tag = zero-based declaration index
  (`compiler/src/Compiler/Data/CtorTag.elm:163-173`), fields keep declaration order, and every
  field is boxed. One C++ header mirrors the declaration, and a layout-pin test guards it.
- **D4 — Facts are stored raw.** Resolution happens at read time (§8).
- **D5 — `lazy*` evaluate eagerly at construction**, like `VirtualDom.server.js`. A thunk cache
  would write into a published heap object, which `HEAP_SNAPSHOT_001` forbids.
- **D6 — `map` and `mapAttribute` keep their taggers** (`Mapped` nodes and `Event` tagger
  lists). C++ never builds closures or decoders.
- **D7 — Naming:** module **`Http.Dom`** (user, 2026-10-08; namespaced to avoid clashing with an
  application's own `Dom` module, F15). Kernel home `Eco.Kernel.Dom`, which is unique among kernel
  homes. Kernel JS refers to the module through `import Http.Dom as Dom`, so its names are spelled
  `__Dom_*`, the same pattern as `VirtualDom.js` importing `Json.Decode as Json`.
- **D8 — Placement** (v6, §1.1 E1):
  - **eco/system (`system-kernel-cpp/`):** `src/Http/Dom.elm`, `src/Eco/Kernel/Dom.js`, the
    `Eco_Kernel_Dom_*` exports (`src/eco-system/Dom/DomExports.cpp`, library `EcoSystem_Dom`),
    and the HttpServer changes.
  - **`elm-kernel-cpp/`:** `Elm_Kernel_VirtualDom_*`, `XssFilters`, `HtmlWriter` (exposed as the
    C++ function `Elm::Kernel::VirtualDom::writeHtml`) and `JsonRead`. eco/system calls
    `writeHtml` and links `ElmKernel_VirtualDom`.
- **D9 — Native `main : Html msg` keeps discarding its value** (`runtime/src/codegen/eco_entry.cpp:122-126`).
- **D10 — URI filters behave as in PROD.** A matching URI is replaced with `""`.
- **D11 — Names are not validated at construction** (user). Construction is total.
- **D12 — Two serializers, one spec.** `Http.Dom.render` (Elm, Appendix A) is the readable
  reference and the JS-target implementation. `HtmlWriter` (C++) mirrors it function for
  function. Natively, `Http.Dom.toString` uses `HtmlWriter`. A differential test requires the two
  to produce byte-identical output.
- **D13 — `setBodyAsHtml`** stores `HtmlBody (Http.Dom.fromNode node)`. Native `send` serializes it in
  the respond binding's copy-out scope (§7.3).
- **D14 — JS twin in scope** (user). It uses privileged knowledge of VirtualDom's JS objects,
  obtained by self-calibration (F6).
- **D15 — `setBodyAsHtml` headers and doctype** (user):
  - It adds `Content-Type: text/html; charset=utf-8` unless a `Content-Type` header (compared
    case-insensitively) is present when the response is sent.
  - It prefixes `<!DOCTYPE html>` iff the root, seen through `Mapped`, is an un-namespaced
    element whose tag lower-cases to `html`.
  - `Http.Dom.toString` adds neither.
- **D16 — Attribute order, number formatting and lone-surrogate bytes may differ between the JS
  and native targets** (user, for order; F10, for numbers; §1.1 E10, for surrogates). So may the
  text a filtered URI is replaced with: a JS program compiled in DEV mode (as `run-js-e2e` does)
  gets elm/virtual-dom's `javascript:alert("This is an XSS vector…")` where native and PROD JS
  write `""` (D10).
- **D17 — Token-breaking names are refused by substitution, and serialization never crashes**
  (user):
  - **Token-breaking:**
    - A *tag* is token-breaking if it is empty or contains any character with code ≤ U+0020,
      U+007F, `"`, `'`, `<`, `>` or `/`.
    - An *attribute* name is token-breaking under the same rule, plus `=`.
  - **What happens:** an attribute with such a name is dropped, and an element with such a tag
    is **unwrapped** (its children are rendered in its place).
  - **Totality:** neither serializer, nor the JS conversion, has an input-dependent `assert`,
    `abort`, `Debug.todo`, exception or unbounded recursion.
  - **Out of memory** is not input validation. It follows the existing `ECO_KERNEL_GUARD`
    convention (`FORBID_IO_001`).
- **D18 — Pinned files are not edited** (F3): `JsonExports.cpp`, `ExportHelpers.hpp`, and
  everything else listed in `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt`.
  (Amended v7: one bug fix to `JsonExports.cpp` was made through the re-audit procedure, §14 I2.)
- **D19 — `Debug.toString` prints `<internals>`** for kernel-built values whose shape differs
  from the declared type (F1), as JS does.

---

## 3. The heap DOM model

### 3.1 Elm declaration (source of truth): `Http/Dom.elm`, Appendix A

```elm
type Node
    = Text String                                                        -- ctor 0
    | Element (Maybe String) String (List Fact) (List Node)              -- ctor 1: ns, tag, facts, kids
    | KeyedElement (Maybe String) String (List Fact) (List ( String, Node ))  -- ctor 2
    | Mapped Tagger Node                                                 -- ctor 3

type Fact
    = Attribute String String                 -- ctor 0: key, value
    | AttributeNS String String String        -- ctor 1: namespace, key, value
    | Property String Json.Encode.Value       -- ctor 2: key, value
    | Style String String                     -- ctor 3: key, value
    | Event String Handler (List Tagger)      -- ctor 4: name, handler, taggers (outermost first)

type Tagger = Tagger     -- opaque; the runtime value is the closure given to VirtualDom.map / mapAttribute
type Handler = Handler   -- opaque; the runtime value is the VirtualDom.Handler msg
```

- `Http.Dom.Node` has no `msg` parameter. The taggers are existential and cannot be typed in Elm.
- **Equality caveat** (for the module docs): `==` on a `Http.Dom.Node` that contains `Event` or
  `Mapped` compares closures, which is the same restriction as `==` on `Html` in stock Elm.

### 3.2 C++ mirror: `elm-kernel-cpp/src/virtual-dom/VirtualDomLayout.hpp` (Appendix B.1)

- **Constructors and fields:** constants for the ctors and field indices above.
- **Field kinds:** every field is boxed, so `alloc::custom(ctor, values, u64{0})`.
- **Empty values:** `Nothing` and `[]` are the merged empty constant (`HeapHelpers.hpp:197-211`).
  `Just ns` is `alloc::just(alloc::boxed(ns), true)`, which is ctor 0 with one field.
- **Nullary constructors:** none, so `HEAP_044` never applies.
- **Lists:** list fields hold the caller's lists as given (they may be chunked, `HEAP_038`).

---

## 4. Kernel functions

**Arity and ABI** come from the stock Elm call sites: every argument and result is `HPtr`, and
Int arguments (`Eco_Kernel_HttpServer_respondHtml`'s `key`/`status`) are `int64_t`
(`compiler/src/Compiler/Generate/MLIR/KernelAbi.elm:143-160`).

### 4.1 `Elm.Kernel.VirtualDom` (`VirtualDomExports.cpp`, Appendix B.2)

| Kernel(arity) | Result | Allocations | Rooting |
|---|---|---|---|
| `text`(1) | `Text [s]` | 1 | R1 |
| `node`(3) | `Element [Nothing, tag, facts, kids]` | 1 | R1 |
| `nodeNS`(4) | `Element [Just ns, tag, facts, kids]` | 2 | R2 |
| `keyedNode`(3), `keyedNodeNS`(4) | `KeyedElement` (as above) | 1 / 2 | R1 / R2 |
| `map`(2) | `Mapped [f, node]` | 1 | R1 |
| `attribute`(2), `style`(2), `property`(2) | `Attribute`/`Style`/`Property` `[key, value]` | 1 | R1 |
| `attributeNS`(3) | `AttributeNS [ns, key, value]` | 1 | R1 |
| `on`(2) | `Event [name, handler, []]` | 1 | R1 |
| `mapAttribute`(2) | `Event [name, handler, f :: taggers]` for an `Event`; the fact itself otherwise | 0 / 2 | R2 |
| `lazy`(2) … `lazy8`(9) | `eco_apply_closure(f, args, n)` | by `f` | R4 |
| `noScript`(1) | `"p"` if `/^script$/i` matches, else `tag` | 0 / 1 | R3 |
| `noOnOrFormAction`(1) | `"data-" ++ key` if `/^(on\|formAction$)/i` matches, else `key` | 0 / 1 | R3 |
| `noInnerHtmlOrFormAction`(1) | `"data-" ++ key` if key ∈ {`innerHTML`, `outerHTML`, `formAction`} (exact case), else `key` | 0 / 1 | R3 |
| `noJavaScriptUri`(1) **new** | `""` if `RE_js` matches, else `value` | 0 / 1 | R3 |
| `noJavaScriptOrHtmlUri`(1) | `""` if `RE_js_html` matches, else `value` | 0 / 1 | R3 |
| `noJavaScriptOrHtmlJson`(1) | `Json.Encode.string ""` if the value is a String or an Array whose JS `String(value)` matches `RE_js_html`; else `value` | 0 / 1 | R3 |

`init` and `custom` are JS-only and not provided natively (D9; no Elm source references
`custom`).

### 4.2 `Eco.Kernel.Dom` (eco/system `src/eco-system/Dom/DomExports.cpp`, Appendix B.4)

| Kernel | Native | JS twin (Appendix C) |
|---|---|---|
| `fromNode`(1) | returns its argument | calibrated conversion |
| `fromAttribute`(1) | returns its argument | calibrated conversion of one fact |
| `toString`(1) | `HtmlWriter` into a `std::string`, then one `allocStringFromUTF8` | `__Dom_render(_Dom_fromNode(node))` |

These follow eco/system's export conventions:
- They take and return `uint64_t`, the same bits as elm-kernel-cpp's `HPtr`.
- Each body is wrapped in `ECO_KERNEL_GUARD` (B6).
- They are pure and return values, not Tasks, which B5 permits once P5 extends its list.

### 4.3 `Eco.Kernel.HttpServer.respondHtml` (eco/system, §7.3)

---

## 5. GC rooting rules (apply to every kernel above)

- **R1 — Single-allocation constructors** put the decoded arguments straight into the
  `std::vector<Unboxable>` given to `alloc::custom`, which roots them across its allocation
  (`HeapHelpers.hpp:1436-1468`). Nothing allocates before that call, so no guard is needed.
- **R2 — Two-allocation constructors** guard every `HPointer` local that is used after the
  first allocation, with one `Elm::StackRootGuard` naming all of them (Appendix B.2,
  `nodeNS`/`mapAttribute`). Copy fields out of a resolved object *before* the first allocation;
  the `Custom*` is dead after it.
- **R3 — Read through `Export::toPtr`, never `Allocator::resolve`**, because arguments may be
  raw literal pointers (F4). The filters copy their input into a `std::u16string`
  (`StringOps::toStdU16String`, no Eco allocation) and only then allocate. Nothing heap-resident
  is live across that allocation, so no guard is needed.
- **R4 — Calling Elm** (`lazy*`): `eco_apply_closure(f, args, n)`, then return its result.
  Nothing is live after the call. Any future change that keeps a value across a closure call
  guards it, as `JsonExports.cpp:1162-1188` does.
- **R5 — List walks** use `alloc::ListCursor` when the walk never allocates and
  `alloc::RootedListCursor` when it can (`HeapHelpers.hpp:755-880`). Never assume `Cons` cells.
- **R6 — No off-heap state:** no globals, caches or root scanners, and no writes after
  construction (`HEAP_SNAPSHOT_001`/`002` hold by construction).
- **R7 — The `Http.Dom` identities allocate nothing.**
- **R8 — `HtmlWriter` and `JsonRead` neither allocate on the Eco heap nor call Elm code.**
  - Object addresses are therefore stable for the whole walk, which is the same discipline the
    read-only walkers `eq`/`compare`/`toString` rely on (`HeapHelpers.hpp:827-836`).
  - All their state lives in `std::` containers.
  - The only Eco allocation is the final `allocStringFromUTF8` in `Eco_Kernel_Dom_toString`, made
    after the walk. `httpServerRespondHtmlBody` makes none inside its G3 copy-out scope (the
    export's payload tuples are allocated before the walk, §7.3).
  - Reviewers check that `HtmlWriter.cpp`/`JsonRead.cpp` call no `alloc::` allocator, no
    `eco_alloc_*`, and no `eco_apply_closure*`.
- **R9** — `FORBID_HEAP_001`/`003` apply: detect constants with the helpers, and root only
  through `StackRootGuard`/`StackRootRangeGuard`/`RootedSlots`.

---

## 6. XSS filter semantics (`XssFilters.hpp/.cpp`, pure functions on `std::u16string`)

- **`isJsSpace(c)`:** true for U+0009–000D, U+0020, U+00A0, U+1680, U+2000–200A, U+2028, U+2029,
  U+202F, U+205F, U+3000 and U+FEFF (ECMAScript WhiteSpace ∪ LineTerminator).
- **Case-insensitivity:** `/i` without `u` folds only ASCII letters here; a non-ASCII character
  never matches an ASCII letter.
- **`looseMatch(s, i, pattern)`:** for each pattern character, skip `isJsSpace` characters,
  then require the character (ASCII-case-insensitively for letters, exactly for punctuation).
  It returns the end index or `npos`. Patterns: `"javascript:"`, `"data:text/html"`.
- **Predicates:**
  - `isScriptTag(s)`: `s` equals `script`, ASCII-case-insensitively.
  - `isOnOrFormAction(s)`: `s` starts with `on`, or equals `formaction`, both
    ASCII-case-insensitively.
  - `isInnerHtmlOrFormAction(s)`: `s` ∈ {`innerHTML`, `outerHTML`, `formAction`}, exact.
  - `isJavaScriptUri(s)`: `looseMatch(s, 0, "javascript:")`.
  - `isJavaScriptOrHtmlUri(s)`: `isJavaScriptUri(s)`, or (`e = looseMatch(s, 0, "data:text/html")`,
    then skip spaces from `e`, then the next character is `,` or `;`).
- **`noJavaScriptOrHtmlJson`:**
  - `JsonRead::jsToString(bits, out)` (Appendix B.3) produces JS `String(value)` for a String or
    an Array and returns false for anything else.
  - Arrays use `Array.prototype.toString` semantics: elements joined with `,`; null → `""`;
    Bool → `true`/`false`; Number → shared formatter; String → itself; Array → recursive;
    Object → `[object Object]`.
  - Recursion is capped at depth 256; deeper elements stringify as `""`. This is safe because
    native serialization never writes array-valued properties (§8.5).
  - Replacement: `Elm_Kernel_Json_wrap(empty string)`.

---

## 7. The side door and the HTTP server

### 7.1 Module `Http.Dom` (eco/system `src/Http/Dom.elm`, full source in Appendix A)

Exposes `Node(..)`, `Fact(..)`, `Tagger`, `Handler`, `fromNode`, `fromAttribute`,
`attributes`, `render` and `toString`.
- `system-kernel-cpp/elm.json` gains `"elm/virtual-dom": "1.0.0 <= v < 2.0.0"` and lists
  `Http.Dom` in `exposed-modules` after `Http.Server.Response`. `elm/json` is already a
  dependency. Applications that use eco/system must then list `elm/virtual-dom` too (§1.1 E6).
- The kernel crossings are allowed by rule B1b, which P5 adds to eco/system's plan (§1.1 E2).
- Kernel bindings are annotated, eta-free aliases (`TYPE_KERNEL_001`; first usage wins,
  `compiler/src/Compiler/Type/KernelTypes.elm:7-24`).

### 7.2 JS twin `src/Eco/Kernel/Dom.js` (Appendix C)

- **Calibration** (F6): on first use, build probe vnodes with the imported VirtualDom kernel
  functions, then read off the `$` codes (TEXT/NODE/KEYED/TAGGER/THUNK/CUSTOM and the fact
  categories) and the field keys. No `__field` names appear in the twin.
- **Conversion** is iterative (explicit stack) and post-order:
  - Thunks are forced with `thunk()`, never written back.
  - Organized facts are emitted in `for…in` order, the same order `_VirtualDom_applyFacts` uses.
    Property values are re-wrapped with `__Json_wrap`, because organized facts store them
    unwrapped. Events become `Event name handler []`.
  - An unknown or CUSTOM vnode becomes `Element Nothing "div" facts []`, matching what
    `VirtualDom.server.js` renders. Nothing throws.
- Every `__Home_name` token used must appear in the header imports (eco kernel-JS pitfall).

### 7.3 `setBodyAsHtml` (eco/system; checked against the merged `system-kernel-cpp/`)

**Elm.**
- `system-kernel-cpp/src/Http/Server/Internal.elm:26-28` becomes
  `type Body = StringBody String | BytesBody Bytes | HtmlBody Dom.Node`.
- `Response.elm` and `Internal.elm` add `import Http.Dom as Dom` (the snippets below use the
  `Dom.` alias) and `import VirtualDom`. `Response.elm` gains (and exposes in its module header
  and `@docs`):

```elm
setBodyAsHtml : VirtualDom.Node msg -> Response -> Response
setBodyAsHtml node (Internal.Response r) =
    Internal.Response { r | body = HtmlBody (Dom.fromNode node) }
```

- `send` (`Response.elm:57-58`) dispatches on the body. Its doc comment gains one sentence: an
  HTML body is serialized as it is sent (see `setBodyAsHtml`).

```elm
send : Response -> Cmd msg
send (Internal.Response r) =
    case r.body of
        HtmlBody node ->
            System.endSimpleProgram
                (kRespondHtml r.key r.status (withHtmlContentType r.headers) (isDocument node) node)

        _ ->
            System.endSimpleProgram (kRespond r.key r.status r.headers (bodyBytes r.body))


withHtmlContentType : List ( String, List String ) -> List ( String, List String )
withHtmlContentType headers =
    if List.any (\( name, _ ) -> String.toLower name == "content-type") headers then
        headers

    else
        ( "Content-Type", [ "text/html; charset=utf-8" ] ) :: headers


isDocument : Dom.Node -> Bool
isDocument node =
    case node of
        Dom.Mapped _ inner ->
            isDocument inner

        Dom.Element Nothing tag _ _ ->
            String.toLower tag == "html"

        Dom.KeyedElement Nothing tag _ _ ->
            String.toLower tag == "html"

        _ ->
            False


kRespondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Dom.Node -> Task Never ()
kRespondHtml =
    Eco.Kernel.HttpServer.respondHtml
```

- `bodyBytes` gains `HtmlBody node -> kStringToUtf8 (Dom.render node)`, for exhaustiveness and
  any other caller.

**Native** (`system-kernel-cpp/src/eco-system/HttpServer/`, eco/system conventions §1.1 E3):
- **Export.** `HttpServerExports.cpp` gains, after `Eco_Kernel_HttpServer_respond` (`:27-44`)
  and in the same shape:

```cpp
// respondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Http.Dom.Node -> Task Never ()
uint64_t Eco_Kernel_HttpServer_respondHtml(int64_t key, int64_t status, uint64_t headers,
                                           uint64_t doctype, uint64_t node) {
    ECO_KERNEL_GUARD(
        HPointer headersHP = dec(headers);
        HPointer doctypeHP = dec(doctype);
        HPointer nodeHP = dec(node);
        HPointer ks = alloc::listNil();
        HPointer hdn = alloc::listNil();
        Elm::StackRootGuard g({&headersHP, &doctypeHP, &nodeHP, &ks, &hdn});
        // Five arguments: nested tuples (G2), each rooted before the next allocation.
        ks = alloc::tuple2(alloc::unboxedInt(key), alloc::unboxedInt(status), 0x5);
        hdn = alloc::tuple3(alloc::boxed(headersHP), alloc::boxed(doctypeHP), alloc::boxed(nodeHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(ks), alloc::boxed(hdn), 0);
        return enc(makeAsyncBinding<httpServerRespondHtmlBody>(payload));
    )
}
```

- **Declaration.** `HttpServer.hpp` gains, after `httpServerRespondBody` (`:33-35`):
  `// captured = ( ( key, status ) mask 0x5, ( headers, doctype, node ) ) mask 0.` followed by
  `HPointer httpServerRespondHtmlBody(HPointer captured, HPointer resume);`.
- **Body.** In `HttpServer.cpp`, factor the header loop of `httpServerRespondBody`
  (`:298-303`) into a file-local
  `static void copyHeaders(HPointer headers, ResponseData& data)`, which does not allocate.
  Then add `httpServerRespondHtmlBody`, a copy of `httpServerRespondBody` (`:282-313`) whose
  G3 scope reads:

```cpp
        {   // G3: copy everything out; no allocation in this scope (G5)
            Tuple2* outer = asTuple2(captured);
            Tuple2* ks = asTuple2(outer->a.p);
            key = ks->a.i;
            data.status = ks->b.i;
            Tuple3* hdn = asTuple3(outer->b.p);
            copyHeaders(hdn->a.p, data);
            if (::Elm::hpBits(hdn->b.p) == ::Elm::hpBits(alloc::elmTrue()))   // Bool: a constant
                data.body = "<!DOCTYPE html>";
            // R8/VDOM_004: no Eco allocation and no Elm call, so G5 holds across the walk.
            ::Elm::Kernel::VirtualDom::writeHtml(enc(hdn->c.p), data.body);
        }
```

  Everything after the scope (`ensureHttpTables`, G10 registration, `httpTablesRespond`) is
  unchanged, so HTTP/1.1, HTTP/2, `HEAD` and keep-alive framing are shared with `respond`.
  `HttpServer.cpp` adds `#include "virtual-dom/HtmlWriter.hpp"`, and its file header's kernel
  list (`:29-36`) gains `respondHtml` next to `respond`. Its "Templates used" line is unchanged
  (T2, T4, G3, G10).
- **Windows.** `HttpServerServiceWin32.cpp` stubs the service, not the bodies, so the new body
  needs no Windows variant.
- **CMake** (`system-kernel-cpp/CMakeLists.txt`, after `:149`):
  `target_link_libraries(EcoSystem_HttpServer PRIVATE ElmKernel_VirtualDom)`. This gives
  eco/system the `elm-kernel-cpp/src` include path (`elm-kernel-cpp/CMakeLists.txt:161-164`) and
  pulls the library into `eco-system-core-test`. **No registration and no AOT change:** the
  `test` binary whole-archives `EcoSystem_HttpServer`, and the AOT driver already links
  elm-kernel and eco/system archives in one group (§1.1 E4, E5).

**JS** (`system-kernel-cpp/src/Eco/Kernel/HttpServer.js:1276-1295`): after `_HttpServer_respond`,
add

```js
// respondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Http.Dom.Node -> Task Never ()
var _HttpServer_respondHtml = F5(function(key, status, headers, doctype, node)
{
	return __Scheduler_binding(function(callback)
	{
		var complete = function()
		{
			callback(__Scheduler_succeed(__Utils_Tuple0));
		};
		var e = _HttpServer_pending[key];
		if (!e)
		{
			complete();   // unknown or already answered
			return;
		}
		delete _HttpServer_pending[key];
		__Stream_noteActivity();
		var user = _HttpServer_userHeaders(headers);
		var body = Buffer.from((doctype ? '<!DOCTYPE html>' : '') + __Dom_render(node), 'utf8');
		_HttpServer_writeAnswer(e, status, user.__raw, body, user.__askClose, complete);
	});
});
```

- Add `import Http.Dom as Dom exposing (render)` to the header comment (`HttpServer.js:1-9`).
  The alias keeps the `__Dom_render` spelling, and every `__Home_name` token must be imported
  (eco JS-kernel pitfall).
- Add `respondHtml` to the kernel list in the file's header comment, next to `respond`.

---

## 8. Serialization rules (shared spec; Elm reference in Appendix A, C++ mirror in B.5)

1. **Work loop.** Each item is `Visit raw node` or `Emit text`. The start state is
   `[Visit False root]`. Output is the concatenation of emitted texts.
2. **Text:** if `raw`, emit `rawText s`, which replaces each `</` with `<\/`. Otherwise emit
   `escapeText s`, which replaces `& < > " '` with `&amp; &lt; &gt; &quot; &#039;` (with `&`
   first).
3. **`Mapped _ inner`** → `Visit raw inner`. **`KeyedElement`** is treated as `Element` over the
   second components of its pairs.
4. **`Element ns tag facts kids`:**
   - If the tag is token-breaking (D17), push `Visit False` for each kid (unwrap).
   - Otherwise, with `lower = asciiLower tag`, `isHtml = (ns == Nothing)` and
     `r = resolve ns lower facts`:
     - emit `<` ++ tag (verbatim) ++ attributes ++ `>`;
     - if `isHtml` and `lower` ∈ {`area base br col embed hr img input link meta source track wbr`},
       stop there (no children, no end tag);
     - else if `isHtml`, `lower == "textarea"` and `r.textareaValue == Just v`, emit
       `escapeText v` then `</tag>`;
     - else push `Visit (isHtml && lower == "style")` for each kid, then `Emit "</tag>"`.
   - Each attribute is rendered as ` name` when its value is `Nothing`, and as
     ` name="escapeAttr v"` otherwise. `escapeAttr` replaces `& " < >`.
5. **`resolve ns lower facts`** emulates `_VirtualDom_organizeFacts` followed by
   `_VirtualDom_applyFacts` (`elm-virtual-dom/src/Elm/Kernel/VirtualDom.js:389-420`, `:500-570`).

   **Organize**, folding the facts in order:
   - `Attribute k v` → bucket ATTR. Upsert in place; when `k == "class"` and a value exists, join
     the two with a space (an empty old value is replaced).
   - `AttributeNS _ k v` → bucket ATTR_NS (upsert).
   - `Style k v` → bucket STYLE (upsert).
   - `Property k json` → a property slot `k`, upserted with `propValue json`. For
     `k == "className"` an existing value is joined with a space (via `jsString`).
   - `Event` → ignored.
   - A bucket's slot is created at its first fact, and the slot order is first-insertion order.

   **Apply**, walking the slots in order, with state `attrs` (ordered, name → `Maybe String`),
   `styleRaw`, `styleProps` (ordered) and `textareaValue`:
   - STYLE: `setStyle k v` for each entry.
   - ATTR: `setAttr (isHtml ? asciiLower k : k) (Just v)` for each entry.
   - ATTR_NS: `setAttr k (Just v)` for each entry (no lowercasing).
   - Property `k pv`, by `reflection k`:
     - `AsString name` → `setAttr name (jsString pv)` when that is `Just`.
     - `AsBool name` → `truthy pv` ? `setAttr name Nothing` (bare) : `removeAttr name`.
     - `AsValue` → for `lower == "textarea"`, `textareaValue = jsString pv`; for
       `lower == "select"`, nothing; otherwise as `AsString "value"`.
     - `NoReflect` → nothing.
   - `setAttr name v`:
     - drop it if the name is token-breaking (attribute rule);
     - for `name == "style"`, set `styleRaw = v or ""`, clear `styleProps`, and upsert a
       `style` placeholder;
     - otherwise upsert in place.
   - `removeAttr name` deletes the entry.
   - `setStyle k v`: with `n = cssName k`, `v == ""` removes `n` from `styleProps`; otherwise
     upsert it, and append a `style` placeholder if there is none.
   - **Finish:** the `style` entry's value becomes `styleRaw ++ props` when `props` is empty,
     `styleRaw` is empty or `styleRaw` ends with `;`, and `styleRaw ++ ";" ++ props` otherwise,
     where `props = concat (n ++ ":" ++ v ++ ";")`. (An untouched `style` attribute keeps its
     text exactly, as in a browser; golden D.1 #10.)

   **Reflection table** (closed; built from every property key `Html/Attributes.elm` uses):
   - `AsString` with renaming: `className→class`, `htmlFor→for`, `httpEquiv→http-equiv`,
     `acceptCharset→accept-charset`, `accessKey→accesskey`, `useMap→usemap`,
     `contentEditable→contenteditable`, `spellcheck→spellcheck`.
   - `AsString` with the same name: `accept action align alt autocomplete cite coords dir
     download dropzone enctype headers href hreflang id kind label lang max method min name
     pattern ping placeholder poster preload sandbox scope shape span src srcdoc srclang start
     step target title type wrap`.
   - `AsBool`: `isMap→ismap`, `noValidate→novalidate`, `readOnly→readonly`, and the same-name
     `autofocus autoplay checked controls default disabled hidden loop multiple required
     reversed selected`.
   - `AsValue`: `value`.
   - Anything else is `NoReflect`.

   **`propValue`** is one of `PString`, `PBool`, `PNumber` (ints are read as floats),
   `PNull` or `PCompound`.
   - **`jsString`:** string → itself; bool → `"true"`/`"false"`; number → shared float
     formatter; null → `"null"`; compound → none.
   - **`truthy`:** string ≠ `""`; bool; number ≠ 0 and not NaN; null → false;
     compound → true.

   **`cssName k`:**
   - `k` verbatim if it contains `-` or has no ASCII uppercase letter;
   - `cssFloat → float`;
   - otherwise each ASCII uppercase letter `C` becomes `-c`, and the result gets a leading `-`
     if it starts with `webkit-`, `moz-`, `ms-` or `o-`.
6. **Encoding:**
   - C++ writes UTF-8 using the runtime's transcoding (`StringOps::toStdString`), so a lone
     surrogate becomes its 3-byte form (F9).
   - Elm produces a `String`.
   - Name tests (`asciiLower`, token-breaking) operate on ASCII only, so the UTF-8 and UTF-16
     implementations agree.
7. **Numbers:** both native serializers use `StringOps::formatFloatShortest` (P0.2), so native
   `String.fromFloat` and `HtmlWriter` agree.
8. **Known deliberate divergences from a browser** (module docs):
   - children of void elements are dropped;
   - `select`'s `value` property does not mark an option;
   - `xmp`/`iframe`/`noembed`/`noframes`/`noscript` text is escaped (safe, but entities may
     show);
   - `null` property → `"null"`, arrays and objects → no write;
   - JS object integer-key ordering is ignored;
   - JS-target filters follow whichever elm/virtual-dom version is installed (F17).

---

## 9. Phases

**Every phase ends with these gates green** (v6, §1.1 E8; the gates of `plans/eco-system-library.md`
§3.3.3):
1. **Normal suite:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, run
   **once** (CLAUDE.md). `full` also runs `check-root-bounded.py` and `check-kernel-homes.sh`,
   then the JIT E2E suite, `eco-system-core-test` and the JS eco/system suite (`run-js-e2e`).
2. **Validate tree** (from P2 on). Configure it once with
   `cmake -DECO_HEAP_VALIDATE=ON --preset build -B build-validate`. Then run
   `ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=$PWD/benchmarks/heap-config-gc-pressure.json build-validate/test/test --filter <F> 2>&1 | tee /tmp/test_output_validate.txt`,
   where `<F>` is `VirtualDomKernel` (P2, P4), `elm-html` (P3) or `eco-system` (P5, P6).
   This gate catches a forgotten root.
3. **Stress** (P6): `ECO_NURSERY_POISON=1 build-validate/test/stress-test --timeout 5m --filter EcoSystemHttpServerHtml`.


### P0 — Groundwork in this repo (no behaviour change for existing programs)

- **P0.1 `Debug.toString` fallback (D19).** In `runtime/src/allocator/RuntimeExports.cpp`, Custom
  branch of `print_typed_value` (`:4052-4150`):
  - `ctor_count == 0` → `output_text("<internals>"); break;`, before the constant handling;
  - `header->tag != Tag_Custom` → `<internals>` (replaces the assert and `<not-custom>`);
  - `ctor_info == nullptr` → `<internals>` (replaces the assert);
  - `ctor_info->field_count != size` → `<internals>` (replaces the assert).

  Add a comment citing D19 and JS's `<internals>`.
  - **Test:** `test/elm-html/src/DebugInternalsTest.elm`, created with the suite in P3. It needs
    `elm/json` as a direct dependency, which `test/elm-html/elm.json` has. It logs
    `Debug.log "html" (Html.div [] [ Html.text "x" ])`, `Debug.log "text" (Html.text "x")` and
    `Debug.log "json" (Json.Encode.string "x")`, with
    `-- CHECK: html: <internals>`, `-- CHECK: text: <internals>` and
    `-- CHECK: json: <internals>`.
- **P0.2 Shared float formatter.** In `runtime/src/allocator/StringOps.hpp`, add
  `inline size_t formatFloatShortest(f64 n, char* buf /*>= 32*/)`. It produces exactly the text
  `fromFloat` produces today (`NaN`, `Infinity`, `-Infinity`, `0` for ±0, else
  `std::to_chars` shortest). `fromFloat` becomes a call to it plus `makeUtf8LeafFromBytes`.
  - **Test:** the existing `String.fromFloat` E2E tests stay green.
- **P0.3 `JsonRead`** (`elm-kernel-cpp/src/json/JsonRead.hpp/.cpp`, Appendix B.3), added to
  `ElmKernel_Json`'s sources (`elm-kernel-cpp/CMakeLists.txt:169-178`).
  - **Unit tests** (new file `test/kernel/VirtualDomKernelTest.cpp`, P2 harness). Build values
    through the exported kernels and check `view`/`arrayElements`/`jsToString`:
    - `Elm_Kernel_Json_wrap` of a string, `""`, True, `wrap_Int`/`wrap_Float`;
    - `Elm_Kernel_Json_encodeNull`;
    - `emptyArray` + `addEntry` × 3, checking the order is restored (F2);
    - `runOnString(decodeValue, "[1,\"a\",[null,true]]")` for the decoded forms, including a
      long array for `CTOR_JSON_ARRAY_CHUNKED`.
- **P0.4 `XssFilters`** (`elm-kernel-cpp/src/virtual-dom/XssFilters.hpp/.cpp`, §6), with unit
  tests over the truth table in Appendix D.2.

### P1 — Fresh VirtualDom kernel

1. Delete `elm-kernel-cpp/src/virtual-dom/VirtualDom.hpp`, `VirtualDom.cpp` and
   `VirtualDomExports.cpp`.
2. Add `VirtualDomLayout.hpp` (B.1), `VirtualDomExports.cpp` (B.2), and empty-for-now
   `HtmlWriter.hpp/.cpp`. There is no `DomExports.cpp` here: it lives in eco/system (D8, P5).
3. Update `elm-kernel-cpp/CMakeLists.txt:157-166`:

   ```cmake
   add_library(ElmKernel_VirtualDom STATIC
       src/virtual-dom/VirtualDomExports.cpp
       src/virtual-dom/XssFilters.cpp
       src/virtual-dom/HtmlWriter.cpp
   )
   target_link_libraries(ElmKernel_VirtualDom PUBLIC ElmKernel_Json)
   ```

4. In `elm-kernel-cpp/src/KernelExports.h:350-377`, add the prototype
   `HPtr Elm_Kernel_VirtualDom_noJavaScriptUri(HPtr value);`.
5. In `runtime/src/codegen/RuntimeSymbols.cpp:803-828`, add
   `KERNEL_SYM(Elm_Kernel_VirtualDom_noJavaScriptUri)` (F16). Nothing named `Eco_Kernel_*` is
   added to `elm-kernel-cpp/`: `check-kernel-homes.sh` would fail `full` (§1.1 E1).
6. **Gate:** the ~950 `main = text "done"` tests pass.

### P2 — C++ kernel unit tests (`test/kernel/VirtualDomKernelTest.cpp/.hpp`)

**Wiring:**
- Add the file to `test/CMakeLists.txt:137`.
- Register a `Testing::TestSuite virtualDomKernelTests("VirtualDomKernel")` next to
  `kernelExportsTests` (`test/main.cpp:1094-1095`, `:1226`).
- Follow `KernelExportsTest.cpp`'s pattern: `initAllocator()` and the export calls.

**Cases:**
- **V1 layout:** each constructor kernel → resolve → ctor, `header.size`, field kinds 0, and
  field contents (strings compared with `toStdString`).
- **V2 `nodeNS` rooting.** Set up a small nursery (`initAllocatorScaled(0)`, 64 KB) and, for
  `i` in `0..4096`:
  - build `ns`, `tag`, `facts = [attribute "a" "b"]` and `kids = [text "k"]`, rooted test-side
    with a `StackRootGuard`;
  - call `allocateGarbageInts(alloc, i)` (`test/allocator/TestHelpers.hpp:177`);
  - call `Elm_Kernel_VirtualDom_nodeNS` and verify the whole result (V1 checks).

  Some `i` lands a minor GC between `just` and `custom`. Repeat the scheme for `keyedNodeNS`
  and `mapAttribute`.
- **V3 `lazy`:** a test closure (`eco_alloc_closure_fn`, as `KernelExportsTest.cpp:213` does)
  whose evaluator allocates garbage and then returns `Elm_Kernel_VirtualDom_text(arg)`. Check
  `lazy` through `lazy8` return that node.
- **V4 filters:** the export-level wrappers return the input word unchanged when there is no
  match, and the right strings otherwise. `noJavaScriptOrHtmlJson` returns an `ENC_STRING ""`
  (check with `JsonRead::view`).
- **V5 literal arguments:** pass a raw pointer to a static `ElmString` as `tag`, if the test
  harness can build one. Otherwise rely on the E2E tests, where literals arrive this way.

### P3 — `test/elm-html` E2E suite (no `Http.Dom` yet)

**Wiring:**
- Create `test/elm-html/{elm.json, ElmHtmlTest.hpp, src/}`, modelled on `test/elm-url`.
  `elm.json` direct deps: `elm/core 1.0.5`, `elm/html 1.0.0`, `elm/json 1.1.3`; indirect:
  `elm/virtual-dom 1.0.3`.
- Add `elm-html` to `ELM_TEST_PACKAGES` (`test/CMakeLists.txt:15-27`) and
  `aot_test_packages()` (`test/aot_e2e_main.cpp:188-195`).
- Include and register the suite in `test/main.cpp` (pattern at `:77`, `:1197`, `:1237`).

**Tests:**
- `HtmlApiCoverageTest.elm` references **every exposed function** of `Html`,
  `Html.Attributes`, `Html.Events`, `Html.Keyed` and `Html.Lazy`, and builds one tree that uses
  them all. A missing symbol or ABI mismatch fails the build (CGEN_038). It logs
  `-- CHECK: built: <internals>`.
- `HtmlLazyTest.elm`: `lazy`…`lazy8` with a function that `Debug.log`s its arguments.
  `CHECK` lines prove eager evaluation and argument order.
- `HtmlLargeTreeTest.elm` builds 200k nodes and a 10k-deep nesting through `Html.div`/`Html.map`
  and logs `done`. It is GC pressure on the constructors.
- `DebugInternalsTest.elm` (specified in P0.1).

### P4 — `HtmlWriter` C++ (`elm-kernel-cpp/`)

- Implement `HtmlWriter.cpp` (B.5) as a **line-by-line mirror of Appendix A** (same function
  names).
- **Unit tests V6** in `VirtualDomKernelTest.cpp`: build the trees for Appendix D.1 cases 1–17
  and 20–24 from C++ through the kernels. Properties come from
  `Elm_Kernel_Json_wrap`/`wrap_Int`/`wrap_Float` and booleans from the Bool constants. Call
  `Elm::Kernel::VirtualDom::writeHtml(bits, out)` and compare `out` with the expected strings.
  `Eco_Kernel_Dom_toString` is P5's; it adds only the final string allocation.
- **V7 totality:** a seeded fuzz of 10k random tags, attribute names, values and JSON property
  values over a 64-character alphabet that includes every breaking character. It must never
  crash, and the output must never contain a breaking character inside an emitted name.
- **V8:** a lone surrogate in a text node is emitted as its 3-byte form.

### P5 — `Http.Dom` in eco/system (Elm module, native exports and JS twin together)

The JS twin lands in this phase, not after it (§1.1 E12). `full` runs the JS eco/system suite,
and without `src/Eco/Kernel/Dom.js` every `_Dom_*` reference is undefined at run time on JS.

1. **Rules** (`plans/eco-system-library.md` §3.2). After B1a, add:
   > **B1b The VirtualDom side door.** `Eco.Kernel.Dom.fromNode`/`fromAttribute`/`toString`
   > take `VirtualDom.Node msg`/`VirtualDom.Attribute msg`, and `HttpServer.respondHtml` takes an
   > `Http.Dom.Node`. Natively these are one and the same heap layout, read-only, defined by
   > `elm-kernel-cpp/src/virtual-dom/VirtualDomLayout.hpp` and pinned by VDOM_001 and
   > `test/eco-system/src/DomLayoutTest.elm` (plans/elm-html-native-kernel.md §3). On JS the
   > twin reads VirtualDom's objects through calibrated keys (Appendix C).

   In B5, extend the list of allowed pure kernels with "`Dom.fromNode`, `Dom.fromAttribute` and
   `Dom.toString` (side-effect-free conversions, B1b)".
2. **Package metadata.**
   - `system-kernel-cpp/elm.json`: add `Http.Dom` to `exposed-modules` after
     `Http.Server.Response`, and `"elm/virtual-dom": "1.0.0 <= v < 2.0.0"` to `dependencies`.
   - `test/eco-system/elm.json`: add `"elm/html": "1.0.0"` and `"elm/virtual-dom": "1.0.3"` to
     `direct`. Both are in the package cache, so nothing is fetched (E7).
   - `examples/system/elm.json`: add `"elm/virtual-dom": "1.0.3"` to `indirect` (E6).
     `test/stress-elm/elm.json` already lists it.
3. **Elm.** Add `system-kernel-cpp/src/Http/Dom.elm` (Appendix A).
4. **Native.**
   - Add `system-kernel-cpp/src/eco-system/Dom/DomExports.cpp` (B.4).
   - In `system-kernel-cpp/CMakeLists.txt`, after the WebSocket module block (`:297-322`), add:

     ```cmake
     # Http.Dom's kernels: the VirtualDom side door (plans/elm-html-native-kernel.md §4.2, B1b).
     # The serializer itself is ElmKernel_VirtualDom's writeHtml.
     eco_system_module(Dom          POSIX
         src/eco-system/Dom/DomExports.cpp)
     target_link_libraries(EcoSystem_Dom PRIVATE ElmKernel_VirtualDom)
     ```

   - Append `Dom` to `ECO_SYSTEM_MODS` (`runtime/src/codegen/CMakeLists.txt:958-959`). That
     one list drives the AOT link (`EcoBootConfig.h`), the `test`/`stress-test` whole-archive
     link, the eco-boot dependencies and the bundle installs (E4). The `foreach` at
     `system-kernel-cpp/CMakeLists.txt:325-329` fails configuration if the target is missing.
5. **JS twin.** Add `system-kernel-cpp/src/Eco/Kernel/Dom.js` (Appendix C). Before the first
   build, check that every `__[A-Z]` token in it appears in its header imports:
   `grep -o '__[A-Z][A-Za-z]*_[A-Za-z]*' Dom.js | sort -u`.
6. **Tests** in `test/eco-system/src/`. Both the native suite and `run-js-e2e` pick them up with
   no wiring (E9). Each is a `System.SimpleProgram` that prints its result lines with
   `Stream.Log.line env.stdout`, as `HelloStdoutTest.elm` does, so the output is the same on
   both targets. SVG is built as `elm/svg` builds it:
   `svgNode = VirtualDom.nodeNS "http://www.w3.org/2000/svg"`, with
   `VirtualDom.attribute`/`attributeNS` (E7).
   - `DomLayoutTest.elm`: build every `Node`/`Fact` shape through `Html`, `Html.Keyed`,
     `Html.map`, `Html.Attributes.style`/`property`/`attribute`, `Html.Events.on` and `svgNode`
     with an `attributeNS`. Pattern-match the results with `Http.Dom.fromNode` and
     `Http.Dom.fromAttribute`, and print the extracted constructor names, strings and namespaces
     (one `-- CHECK:` per shape). This pins VDOM_001 natively and the calibration on JS.
   - `DomGoldenTest.elm`: every case in Appendix D.1. Print
     `<n>: <Http.Dom.toString h>` and `<n> ref: <Http.Dom.render (Http.Dom.fromNode h)>`,
     checking both against the expected string. Cases whose JS output may differ under D16
     (several attributes on one element, number text) are written so that they do not depend
     on it: one attribute per element, and integral numbers.
   - `DomDifferentialTest.elm` (`-- SKIP-JS: compares the C++ HtmlWriter with the Elm render;
     on JS both are the Elm render`): an Elm LCG with a fixed seed (no `elm/random`) generates
     2,000 random trees from a vocabulary of tags, including breaking ones, `attribute`,
     `property` with string/bool/int/float/null/list values, `style`, `classList`, `map`,
     `Keyed` and `lazy`. Count the trees where
     `Http.Dom.toString h /= Http.Dom.render (Http.Dom.fromNode h)`, and expect
     `-- CHECK: mismatches: 0`. Strings exclude lone surrogates (F9; V8 covers them).
   - `DomDeepTest.elm`: a 10k-deep and a 200k-wide tree through both serializers. Print the
     lengths and whether they are equal. On JS this also proves that the twin's conversion is
     iterative (D17).

### P6 — `setBodyAsHtml` (§7.3, native and JS together)

1. The Elm changes in `Internal.elm` and `Response.elm` (§7.3). In `Response.elm`, add
   `setBodyAsHtml` to the module's `exposing` list and to the `## Body` `@docs` line, give it
   a doc comment (D13, D15, the `Http.Dom` divergences), and add the `send` doc sentence.
2. Native `respondHtml` (export, declaration, `copyHeaders` refactor, body) and the CMake link
   `EcoSystem_HttpServer → ElmKernel_VirtualDom`.
3. JS `_HttpServer_respondHtml` and its header import.
4. **E2E test** `test/eco-system/src/HttpServerHtmlTest.elm`, on `HttpServerTestHelp.program`
   (pattern: `HttpServerJsonTest.elm`). The handler dispatches on `request.url.path`:
   - `/page` → `Response.setBodyAsHtml (node "html" [] [ node "body" [] [ text "x" ] ])`;
   - `/xhtml` → `Response.setHeader "Content-Type" "application/xhtml+xml"`, then
     `setBodyAsHtml (div [] [ text "y" ])`;
   - `/frag` → `setBodyAsHtml (Html.map identity (p [] [ text "<z>" ]))`.

   The client runs `Help.get` on each path in turn. Expected lines:

   ```
   -- CHECK: client: 200 text/html; charset=utf-8 <!DOCTYPE html><html><body>x</body></html>
   -- CHECK: client: 200 application/xhtml+xml <div>y</div>
   -- CHECK: client: 200 text/html; charset=utf-8 <p>&lt;z&gt;</p>
   ```

   This covers D15's three rules: the doctype only for an `html` root, the Content-Type added,
   and a user Content-Type kept. The harness prints client lines as `client: <line>`
   (`HttpServerTestHelp.elm:184`), and `get` looks up the lower-cased `content-type` header in
   elm/http's metadata (`:120-123`).
5. **Stress** `test/stress-elm/src/EcoSystemHttpServerHtml.elm` (pattern:
   `EcoSystemHttpServerSequential.elm`, `StressHarness`): each cycle serves a 5,000-node page
   with `setBodyAsHtml` and fetches it, checking the length. It runs under gate 3, so a nursery
   collection lands between the export's tuple allocations and during the copy-out of a large
   tree.

### P7 — JS target (no separate landing; it applies inside P5 and P6, E12)

- `full` runs every P5/P6 test under `run-js-e2e`. Run a subset by hand with
  `TEST_FILTER=eco-system/Dom,eco-system/HttpServerHtml cmake --build build --target run-js-e2e`;
  logs are in `build/test/js-e2e/out/<Name>.log`.
- Golden expectations may differ only where D16 allows. Prefer test shapes that cannot differ
  (P5 step 6). Use `-- SKIP-JS: <reason>` only for native-only behaviour, as
  `run-js-e2e.js:29-30` requires.
- On a calibration failure (wrong `$` codes or keys), fix the probe in `_Dom_calibrate`. Never
  hard-code renamed field letters (F6).

### P8 — Invariants and documentation

- Add VDOM_001–VDOM_005 (§11) to `design_docs/invariants.csv`.
- Module docs for `Http.Dom`: the model, `==`, eager `lazy`, §8.8 divergences, and D16.
- `system-kernel-cpp/README.md`: add to the Modules list, after `Http.Server`, the line
  "`Http.Dom`: a transparent view of `Html`/`Svg` values and their HTML serialization", and
  mention `setBodyAsHtml` in the `Http.Server` line. Run `pnpm docs:check` in
  `system-kernel-cpp/` (stock Elm, E11) to confirm the docs build.
- A note in `elm-kernel-cpp/LIBRARY_DEPENDENCIES.md` (VirtualDom: no external libraries).
- *Optional:* `KernelFacts` rows for the **`VirtualDom`** home only (constructors are pure
  allocators; filters are pure), added by the audited-row procedure in
  `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`. Not required for correctness: a missing row
  is the conservative default. **No `( "Dom", … )` rows.** Fact tables are keyed without the
  `Eco` prefix, and `check-kernel-homes.sh` counts every home named there as a non-eco/system
  home (`:20-24`), so a Dom row would collide with `Dom.js` and fail `full`. No eco/system
  kernel has fact rows today.

---

## 10. Test inventory (where each guarantee is checked)

| Guarantee | Tests |
|---|---|
| Every elm/html function links and runs natively | P3 `HtmlApiCoverageTest` |
| Constructor layout = `Http.Dom` declaration (VDOM_001) | P2 V1, P5 `DomLayoutTest` |
| GC rooting in two-allocation kernels and `lazy` | P2 V2/V3, P3 `HtmlLargeTreeTest` |
| XSS filters = 1.0.5 JS PROD (VDOM_003) | P0.4, P2 V4, D.2 table |
| Serializer spec, Elm = C++ (VDOM_005) | P4 V6, P5 golden + differential |
| No crash on any input (D17) | P4 V7, P5 differential (breaking names), deep trees |
| `Debug.toString` safe (D19) | P0.1 / P3 `DebugInternalsTest` |
| HTML response path, headers, doctype (D13/D15) | P6 |
| JS target | P5 and P6 under `run-js-e2e` (rules in P7) |

## 11. Invariants to add

- **VDOM_001 (Runtime_Heap):** native VirtualDom values are `Tag_Custom` objects whose ctor and
  field layout equals eco/system `Http.Dom.Node`/`Http.Dom.Fact`. `VirtualDomLayout.hpp` is the only C++
  source of those constants, and `DomLayoutTest` enforces the match.
- **VDOM_002 (Runtime_Heap):** VirtualDom and Dom kernels keep no off-heap state, write no heap
  object after constructing it, and evaluate `lazy*` eagerly. Taggers and handlers are retained
  only inside the values they return.
- **VDOM_003 (CrossPhase):** the native XSS filters return what elm/virtual-dom 1.0.5's JS PROD
  arms return, for every input.
- **VDOM_004 (Runtime_Heap):** `HtmlWriter` and `JsonRead` never allocate on the Eco heap and
  never call Elm code. `Eco_Kernel_Dom_toString` allocates once, after the walk, and
  `httpServerRespondHtmlBody` allocates nothing in its copy-out scope.
- **VDOM_005 (CrossPhase):** `Http.Dom.render` (Elm) and `HtmlWriter` (C++) implement §8 and agree
  byte for byte natively. All text and attribute values are escaped. No token-breaking name is
  emitted: attributes are dropped and elements unwrapped. Serialization is total: no input
  makes it crash, assert or abort.

## 12. Risks

- **K-1 — Module name (resolved).** The module is namespaced as `Http.Dom` (D7, F15).
- **K-2 — Layout coupling (D3).** A future compiler change could give custom types
  type-specific layouts. With only boxed, non-polymorphic fields that is unlikely, and the pin
  test catches it. The fallback is a copying `fromNode` with the same Elm API.
- **K-3 — JS internals (D14).** Calibration absorbs renaming and version drift. A *structural*
  change in VirtualDom's JS objects (for example, a field that holds an array no longer being
  an array) would break the twin; `DomLayoutTest` under `run-js-e2e` catches it (P5, P7).
- **K-4 — Eager `lazy` (D5)** differs from the browser only for subtrees that crash or never
  terminate and are never rendered.
- **K-5 — Weakened printer asserts (D19).** Codegen bugs that produce mismatched shapes now
  print `<internals>` instead of aborting. This only affects the `Debug` printing path.

## 13. Out of scope

- `Browser.*` natively, diffing, patching, events and hydration.
- Native `elm-explorations/test` `HtmlAsJson`.
- Printing `main : Html` (D9).
- Chunked HTML streaming across scheduler yields.
- Removing the `Json.hpp` stub (F18).

---

## 14. Implementation notes (v7)

What implementing the plan changed or found, in order of discovery:

- **I1 — Style finish rule (spec bug, fixed in §8.5, Appendix A and C++).** The v6 rule appended
  `;` to a raw `style` attribute even when no style property followed, so golden D.1 #10 gave
  `style="margin: 0;"`. A browser leaves an untouched `style` attribute as written. The rule now
  takes `styleRaw ++ props` when `props` is empty.
- **I2 — Native `Json.Decode.null` did not match `Json.Encode.null` (kernel bug, fixed).**
  `Encode.null` is the embedded `ENC_NULL` constant. `Elm_Kernel_Json_run` bridged only heap
  encoder nodes to the decoder family, so `runDecoder` saw ctor 0, not `CTOR_JSON_NULL`, and
  `DEC_NULL` failed: `Decode.decodeValue (Decode.null x) Encode.null` (and `Decode.nullable`)
  was `Err` natively. The differential test found it (83 of 2,000 trees). Fixed in
  `JsonExports.cpp` (`Elm_Kernel_Json_run` maps the `ENC_NULL` constant to the `CTOR_JSON_NULL`
  constant before decoding) through the LSS_022 procedure: every licensed row pinned to the file
  got a `re-audit 2026-10-08` note (31 KernelSetFacts rows, 2 KernelIntrinsics rows) and the
  manifest was regenerated. This amends D18 for this one fix. Regression test:
  `test/elm-json/src/DecodeValueEncodeNullTest.elm`. `Http.Dom.propValue` uses plain
  `Decode.null` again.
- **I3 — DEV-mode filter text on JS (D16 extended).** `run-js-e2e` compiles in DEV mode, where
  elm/virtual-dom replaces a filtered URI with `javascript:alert("This is an XSS vector…")`
  instead of `""`. DomGoldenTest cases 14–16 accept either text.
- **I4 — Kernel-home check reads comments.** A comment in `elm-kernel-cpp` that spelled out an
  `Eco_Kernel_Dom_*` symbol made `check-kernel-homes.sh` report a `Dom` collision (the E1
  mechanism). `HtmlWriter.hpp` now names the caller without the C symbol.
- **I5 — Test expectations follow eco's output.** `Debug.toString` prints lists and tuples with
  `, ` (`[1, 2]`, `(<internals>, 1)`), and eco evaluates list elements right to left, so
  HtmlLazyTest checks its log lines with `CHECK-DAG`.
- **I6 — Order of work.** `HtmlWriter` was written in full in P1 rather than as an empty file,
  and P4's unit tests (V6–V8) landed with P2's. V5 builds static `ElmString`s outside the heap and
  passes their raw addresses to the constructors, the filters and the writer. Compiled code now
  interns literals as permanent heap objects (`eco_alloc_string_literal`), and the GC traces only
  heap and permanent objects, so V5 checks the R3 read path before any collection.
- **I11 — KernelFacts rows (P8, done).** 18 audited rows under the `VirtualDom` home: the 12
  constructors (`GcFixed 1`, or `GcFixed 2` for `nodeNS`, `keyedNodeNS` and `mapAttribute`) and the
  6 filters (`cppAlloc`; `noJavaScriptUri` and `noJavaScriptOrHtmlUri` are `GcNone`, so they are
  gc-leaf). `params` stays empty, so the borrow analysis is unchanged; `lazy*` have no row, and no
  `Dom` rows exist (kernel-home check). `KernelFactsTest` pins 75 rows and 18 gc-leaf keys.
- **I7 — `respond` shares its tail.** `httpServerRespondBody` and `httpServerRespondHtmlBody` share
  `copyHeaders` and `submitResponse` (registration, count, `httpTablesRespond`), so the two cannot
  drift.
- **I9 — Stress gate budget.** The E2E child watchdog is a fixed 60 s
  (`test/IsolatedTestRunner.hpp:47`, `test/ElmE2ETestBase.hpp:1254`), whatever `--timeout` says,
  so on the validate tree the documented `--timeout 5m` stress command kills any long HTTP
  scenario (the existing `EcoSystemHttpServerSequential` included). Fixed in the harness:
  `runMlirTestsParallel` now allows `StressFlags.timeoutMs` plus `TEST_TIMEOUT_SECONDS` when a
  stress `--timeout` is given (normal suites keep 60 s), and `ECO_TEST_TIMEOUT_SECONDS` overrides
  the 60 s base for slow trees. Gate 3 then passes exactly as specified
  (`--timeout 5m`) for `EcoSystemHttpServerHtml` and `EcoSystemHttpServerSequential`, with clean
  census lines.
- **I10 — Validate-tree observations.** After the I2 fix, gate 2 also covers elm-json (the suite
  of the changed kernel). `RootStackJsonLargeKeyValueTest` and `RootStackJsonLargeListTest` take
  longer than the 60 s watchdog on the validate tree with `heap-config-gc-pressure.json`, with or
  without the I2 change (A/B on 2026-10-08). With `ECO_TEST_TIMEOUT_SECONDS=900` they pass, and
  elm-json is 36/36. One eco-system run
  failed `HttpServerHttp2LimitsTest` (`big header: status 431` missing) under 8-way parallel load;
  it passes alone and passed in the earlier eco-system validate run. In that failing run the
  external `curl` client exited with `(92) Stream error in the HTTP/2 framing layer`. The final
  eco-system validate run on the finished code is green: 164/164.
- **I8 — Docs build.** `pnpm docs:check` runs with stock Elm 0.19.1 (the official release binary,
  sha256 `f8f12a61…92e`, put on `PATH`) and `elm-doc-preview` from `pnpm install`; it passes and the
  docs list `Http.Dom` and `Http.Server.Response.setBodyAsHtml`.

---

## Appendix A — `src/Http/Dom.elm` (eco/system; reference implementation)

```elm
module Http.Dom exposing
    ( Node(..), Fact(..), Tagger, Handler
    , fromNode, fromAttribute
    , attributes, render, toString
    )

{-| A transparent view of `VirtualDom.Node` (and so of `Html` and `Svg`) values,
and their HTML serialization. (Module docs: see plan §11, §8.8, D16.)

@docs Node, Fact, Tagger, Handler, fromNode, fromAttribute, attributes, render, toString

-}

import Eco.Kernel.Dom
import Json.Decode as Decode
import Json.Encode
import VirtualDom


{-| -}
type Node
    = Text String
    | Element (Maybe String) String (List Fact) (List Node)
    | KeyedElement (Maybe String) String (List Fact) (List ( String, Node ))
    | Mapped Tagger Node


{-| -}
type Fact
    = Attribute String String
    | AttributeNS String String String
    | Property String Json.Encode.Value
    | Style String String
    | Event String Handler (List Tagger)


{-| The function given to `Html.map` or `Html.Attributes.map`. Opaque. -}
type Tagger
    = Tagger


{-| An event handler (`VirtualDom.Handler msg`). Opaque. -}
type Handler
    = Handler


{-| -}
fromNode : VirtualDom.Node msg -> Node
fromNode =
    Eco.Kernel.Dom.fromNode


{-| -}
fromAttribute : VirtualDom.Attribute msg -> Fact
fromAttribute =
    Eco.Kernel.Dom.fromAttribute


{-| -}
toString : VirtualDom.Node msg -> String
toString =
    Eco.Kernel.Dom.toString


{-| The attributes the browser would end up with, in order. `Nothing` is a bare boolean attribute. -}
attributes : Node -> List ( String, Maybe String )
attributes node =
    case node of
        Element ns tag facts _ ->
            (resolve ns (asciiLower tag) facts).attrs

        KeyedElement ns tag facts _ ->
            (resolve ns (asciiLower tag) facts).attrs

        Mapped _ inner ->
            attributes inner

        Text _ ->
            []



-- RENDER


type Work
    = Visit Bool Node
    | Emit String


{-| -}
render : Node -> String
render node =
    renderLoop [ Visit False node ] []


renderLoop : List Work -> List String -> String
renderLoop work acc =
    case work of
        [] ->
            String.concat (List.reverse acc)

        (Emit s) :: rest ->
            renderLoop rest (s :: acc)

        (Visit raw node) :: rest ->
            case node of
                Text s ->
                    renderLoop rest
                        ((if raw then
                            rawText s

                          else
                            escapeText s
                         )
                            :: acc
                        )

                Mapped _ inner ->
                    renderLoop (Visit raw inner :: rest) acc

                Element ns tag facts kids ->
                    renderLoop (expand ns tag facts kids rest) acc

                KeyedElement ns tag facts kids ->
                    renderLoop (expand ns tag facts (List.map Tuple.second kids) rest) acc


expand : Maybe String -> String -> List Fact -> List Node -> List Work -> List Work
expand ns tag facts kids rest =
    if isTokenBreaking False tag then
        List.map (Visit False) kids ++ rest

    else
        let
            lowerTag =
                asciiLower tag

            isHtml =
                ns == Nothing

            resolved =
                resolve ns lowerTag facts

            open =
                Emit ("<" ++ tag ++ renderAttrs resolved.attrs ++ ">")

            close =
                Emit ("</" ++ tag ++ ">")
        in
        if isHtml && List.member lowerTag voidElements then
            open :: rest

        else
            case ( isHtml && lowerTag == "textarea", resolved.textareaValue ) of
                ( True, Just value ) ->
                    open :: Emit (escapeText value) :: close :: rest

                _ ->
                    open :: List.map (Visit (isHtml && lowerTag == "style")) kids ++ (close :: rest)


voidElements : List String
voidElements =
    [ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" ]


renderAttrs : List ( String, Maybe String ) -> String
renderAttrs attrs =
    String.concat (List.map renderAttr attrs)


renderAttr : ( String, Maybe String ) -> String
renderAttr ( name, value ) =
    case value of
        Nothing ->
            " " ++ name

        Just v ->
            " " ++ name ++ "=\"" ++ escapeAttr v ++ "\""



-- RESOLVE: _VirtualDom_organizeFacts followed by _VirtualDom_applyFacts (plan §8.5)


type alias Resolved =
    { attrs : List ( String, Maybe String )
    , textareaValue : Maybe String
    }


type PropValue
    = PString String
    | PBool Bool
    | PNumber Float
    | PNull
    | PCompound


type Slot
    = StyleSlot
    | AttrSlot
    | AttrNSSlot
    | PropSlot String PropValue


type alias Organized =
    { slots : List Slot
    , styles : List ( String, String )
    , attrs : List ( String, String )
    , attrsNS : List ( String, String )
    }


type alias Applied =
    { attrs : List ( String, Maybe String )
    , styleRaw : String
    , styleProps : List ( String, String )
    , textareaValue : Maybe String
    }


type Reflect
    = AsString String
    | AsBool String
    | AsValue
    | NoReflect


resolve : Maybe String -> String -> List Fact -> Resolved
resolve ns lowerTag facts =
    let
        organized =
            List.foldl organizeFact { slots = [], styles = [], attrs = [], attrsNS = [] } facts

        applied =
            List.foldl (applySlot (ns == Nothing) lowerTag organized)
                { attrs = [], styleRaw = "", styleProps = [], textareaValue = Nothing }
                organized.slots
    in
    { attrs = List.map (finishStyle applied) applied.attrs
    , textareaValue = applied.textareaValue
    }


organizeFact : Fact -> Organized -> Organized
organizeFact fact o =
    case fact of
        Attribute k v ->
            { o
                | slots = addSlot AttrSlot o.slots
                , attrs =
                    case ( k == "class", lookup k o.attrs ) of
                        ( True, Just old ) ->
                            upsert k (joinClass old v) o.attrs

                        _ ->
                            upsert k v o.attrs
            }

        AttributeNS _ k v ->
            { o | slots = addSlot AttrNSSlot o.slots, attrsNS = upsert k v o.attrsNS }

        Style k v ->
            { o | slots = addSlot StyleSlot o.slots, styles = upsert k v o.styles }

        Property k json ->
            { o | slots = upsertProp k (propValue json) o.slots }

        Event _ _ _ ->
            o


applySlot : Bool -> String -> Organized -> Slot -> Applied -> Applied
applySlot isHtml lowerTag o slot st =
    case slot of
        StyleSlot ->
            List.foldl (\( k, v ) acc -> setStyle k v acc) st o.styles

        AttrSlot ->
            List.foldl
                (\( k, v ) acc ->
                    setAttr
                        (if isHtml then
                            asciiLower k

                         else
                            k
                        )
                        (Just v)
                        acc
                )
                st
                o.attrs

        AttrNSSlot ->
            List.foldl (\( k, v ) acc -> setAttr k (Just v) acc) st o.attrsNS

        PropSlot k value ->
            reflectProp lowerTag k value st


reflectProp : String -> String -> PropValue -> Applied -> Applied
reflectProp lowerTag key value st =
    case reflection key of
        AsString name ->
            setString name value st

        AsBool name ->
            if truthy value then
                setAttr name Nothing st

            else
                removeAttr name st

        AsValue ->
            if lowerTag == "textarea" then
                { st | textareaValue = jsString value }

            else if lowerTag == "select" then
                st

            else
                setString "value" value st

        NoReflect ->
            st


setString : String -> PropValue -> Applied -> Applied
setString name value st =
    case jsString value of
        Just s ->
            setAttr name (Just s) st

        Nothing ->
            st


setAttr : String -> Maybe String -> Applied -> Applied
setAttr name value st =
    if isTokenBreaking True name then
        st

    else if name == "style" then
        { st
            | attrs = upsert "style" Nothing st.attrs
            , styleRaw = Maybe.withDefault "" value
            , styleProps = []
        }

    else
        { st | attrs = upsert name value st.attrs }


removeAttr : String -> Applied -> Applied
removeAttr name st =
    { st | attrs = List.filter (\( n, _ ) -> n /= name) st.attrs }


setStyle : String -> String -> Applied -> Applied
setStyle key value st =
    let
        name =
            cssName key
    in
    if value == "" then
        { st | styleProps = List.filter (\( n, _ ) -> n /= name) st.styleProps }

    else
        { st
            | styleProps = upsert name value st.styleProps
            , attrs =
                if List.any (\( n, _ ) -> n == "style") st.attrs then
                    st.attrs

                else
                    st.attrs ++ [ ( "style", Nothing ) ]
        }


finishStyle : Applied -> ( String, Maybe String ) -> ( String, Maybe String )
finishStyle st ( name, value ) =
    if name == "style" then
        let
            props =
                String.concat (List.map (\( k, v ) -> k ++ ":" ++ v ++ ";") st.styleProps)
        in
        if props == "" || st.styleRaw == "" || String.endsWith ";" st.styleRaw then
            ( name, Just (st.styleRaw ++ props) )

        else
            ( name, Just (st.styleRaw ++ ";" ++ props) )

    else
        ( name, value )


reflection : String -> Reflect
reflection key =
    case key of
        "className" ->
            AsString "class"

        "htmlFor" ->
            AsString "for"

        "httpEquiv" ->
            AsString "http-equiv"

        "acceptCharset" ->
            AsString "accept-charset"

        "accessKey" ->
            AsString "accesskey"

        "useMap" ->
            AsString "usemap"

        "contentEditable" ->
            AsString "contenteditable"

        "spellcheck" ->
            AsString "spellcheck"

        "isMap" ->
            AsBool "ismap"

        "noValidate" ->
            AsBool "novalidate"

        "readOnly" ->
            AsBool "readonly"

        "value" ->
            AsValue

        _ ->
            if List.member key sameNameString then
                AsString key

            else if List.member key sameNameBool then
                AsBool key

            else
                NoReflect


sameNameString : List String
sameNameString =
    [ "accept", "action", "align", "alt", "autocomplete", "cite", "coords", "dir", "download"
    , "dropzone", "enctype", "headers", "href", "hreflang", "id", "kind", "label", "lang", "max"
    , "method", "min", "name", "pattern", "ping", "placeholder", "poster", "preload", "sandbox"
    , "scope", "shape", "span", "src", "srcdoc", "srclang", "start", "step", "target", "title"
    , "type", "wrap"
    ]


sameNameBool : List String
sameNameBool =
    [ "autofocus", "autoplay", "checked", "controls", "default", "disabled", "hidden", "loop"
    , "multiple", "required", "reversed", "selected"
    ]


propValue : Json.Encode.Value -> PropValue
propValue value =
    Decode.decodeValue
        (Decode.oneOf
            [ Decode.map PString Decode.string
            , Decode.map PBool Decode.bool
            , Decode.map PNumber Decode.float
            , Decode.null PNull
            , Decode.succeed PCompound
            ]
        )
        value
        |> Result.withDefault PCompound


jsString : PropValue -> Maybe String
jsString value =
    case value of
        PString s ->
            Just s

        PBool b ->
            Just
                (if b then
                    "true"

                 else
                    "false"
                )

        PNumber f ->
            Just (String.fromFloat f)

        PNull ->
            Just "null"

        PCompound ->
            Nothing


truthy : PropValue -> Bool
truthy value =
    case value of
        PString s ->
            s /= ""

        PBool b ->
            b

        PNumber f ->
            f /= 0 && not (isNaN f)

        PNull ->
            False

        PCompound ->
            True



-- ORGANIZE HELPERS


lookup : String -> List ( String, v ) -> Maybe v
lookup key entries =
    List.filter (\( k, _ ) -> k == key) entries
        |> List.head
        |> Maybe.map Tuple.second


upsert : String -> v -> List ( String, v ) -> List ( String, v )
upsert key value entries =
    if List.any (\( k, _ ) -> k == key) entries then
        List.map
            (\( k, old ) ->
                if k == key then
                    ( k, value )

                else
                    ( k, old )
            )
            entries

    else
        entries ++ [ ( key, value ) ]


joinClass : String -> String -> String
joinClass old new =
    if old == "" then
        new

    else
        old ++ " " ++ new


addSlot : Slot -> List Slot -> List Slot
addSlot slot slots =
    if List.member slot slots then
        slots

    else
        slots ++ [ slot ]


upsertProp : String -> PropValue -> List Slot -> List Slot
upsertProp key value slots =
    if List.any (isPropSlot key) slots then
        List.map (mergePropSlot key value) slots

    else
        slots ++ [ PropSlot key value ]


isPropSlot : String -> Slot -> Bool
isPropSlot key slot =
    case slot of
        PropSlot k _ ->
            k == key

        _ ->
            False


mergePropSlot : String -> PropValue -> Slot -> Slot
mergePropSlot key value slot =
    case slot of
        PropSlot k old ->
            if k /= key then
                slot

            else if key == "className" then
                PropSlot k (PString (joinClass (jsStringOrEmpty old) (jsStringOrEmpty value)))

            else
                PropSlot k value

        _ ->
            slot


jsStringOrEmpty : PropValue -> String
jsStringOrEmpty value =
    Maybe.withDefault "" (jsString value)



-- TEXT HELPERS


isTokenBreaking : Bool -> String -> Bool
isTokenBreaking isAttribute name =
    String.isEmpty name || String.any (breaksToken isAttribute) name


breaksToken : Bool -> Char -> Bool
breaksToken isAttribute c =
    let
        code =
            Char.toCode c
    in
    code <= 0x20 || code == 0x7F || c == '"' || c == '\'' || c == '<' || c == '>' || c == '/' || (isAttribute && c == '=')


asciiLower : String -> String
asciiLower =
    String.map lowerChar


lowerChar : Char -> Char
lowerChar c =
    if Char.isUpper c then
        Char.fromCode (Char.toCode c + 32)

    else
        c


cssName : String -> String
cssName key =
    if String.contains "-" key || not (String.any Char.isUpper key) then
        key

    else if key == "cssFloat" then
        "float"

    else
        let
            kebab =
                String.foldr
                    (\c acc ->
                        if Char.isUpper c then
                            "-" ++ String.cons (lowerChar c) acc

                        else
                            String.cons c acc
                    )
                    ""
                    key
        in
        if List.any (\p -> String.startsWith p kebab) [ "webkit-", "moz-", "ms-", "o-" ] then
            "-" ++ kebab

        else
            kebab


escapeText : String -> String
escapeText s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"
        |> String.replace "\"" "&quot;"
        |> String.replace "'" "&#039;"


escapeAttr : String -> String
escapeAttr s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "\"" "&quot;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"


rawText : String -> String
rawText =
    String.replace "</" "<\\/"
```

Notes for the implementer:
- `Char.isUpper` in elm/core is ASCII-only (0x41–0x5A). `breaksToken` therefore matches the C++
  byte test, because UTF-8 bytes ≥ 0x80 never break.
- All recursion that grows with tree size is in `renderLoop`, which is self-tail-recursive.
  `attributes` recurses only through `Mapped` chains, and that recursion is a tail call too.

## Appendix B — C++ skeletons (`elm-kernel-cpp/src/virtual-dom/`, `src/json/`)

### B.1 `VirtualDomLayout.hpp`

```cpp
#ifndef ECO_VIRTUALDOMLAYOUT_H
#define ECO_VIRTUALDOMLAYOUT_H

#include "allocator/Heap.hpp"

namespace Elm::Kernel::VirtualDom {

// Mirrors eco/system src/Http/Dom.elm `type Node` / `type Fact` (VDOM_001). Constructor tag =
// declaration index. Change both together; DomLayoutTest.elm pins them.
inline constexpr u16 NODE_TEXT          = 0;  // Text String
inline constexpr u16 NODE_ELEMENT       = 1;  // Element (Maybe String) String (List Fact) (List Node)
inline constexpr u16 NODE_KEYED_ELEMENT = 2;  // KeyedElement (Maybe String) String (List Fact) (List (String, Node))
inline constexpr u16 NODE_MAPPED        = 3;  // Mapped Tagger Node

inline constexpr u16 FACT_ATTRIBUTE    = 0;   // Attribute key value
inline constexpr u16 FACT_ATTRIBUTE_NS = 1;   // AttributeNS namespace key value
inline constexpr u16 FACT_PROPERTY     = 2;   // Property key Json.Value
inline constexpr u16 FACT_STYLE        = 3;   // Style key value
inline constexpr u16 FACT_EVENT        = 4;   // Event name Handler (List Tagger)

inline constexpr u32 EL_NS = 0, EL_TAG = 1, EL_FACTS = 2, EL_KIDS = 3;
inline constexpr u32 MAPPED_TAGGER = 0, MAPPED_NODE = 1;
inline constexpr u32 TEXT_STRING = 0;
inline constexpr u32 FACT_KEY = 0, FACT_VALUE = 1;          // Attribute / Property / Style
inline constexpr u32 NS_NAMESPACE = 0, NS_KEY = 1, NS_VALUE = 2;
inline constexpr u32 EV_NAME = 0, EV_HANDLER = 1, EV_TAGGERS = 2;

} // namespace Elm::Kernel::VirtualDom

#endif // ECO_VIRTUALDOMLAYOUT_H
```

### B.2 `VirtualDomExports.cpp` (all functions shown or patterned)

```cpp
//===- VirtualDomExports.cpp - Elm.Kernel.VirtualDom (heap model, plans/elm-html-native-kernel.md) ===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "VirtualDomLayout.hpp"
#include "XssFilters.hpp"
#include "../json/JsonRead.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <initializer_list>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::Kernel::VirtualDom;

namespace {

HPointer dec(HPtr h) { return Export::decode(h.toBits()); }
HPtr enc(HPointer h) { return HPtr::fromBits(Export::encode(h)); }

// R1: one allocation; alloc::custom roots `v` across it.
HPointer make(u16 ctor, std::initializer_list<HPointer> fields) {
    std::vector<Unboxable> v;
    v.reserve(fields.size());
    for (HPointer f : fields) { Unboxable u; u.p = f; v.push_back(u); }
    return alloc::custom(ctor, v, u64{0});
}

// R3: copy the string out before any allocation.
std::u16string toU16(HPtr s) { return StringOps::toStdU16String(Export::toPtr(s.toBits())); }

HPtr dataPrefixed(const std::u16string& key) {
    return enc(alloc::allocString(u"data-" + key));
}

} // namespace

extern "C" {

HPtr Elm_Kernel_VirtualDom_text(HPtr s) { return enc(make(NODE_TEXT, {dec(s)})); }

HPtr Elm_Kernel_VirtualDom_node(HPtr tag, HPtr facts, HPtr kids) {
    return enc(make(NODE_ELEMENT, {alloc::nothing(), dec(tag), dec(facts), dec(kids)}));
}

HPtr Elm_Kernel_VirtualDom_nodeNS(HPtr ns, HPtr tag, HPtr facts, HPtr kids) {
    HPointer t = dec(tag), f = dec(facts), k = dec(kids);
    Elm::StackRootGuard g(&t, &f, &k);                               // R2
    HPointer justNs = alloc::just(alloc::boxed(dec(ns)), true);      // may GC: t/f/k updated
    return enc(make(NODE_ELEMENT, {justNs, t, f, k}));
}

// keyedNode / keyedNodeNS: as node / nodeNS with NODE_KEYED_ELEMENT.

HPtr Elm_Kernel_VirtualDom_map(HPtr tagger, HPtr node) {
    return enc(make(NODE_MAPPED, {dec(tagger), dec(node)}));
}

HPtr Elm_Kernel_VirtualDom_attribute(HPtr key, HPtr value) {
    return enc(make(FACT_ATTRIBUTE, {dec(key), dec(value)}));
}
// attributeNS(ns, key, value) -> FACT_ATTRIBUTE_NS {ns, key, value}; property -> FACT_PROPERTY;
// style -> FACT_STYLE; on(name, handler) -> FACT_EVENT {name, handler, alloc::listNil()}.

HPtr Elm_Kernel_VirtualDom_mapAttribute(HPtr func, HPtr fact) {
    void* p = Export::toPtr(fact.toBits());
    if (p == nullptr || alloc::getTag(p) != Tag_Custom ||
        static_cast<Custom*>(p)->ctor != FACT_EVENT) {
        return fact;                                                 // JS: non-events unchanged
    }
    Custom* ev = static_cast<Custom*>(p);
    HPointer name = ev->values[EV_NAME].p;
    HPointer handler = ev->values[EV_HANDLER].p;
    HPointer taggers = ev->values[EV_TAGGERS].p;
    HPointer f = dec(func);
    // `ev` is dead from here: the next line may GC (R2).
    Elm::StackRootGuard g({&name, &handler, &taggers, &f});
    HPointer consed = alloc::cons(alloc::boxed(f), taggers, true);
    return enc(make(FACT_EVENT, {name, handler, consed}));
}

HPtr Elm_Kernel_VirtualDom_lazy(HPtr fn, HPtr a) {                   // R4, D5
    uint64_t args[1] = {a.toBits()};
    return eco_apply_closure(fn, args, 1);
}
// lazy2..lazy8: the same with 2..8 args, in order.

HPtr Elm_Kernel_VirtualDom_noScript(HPtr tag) {
    return Xss::isScriptTag(toU16(tag)) ? enc(alloc::allocStringFromUTF8("p")) : tag;
}

HPtr Elm_Kernel_VirtualDom_noOnOrFormAction(HPtr key) {
    std::u16string k = toU16(key);
    return Xss::isOnOrFormAction(k) ? dataPrefixed(k) : key;
}

HPtr Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(HPtr key) {
    std::u16string k = toU16(key);
    return Xss::isInnerHtmlOrFormAction(k) ? dataPrefixed(k) : key;
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptUri(HPtr value) {
    return Xss::isJavaScriptUri(toU16(value)) ? enc(alloc::emptyString()) : value;
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(HPtr value) {
    return Xss::isJavaScriptOrHtmlUri(toU16(value)) ? enc(alloc::emptyString()) : value;
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value) {
    std::u16string s;
    if (!JsonRead::jsToString(value.toBits(), s) || !Xss::isJavaScriptOrHtmlUri(s)) return value;
    return Elm_Kernel_Json_wrap(enc(alloc::emptyString()));          // == Json.Encode.string "" (D18)
}

} // extern "C"
```

### B.3 `src/json/JsonRead.hpp` (implementation mirrors `JsonExports.cpp` without editing it)

```cpp
#ifndef ECO_JSONREAD_H
#define ECO_JSONREAD_H

#include "allocator/Heap.hpp"
#include <cstdint>
#include <string>
#include <vector>

// Read-only view of Json.Value (both heap forms). Never allocates on the Eco heap and never
// calls Elm (VDOM_004). Constants mirror JsonExports.cpp:49-60 (CTOR_JSON_*) and :88-94 (ENC_*);
// that file is LSS_022-pinned, so the mirror is checked by VirtualDomKernelTest instead.
namespace Elm::Kernel::JsonRead {

enum class Kind { Null, Bool, Number, String, Array, Object };

struct View {
    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0.0;
    void* string = nullptr;   // resolved string object; nullptr = "" (empty constant)
    uint64_t bits = 0;        // the value word (Array: for arrayElements)
};

// Classification, mirroring elmToJson (JsonExports.cpp:1340-1420) and heapJsonToNlohmann
// (:600-670):
//  - embedded constant: Bool constant -> Bool, anything else -> Null
//  - Tag_Int / Tag_Float -> Number; a string object -> String (legacy primitive fallthrough)
//  - Tag_Custom by ctor: 0|100 Null, 1|101 Bool(values[0] constant), 2|102 Number(i64 -> double),
//    3|103 Number(f64), 4|104 String(values[0]), 5|105|107 Array, 6|106 Object; otherwise Null
View view(uint64_t valueBits);

// Elements of an Array view in JSON order: ENC_ARRAY lists are reversed (F2); 105 = ElmArray;
// 107 = chunked (indexing as jsonArrayAt, JsonExports.cpp:465-479).
void arrayElements(const View& array, std::vector<uint64_t>& out);

// JS String(value) for String and Array (Array.prototype.toString; plan §6). Returns false for
// other kinds. Nested-array depth is capped at 256.
bool jsToString(uint64_t valueBits, std::u16string& out);

} // namespace Elm::Kernel::JsonRead

#endif // ECO_JSONREAD_H
```

### B.4 `system-kernel-cpp/src/eco-system/Dom/DomExports.cpp` (eco/system, §1.1 E1/E3)

```cpp
//===- DomExports.cpp - C exports of Eco.Kernel.Dom ------------------------===//
//
// plans/elm-html-native-kernel.md §4.2 and plans/eco-system-library.md B1b. The
// VirtualDom side door: natively a VirtualDom.Node msg already has the heap
// layout of Http.Dom.Node (VirtualDomLayout.hpp, VDOM_001), so fromNode and
// fromAttribute are identities. toString runs ElmKernel_VirtualDom's
// writeHtml, which never allocates on the Eco heap (VDOM_004), then allocates
// the one result String. Pure kernels (B5): no binding, no table.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "virtual-dom/HtmlWriter.hpp"

#include <string>

using namespace Eco::System;

extern "C" {

// fromNode : VirtualDom.Node msg -> Http.Dom.Node
uint64_t Eco_Kernel_Dom_fromNode(uint64_t node) {
    ECO_KERNEL_GUARD(
        return node;   // R7: zero-copy (D3)
    )
}

// fromAttribute : VirtualDom.Attribute msg -> Http.Dom.Fact
uint64_t Eco_Kernel_Dom_fromAttribute(uint64_t fact) {
    ECO_KERNEL_GUARD(
        return fact;
    )
}

// toString : VirtualDom.Node msg -> String
uint64_t Eco_Kernel_Dom_toString(uint64_t node) {
    ECO_KERNEL_GUARD(
        std::string out;
        ::Elm::Kernel::VirtualDom::writeHtml(node, out);   // R8: no Eco allocation
        return enc(alloc::allocStringFromUTF8(out));       // the one allocation, after the walk
    )
}

} // extern "C"
```

- `node` is only passed through to `writeHtml`, which reads it with elm-kernel-cpp's
  `Export::toPtr` (R3). No `HPointer` is live across the one allocation, so no guard is needed.
- `ECO_KERNEL_GUARD` is a `try` block whose handlers call `reportFatal`
  (`eco-kernel-cpp/src/eco-kernel/KernelExports.h:44-52`), so it wraps a plain `return`. Only
  `std::bad_alloc` from `out` can reach it, and running out of memory is outside D17.

### B.5 `HtmlWriter.hpp/.cpp`

```cpp
// elm-kernel-cpp/src/virtual-dom/HtmlWriter.hpp. Self-contained: eco/system includes it
// (as "virtual-dom/HtmlWriter.hpp"), so it includes nothing from elm-kernel-cpp (§1.1 E3).
#ifndef ECO_HTMLWRITER_H
#define ECO_HTMLWRITER_H
#include <cstdint>
#include <string>

namespace Elm::Kernel::VirtualDom {
// Appends the HTML serialization (plan §8) of a VirtualDom.Node / Http.Dom.Node value to `out` as
// UTF-8. `nodeBits` is an encoded word (heap pointer or raw literal pointer, R3). Never allocates
// on the Eco heap, never calls Elm (VDOM_004), never fails (D17). Callers: eco/system's
// Eco_Kernel_Dom_toString and httpServerRespondHtmlBody.
void writeHtml(uint64_t nodeBits, std::string& out);
}

#endif // ECO_HTMLWRITER_H
```

Implementation outline. Mirror Appendix A **function for function**, with the same names:
`expand`, `resolve`, `organizeFact`, `applySlot`, `reflectProp`, `setString`, `setAttr`,
`removeAttr`, `setStyle`, `finishStyle`, `reflection`, `propValue`, `jsString`, `truthy`,
`upsert`, `joinClass`, `isTokenBreaking`, `asciiLower`, `cssName`, `escapeText`, `escapeAttr`
and `rawText`.

- **Work stack:** `std::vector<Work>` with `struct Work { bool emit; bool raw; uint64_t node; std::string text; }`.
  Children are pushed in reverse, mirroring the Elm list order exactly.
- **Reading a node:** `void* p = Export::toPtr(bits)`. If `p == nullptr` or the tag is not
  `Tag_Custom`, emit nothing (total). Otherwise dispatch on `ctor` with the layout constants.
- **Strings:** names and texts are `StringOps::toStdString(Export::toPtr(field))`; `nullptr`
  gives `""`.
- **Namespace:** `Nothing` is a constant (`toPtr` → `nullptr`); `Just` is a `Custom` whose
  `values[0]` is the string.
- **Lists:** `for (alloc::ListCursor c(field.p); !c.done(); c.next())`. Keyed kids are `Tuple2`,
  and their `.b.p` is the node.
- **Properties:** `JsonRead::view`. String → `PString` (`toStdString`), Bool, Number, Null;
  Array/Object → `PCompound`.
- **Numbers:** `jsString` for a number uses `StringOps::formatFloatShortest` (P0.2).
- **Organized and applied state:** `std::vector<std::pair<std::string, std::string>>` and
  `std::vector<std::pair<std::string, std::optional<std::string>>>`, with linear upsert as in
  the Elm (fact lists are short).

## Appendix C — JS twin `src/Eco/Kernel/Dom.js` (eco/system)

```js
/*

import Elm.Kernel.VirtualDom exposing (text, nodeNS, keyedNodeNS, map, lazy, custom, style, attribute, attributeNS, property, on)
import Elm.Kernel.List exposing (Nil, fromArray)
import Elm.Kernel.Json exposing (wrap)
import Elm.Kernel.Utils exposing (Tuple2)
import Maybe exposing (Just, Nothing)
import Http.Dom as Dom exposing (Text, Element, KeyedElement, Mapped, Attribute, AttributeNS, Property, Style, Event, render)

*/

// Dom: the JS twin of src/eco-system/Dom/DomExports.cpp (plans/elm-html-native-kernel.md
// section 7.2). Stock VirtualDom JS objects are read through keys and type codes CALIBRATED from probe
// vnodes, so kernel field renaming and package versions do not matter. Never throws (D17).

var _Dom_k = null;

function _Dom_keyOf(obj, value)
{
	for (var key in obj) { if (key !== '$' && obj[key] === value) return key; }
	return undefined;
}

function _Dom_keyWhere(obj, pred)
{
	for (var key in obj) { if (key !== '$' && pred(obj[key])) return key; }
	return undefined;
}

function _Dom_calibrate()
{
	if (_Dom_k) return _Dom_k;
	var k = {};
	var id = function(x) { return x; };
	var t = __VirtualDom_text('\u0001');
	k.TEXT = t.$;
	k.text = _Dom_keyOf(t, '\u0001');
	var el = A4(__VirtualDom_nodeNS, '\u0002', '\u0003', __List_Nil, __List_Nil);
	k.NODE = el.$;
	k.namespace = _Dom_keyOf(el, '\u0002');
	k.tag = _Dom_keyOf(el, '\u0003');
	k.kids = _Dom_keyWhere(el, Array.isArray);
	k.facts = _Dom_keyWhere(el, function(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); });
	k.KEYED = A4(__VirtualDom_keyedNodeNS, '\u0002', '\u0003', __List_Nil, __List_Nil).$;
	var tagged = A2(__VirtualDom_map, id, t);
	k.TAGGER = tagged.$;
	k.tagger = _Dom_keyOf(tagged, id);
	k.taggerNode = _Dom_keyOf(tagged, t);
	var thunk = A2(__VirtualDom_lazy, id, t);
	k.THUNK = thunk.$;
	k.thunk = _Dom_keyWhere(thunk, function(v) { return typeof v === 'function'; });
	k.CUSTOM = __VirtualDom_custom(__List_Nil, 0, id, id).$;
	var sty = A2(__VirtualDom_style, '\u0004', '\u0005');
	k.STYLE = sty.$;
	k.key = _Dom_keyOf(sty, '\u0004');
	k.value = _Dom_keyOf(sty, '\u0005');
	k.ATTR = A2(__VirtualDom_attribute, 'a', 'b').$;
	k.PROP = A2(__VirtualDom_property, 'a', __Json_wrap('b')).$;
	k.EVENT = A2(__VirtualDom_on, 'a', {}).$;
	var ns = A3(__VirtualDom_attributeNS, '\u0006', 'a', '\u0007');
	k.ATTR_NS = ns.$;
	k.nsNamespace = _Dom_keyOf(ns[k.value], '\u0006');
	k.nsValue = _Dom_keyOf(ns[k.value], '\u0007');
	return _Dom_k = k;
}

function _Dom_maybe(ns) { return ns === undefined ? __Maybe_Nothing : __Maybe_Just(ns); }

// Organized facts -> List Fact, in the for..in order _VirtualDom_applyFacts uses.
function _Dom_facts(k, facts)
{
	var out = [];
	for (var key in facts)
	{
		var v = facts[key];
		if (key === k.STYLE) { for (var s in v) out.push(A2(__Dom_Style, s, v[s])); }
		else if (key === k.EVENT) { for (var e in v) out.push(A3(__Dom_Event, e, v[e], __List_Nil)); }
		else if (key === k.ATTR) { for (var a in v) out.push(A2(__Dom_Attribute, a, v[a])); }
		else if (key === k.ATTR_NS) { for (var n in v) out.push(A3(__Dom_AttributeNS, v[n][k.nsNamespace], n, v[n][k.nsValue])); }
		else { out.push(A2(__Dom_Property, key, __Json_wrap(v))); }   // organized props are unwrapped
	}
	return __List_fromArray(out);
}

function _Dom_build(k, v, built)
{
	if (v.$ === k.TEXT) return __Dom_Text(v[k.text]);
	if (v.$ === k.NODE)
		return A4(__Dom_Element, _Dom_maybe(v[k.namespace]), v[k.tag], _Dom_facts(k, v[k.facts]), __List_fromArray(built));
	if (v.$ === k.KEYED)
	{
		var pairs = [];
		for (var i = 0; i < built.length; i++) pairs.push(__Utils_Tuple2(v[k.kids][i].a, built[i]));
		return A4(__Dom_KeyedElement, _Dom_maybe(v[k.namespace]), v[k.tag], _Dom_facts(k, v[k.facts]), __List_fromArray(pairs));
	}
	if (v.$ === k.TAGGER) return A2(__Dom_Mapped, v[k.tagger], built[0]);
	// CUSTOM or unknown: what VirtualDom.server.js renders.
	return A4(__Dom_Element, __Maybe_Nothing, 'div', _Dom_facts(k, v[k.facts]), __List_Nil);
}

function _Dom_fromNode(root)
{
	var k = _Dom_calibrate();
	var stack = [{ v: root, kids: null, i: 0, built: [] }];
	var result;
	while (stack.length)
	{
		var fr = stack[stack.length - 1];
		if (fr.kids === null)
		{
			while (fr.v.$ === k.THUNK) { fr.v = fr.v[k.thunk](); }    // forced, never cached
			fr.kids =
				(fr.v.$ === k.NODE || fr.v.$ === k.KEYED) ? fr.v[k.kids]
				: fr.v.$ === k.TAGGER ? [fr.v[k.taggerNode]]
				: [];
		}
		if (fr.i < fr.kids.length)
		{
			var child = fr.kids[fr.i++];
			stack.push({ v: fr.v.$ === k.KEYED ? child.b : child, kids: null, i: 0, built: [] });
			continue;
		}
		stack.pop();
		var node = _Dom_build(k, fr.v, fr.built);
		if (stack.length) stack[stack.length - 1].built.push(node); else result = node;
	}
	return result;
}

function _Dom_fromAttribute(fact)
{
	var k = _Dom_calibrate();
	var key = fact[k.key];
	var value = fact[k.value];
	if (fact.$ === k.STYLE) return A2(__Dom_Style, key, value);
	if (fact.$ === k.ATTR) return A2(__Dom_Attribute, key, value);
	if (fact.$ === k.ATTR_NS) return A3(__Dom_AttributeNS, value[k.nsNamespace], key, value[k.nsValue]);
	if (fact.$ === k.EVENT) return A3(__Dom_Event, key, value, __List_Nil);
	return A2(__Dom_Property, key, value);                             // PROP: already a Json.Value
}

function _Dom_toString(node) { return __Dom_render(_Dom_fromNode(node)); }
```

Notes for the implementer:
- `_VirtualDom_nodeNS` is `F2` returning `F2`, so `A4` reaches it through the curried path.
- A one-field Elm ctor (`__Dom_Text`) is a plain function; ctors with more fields are
  `F`-wrapped (`A2`–`A4`).
- If the eco kernel parser rejects importing ctors from `Http.Dom`, import them as functions from
  small Elm helpers in `Http/Dom.elm` instead (for example `mkElement`), and keep them unexposed
  through an internal module.

## Appendix D — Golden corpus and filter truth table

### D.1 Serializer goldens

Each case is `Http.Dom.toString` of the given `Html`; `Encode` is `Json.Encode`.

| # | Html | Expected |
|---|---|---|
| 1 | `text "a<b>&\"'"` | `a&lt;b&gt;&amp;&quot;&#039;` |
| 2 | `div [] []` | `<div></div>` |
| 3 | `div [ id "x", class "a", class "b" ] [ text "hi" ]` | `<div id="x" class="a b">hi</div>` |
| 4 | `div [ class "a", attribute "class" "b" ] []` | `<div class="b"></div>` |
| 5 | `div [ attribute "class" "b", class "a" ] []` | `<div class="a"></div>` |
| 6 | `input [ type_ "checkbox", checked True, disabled False ] []` | `<input type="checkbox" checked>` |
| 7 | `br [] [ text "x" ]` | `<br>` |
| 8 | `div [ style "color" "red", style "backgroundColor" "blue", style "color" "green" ] []` | `<div style="color:green;background-color:blue;"></div>` |
| 9 | `div [ attribute "style" "margin: 0", style "color" "red" ] []` | `<div style="margin: 0;color:red;"></div>` |
| 10 | `div [ style "color" "red", attribute "style" "margin: 0" ] []` | `<div style="margin: 0"></div>` |
| 11 | `node "style" [] [ text "a > b {}</style><script>" ]` | `<style>a > b {}<\/style><script></style>` |
| 12 | `node "script" [] [ text "x" ]` | `<p>x</p>` |
| 13 | `div [ attribute "onclick" "alert(1)" ] []` | `<div data-onclick="alert(1)"></div>` |
| 14 | `a [ href "javascript:alert(1)" ] [ text "x" ]` | `<a href="">x</a>` |
| 15 | `a [ href "\tjava\tSCRIPT:alert(1)" ] []` | `<a href=""></a>` |
| 16 | `iframe [ src "data:text/html,<b>" ] []` | `<iframe src=""></iframe>` |
| 17 | `div [ property "innerHTML" (Encode.string "<b>") ] []` | `<div></div>` |
| 18 | `node "div onclick=alert(1)" [] [ text "x" ]` | `x` |
| 19 | `node "script " [] [ text "x" ]` | `x` |
| 20 | `div [ attribute "x onclick" "y", attribute "a=b" "z", attribute "data-ok" "1" ] []` | `<div data-ok="1"></div>` |
| 21 | `node "my-widget" [ attribute "aria-label" "q\"<" ] []` | `<my-widget aria-label="q&quot;&lt;"></my-widget>` |
| 22 | `div [ attribute "tabIndex" "1", attribute "TABINDEX" "2" ] []` | `<div tabindex="2"></div>` |
| 23 | `Html.map identity (Html.Keyed.ul [] [ ( "a", li [] [ text "1" ] ) ])` | `<ul><li>1</li></ul>` |
| 24 | `textarea [ value "a<b" ] [ text "ignored" ]` | `<textarea>a&lt;b</textarea>` |
| 25 | `select [ value "b" ] [ option [ value "a" ] [], option [ value "b" ] [] ]` | `<select><option value="a"></option><option value="b"></option></select>` |
| 26 | `svgNode "svg" [ VirtualDom.attribute "viewBox" "0 0 10 10" ] [ svgNode "use" [ VirtualDom.attributeNS "http://www.w3.org/1999/xlink" "xlink:href" "#a" ] [] ]`, where `svgNode = VirtualDom.nodeNS "http://www.w3.org/2000/svg"` (what `Svg.svg`/`Svg.use`/`viewBox`/`xlinkHref` expand to, E7) | `<svg viewBox="0 0 10 10"><use xlink:href="#a"></use></svg>` |
| 27 | `div [ Html.Events.onClick (), id "e" ] []` | `<div id="e"></div>` |
| 28 | `Html.Lazy.lazy (\n -> text (String.fromInt n)) 5` | `5` |
| 29 | `div [ property "title" (Encode.int 3), property "foo" (Encode.string "x") ] []` | `<div title="3"></div>` |
| 30 | `node "" [] [ text "x" ]` | `x` |
| 31 | `div [ contenteditable True, spellcheck False ] []` | `<div contenteditable="true" spellcheck="false"></div>` |
| 32 | `input [ autocomplete False ] []` | `<input autocomplete="off">` |
| 33 | `div [ classList [ ( "a", True ), ( "b", False ), ( "c", True ) ] ] []` | `<div class="a c"></div>` |
| 34 | `div [ attribute "class" "a", attribute "class" "b" ] []` | `<div class="a b"></div>` |
| 35 | `node "html" [] [ node "body" [] [ text "x" ] ]` | `<html><body>x</body></html>` (and with `setBodyAsHtml`: `<!DOCTYPE html>` prefix, P6) |

### D.2 Filter truth table (`XssFilters` unit tests; `\t` is TAB, ` ` is NBSP)

| Function | Input | Result |
|---|---|---|
| `isScriptTag` | `script`, `SCRIPT`, `ScRiPt` | true |
| `isScriptTag` | `script `, `scripts`, `ſcript` | false |
| `isOnOrFormAction` | `onclick`, `ONLOAD`, `on`, `formAction`, `FORMACTION` | true |
| `isOnOrFormAction` | `x onclick`, `formActions`, `data-on` | false |
| `isInnerHtmlOrFormAction` | `innerHTML`, `outerHTML`, `formAction` | true |
| `isInnerHtmlOrFormAction` | `innerhtml`, `InnerHTML` | false |
| `isJavaScriptUri` | `javascript:x`, `  JaVaScRiPt:`, `\tjava\tscript:`, ` javascript:`, ` j a v a s c r i p t :` | true |
| `isJavaScriptUri` | `javascript`, `java-script:`, `xjavascript:`, `https://x` | false |
| `isJavaScriptOrHtmlUri` | everything true above, plus `data:text/html,`, `DATA : text / HTML ;` | true |
| `isJavaScriptOrHtmlUri` | `data:text/html`, `data:text/plain,`, `data:text/htmlx,` | false |
| `noJavaScriptOrHtmlJson` | `Encode.string "javascript:x"`, `Encode.list Encode.string ["javascript:x"]`, `[["data:text/html;"]]`, 100 spaces + `javascript:` | `Encode.string ""` |
| `noJavaScriptOrHtmlJson` | `Encode.int 1`, `Encode.object []`, `[null, "javascript:x"]` (stringifies to `,javascript:x`), `["java", "script:"]` | unchanged |
