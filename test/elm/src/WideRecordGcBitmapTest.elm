module WideRecordGcBitmapTest exposing (main)

{-| Regression test for the 32-bit Bitwise wraparound in
`Types.bitmapSetKind` (MLIR codegen).

Records with more than 16 fields wrapped their high slots onto slots
0..6 of the 2-bit-per-slot unboxed bitmap (Elm Bitwise shifts are 32-bit,
so slot 16's mask landed on slot 0) and CLEARED the Int kind at slot 0.
The GC then scanned the raw Int as a heap pointer and aborted with
"Pointer below heap base" the first time a minor GC scanned the live
record — the MonoSolver self-host crash (its 23-field `S` state record).

This builds 17-field records whose single Int field occupies unboxed
slot 0 (boxed field index 16 is the one that wrapped onto it), keeps
them live across enough allocation churn to force minor GCs, and reads
the fields back.

-}

-- CHECK: WideRecordGcBitmap: 200000
-- CHECK: WideRecordGcBitmapTag: 2

import Html exposing (text)


type alias Wide =
    { count : Int
    , a : String
    , b : String
    , c : String
    , d : String
    , e : String
    , f : String
    , g : String
    , h : String
    , i : String
    , j : String
    , k : String
    , l : String
    , m : String
    , n : String
    , o : String
    , p : String
    }


mkWide : Int -> Wide
mkWide count =
    { count = count
    , a = "a"
    , b = "b"
    , c = "c"
    , d = "d"
    , e = "e"
    , f = "f"
    , g = "g"
    , h = "h"
    , i = "i"
    , j = "j"
    , k = "k"
    , l = "l"
    , m = "m"
    , n = "n"
    , o = "o"
    , p = "p"
    }


churn : Int -> List String -> List String
churn n acc =
    if n <= 0 then
        acc

    else
        churn (n - 1) (String.fromInt n :: acc)


main =
    let
        seed =
            churn 50000 []

        -- Non-constant count so the record construction cannot fold away.
        w1 =
            mkWide (List.length seed)

        -- Allocation churn while w1 is live: minor GCs must scan w1 and
        -- correctly skip its unboxed Int slot.
        more =
            churn 150000 []

        w2 =
            mkWide (List.length more)

        total =
            w1.count + w2.count

        tag =
            w1.p ++ w2.a

        _ =
            Debug.log "WideRecordGcBitmap" total

        _ =
            Debug.log "WideRecordGcBitmapTag" (String.length tag)
    in
    text "done"
