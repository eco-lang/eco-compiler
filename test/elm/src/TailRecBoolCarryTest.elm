module TailRecBoolCarryTest exposing (main)

{-| Test tail-recursive function that carries a Bool through the loop.

This exercises the bug where compileTailCallStep yields i1 (SSA type for Bool)
in a position where the scf.while carry type expects !eco.value (ABI type for Bool).

The pattern:
  - Tail-recursive function with a Bool parameter (becomes !eco.value carry type)
  - Case expression inside the loop body (becomes eco.case inside scf.while)
  - Tail call passes a Bool value (Expr.generateExpr produces i1, but carry expects !eco.value)
-}

-- CHECK: result1: 10
-- CHECK: result2: 0
-- CHECK: result3: 42

import Html exposing (text)


{-| A tail-recursive function with a Bool parameter.
The Bool `found` is carried through the while-loop as !eco.value (ABI type),
but inside the case branch, the tail call yields it as i1 (SSA type).
-}
searchList : Bool -> Int -> List Int -> Int
searchList found acc list =
    case list of
        [] ->
            if found then
                acc
            else
                0

        x :: xs ->
            if x > 5 then
                searchList True (acc + x) xs
            else
                searchList found acc xs


main =
    let
        _ = Debug.log "result1" (searchList False 0 [1, 2, 3, 10])
        _ = Debug.log "result2" (searchList False 0 [1, 2, 3])
        _ = Debug.log "result3" (searchList False 0 [1, 42])
    in
    text "done"
