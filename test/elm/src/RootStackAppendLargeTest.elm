module RootStackAppendLargeTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `++`, `List.append`
and `List.concat` on lists too long for a chunk chain.

Below the `chunkChainFits` cap these kernels fill a builder chunk chain and root nothing per
element (which is why RootStackAppendTest passes). Above it they fall back to
`listFromUnboxables`, which pushes one root record per boxed element.
-}

-- CHECK: appended: 4300001
-- CHECK: concatenated: 8600000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


{-| 4,300,000 boxed strings: more than the chunk-chain cap (`chunkChainFits`: a quarter of the 128 MB
nursery) and more than 64 × 65,536 = 4,194,304, so per-64 rooting overflows too.
-}
strs : List String
strs =
    List.map pad (List.range 0 4299999)


main =
    let
        _ =
            Debug.log "appended" (List.length (strs ++ [ "x" ]))

        _ =
            Debug.log "concatenated" (List.length (List.concat [ strs, strs ]))
    in
    text "done"
