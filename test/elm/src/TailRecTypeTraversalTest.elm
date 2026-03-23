module TailRecTypeTraversalTest exposing (main)

{-| Tail-recursive type substitution with nested string case.
Mimics Compiler.Monomorphize.TypeSubst.applySubst: tail-recursive via
TAlias branch, outer case on type constructor, inner string case for
primitive type names inside TPrim branch.
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
