module FunctionEqualityFalseTest exposing (main)

{-| UTILS-06 (plans/kernel-lib-bug-fixes.md): `==` on functions. Elm crashes ("Trying to use
`(==)` on functions") unless both sides are the same reference. Decision D24 (user,
2026-11-04) keeps eco's answer, `False`, as a documented divergence
(design_docs/elm-divergence.md section 4.1), so this test pins it rather than exposing a bug:
the same reference is equal (as in JS, which checks `x === y` first), two distinct closures are
not, also when nested in a record, a custom type or a Dict, and the program runs on (exit 0).

-}

-- CHECK: same ref: True
-- CHECK: distinct: False
-- CHECK: record distinct: False
-- CHECK: record same ref: True
-- CHECK: maybe distinct: False
-- CHECK: dict distinct: False
-- CHECK: after: "done"
-- EXIT: 0

import Dict
import Html exposing (text)


main =
    let
        f =
            \x -> x + 1

        g =
            \x -> x * 2

        _ =
            Debug.log "same ref" (f == f)

        _ =
            Debug.log "distinct" ((\x -> x) == (\x -> x + 0))

        _ =
            Debug.log "record distinct" ({ h = f } == { h = g })

        _ =
            Debug.log "record same ref" ({ h = f } == { h = f })

        _ =
            Debug.log "maybe distinct" (Just f == Just g)

        _ =
            Debug.log "dict distinct" (Dict.singleton 1 f == Dict.singleton 1 g)

        _ =
            Debug.log "after" "done"
    in
    text "done"
