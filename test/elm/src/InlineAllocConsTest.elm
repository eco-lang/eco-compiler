module InlineAllocConsTest exposing (main)

{-| Inline nursery allocation (HEAP_034, plans/inline-nursery-allocation.md
N3.3): long folds building cons/tuple/record/custom chains so the inline
bump diamond executes across MANY nursery block boundaries and minor GCs —
the slow path (eco_alloc_inline_slow: block advance + minor GC) and the
relocation of pending field values across it are exercised for every
converted class. Under a tiny-nursery `ECO_HEAP_CONFIG` this test forces
the slow edge constantly (the plan's §5.5 stress leg); under stock config
it still crosses many minor GCs.

Boxed heads/fields (the String leg, the tuple-in-list leg) additionally
cover the REP_LLVM_002 barriered fresh stores under GC movement: a stale
head/tail after relocation shows up as a wrong sum/concat or a crash.

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
            -- 1M cons cells (unboxed Int heads), sum via fold.
            List.foldl (+) 0 (buildInts 1000000 [])

        _ =
            Debug.log "intsum" intsum

        strlen =
            -- 20K boxed-head cons cells.
            List.foldl (\s a -> a + String.length s) 0 (buildStrs 20000 [])

        _ =
            Debug.log "strlen" strlen

        tupsum =
            -- Tuple2 (i64, f64) inside cons cells: inline tuple alloc feeding
            -- inline cons alloc — the adjacent-diamond shape.
            List.foldl (\( i, f ) a -> a + i + floor f) 0 (buildTups 200 [])

        _ =
            Debug.log "tupsum" tupsum

        recsum =
            -- Records with a mixed unboxed bitmap.
            List.foldl (\r a -> a + r.a + r.c + floor r.b) 0 (buildRecs 1000 [])

        _ =
            Debug.log "recsum" recsum

        mixed =
            -- Custom ctors (Wrap = 2-field custom with i64+f64 unboxed;
            -- Tag = boxed String field) through a case.
            List.foldl (\w a -> a + sumWrap w) 0 [ Wrap 10 5.5, Tag "abcdefghijklmnop" ]

        _ =
            Debug.log "mixed" mixed
    in
    text "done"
