# `getComments_$_16433` Shape Analysis & Reproducer Plan

**Date:** 2026-04-27
**Reference:** `/work/bootstrap-stage7-crash-analysis.md`
**Question (from user):** *Analyse the code, the shape of the closure(s) and data that `getComments` creates. Can you see a pattern here that we can make a test out of that will reproduce the bug?*

This document walks the source-level shape, lines it up against the trace evidence, identifies the *specific* layout pattern most likely to be miscompiled, and proposes a tight Elm reproducer that exercises that pattern end-to-end.

---

## 1. The crashing function (source)

`/work/compiler/src/Compiler/Parse/Module.elm`:

```elm
getComments : List Decl.Decl
           -> List ( Name.Name, Src.Comment )
           -> List ( Name.Name, Src.Comment )
getComments decls comments =
    case decls of
        [] ->
            comments

        decl :: otherDecls ->
            case decl of
                Decl.Value c (A.At _ (Src.Value v)) ->
                    getComments otherDecls (addComment c (Tuple.second v.name) comments)

                Decl.Union c (A.At _ (Src.Union ( _, n ) _ _)) ->
                    getComments otherDecls (addComment c n comments)

                Decl.Alias c (A.At _ (Src.Alias data)) ->
                    getComments otherDecls (addComment c (Tuple.second data.name) comments)

                Decl.Port c (Src.Port _ ( _, n ) _) ->
                    getComments otherDecls (addComment c n comments)


addComment : Maybe Src.Comment
          -> A.Located Name.Name
          -> List ( Name.Name, Src.Comment )
          -> List ( Name.Name, Src.Comment )
addComment maybeComment (A.At _ name) comments =
    case maybeComment of
        Just comment ->
            ( name, comment ) :: comments

        Nothing ->
            comments
```

## 2. The data shape, fully expanded

```
Decl                                   -- Custom, 4 ctors, each 2 fields
  Value (Maybe Src.Comment) (A.Located Src.Value)
  Union (Maybe Src.Comment) (A.Located Src.Union)
  Alias (Maybe Src.Comment) (A.Located Src.Alias)
  Port  (Maybe Src.Comment) Src.Port

Maybe a                                -- Custom, 2 ctors
  Just a                               -- ctor=1, 1 field (boxed)
  Nothing                              -- ctor=0, 0 fields  (embedded constant)

A.Located a                            -- Custom, 1 ctor
  At Region a                          -- 2 fields: Region (custom), payload (boxed)

A.Region                               -- Custom, 1 ctor
  Region Position Position             -- 2 fields, each a Position

A.Position                             -- Custom, 1 ctor
  Position Int Int                     -- 2 fields, BOTH unboxed (Int)

Src.Comment                            -- Custom, 1 ctor
  Comment Snippet                      -- 1 field

Snippet                                -- Custom, 1 ctor (a record-like custom)
  Snippet { fptr   : String            -- BOXED
          , offset : Int               -- UNBOXED
          , length : Int               -- UNBOXED
          , offRow : Int               -- UNBOXED
          , offCol : Int               -- UNBOXED
          }                            -- → Record with mixed-kind unboxed bitmap

Src.Value                              -- Custom, 1 ctor
  Value ValueData                      -- 1 field

ValueData                              -- record
  { comments : FComments               -- BOXED  (List FComment)
  , name     : C1 (A.Located Name)     -- BOXED  ( = (FComments, A.Located Name) tuple )
  , args     : List (C1 Pattern)       -- BOXED
  , body     : C1 Expr                 -- BOXED
  , tipe     : Maybe (C1 (C2 Type))    -- BOXED
  }

C1 a   = ( FComments, a )              -- Tuple2; both boxed
C2 a   = ( ( FComments, FComments ), a ) -- Tuple2 of (Tuple2 boxed, boxed)
```

The monomorphisation `getComments_$_16433` was emitted for a *fully-concrete* call (`List Decl.Decl → List (Name, Comment) → List (Name, Comment)` — no type variables remain), so we should expect exactly one specialisation of this function in the binary.

The two-tuple it builds and Cons-prepends:

```
( Name              -- a String pointer (BOXED)
, Src.Comment       -- a Custom-1 wrapping a Snippet record (BOXED)
)
```

— is `Tuple2 a:HPointer b:HPointer`, both slots boxed. (Trace entry `[10]` shows exactly this: `tag=4 size=24` — 24 = `sizeof(Tuple2) = 8 + 2*8`.)

## 3. Lining up the trace's last-32 successful resolves

(From `/work/bootstrap-stage7-crash-analysis.md`, oldest → newest. **Bold** is my interpretation.)

| Slice    | Trace entry                                                        | Likely AST element                                                   |
|----------|--------------------------------------------------------------------|----------------------------------------------------------------------|
| [11–16]  | 6× `Closure size=3` at nursery `0x7efb2b6ebf80`                    | The PAP / closure for the recursive tail-call, **probably `addComment c (...)` partially applied** with the 3 captures (c, located-name, accumulator) — alternatively the Result.map continuation from `checkModule` |
| [17–21]  | 5× `Closure size=1` at nursery `0x7efb2b6ebf60` (16 B earlier)     | A 1-capture continuation — likely the inner λ that closes over `comment` after `Maybe` is destructured |
| [22]     | `Tuple2 size=24` at old-gen `0x7ef82b875d38`                       | The `(name, comment)` tuple just consed onto the result list         |
| [23–24]  | 2× `Custom size=1` at old-gen `0x7ef82b863f78`                     | The `Comment Snippet` wrapper or a `Just X` (both shapes match)      |
| [25–27]  | 3× `Cons size=0` at nursery `0x7efb2b6ec0e8`                       | The list-spine cell (`decl :: otherDecls`)                           |
| [28–30]  | 3× `Tag_Int` at `0x7ef8855d4fe0`                                   | An `Int` field — three reads of the same int suggest a `case`-match on a `Position` row/col, or on `Snippet.offset`/`length` |
| **[31]** | `hptr=0x0` → `obj=heap_base+0` `tag=0`                             | All-zero 8 bytes read from a slot that should have held an HPointer  |
| **⛔**   | `hptr=0x006c0061006e0069` ("inal" UTF-16 LE) → 3 TB above heap_end | 8 bytes read from the slot **immediately after** the all-zero one    |

The critical observation is the **last two reads**: zeros followed by 8 bytes of UTF-16 character data. *No legitimate boxed field ever contains either of those values.* Two consecutive reads producing first all-zeros and then UTF-16 string content is the signature of **stepping off the end of one allocation and into the next** — and the next adjacent allocation is a `Tag_String`.

## 4. Why `Snippet.fptr` (UTF-16 source text) is the next-adjacent allocation

`Snippet`'s first field is `fptr : String`. The `fptr` slot holds an HPointer to an `ElmString` whose `chars[]` are the **actual source text** the compiler is parsing. Every `Maybe Src.Comment` that flows into `getComments` carries a Snippet that points at a freshly-allocated UTF-16 String containing whatever characters appear in the Elm source on disk.

So the heap, while `getComments` runs, is full of `(Custom Comment / Custom Snippet / Record / String)` quads stored close together in age order. When the compiled code over-shoots the end of one of these objects by one or two slots, the bytes it reads are almost guaranteed to be either:

1. **the next object's `Header`** (zeros for a freshly-allocated `Tag_Int(0)` or a `Tag_Free` cell — entry **[31]**), then
2. **the next object's *first* payload word** — and if that next object is a String, you get `header_size_bytes ⨯ 1` UTF-16 chars of source code (the failure).

The `"inal"` string fragment in the failing bits is consistent with a substring of any of: `"Original"`, `"Internal"`, `"Final"`, `"Marginal"`, `"Original.elm"`. The compiler is parsing its own modules at this point, several of which contain such tokens.

## 5. The likely off-by-N

Three structurally suspicious places in `getComments`'s codegen are worth flagging, in order of likelihood:

### 5.1 The 4-deep nested pattern destructuring `Decl.Value c (A.At _ (Src.Value v))`

Reading `v.name.second` from a `Decl.Value` requires walking:

```
Decl.Value [Custom, ctor=0, 2 fields]
   field[1] -> A.Located Src.Value [Custom At, 2 fields]
      field[1] -> Src.Value [Custom, 1 field]
         field[0] -> ValueData [Record, 5 fields, mixed unboxed bitmap]
            slot 'name' (offset 1 in record) -> C1 (A.Located Name) = Tuple2 [boxed, boxed]
               slot 1 -> A.Located Name [Custom At, 2 fields]
                  field[1] -> Name [String]
```

That's **seven heap-load steps in a row** with three different container layouts (Custom, Record, Tuple2). Any field-offset bug at any one of these steps gives the symptom we see.

The single most likely bug among them is in **Record-slot indexing for `ValueData.name`**. `Record.values[i]` is at byte offset `sizeof(Header) + sizeof(u64) /* unboxed bitmap */ + i * sizeof(Unboxable)` = `16 + 8*i`. If the codegen instead emits `8 + 8*i` (forgetting the per-record `unboxed` bitmap field), it reads slot `i+1` thinking it's slot `i` — which on a 5-field record `{comments, name, args, body, tipe}` reading "slot name" (i=1) actually reads the `args` field. Worse: reading "slot tipe" (i=4) reads off the end into the next adjacent object.

### 5.2 The `(_, n)` and `(_, name)` skip-and-extract of Tuple2

`(_, n)` in `Decl.Union c (A.At _ (Src.Union ( _, n ) _ _))` reads `Tuple2.b` while ignoring `Tuple2.a`. The Tuple2's bitmap (`hdr->unboxed`) tells the GC and the codegen which slots are boxed. If the codegen for `(_, n)` reads at offset `8 + 8` (i.e. `Tuple2.a + 8 = Tuple2.b`) but the codegen for the other arm `Tuple.second v.name` reads at `8 + 16` (Tuple2.b *plus* an extra 8), one of those is wrong by 8 bytes. The "miss by 8" would cleanly explain how the next `eco_resolve_hptr` reads the next slot of the adjacent allocation.

### 5.3 Closure capture order in the tail-recursive call

```
getComments otherDecls (addComment c (Tuple.second v.name) comments)
```

If the tail call is implemented as a saturated apply and `addComment` is over-applied (Eco does this via `eco_apply_segmentation_unknown`, which **is on the backtrace**), the wrapper has to assemble a 3-arg array from a partially-built closure. The wrapper reads `closure->values[i]` for each captured arg. If the closure says `n_values = 3` but actually only 2 captures were written before it was called, `values[2]` reads garbage memory — the immediately-adjacent allocation.

The 6 consecutive `Closure size=3` resolves at trace entries `[11–16]` (and 5 consecutive `Closure size=1` at `[17–21]`) are exactly the kind of churn that `eco_apply_segmentation_unknown` produces on every iteration of the loop. If even one iteration's closure has a mismatched `n_values` vs. capture-slot fill, this exact failure follows.

## 6. The shape we want a reproducer to exercise

To trigger the same off-by-N reliably, the test program should hit *all* of:

1. **Custom-with-`Maybe`-payload + nested-Located + nested-Custom destructuring** — a `Decl`-shape with at least two layers of `(_, X)` skip-extraction.
2. **A Record field of `String`** sitting next to several `Int` fields (Snippet's `{fptr, offset, length, offRow, offCol}`). The `unboxed` bitmap matters: 1 boxed slot followed by N unboxed slots.
3. **Tail-recursive walk of a list of those values** with a tail call that `Cons`-prepends `(Name, Comment)` — i.e. the recursion builds an accumulator List of `Tuple2 (HPointer, HPointer)`.
4. **An over-applied call through `eco_apply_segmentation_unknown`** — wrap the recursion in a `Result.map (\x -> walkAll x)` so the saturation is decided at runtime by the apply machinery.
5. **Heavy GC pressure**, so the next-adjacent allocation after the destructured object is reliably a freshly-allocated `Tag_String` (the source text of the next iteration). The Stage 7 workload trips this naturally; a small program needs an inner loop of "allocate a String of 4–8 chars, then walk a Decl-shaped list" to force-fit dead nursery objects with String content.

## 7. Concrete reproducer — Elm program

A minimal reproducer that hits all 5 points. (Not yet validated end-to-end — proposed for the next iteration; sized small enough to drop into `tests/elm-e2e/` and run under the same E2E harness as the current 542-test suite.)

```elm
-- file: tests/e2e/GetCommentsRepro.elm
module GetCommentsRepro exposing (main)

import Eco.Crash


-- Mirror of Compiler.Parse.Module's data shape.

type Decl
    = Value (Maybe Comment) (Located ValueAST)
    | Union (Maybe Comment) (Located UnionAST)


type Comment
    = Comment Snippet


type alias Snippet =
    { fptr : String      -- BOXED   (the whole point: holds UTF-16 source text)
    , offset : Int       -- UNBOXED
    , length : Int       -- UNBOXED
    , offRow : Int       -- UNBOXED
    , offCol : Int       -- UNBOXED
    }


type Located a
    = At Region a


type alias Region =
    { startRow : Int, startCol : Int, endRow : Int, endCol : Int }


type ValueAST
    = ValueAST { comments : List String
               , name     : ( List String, Located String )   -- C1 (Located Name)
               , body     : String
               }


type UnionAST
    = UnionAST ( List String, Located String )                -- (FComments, Located Name)
              (List String) (List String)


-- The recursive walker — same shape as getComments.

walk : List Decl -> List ( String, Comment ) -> List ( String, Comment )
walk decls acc =
    case decls of
        [] ->
            acc

        decl :: rest ->
            case decl of
                Value c (At _ (ValueAST v)) ->
                    walk rest (push c (Tuple.second v.name) acc)

                Union c (At _ (UnionAST ( _, n ) _ _)) ->
                    walk rest (push c n acc)


push : Maybe Comment -> Located String -> List ( String, Comment )
                     -> List ( String, Comment )
push maybeComment (At _ name) acc =
    case maybeComment of
        Just c ->
            ( name, c ) :: acc

        Nothing ->
            acc


-- Build N input declarations whose Snippet.fptr is a freshly-allocated
-- String. The String is `String.repeat n "Original"` — i.e. a long
-- ASCII text whose UTF-16 encoding contains the bytes 0x69 0x00 0x6e 0x00
-- 0x61 0x00 0x6c 0x00 ("inal") at every "Original" boundary.

mkDecl : Int -> Decl
mkDecl i =
    let
        snippet =
            { fptr = String.repeat 8 "Original"   -- text the runtime can mis-read
            , offset = i
            , length = 8 * 8
            , offRow = i
            , offCol = i
            }

        comment =
            if remainderBy 2 i == 0 then
                Just (Comment snippet)
            else
                Nothing

        located =
            At { startRow = i, startCol = 0, endRow = i, endCol = 80 }
                (ValueAST
                    { comments = []
                    , name = ( [], At { startRow = i, startCol = 0, endRow = i, endCol = 8 }
                                       ("name_" ++ String.fromInt i) )
                    , body = String.repeat 4 "x"
                    }
                )
    in
    Value comment located


mkInputs : Int -> List Decl
mkInputs n =
    List.map mkDecl (List.range 1 n)


-- Iterate to force ~thousands of major GCs. Each pass:
--   1. Builds a fresh List Decl whose Comment payloads point at fresh Strings.
--   2. Calls walk in a Result.map — the apply machinery has to go through
--      eco_apply_segmentation_unknown for the result-wrapping closure.
--   3. Discards the result (it's all garbage by the time the next iteration
--      starts), so the Strings end up on dead old-gen pages and the next
--      iteration's allocations land on top of them.

doPass : Int -> Result () (List ( String, Comment ))
doPass i =
    Ok (mkInputs (200 + remainderBy 50 i))
        |> Result.map (\decls -> walk decls [])


main : Program () () ()
main =
    let
        loop : Int -> Int
        loop i =
            if i >= 5000 then
                i
            else
                case doPass i of
                    Ok xs ->
                        if List.length xs >= 0 then
                            loop (i + 1)
                        else
                            i

                    Err _ ->
                        i
    in
    Eco.Crash.crash ("done at " ++ String.fromInt (loop 0))
```

If `getComments_$_16433` is miscompiled, this should crash inside `walk` with a `Pointer above heap end` SIGABRT whose recent-resolves window looks structurally identical to the production Stage-7 trace.

## 8. Diagnostic test plan

To confirm it's actually the same bug (rather than a similar-shape bug) and to localise the off-by-N:

1. **Run the reproducer with `ECO_RESOLVE_TRACE=1`** (the instrumentation from the prior report). Expected: trace fires inside `walk`, last few resolves show Cons → Custom → Tuple2 → Int → zero → UTF-16 fragment; the failing bits are characters from `String.repeat 8 "Original"`.
2. **Bisect the destructuring depth.** Start with `Value c (At _ v)` (1-deep), then `Value c (At _ (ValueAST v))` (2-deep), then add `(_, n) = v.name`. The shallowest depth that crashes is the one whose codegen is wrong.
3. **Bisect the Snippet shape.** Drop fields one at a time: pure `String`, then add 1 `Int`, then 2 `Int`, etc. The smallest mixed-kind Record that crashes points at the slot-offset arithmetic that's buggy.
4. **Add a per-`eco.heap.read` bounds-check assertion in EcoToLLVM** for debug builds (one extra `cmp + br` per heap load — cheap). Without that, the *first* downstream `eco_resolve_hptr` is the only place we see the failure; with it, the first off-end load itself fires.
5. **Dump the MLIR for `Compiler_Parse_Module_getComments_$_16433`** with `--text-mlir` and grep for `eco.heap.read` / `eco.tuple.get` / `eco.record.get` / `eco.closure.capture` — every offset constant in this function's body is a candidate for the off-by-N.

## 9. What I still don't know

- Which of §5.1 / §5.2 / §5.3 is the actual bug. The trace evidence is consistent with all three. Step 2 of §8 (depth bisection) cleanly distinguishes 5.1 from 5.2; step 5 (MLIR dump) distinguishes 5.3 from the field-offset bugs.
- Whether the `Terminal_Main_lambda_14536$cap` 3-capture closure is the saturated `Result.map` continuation or a closer hoisting. The number `14536` is post-monomorphisation — without a debug map I can't trace it back to source. Step 5 (`--text-mlir`) would resolve this too, since the lambda's body is what the closure_wrapper invokes.

## 10. Files referenced

- `runtime/src/allocator/Allocator.cpp` — `Allocator::resolve` (where the assert fires; `ECO_RESOLVE_TRACE` instrumentation is currently *not* in the tree — see system note about the file being modified). The trace data shown here is from the prior run and is preserved in `bootstrap-stage7-crash-analysis.md`.
- `runtime/src/allocator/RuntimeExports.cpp` — `buildEvaluatorArgs` (closure-wrapper bitmap interpretation).
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` — `getOrCreateWrapper` (the `__closure_wrapper_*` symbols you see on the backtrace).
- `runtime/src/allocator/Heap.hpp` — `Closure` / `Custom` / `Record` / `Tuple2` / `Cons` / `ElmString` layouts (lines 226–290).
- `compiler/src/Compiler/Parse/Module.elm` — `getComments` (line 342) / `addComment` (line 363).
- `compiler/src/Compiler/Parse/Declaration.elm` — `Decl` (line 46).
- `compiler/src/Compiler/AST/Source.elm` — `Comment` (line 513), `ValueData` (line 429), `Located` / `C1` / `C2`.
- `compiler/src/Compiler/AST/Snippet.elm` — `Snippet` (line 48).
