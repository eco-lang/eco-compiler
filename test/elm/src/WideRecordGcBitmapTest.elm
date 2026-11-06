module WideRecordGcBitmapTest exposing (main)

{-| A 17-field record holding one `Int` and sixteen `String`s keeps its field
values while the program builds large lists before reading them.

`w1` is built with a `count` of 50000 (the length of one list), then a list of
150000 strings is built before `w2` is made and both are read. The test checks
that the two counts add to 200000 and that `w1.p ++ w2.a` has length 2.

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

        -- The count comes from a list length rather than a literal.
        w1 =
            mkWide (List.length seed)

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
