module AsPatternFuncArgTest exposing (main)

{-| Test as-patterns in function arguments. -}

-- CHECK: var_alias: (42, 42)
-- CHECK: tuple_alias: (1, (1, 2))
-- CHECK: record_alias: (1, { x = 1, y = 2 })
-- CHECK: cons_alias: (1, [1, 2, 3])

import Html exposing (text)


withVar (x as whole) = (x, whole)


withPair (((a, b)) as pair) = (a, pair)


withRec (({ x, y }) as point) = (x, point)


withList (((h :: t)) as list) = (h, list)


main =
    let
        _ = Debug.log "var_alias" (withVar 42)
        _ = Debug.log "tuple_alias" (withPair (1, 2))
        _ = Debug.log "record_alias" (withRec { x = 1, y = 2 })
        _ = Debug.log "cons_alias" (withList [1, 2, 3])
    in
    text "done"
