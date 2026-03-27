module TailRecManyBranchStringTest exposing (main)

{-| Test tail-recursive function with >2 constructor alternatives
and nested string matching, mimicking the Port.toDecoder pattern.

-}

-- CHECK: result: "found-beta"

import Html exposing (text)


type Expr
    = Lit String
    | Ref String
    | Alias Expr


eval : Expr -> String
eval expr =
    case expr of
        Lit s ->
            s

        Ref name ->
            case name of
                "alpha" ->
                    "found-alpha"

                "beta" ->
                    "found-beta"

                "gamma" ->
                    "found-gamma"

                _ ->
                    "unknown"

        Alias inner ->
            eval inner


main =
    let
        result =
            eval (Alias (Alias (Ref "beta")))

        _ =
            Debug.log "result" result
    in
    text "done"
