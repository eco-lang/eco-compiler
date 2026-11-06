module LssGapBodyTieAnnoAB exposing (main)

{-| A top-level function that returns a lambda gives the same result whether or
not it has a type annotation.

`adderAnn` (annotated `Int -> (Int -> Int)`) and `adderInf` (no annotation)
have identical bodies, `\y -> x + y`. Each is partially applied to 3 and
passed to `apply`, which calls it with 4, printing 7 for both.
-}

-- CHECK: bodyTieAnn: 7
-- CHECK: bodyTieInf: 7

import Html exposing (text)


adderAnn : Int -> (Int -> Int)
adderAnn x =
    \y -> x + y


adderInf x =
    \y -> x + y


apply : (Int -> Int) -> Int -> Int
apply f n =
    f n


main =
    let
        _ =
            Debug.log "bodyTieAnn" (apply (adderAnn 3) 4)

        _ =
            Debug.log "bodyTieInf" (apply (adderInf 3) 4)
    in
    text "hello"
