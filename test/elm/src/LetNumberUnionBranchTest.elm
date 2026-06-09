module LetNumberUnionBranchTest exposing (main)

{-| Probe: `number` carried in a multi-field / multi-branch union, projected at
`Float`. `Pair 30 40` binds two `number`s in one constructor; the case body uses
both at `Float`. Correct: 30*1.5 + 40*2.5 = 145.

-}

-- CHECK: union: 145

import Html exposing (text)


type NumBox number
    = Lone number
    | Pair number number


main =
    let
        v =
            Pair 30 40

        result =
            case v of
                Lone n ->
                    round (n * 1.5)

                Pair a b ->
                    round (a * 1.5 + b * 2.5)

        _ =
            Debug.log "union" result
    in
    text "done"
