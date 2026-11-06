module LetNumberUnionBranchTest exposing (main)

{-| Integer literals carried by a constructor of a two-constructor custom type
with a `number` type parameter are used as `Float`s: `Pair 30 40`, matched by
`Pair a b` and computing `round (a * 1.5 + b * 2.5)`, logs 145.

The other constructor, `Lone`, has its own branch multiplying by `1.5`, which
is not taken.

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
