module InlineAllocConsTest exposing (main)

{-| Folds over lists of Ints, Strings, tuples, records and custom-type values give the right totals.

The first four lists are built by tail-recursive loops: the Int list has one
million elements, the String list 20000, the tuple list 200 and the record list
1000. The custom-type list holds one value of each
constructor of `Wrap`, one with Int and Float fields and one with a String
field.

## eco

Exercises inline nursery allocation (HEAP_034 in design_docs/invariants.csv;
plans/inline-nursery-allocation.md). The long folds build cons, tuple, record
and custom-type chains, so the inline bump-allocation diamond runs across many
nursery block boundaries and minor GCs. That covers the slow path
(`eco_alloc_inline_slow`, declared in runtime/src/allocator/RuntimeExports.h:
block advance plus minor GC) and relocation of pending field values across it
for every converted class. Under a tiny-nursery `ECO_HEAP_CONFIG` the slow edge
is taken constantly.

The lists cover the unboxed cases (Int heads; `Wrap` with i64 and f64 fields;
records with a mixed unboxed bitmap) and the boxed ones (String heads, tuples
in cons cells, which also give the adjacent inline tuple and cons allocation
diamonds). The boxed ones cover the barriered fresh stores of REP_LLVM_002
under GC movement: a stale head or tail after relocation shows up as a wrong
sum or a crash.

-}

-- CHECK: intsum: 500000500000
-- CHECK: strlen: 40000
-- CHECK: tupsum: 40200
-- CHECK: recsum: 2002000
-- CHECK: mixed: 31

import Html exposing (text)


type Wrap
    = Wrap Int Float
    | Tag String


buildInts : Int -> List Int -> List Int
buildInts n acc =
    if n <= 0 then
        acc

    else
        buildInts (n - 1) (n :: acc)


buildStrs : Int -> List String -> List String
buildStrs n acc =
    if n <= 0 then
        acc

    else
        buildStrs (n - 1) ("ab" :: acc)


buildTups : Int -> List ( Int, Float ) -> List ( Int, Float )
buildTups n acc =
    if n <= 0 then
        acc

    else
        buildTups (n - 1) (( n, toFloat n ) :: acc)


buildRecs : Int -> List { a : Int, b : Float, c : Int } -> List { a : Int, b : Float, c : Int }
buildRecs n acc =
    if n <= 0 then
        acc

    else
        buildRecs (n - 1) ({ a = n, b = toFloat n, c = n * 2 } :: acc)


sumWrap : Wrap -> Int
sumWrap w =
    case w of
        Wrap i f ->
            i + floor f

        Tag s ->
            String.length s


main =
    let
        intsum =
            -- The sum of 1 to 1000000.
            List.foldl (+) 0 (buildInts 1000000 [])

        _ =
            Debug.log "intsum" intsum

        strlen =
            -- 20000 copies of "ab".
            List.foldl (\s a -> a + String.length s) 0 (buildStrs 20000 [])

        _ =
            Debug.log "strlen" strlen

        tupsum =
            -- Each ( n, toFloat n ) contributes 2n, for n from 1 to 200.
            List.foldl (\( i, f ) a -> a + i + floor f) 0 (buildTups 200 [])

        _ =
            Debug.log "tupsum" tupsum

        recsum =
            -- Each record contributes 4n, for n from 1 to 1000.
            List.foldl (\r a -> a + r.a + r.c + floor r.b) 0 (buildRecs 1000 [])

        _ =
            Debug.log "recsum" recsum

        mixed =
            -- (10 + floor 5.5) + String.length "abcdefghijklmnop" = 15 + 16.
            List.foldl (\w a -> a + sumWrap w) 0 [ Wrap 10 5.5, Tag "abcdefghijklmnop" ]

        _ =
            Debug.log "mixed" mixed
    in
    text "done"
