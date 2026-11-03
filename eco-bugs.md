# eco 0.2.0: bugs found while building kg

Found on 2026-11-03 while building kg, the compiler knowledge graph (`kg/`,
see `plans/compiler-knowledge-graph.md` §21). Everything here was seen with
`/usr/local/bin/eco` 0.2.0 on Linux x86-64, building native programs with
`eco make` and the bundled `eco/system` 1.0.0. Source references are to
eco-compiler master at `a874aa90`, which may differ from what 0.2.0 was
built from.

kg works around every one of these. None was fixed in eco-compiler: that was
left for later.

| # | bug | kind | severity |
|---|---|---|---|
| 1 | `Regex.find` and `Regex.replace` return malformed `Match` records | crash, wrong values | high |
| 2 | Any use of a `Json.Decode.Error` crashes | crash | high |
| 3 | `Bitwise` is 64-bit, which breaks 32-bit Elm code silently | divergence, wrong values | medium |
| 4 | `Match.index` counts code points, not UTF-16 units | divergence, wrong values | medium |
| 5 | `String.toList` and `String.foldl` step by UTF-16 unit, not by character | divergence | medium |
| 6 | Lists made by `List.take` are 4–12 times slower to walk | performance | medium |
| 7 | `Bytes.Decode` loops are slow and allocate heavily | performance | medium |
| 8 | Decoded data takes about 8 times its encoded size | memory | low |
| 9 | The parser rejects a character literal outside the BMP | divergence | low |
| 10 | `Json.Encode` sorts object keys | divergence | low |
| 11 | The bundled `eco/kernel` is behind master's compiler sources | packaging | low |

---

## 1. `Regex.find` and `Regex.replace` return malformed `Match` records

Reading `.match` from a match segfaults, and `.number` is garbage. `.index`
and `.submatches` are right.

```elm
case Regex.fromString "a" of
    Just re ->
        Regex.find re "abc" |> List.map .match   -- segfault

    Nothing ->
        []
```

Probed field by field, with the pattern `a` on `"abc"`:

| field | expected | got |
|---|---|---|
| `List.length` of the result | 1 | 1 |
| `index` | 0 | 0 |
| `number` | 1 | 1120986466832 (looks like a pointer) |
| `submatches` | `[]` | `[]` (length 0) |
| `match` | `"a"` | segfault |

`Regex.replace` with a function also crashes, because it passes the same
records to the function. `Regex.contains`, `Regex.split` and
`Regex.findAtMost`'s count are fine.

**Likely cause.** `elm-kernel-cpp/src/regex/RegexExports.cpp:108-122`
(`createMatch`) builds the record with the fields in alphabetical order:
`index` (unboxed), `match` (boxed), `number` (unboxed), `submatches` (boxed),
with an unboxed mask for fields 0 and 2. The compiled code reads `number`
from slot 1, where the match string's pointer is, and `match` from slot 2,
where the integer 1 is. That fits a record layout that puts unboxed fields
first: (index, number, match, submatches). Slots 0 and 3 agree under both
orders, which is why `index` and `submatches` work. The kernel and the
compiler disagree on record field order; any other kernel that builds
records with mixed boxed and unboxed fields may have the same bug.

**Workaround in kg.** `kg/src/Kg/Re.elm` wraps every pattern in a capture
group, so the matched text is the first submatch, and never reads `match` or
`number`. Backreferences in the pattern are renumbered to allow for the
extra group.

---

## 2. Any use of a `Json.Decode.Error` crashes

`Json.Decode.errorToString` segfaults. So does a `case` on the error's
constructors, even one that never touches the `Value` inside `Failure`. This
holds for parse errors (`"not json"`, `"{\"a\":"`, `"[1,2"`) and for type
errors on valid JSON (`{"a":"x"}` decoded as `field "a" int`) alike.

```elm
D.decodeString D.int "x" |> Result.mapError D.errorToString   -- segfault

render : D.Error -> String
render e =
    case e of                                                 -- segfault
        D.Field f _ ->
            f

        D.Index _ _ ->
            "index"

        D.OneOf _ ->
            "oneOf"

        D.Failure msg _ ->
            msg
```

Testing only `Ok` against `Err` is safe.

**Likely cause.** The kernel builds the error values in a layout the
compiled code does not expect: the same class of bug as number 1, in the
JSON kernel's constructors for `Field`, `Index`, `OneOf` and `Failure`.

**Impact.** No eco program can explain a decode failure. In kg's MCP server
it meant a malformed request line crashed the whole server until it was
worked around.

**Workaround in kg.** kg never looks inside a decode error. Bad JSON is
answered with a fixed message (`kg/src/Mcp/Protocol.elm`). Tool arguments
are decoded one field at a time, each with its own message
(`kg/src/Kg/Args.elm`).

---

## 3. `Bitwise` is 64-bit

eco's `Int` is 64-bit (documented in `design_docs/elm-divergence.md` §1), and
`Bitwise` works on all 64 bits. Elm's `Bitwise` is 32-bit. §1 marks the
bitwise width as a TODO, and §5.5 lists it as a suspected divergence. Elm
code that relies on 32-bit wrap-around gives wrong answers with no error.

```elm
Sha256.sha256 ""   -- billstclair/elm-sha256 1.0.9
-- expected e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
-- got      66e8de676cc076e0d26754c55d4a73b1d39b11e014e350f7d1a971ced4dcd0dd
```

`"abc"` and the 448-bit test vector are wrong too.

**Impact.** Any hash, checksum, PRNG or bit-packing package written for
Elm's 32-bit semantics is silently wrong.

**Fix to consider.** Either make `Bitwise` 32-bit, as in Elm, with 64-bit
operations in a separate module, or document the divergence clearly and
list the affected packages.

**Workaround in kg.** `kg/src/Kg/Sha256.elm` masks every step to 32 bits;
the package is not used.

---

## 4. `Match.index` counts code points, not UTF-16 units

The regex kernel converts byte offsets to code-point offsets
(`byteOffsetToCharIndex` in `RegexExports.cpp`). eco's `String.slice` and
`String.length` count UTF-16 units, as Elm's do, and in Elm `Match.index` is
in UTF-16 units too.

```elm
Regex.find (re "(b)") "a😀b" |> List.map .index
-- eco: [2]    Elm: [3]

String.slice 2 3 "a😀b"
-- "\uDE00", the second half of the emoji, not "b"
```

**Impact.** Code that slices the string at a match's index is wrong after
any character outside the BMP (emoji, some CJK, mathematical symbols).

**Workaround in kg.** `Kg.Re` maps code-point indexes to UTF-16 indexes when
the text holds a surrogate. Texts without one, nearly all source code, take
a fast path.

---

## 5. `String.toList` and `String.foldl` step by UTF-16 unit, not by character

```elm
String.length "a😀b"               -- 4, as in Elm (UTF-16 units)
List.length (String.toList "a😀b")  -- eco: 4, Elm: 3
String.foldl (\_ n -> n + 1) 0 "a😀b"   -- eco: 4, Elm: 3
```

The emoji arrives as two surrogate `Char`s. That contradicts
`design_docs/elm-divergence.md` §2, which says a `Char` is exactly one
Unicode code point.

**Impact.** Code that walks a string by character mishandles anything
outside the BMP: case mapping, classification and counting.

**Workaround in kg.** None needed beyond `Kg.Re`'s index conversion, which
looks for surrogates itself.

---

## 6. Lists made by `List.take` are 4–12 times slower to walk

A list returned by `List.take` is much slower to traverse than an equal list
made by `List.map`.

```elm
dot : List Float -> List Float -> Float -> Float
dot xs ys acc =
    case xs of
        x :: xr ->
            case ys of
                y :: yr ->
                    dot xr yr (acc + x * y)

                [] ->
                    acc

        [] ->
            acc

-- v, plain : 384 Floats from List.map; taken = List.take 384 (plain ++ [ 0, 0 ])
-- 100,000 × dot plain v 0 : 190 ms
-- 100,000 × dot taken v 0 : 750 ms
```

Inside kg's vector scan the gap was 12 times: 832 ms against 69 ms over
37,150 vectors. That cost was found by elimination: every other part of the
scan was timed on its own.

**Likely cause, not checked.** `List.take`'s implementation in the core
kernel builds cons cells in a different representation, for example with
boxed `Float`s where `List.map` stores them unboxed, so every later read
pays to unbox.

**Workaround in kg.** `Kg.Search.Vectors.padTo` returns a list unchanged
when it already has the right length, and otherwise avoids `List.take` on
the hot path.

---

## 7. `Bytes.Decode` loops are slow and allocate heavily

The plan expected fixed-width decoder count loops to be fused. Measured on
37,150 × 384 values:

| decode | time | peak memory |
|---|---|---|
| 14.3 M `float32 LE` with `Decode.loop`, one row at a time | 1.1–1.25 s | 2.2 GB |
| 14.3 M `unsignedInt8` with the documented `listStep` pattern, per row | 1.1 s | 2.0 GB |
| the same in one loop over the whole block | 1.4 s | 2.6 GB |

Neither appears to be fused, the `unsignedInt8` `listStep` loop included,
and the transient allocation is large.

**Workaround in kg.** Vectors are decoded once when they load, quantized to
int8 and packed eight to an `Int`. The scan then walks lists of `Int`s
(81 ms). Loading still takes 3 s and peaks at 1.15 GB.

---

## 8. Decoded data takes about 8 times its encoded size

kg's snapshot is 104 MB as bytes and about 800 MB once decoded into Elm
values: dicts of records, lists and strings. 14.3 M `Float`s cost about
50 bytes each, whether in an `Array` (765 MB) or in lists of lists
(682 MB), which suggests each `Float` is boxed.

**Impact.** kg's query process peaks at 808 MB without vectors and at
1.15 GB with them, over the 1 GB budget the plan set.

**Not a correctness bug.** It is a representation cost worth measuring
against the unboxing work under way: unboxed `Float` in lists and arrays,
and smaller dict nodes.

---

## 9. The parser rejects a character literal outside the BMP

```elm
c : Char
c =
    '😀'
```

eco's parser rejects this and suggests double quotes. Elm accepts it.
Probably the same UTF-16 view as number 5: the parser sees two units between
the quotes.

**Workaround.** `String.toList "😀"` (which gives two `Char`s in eco; see
number 5).

---

## 10. `Json.Encode` sorts object keys

```elm
E.encode 0 (E.object [ ( "b", E.int 1 ), ( "a", E.int 2 ) ])
-- eco: {"a":2,"b":1}     Elm: {"b":1,"a":2}
```

Harmless for kg, and for most consumers of JSON, but it changes output byte
for byte: golden files, signatures over JSON, and readable key order.

---

## 11. The bundled `eco/kernel` is behind master's compiler sources

The `eco/kernel` package bundled with eco 0.2.0 lacks
`Eco.Console.isTerminal`, which master's `compiler/src/System/IO.elm` uses.
A program that uses the compiler's parser as a library therefore fails to
build with `compiler/src` alone. It builds when `compiler/src-xhr` is also a
source directory: its stand-ins for the IO modules don't need the newer
kernel.

**Workaround in kg.** `kg/elm.json` lists `vendor/eco-compiler/compiler/src-xhr`
after `compiler/src`.

---

## Where the workarounds are

| bug | kg file |
|---|---|
| 1, 4 | `kg/src/Kg/Re.elm` |
| 2 | `kg/src/Mcp/Protocol.elm`, `kg/src/Kg/Args.elm` |
| 3 | `kg/src/Kg/Sha256.elm` |
| 6 | `kg/src/Kg/Search/Vectors.elm` (`padTo`) |
| 7, 8 | `kg/src/Kg/Search/Vectors.elm` (packed int8 rows) |
| 11 | `kg/elm.json` |

Once eco fixes one of these, the matching workaround can go. kg's tests
(`kg/tests/Run.elm`, the "eco:" and "re:" cases) check that the workarounds
give the right answers. They do not test the bugs themselves, so each
reproduction above is the test to rerun against a new eco before removing a
workaround.
