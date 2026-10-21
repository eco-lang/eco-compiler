module LocalRecCaptureSplitParamTest exposing (main)

{-| A local recursive function captures a tuple param of an enclosing
tail-recursive function. The outer loop scalar-splits that param (its
varMapping is removed; it lives only as slots in `splitAggParams`), so the
MonoTailDef capture lookup — which only read varMappings — silently DROPPED
the capture. The lambda body then crashed codegen
(`lookupVar: unbound variable pair`), and the swallowed crash left a
truncated .mlir behind while the compiler exited 0.

outer2 (0,0) 2 -> pair (2,4); loop 0 -> 3 + 2 + 4 = 9 (whole-value use
via Tuple.first/second). outer3 is the same via a `case` destructure.

-}

-- CHECK: o2: 9
-- CHECK: o3: 9

import Html exposing (text)


outer2 : ( Int, Int ) -> Int -> Int
outer2 pair n =
    if n <= 0 then
        let
            loop i =
                if i >= 3 then
                    i + Tuple.first pair + Tuple.second pair

                else
                    loop (i + 1)
        in
        loop 0

    else
        case pair of
            ( x, y ) ->
                outer2 ( x + 1, y + 2 ) (n - 1)


outer3 : ( Int, Int ) -> Int -> Int
outer3 pair n =
    if n <= 0 then
        let
            loop i =
                case pair of
                    ( p, q ) ->
                        if i >= 3 then
                            i + p + q

                        else
                            loop (i + 1)
        in
        loop 0

    else
        case pair of
            ( x, y ) ->
                outer3 ( x + 1, y + 2 ) (n - 1)


main =
    let
        _ =
            Debug.log "o2" (outer2 ( 0, 0 ) 2)

        _ =
            Debug.log "o3" (outer3 ( 0, 0 ) 2)
    in
    text "done"
