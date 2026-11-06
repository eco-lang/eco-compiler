module TypeClassConstraintTest exposing (main)

{-| Checks functions whose types use the constrained type variables `number`,
`comparable` and `appendable`.

`zabs` is applied to an `Int` (`-5` gives `5`) and a `Float` (`-3.14` gives
`3.14`), `zmin` to two `Int`s, and `zconcat` to two `String`s.

Among what is not tested: `zmin` on non-`Int` comparables, and `zconcat` on
lists.

-}

-- CHECK: absInt: 5
-- CHECK: absFloat: 3.14
-- CHECK: minInt: 3
-- CHECK: concatStr: "hello world"

import Html exposing (text)


zabs : number -> number
zabs n =
    if n < 0 then
        -n

    else
        n


zmin : comparable -> comparable -> comparable
zmin a b =
    if a < b then
        a

    else
        b


zconcat : appendable -> appendable -> appendable
zconcat a b =
    a ++ b


main =
    let
        _ =
            Debug.log "absInt" (zabs -5)

        _ =
            Debug.log "absFloat" (zabs -3.14)

        _ =
            Debug.log "minInt" (zmin 3 5)

        _ =
            Debug.log "concatStr" (zconcat "hello " "world")
    in
    text "done"
