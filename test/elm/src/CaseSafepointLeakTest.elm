module CaseSafepointLeakTest exposing (main)

{-| Test that case expressions with temporaries in alternatives don't leak
SSA variables into the GC root hints attached to GCRootCarrier ops at the
parent scope. The pattern:

    1. Case expression where alternatives create temporary !eco.value values
    2. Heap allocation after the case (the carrier op picks up live-root hints)

If the carrier's appended GC root operands reference SSA values from inside
the case regions, the MLIR will fail to parse (cross-region SSA reference).
This test predates the removal of `eco.safepoint`; the hazard now lives on
the carrier's `live_roots` segment instead of a standalone safepoint op.
-}

-- CHECK: extract1: ["b", "a"]
-- CHECK: extract2: ["default", "a"]

import Html exposing (text)


type MyResult
    = MyOk String
    | MyErr String


extract : MyResult -> String -> List String -> List String
extract result fallback acc =
    let
        val =
            case result of
                MyOk s ->
                    s

                MyErr _ ->
                    fallback

        -- List cons triggers a safepoint; leaked SSA vars from case regions
        -- would cause MLIR parse failure
        newAcc =
            val :: acc
    in
    newAcc


main =
    let
        _ = Debug.log "extract1" (extract (MyOk "b") "default" [ "a" ])
        _ = Debug.log "extract2" (extract (MyErr "oops") "default" [ "a" ])
    in
    text "done"
