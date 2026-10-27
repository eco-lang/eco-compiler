---
status: done
updated: 2026-10-27
---

# Plan: expand the compute benchmarks beyond lists

## Goal

`examples/benchmarks` measures mostly `List` code: of its 17 workloads only `dict`, `lru`
(Dict), `nsieve` and `fannkuch-redux` (Array), `fasta` (String) and the Float workloads leave
lists behind, and nothing covers `Set`, `Bitwise`, `elm/bytes`, `elm/json` or `elm/parser`.
Add 40 benchmarks, five per area, in three batches (45 workloads, since three benchmarks are
split into variants): Dict, Set, Array, String, Bitwise, Bytes,
JSON and Parser. Where the literature has a standard benchmark for an area, use it (Benchmarks
Game, plb2, kostya/benchmarks, nativejson-benchmark, Embench, FIPS test vectors); the rest test
what is specific to Elm and to eco (persistent structures, `comparable` keys, UTF-8 strings,
32-bit `Bitwise` semantics, Bytes decoder fusion, combinator parsers).

## Conventions every workload follows

These are the harness's rules (`src/Bench.elm`, `README.md`), restated so each batch can be
built against them:

- One module per workload in `src/`, exposing `bench : Int -> Bool` (and `output : Int ->
  String` when the benchmark has a standard text output, shown by `--print`). `bench` does the
  work at the given size and checks its own result, as strongly as the README's "How results are
  checked" allows: exact by a closed form or an independent recomputation where possible; else
  a table covering every feasible size; else a table at known sizes plus an invariant elsewhere.
  A workload that can only be checked at known sizes says so in its module documentation.
- Registered in `workloads` in `src/Bench.elm` and in `bench` in `elm/ElmBench.elm`, under the
  same name.
- Input is generated in the program from the size (a seeded LCG, as `Sort` and `Lru` do): a
  benchmark cannot read files, and the generator must give the same input on every backend.
- The default size takes at least 200 ms on the official Elm compiler's JavaScript in a fresh
  process (`node run.mjs NAME=SIZE --warmup 1 --runs 3` to calibrate), and is a size the check
  covers exactly.
- Every value a check computes stays below 2^53, so it is exact on the JavaScript backends.
  Never `//` a value above 2^31 there (Elm's `//` truncates to 32 bits in JavaScript; halve the
  even factor first, as `ListFold.triangle` does), and never convert a Float outside 64-bit range
  to Int (eco native gives INT64_MIN).
- Reference data (expected outputs, digests, tables) comes from a source independent of the
  Elm code: a published reference output, a standard's test vectors, OEIS, or a small C or
  Python program (kept out of the repository). The workload's module documentation says where
  each table comes from.
- Known eco compiler bug to stay clear of: two mutually recursive `let`-bound local functions
  emit unparseable MLIR; use top-level functions or one self-recursive function.

### Dependencies

`elm/bytes` (1.0.8) and `elm/parser` (1.1.0) must be added to `examples/benchmarks/elm.json`
and to `examples/benchmarks/elm/elm.json` (batch 1, which needs both). `elm/json` is already
there. eco implements all three kernels (`elm-kernel-cpp/src/{bytes,json,parser}`, with E2E suites
in `test/elm-{bytes,json,parser}`).

### Done means, for every batch

1. Every new workload passes its check on all three backends (`node run.mjs`) at its default
   size, and on eco native and eco-js at a spread of other sizes (small, odd, boundary; the way
   the 77-size sweep checked the first 17).
2. Every check is shown to catch a fault: a deliberate small mutation of each workload (in a
   scratch copy) must make its check fail at the default size. A check that cannot catch the
   mutation is strengthened (as `nbody` was, with its table of known outputs) or documented.
3. `README.md` "How results are checked" lists the new workloads in the right category.
4. One full `node run.mjs` comparison (elm, eco-js, eco native) and a bundle-built run, recorded
   in this plan's Status.

## Batch 1 (8 benchmarks, 9 workloads: one standard benchmark per area) — done 2026-10-16

- **k-nucleotide** (`KNucleotide.elm`, Dict). Standard: Benchmarks Game. Take the THREE section
  of `Fasta.output n`, count every k-mer for k = 1, 2 (frequencies, sorted) and the specific
  sequences GGT, GGTA, GGTATT, GGTATTTTAATT, GGTATTTTAATTTATAGT with `Dict String Int` and
  `Dict.update`. Stresses String keys (every comparison a string compare) and `String.slice`.
  Check: the counts for each k sum to `length - k + 1`; at the size of the published reference
  output (`knucleotide-output.txt`, for the reference fasta input) the output must match it.
  Prerequisite: confirm `Fasta.output` is byte-identical to the published `fasta-output.txt`
  (N = 1000), which no check does yet. `--print`: the standard output.
- **life** (`Life.elm`, Set). Standard and widely used: Conway's Game of Life on an unbounded
  plane, live cells in a `Set (Int, Int)`, neighbour counts via a `Dict (Int, Int) Int`. Size =
  generations of an R-pentomino. Check: a table of the R-pentomino's population by generation
  (computed with a Python reference), including the known 116 cells from generation 1,103 on;
  at every size the population must be positive and, from 1,103, exactly 116.
- **brainfuck** (`Brainfuck.elm`, Array). Standard: kostya/benchmarks. An interpreter with the
  tape an `Array Int` (constant `Array.set`) and the program an `Array` of pre-parsed ops with
  matched jumps. Size = how many times to run kostya's `bench.b`. Check: each run must print
  kostya's known output exactly. Licence: kostya/benchmarks is MIT; keep its notice next to the
  embedded program.
- **revcomp** (`RevComp.elm`, String). Standard: Benchmarks Game reverse-complement. Read the
  sequences of `Fasta.output n`, reverse-complement each (`String.reverse`, `String.map` with
  the IUB complement table) and re-wrap at 60 columns. Check: applying the transform twice gives
  back the input sequences exactly (at every size), and at the reference size the output matches
  `revcomp-output.txt`. `--print`: the standard output.
- **sha256** (`Sha256.elm`, Bitwise). Standard: FIPS 180-4. Hash a chain: `h0 = sha256 "abc"`,
  `h(i+1) = sha256 h(i)`, `n` times, over 32-bit words with `Bitwise.and`, `or`, `xor`,
  `shiftRightZfBy`, rotations. Check: the three FIPS test vectors ("abc", the 448-bit message,
  one million "a") at every size, and a table of chain ends from Python's `hashlib` at known
  sizes. Elm-specific: `Bitwise` is 32-bit by definition while eco's native Int is 64-bit, so a
  native op that leaks the upper bits fails the vectors.
- **bytes-fixed** and **bytes-loop** (`BytesCodec.elm`, Bytes; two workloads, one module; built
  as `bytes-static` and `bytes-dynamic` over byte loops, see Status). Encode
  a stream of `n` records (`unsignedInt32`, `float64`, `signedInt16`, `unsignedInt8`, mixed
  endianness) and decode it back two ways: `bytes-fixed` with a fixed-shape decoder eco can fuse
  into one kernel (`design_docs/invariants.csv` BFUSE_*), `bytes-loop` with a count-prefixed
  `Decode.loop`, which it cannot. Check: re-encoding the decoded records gives identical
  bytes, and the field sums equal closed forms of the generator. Pair them in the README so the
  fusion speed-up reads directly.
- **json** (`JsonCoords.elm`, JSON). Standard: kostya/benchmarks "JSON". Build `n` coordinate
  objects `{x, y, z, name, opts}`, `Encode.encode 0` them, `Decode.decodeString` the text, and
  average x, y, z. Check: kostya's own fixed case (`[{"x":2.0,"y":0.5,"z":0.25}]` gives 2.0,
  0.5, 0.25) at every size, and the averages against the generator's closed form within
  rounding.
- **expr-parser** (`ExprParser.elm`, Parser). An arithmetic expression grammar (`+ - *`,
  parentheses, precedence, integer literals) in `elm/parser`, then evaluated. The generator
  builds a random expression of about `n` tokens and computes its value as it goes, keeping
  every intermediate value below 2^53 (reduce modulo a prime after each `*`, no division).
  Check: the parsed and evaluated value equals the generator's, exactly, at every size.

## Batch 2 (16 benchmarks and workloads: two more per area) — done 2026-10-16

- **dijkstra** (`Dijkstra.elm`, Dict). Shortest paths on an `n` x `n` grid with generated edge
  weights; distances in a `Dict (Int, Int) Int`, the frontier a `Dict (Int, Int) ()` keyed by
  `(distance, node)` (insert, remove, `Dict.toList`/min). Check: with unit weights, distance =
  Manhattan distance (closed form, every size); with generated weights, an O(V^2) array
  Dijkstra on the same graph (independent recomputation, smaller sizes only, so the timed run
  uses unit weights plus a weighted subgrid).
- **word-freq** (`WordFreq.elm`, Dict). Generate text from a fixed vocabulary with an LCG,
  `String.words`, count with `Dict.update`, take the 10 most frequent. Check: the total equals
  the word count, and each word's count is recomputed from the generator without a Dict.
- **sudoku** (`Sudoku.elm`, Set). Standard: plb2 (and Norvig's solver). Candidates as `Set Int`
  per cell, constraint propagation plus search, over a fixed list of hard puzzles (plb2's set)
  repeated `n` times. Check: every solution is a valid grid that keeps the givens (a direct
  validity check, every size).
- **flood-fill** (`FloodFill.elm`, Set). Breadth-first flood fill of a generated `n` x `n` maze
  with a visited `Set (Int, Int)`. Check: the area reached equals the open cells of the start's
  component counted by a separate union-find over an `Array` (independent recomputation).
- **matmul** (`MatMul.elm`, Array). Standard: plb2 and kostya/benchmarks. Multiply two `n` x `n`
  `Array (Array Float)` matrices built with the benchmarks' standard generator. Check: the
  centre element against the published values at plb2's sizes; at every size, the product of
  the generator's closed-form matrices (both are polynomial in i and j, so element sums have a
  closed form) within rounding.
- **floyd-warshall** (`FloydWarshall.elm`, Array). All-pairs shortest paths over a flat
  `Array Int`, `n^3` `get`/`set`. Check: on a ring of `n` nodes with unit edges the distance is
  `min(|i - j|, n - |i - j|)` (closed form, every size); a generated chord set is checked by
  BFS from a sample of nodes.
- **levenshtein** (`Levenshtein.elm`, String). Edit distance by dynamic programming over pairs of
  generated strings (`String.toList`, one row at a time). Check: closed forms for structured
  pairs (a string against itself is 0, against its prefix of length k is `n - k`, against a
  string over a disjoint alphabet is `max` of the lengths) mixed into every run, plus known
  pairs.
- **unicode-string** (`UnicodeString.elm`, String; eco-specific). The same operations (`length`,
  `slice`, `indexes`, `toUpper`, `foldl`, `reverse`) on ASCII text and on text with BMP and
  astral characters, generated from code points. eco stores UTF-8 and widens to UTF-16 on demand
  (the GC report's "UTF-8 -> UTF-16 widen events"), so this prices that. Check: lengths, index
  positions and code-point sums computed from the generated code points.
- **nsieve-bits** (`NSieveBits.elm`, Bitwise). Standard: Computer Language Shootout. nsieve with
  the flags packed 32 to an Int in an `Array Int`. Check: the same prime-count table as `nsieve`.
- **crc32** (`Crc32.elm`, Bitwise). Standard (Embench, zlib). Table-driven CRC-32 over a
  generated byte sequence (as a `List Int` of bytes, not `Bytes`, to keep it a Bitwise test).
  Check: `CRC32("123456789") = 0xCBF43926` at every size, and a table of CRCs of the generated
  input from Python's `zlib.crc32` at known sizes.
- **base64** (`Base64.elm`, Bytes). Standard: kostya/benchmarks. Encode a generated `Bytes`
  buffer to Base64 text and decode it back. Check: the round trip is the identity at every size,
  plus the RFC 4648 test vectors ("" through "foobar").
- **utf8-bytes** (`Utf8Bytes.elm`, Bytes). `Encode.string` / `Decode.string` over generated
  Unicode text; `Decode.string` never fuses in eco, so it gets its own measurement. Check: the
  round trip, and `Encode.getStringWidth` against the UTF-8 length computed from the code
  points.
- **json-shapes** (`JsonShapes.elm`, JSON). Standard corpora: nativejson-benchmark's
  `canada.json` (floats in nested arrays), `twitter.json` (strings and Unicode) and
  `citm_catalog.json` (objects), as synthetic look-alikes generated in the program, decoded into
  Elm records and re-encoded. Check: the round trip compares equal, plus counts and sums from
  the generator.
- **json-decoders** (`JsonDecoders.elm`, JSON; Elm-specific). Decoder combinator stress: wide
  records via `map8` and `andMap`-style chains, `oneOf` with many alternatives, `andThen` on a
  tag field, `lazy` for a recursive tree. Check: decode then re-encode reproduces the generated
  value.
- **json-parser** (`JsonParser.elm`, Parser). A JSON parser written with `elm/parser`, over the
  same documents as `json`. Check: the same averages as `json` computes with `Json.Decode`, and
  agreement with `Json.Decode` on the whole document.
- **sexpr** (`SExpr.elm`, Parser). A Lisp reader in `elm/parser` and a small evaluator (lambda,
  let, if, arithmetic, lists), running a generated program (recursive fib of `n`, a fold over a
  list). Check: the program's result against a closed form (fib by the iterative formula, the
  fold by its arithmetic sum).

## Batch 3 (16 benchmarks, 20 workloads: the remainder) — done 2026-10-16

- **dict-algebra** (`DictAlgebra.elm`, Dict). `union`, `intersect`, `diff`, `merge` on two large
  overlapping dicts with arithmetic-progression keys, repeated. Check: closed-form sizes and value
  sums.
- **dict-keys** (`DictKeys.elm`, Dict; three workloads `dict-int`, `dict-string`, `dict-tuple`).
  The same build-and-lookup workload with `Int`, `String` and `(Int, Int)` keys, isolating the
  comparison cost (eco compares through `Utils.compare`, with an `Allocator::resolve` per
  operand). Check: as `dict`, by recomputing the sums without a Dict.
- **set-algebra** (`SetAlgebra.elm`, Set). `union`, `intersect`, `diff`, `filter` on large sets.
  Check: closed-form sizes and sums.
- **set-distinct** (`SetDistinct.elm`, Set). `Set.fromList` over a pseudo-random sequence with
  many duplicates. Check: the distinct count from a sort-and-dedupe of an independently generated
  copy.
- **shuffle-sort** (`ShuffleSort.elm`, Array). Fisher-Yates shuffle with `Array.get`/`set`, then
  `List.sort` of `Array.toList`. Check: the result is `0 .. n-1` (closed form), and the shuffle's
  first elements match the LCG's predicted swaps.
- **array-build** (`ArrayBuild.elm`, Array; Elm-specific). Build with `Array.push`, then repeated
  `slice` and `append` of large arrays (Elm's tail buffer and concatenation). Check: `toList`
  against ranges computed in closed form.
- **csv-split** (`CsvSplit.elm`, String). Generate CSV text, `String.split` rows and fields,
  `String.toInt`/`toFloat`, sum the columns. Check: the sums from the generator.
- **string-build** (`StringBuild.elm`, String; Elm-specific; three workloads `string-append`,
  `string-join`, `string-concat`). The same text built by `++` in a loop, `String.join` and
  `String.concat`. Check: the length and a checksum computed from the pieces.
- **prng** (`Prng.elm`, Bitwise). xorshift32 and PCG32 (in 32-bit halves) in a tight loop. Check:
  the generators' published reference sequences for their standard seeds, and the `n`-th value
  from a Python reference table at known sizes.
- **popcount** (`Popcount.elm`, Bitwise). Hamming weight, trailing zeros and bit reversal over
  `0 .. 2^k - 1`. Check: the popcount sum is `k * 2^(k-1)`, and the reversal applied twice is the
  identity.
- **binary-format** (`BinaryFormat.elm`, Bytes). Encode and decode a PNG-like chunked file:
  header, length-prefixed chunks, a CRC-32 per chunk (reusing `Crc32`'s table), mixed
  endianness, `float32`/`float64` and signed/unsigned widths. Check: the round trip and every
  chunk's CRC.
- **adler32** (`Adler32.elm`, Bytes). Adler-32 over a generated buffer with a byte-at-a-time
  `Decode.loop`, pricing the decoder's per-step cost. Check: `Adler32("Wikipedia") =
  0x11E60398`, and a table from Python's `zlib.adler32` at known sizes.
- **json-dict** (`JsonDict.elm`, JSON). `Decode.dict` and `keyValuePairs` over large objects.
  Check: sizes and value sums from the generator.
- **json-encode** (`JsonEncode.elm`, JSON). Encode a large nested value with indentation 0 and 4.
  Check: the text's length is computed from the value, and decoding gives the value back.
- **csv-parser** (`CsvParser.elm`, Parser). The `csv-split` input parsed with `Parser.loop` and
  `chompWhile`, for a direct parser-combinator vs `String.split` comparison. Check: the same sums
  as `csv-split`.
- **lexer** (`Lexer.elm`, Parser; Elm-specific). A lexer for a small language with many `oneOf`
  alternatives sharing prefixes (keywords vs identifiers vs operators), using `backtrackable` and
  `commit`. Check: the token count per kind from the generator.

## Open questions

- The Benchmarks Game's reference outputs for k-nucleotide and reverse-complement are for a
  specific fasta input size; confirm the size and that `Fasta.output` reproduces its input
  exactly before relying on them.
- plb2's matmul and sudoku inputs: confirm the generator and the puzzle list, and their licence,
  before embedding them.
- Whether `dict-keys` and `string-build` should be three workloads each (as planned, so each
  key type or method gets its own row) or one workload each with the variants folded in.
- Batch 1 brings the suite from 17 to 26 workloads, and the full plan to 62. `node run.mjs`
  with every default at 200+ ms on Elm, three backends and a process each will take a long time;
  a `--quick` mode or a subset list may be needed.

## Status

- 2026-10-16: plan written; nothing implemented.
- 2026-10-16: batch 1 implemented: `KNucleotide`, `Life`, `Brainfuck`, `RevComp`, `Sha256`,
  `BytesCodec` (two workloads), `JsonCoords`, `ExprParser`, registered in `Bench.elm` and
  `ElmBench.elm`; `elm/bytes` 1.0.8 and `elm/parser` 1.1.0 added to both `elm.json`;
  `Fasta.output 1000` is byte-identical to the published `fasta-output.txt`, and the Python
  reference used for the k-nucleotide and revcomp tables reproduces the published fasta,
  k-nucleotide and revcomp outputs exactly. (A `reference/` directory of the C and Python
  programs behind every table was added, then removed at the user's request; each module's
  documentation names its table's source.) Done-means: all 26
  workloads pass on elm, eco-js and eco native at their defaults (and in a bundle build); the
  nine new ones pass at 42 other sizes on eco native and eco-js (one wrong check found and
  fixed: k-nucleotide's position count for sequences shorter than k); a deliberate mutation of
  each of the nine fails its check (the first brainfuck mutation, cells wrapping at 255, does
  not change this program's behaviour and was replaced). Changes from the plan:
  - brainfuck runs `bench.b` with its loop nest cut from seven levels of ten to four (965k
    steps a run, same output); the full program is 953M steps, about a minute a run here.
    Size = runs.
  - sha256 drops the one-million-"a" vector (15,625 extra blocks a run) and keeps every word in
    `0 .. 2^32 - 1` with `modBy`, not `shiftRightZfBy 0` (finding 1).
  - the bytes pair is `bytes-static` / `bytes-dynamic` over `unsignedInt8` count loops, not
    mixed-width records: eco fuses only byte loops today (finding 2).
  - expr-parser's size is a number of 1,000-integer expressions, not one long expression
    (finding 3).
- Findings (eco bugs and gaps, none fixed here except the first part of 2):
  1. **eco native `Bitwise` is 64-bit.** elm/core defines it on 32-bit integers (JavaScript's
     semantics): `shiftRightZfBy 0 -1` is 4294967295 in Elm and -1 on eco native,
     `shiftLeftBy 31 1` is -2147483648 vs 2147483648, `complement 2147483648` is 2147483647 vs
     -2147483649; every operation differs once a value leaves 32 bits. Any Elm code that relies
     on the wrap-around (the usual `shiftRightZfBy 0` of hashing and crypto libraries) computes
     wrong results natively. Fixing it changes the semantics of every eco program, eco's own
     compiler included; not decided.
  2. **Bytes fusion miscompiled `Encode.sequence (List.map f records)` over records** (FIXED):
     the fused loop projected every list head as `i64` (or `f64` when all writes were floats),
     so a record element gave an `eco.project.record` on an `i64` and the module failed to parse.
     `BytesFusion.Reify` now carries the element's MonoType into `ELoop`/`WriteEachItem` and
     `Emit` projects the head at its SSA type (REP_BOUNDARY_003); regression test
     `test/elm-bytes/src/BytesEncodeRecordListFusionTest.elm`. Separately, decoder fusion covers
     only `unsignedInt8` shapes: no wider read, and no `map4` record decoder even outside a loop,
     is fused today (`BytesLoopFusionShapesTest` documents the loop case).
  3. **eco native's elm/parser crashes on a source over 128 Ki characters built by appending**:
     `StringOps::ensureFlat` keeps a rope larger than `string_flatten_limit` (128 Ki) structural,
     and `ParserExports.cpp` `parserView` then reads it with `flatStringView`, which asserts
     (RelWithDebInfo) or reads the rope node as characters (Release, `NDEBUG`). Flattening fully on
     every kernel call would be correct but quadratic (the parser kernels run once per step and
     nothing caches the flat copy), so the fix needs a decision: flatten once in `Parser.run`, or
     cache the flattened leaf.
  4. **eco native JSON is slow**: `json` at 90,000 coordinates takes 744 ms on eco native (dev)
     and 526 ms (bundle) against 250 ms on Elm; not profiled yet.
- 2026-10-16: batch 1 results (median ms of 11 after 3 warm-ups, a process per workload and
  backend; eco dev = the dev tree's native build, eco bundle = built by the release bundle):

  | workload | size | elm | eco-js | eco dev | eco bundle |
  |---|---:|---:|---:|---:|---:|
  | k-nucleotide | 9,000 | 236.1 | 236 | 132 | 130 |
  | life | 700 | 308.5 | 313 | 231 | 258 |
  | brainfuck | 4 | 230.3 | 228 | 138 | 152 |
  | revcomp | 70,000 | 233.3 | 235 | 129 | 112 |
  | sha256 | 5,000 | 221.3 | 231 | 40 | 37 |
  | bytes-static | 500,000 | 244.9 | 234 | 27 | 20 |
  | bytes-dynamic | 500,000 | 240.4 | 246 | 71 | 62 |
  | json | 90,000 | 250.1 | 248 | 744 | 526 |
  | expr-parser | 160 | 220.5 | 216 | 168 | 185 |

  Decoder fusion is worth 2.6x on eco native (bytes-static 27 vs bytes-dynamic 71 ms, the same
  work). list-fold measured 195 ms on Elm in this run (202-222 in earlier ones); left at 3M, since
  more would cross eco's list-chunking cutoff and change what it measures natively.
- 2026-10-16: tests after the BytesFusion fix: elm-tests 14,118/0; `--target full` JIT E2E
  2,385/2,385 (new `BytesEncodeRecordListFusionTest` included), JS E2E 162/162 (3 skipped).
- 2026-10-16: batch 2 implemented: `Dijkstra`, `WordFreq`, `Sudoku`, `FloodFill`, `MatMul`,
  `FloydWarshall`, `Levenshtein`, `UnicodeString`, `NSieveBits`, `Crc32`, `Base64`, `Utf8Bytes`,
  `JsonShapes`, `JsonDecoders`, `JsonParser`, `SExpr` (42 workloads in all). Done-means: all 42
  pass on elm, eco-js and eco native at their defaults, and in a bundle build; the 16 pass at 72
  other sizes on eco native and eco-js (one bug found and fixed: floyd-warshall's ring had a
  self-loop at n = 1); a mutation of each fails its check, after two fixes the mutations
  forced: base64 gained two vectors that produce `+` and `/` (a swapped alphabet passed the
  RFC's, which never do), and flood-fill's maze was rebuilt (its corner was a 6-cell pocket at
  every size, so the timed work was the check, not the fill; now 98 % of the open cells are
  reached). Reference values (crc32, levenshtein) came from Python scripts not kept in the
  repository. Changes from the plan:
  - dijkstra uses Dial's bucket queue (`Dict Int (List node)`; elm/core's `Dict` has no cheap
    minimum) and is checked by the shortest-path certificate at every size instead of a second
    Dijkstra.
  - sudoku generates its puzzles (shuffled valid grids, 26 givens) instead of embedding plb2's.
  - matmul is checked against a closed form of plb2's generator at every element.
  - floyd-warshall uses unit edges (ring plus chords), checked by BFS rows.
  - levenshtein: exact checks for structured pairs, bounds for edited ones, Python totals at
    known sizes.
  - unicode-string and utf8-bytes use Basic Multilingual Plane characters only (finding 5), and
    unicode-string checks only the ASCII part of `toUpper` (finding 6).
  - json-parser runs on json's documents (up to 1.2 M characters; `Encode.encode` gives a flat
    string, so finding 3 does not apply); sexpr runs 300-leaf programs under a self-applied
    recursive fib.
- More findings:
  5. **eco native `Char` is one UTF-16 code unit, not a code point.** `Char.fromCode 0x1F600` is
     U+FFFF and `String.toList` of a literal emoji gives its two surrogates (55357, 56832) where
     Elm gives one `Char` (128512); any per-character code over text outside the BMP (emoji, CJK
     extensions) diverges natively. This follows eco's representation (Char is `i16`,
     REP_BOUNDARY_003), so changing it is a design decision.
  6. **eco native `String.toUpper` / `Char.toUpper` map ASCII only** (`elm-kernel-cpp/src/core/
     Char.cpp`: "TODO: Full Unicode case conversion requires ICU"); Elm (JavaScript) maps é to É,
     ж to Ж. `toLower` is likely the same.
  7. Native JSON is slow across the board, not just in `json`: json-shapes 482 ms and
     json-decoders 780 ms (dev; 335 and 537 bundle) against 230 and 237 on Elm.
- 2026-10-16: batch 2 results (median ms of 11 after 3 warm-ups, a process per workload and
  backend):

  | workload | size | elm | eco-js | eco dev | eco bundle |
  |---|---:|---:|---:|---:|---:|
  | dijkstra | 240 | 241.7 | 238 | 136 | 147 |
  | word-freq | 220,000 | 262.3 | 255 | 122 | 111 |
  | sudoku | 340 | 254.5 | 255 | 177 | 172 |
  | flood-fill | 300 | 246.6 | 244 | 96 | 102 |
  | matmul | 165 | 232.6 | 227 | 50 | 60 |
  | floyd-warshall | 130 | 232.6 | 223 | 44 | 50 |
  | levenshtein | 70 | 224.4 | 220 | 258 | 200 |
  | unicode-string | 52,000 | 258.9 | 258 | 160 | 139 |
  | nsieve-bits | 5 | 229.9 | 225 | 125 | 136 |
  | crc32 | 1,000,000 | 227.2 | 246 | 30 | 29 |
  | base64 | 190,000 | 219.2 | 223 | 44 | 37 |
  | utf8-bytes | 500,000 | 278.9 | 282 | 71 | 63 |
  | json-shapes | 6,000 | 230.0 | 220 | 482 | 335 |
  | json-decoders | 35,000 | 237.2 | 236 | 780 | 537 |
  | json-parser | 10,000 | 223.5 | 220 | 248 | 229 |
  | sexpr | 230 | 229.3 | 215 | 227 | 225 |

  All 42 workloads: elm 11,909 ms, eco-js 11,778, eco dev 8,068, eco bundle 7,207 (1.65x
  faster than Elm in total, faster on 35 of the 42).
- 2026-10-16: batch 3 implemented: `DictAlgebra`, `DictKeys` (dict-int, dict-string,
  dict-tuple), `SetAlgebra`, `SetDistinct`, `ShuffleSort`, `ArrayBuild`, `CsvSplit`,
  `StringBuild` (string-append, string-join, string-concat), `Prng`, `Popcount`,
  `BinaryFormat`, `Adler32`, `JsonDict`, `JsonEncode`, `CsvParser`, `Lexer`: the plan is
  complete, 62 workloads. Done-means: all 62 pass on elm, eco-js and eco native at their
  defaults (each 200+ ms on Elm); the 20 pass at 72 other sizes on eco native and eco-js; a
  mutation of each fails its check (including three subtle ones: a Sattolo-style shuffle that
  still permutes, caught by the replay of the last 100 swaps; `floor` for `round` when reading
  prices; `Parser.token` for `Parser.keyword`, which lexes `iffy` as `if` + `fy`). Bugs of my
  own found on the way: string-build's checksum combination overflowed 2^53 on the JavaScript
  backends (now multiplies in 16-bit halves). Changes from the plan:
  - prng uses xorshift32 and xorshift128 (Marsaglia 2003, whose published first outputs are
    checked every run) instead of PCG32, which would need 64-bit multiplication in 16-bit limbs.
  - shuffle-sort's check replays the first 100 swaps over a sparse `Dict` (the last 100
    positions are final after them) instead of predicting first elements.
  - csv-split / csv-parser and lexer use documents under 128 Ki characters (400 rows; 600
    tokens) so the native parser kernel bug (finding 3) cannot fire; `n` counts documents.
  - json-encode compares round trips with object fields sorted (finding 8).
- More findings:
  8. **eco native `Encode.object` writes the fields sorted by key**; Elm (JavaScript) keeps the
     order given (`{"id":..,"name":..}` comes out `{"active":..,"dims":..,...}`). Lengths are
     unchanged, but anything that depends on field order (keyValuePairs after a round trip,
     byte-for-byte output) differs.
  9. **FIXED: eco native decoded corrupt Ints, Floats and Chars from `Decode.list`,
     `Decode.dict` and `Decode.keyValuePairs`** unless the element decoder was a bare
     `Decode.int` / `Decode.float`: `Decode.list (Decode.field "v" Decode.int)` over
     `[1, 2, 40]`-valued objects summed to 3362959422864 (pointer bits read as numbers).
     `JsonExports.cpp` `runDecoder` chose each list head's / tuple value's slot kind from the
     element decoder's top constructor; it now takes it from the decoded value (`decodedSlot`:
     Tag_Int / Tag_Float / Tag_Char unboxed, everything else boxed). `Decode.array` was not
     affected. Regression test `test/elm-json/src/DecodeUnboxedSlotsTest.elm`; the 33 licensed
     Json kernel rows (KernelSetFacts / KernelIntrinsics) re-audited (representation only) and
     the LSS_022 manifest updated. The release bundle in `dist/` predates the fix: json-dict
     fails there, as expected, until the bundle is rebuilt.
  10. `Debug.toString` of a tuple prints `(3, 186)` on eco native and `(3,186)` in Elm (debug
      output only).
  Performance notes: eco native is slower than Elm on string-append (328 vs 249 ms; repeated
  `++` onto a long string), csv-split (333 vs 231), csv-parser, json-dict and json-encode.
- 2026-10-16: batch 3 results (median ms of 11 after 3 warm-ups, a process per workload and
  backend; the bundle is the 12:04 release build, without the finding 9 fix):

  | workload | size | elm | eco-js | eco dev | eco bundle |
  |---|---:|---:|---:|---:|---:|
  | dict-algebra | 56,000 | 254.4 | 257 | 119 | 131 |
  | dict-int | 200,000 | 278.3 | 279 | 133 | 141 |
  | dict-string | 130,000 | 234.4 | 236 | 150 | 142 |
  | dict-tuple | 150,000 | 253.8 | 255 | 148 | 153 |
  | set-algebra | 70,000 | 255.7 | 251 | 127 | 145 |
  | set-distinct | 230,000 | 268.0 | 271 | 151 | 158 |
  | shuffle-sort | 210,000 | 250.3 | 248 | 181 | 191 |
  | array-build | 140,000 | 232.4 | 233 | 95 | 84 |
  | csv-split | 800 | 230.6 | 229 | 333 | 314 |
  | string-append | 300,000 | 248.5 | 244 | 328 | 295 |
  | string-join | 300,000 | 240.0 | 240 | 250 | 216 |
  | string-concat | 250,000 | 238.0 | 248 | 198 | 171 |
  | prng | 2,000,000 | 294.7 | 296 | 14 | 18 |
  | popcount | 1,200,000 | 226.4 | 236 | 35 | 35 |
  | binary-format | 13,000 | 246.5 | 231 | 163 | 151 |
  | adler32 | 1,000,000 | 271.2 | 265 | 76 | 73 |
  | json-dict | 43,000 | 251.6 | 254 | 379 | 278 (fails: no fix) |
  | json-encode | 7,000 | 247.4 | 252 | 337 | 237 |
  | csv-parser | 340 | 210.7 | 206 | 252 | 257 |
  | lexer | 125 | 209.7 | 212 | 159 | 184 |

  All 62 workloads: elm 16,889 ms, eco-js 16,676, eco dev 11,617, eco bundle 10,707 (1.58x
  faster than Elm in total; the bundle is faster than Elm on 51 of the 62, the dev build on 48).
- 2026-10-16: tests after the finding 9 fix: elm-tests 14,118/0; `--target full` JIT E2E
  2,386/2,386 (new `DecodeUnboxedSlotsTest` included), JS E2E 162/162 (3 skipped).
