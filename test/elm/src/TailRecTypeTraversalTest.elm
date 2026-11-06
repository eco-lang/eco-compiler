module TailRecTypeTraversalTest exposing (main)

{-| A function over a small type-expression tree, tail-recursive through its alias constructor and matching primitive type names as string literals, resolves an alias chain to the right name.

`resolve` unwraps `TAlias (TAlias (TPrim "Int"))` by tail calls and maps `"Int"`
to `"integer"`. The `TList` branch, whose recursive call is not in tail
position, is not exercised.
-}

-- CHECK: result: "integer"

import Html exposing (text)


type SimpleType
    = TPrim String
    | TList SimpleType
    | TAlias SimpleType


resolve : SimpleType -> String
resolve tipe =
    case tipe of
        TAlias inner ->
            resolve inner

        TPrim name ->
            case name of
                "Int" ->
                    "integer"

                "Float" ->
                    "decimal"

                "Bool" ->
                    "flag"

                "String" ->
                    "text"

                _ ->
                    name

        TList inner ->
            "list(" ++ resolve inner ++ ")"


main =
    let
        myType =
            TAlias (TAlias (TPrim "Int"))

        _ = Debug.log "result" (resolve myType)
    in
    text "done"
