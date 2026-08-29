module LssGapBodyTieAnnoAB exposing (main)

{-| Q3 discriminator: does the annotation<->body tie fail because
`stampArrowRoots` bails at a generalized annotation ROOT, or for every def?
`adderAnn` and `adderInf` share a body and differ only in having an annotation.
If `/r` reads var on BOTH, the loss is in consumption (translate stays
occurrence-keyed); if only on `adderAnn`, it is the stamp walk, and
[stampguard]/stampwalk: will agree.
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
