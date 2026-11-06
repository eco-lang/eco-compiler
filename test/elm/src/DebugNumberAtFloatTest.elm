module DebugNumberAtFloatTest exposing (main)

{-| Unannotated functions over the `number` type that use `Debug.toString` and
`Debug.log` give the right results when called with a `Float` and with an `Int`
in the same program.

`showAll` maps `Debug.toString` over `[ n, n + n ]`, and `bump` logs `n + 1`.
The test calls `showAll 1.25`, `bump 2.5` and `showAll 2`, and checks that the
`Float` values print as `1.25`, `2.5` and `3.5` and the `Int` values as `2` and
`4`.

-}

-- CHECK: showAll: ["1.25","2.5"]
-- CHECK: bump: 3.5
-- CHECK: bumpResult: 3.5
-- CHECK: showAllInt: ["2","4"]

import Html exposing (text)


showAll n =
    List.map Debug.toString [ n, n + n ]


bump n =
    Debug.log "bump" (n + 1)


main =
    let
        _ =
            Debug.log "showAll" (showAll 1.25)

        _ =
            Debug.log "bumpResult" (bump 2.5)

        _ =
            Debug.log "showAllInt" (showAll 2)
    in
    text "done"
