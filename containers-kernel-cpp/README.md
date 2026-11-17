# eco/containers

`SeqDict` and `SeqSet` for eco programs: a Dict and a Set whose keys can be any equatable value, not
only `comparable` ones, and whose `toList`, `foldl` and the rest go in insertion order. The API and
behaviour are [lamdera/containers](https://github.com/lamdera/containers)'s, and so is most of the
implementation (Robin Hansen's hash trie, an insertion-order `Array`, the `JsArray2` kernel), with
these changes:

- **Hashing.** `FNV.hash` is a native kernel (`src/eco-containers/FNVExports.cpp`) that walks any value
  on eco's heap: FNV-1a over its content, finished with MurmurHash3's fmix32, bounded so a large key
  costs O(1). It hashes by content, not representation, so it agrees with `==`: boxed and unboxed
  numbers, every String form, list cells and chunks, Dicts in key order, SeqDicts in insertion order.
  The JS kernel (`src/Elm/Kernel/FNV.js`) does the same in JavaScript.
- **`JsArray2`** forwards to elm/core's `JsArray` kernel, plus `unsafeSet`, `unsafeInsert` and
  `removeIndex` (`src/eco-containers/JsArray2Exports.cpp`).
- **64-bit `Bitwise`.** eco's Bitwise works on 64 bits, so `compressedIndex` masks to 32 bits.
- **No `encodeDict`/`decodeDict`/`encodeSet`/`decodeSet`**: they need lamdera/codecs.

## `==`

Removing an entry leaves a hole in a SeqDict's insertion-order Array, so two SeqDicts with the same
entries in the same order can differ structurally. The compiler gives `SeqDict_elm_builtin` the
reserved constructor tag `CtorTag.seqDict` (0xFFFB, `CTOR_SEQDICT` in
`elm-kernel-cpp/src/core/SeqDict.hpp`), and `==` (`eqHelp` in `elm-kernel-cpp/src/core/Utils.cpp`)
compares two SeqDicts by their entries in insertion order, as it compares Dicts by their entries in
key order.

In JavaScript, `==` comes from elm/core's kernel, which compares SeqDicts structurally.

Tests: `test/eco-containers`.
