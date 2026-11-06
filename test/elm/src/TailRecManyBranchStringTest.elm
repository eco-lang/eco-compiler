module TailRecManyBranchStringTest exposing (main)

{-| A self-recursive function over a three-constructor custom type, with a tail call in one branch and a `case` in another that matches a `String` against literal patterns, returns the right string.

`eval` unwraps two `Alias` layers by calling itself in tail position, then
matches the name `"beta"` in a `case` on string literals and returns
`"found-beta"`.
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
