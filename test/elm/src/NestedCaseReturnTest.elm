module NestedCaseReturnTest exposing (main)

{-| Outer case on constructor type with nested case on String.
Mimics the convertTType pattern: case on type variant, inner string dispatch.
-}

-- CHECK: r1: "integer"
-- CHECK: r2: "text"
-- CHECK: r3: "custom List"
-- CHECK: r4: "other"
-- CHECK: r5: "empty"

import Html exposing (text)


type TypeRepr
    = Primitive String
    | Compound String (List TypeRepr)
    | Unit


describePrimitive : String -> String
describePrimitive name =
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
            "other"


describeType : TypeRepr -> String
describeType tipe =
    case tipe of
        Primitive name ->
            describePrimitive name

        Compound name _ ->
            case name of
                "List" ->
                    "custom List"

                "Dict" ->
                    "custom Dict"

                "Set" ->
                    "custom Set"

                _ ->
                    "custom " ++ name

        Unit ->
            "empty"


main =
    let
        _ = Debug.log "r1" (describeType (Primitive "Int"))
        _ = Debug.log "r2" (describeType (Primitive "String"))
        _ = Debug.log "r3" (describeType (Compound "List" []))
        _ = Debug.log "r4" (describeType (Primitive "Bytes"))
        _ = Debug.log "r5" (describeType Unit)
    in
    text "done"
