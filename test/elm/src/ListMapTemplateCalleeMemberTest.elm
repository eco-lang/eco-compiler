module ListMapTemplateCalleeMemberTest exposing (main)

{-| F-3's callee-resolution fixture (`plans/list-map-mlir-template.md` F-3,
"Fixture (lands with steps 1-4)").

The callback applies a callee LOCAL (`f`, a parameter) whose lambda set is a
singleton naming a CLOSURE instance — `inc`, bound to a lambda literal at the
call site. A top-level named function would be an `OriginGlobal` member,
which the standalone member table declines BY DESIGN, so the fixture would
pin nothing.

Behaviourally this pins NOTHING positive — a licensed map and a declined map
compute the same list. The positive pin is the compile-and-grep in the F-3
landing note: `licensed` gains exactly 1 against the same compile with `inc`
replaced by a `Debug.log` wrapper, and the artifact greps positive for
`eco.list.map`.

-}

-- CHECK: mapped: [2, 3, 4]

import Html exposing (text)


helper : (Int -> Int) -> List Int -> List Int
helper f xs =
    List.map (\x -> f x) xs


main : Html.Html msg
main =
    let
        inc : Int -> Int
        inc =
            \y -> y + 1

        mapped =
            helper inc [ 1, 2, 3 ]

        _ =
            Debug.log "mapped" mapped
    in
    text "done"
