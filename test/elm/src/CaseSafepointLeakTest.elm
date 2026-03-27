module CaseSafepointLeakTest exposing (main)

{-| Test that case expressions with temporaries in alternatives don't leak
SSA variables into safepoints at the parent scope. The pattern:

    1. Case expression where alternatives create temporary !eco.value values
    2. Heap allocation after the case (triggers eco.safepoint)

If the safepoint references SSA values from inside the case regions,
the MLIR will fail to parse (cross-region SSA reference).
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
