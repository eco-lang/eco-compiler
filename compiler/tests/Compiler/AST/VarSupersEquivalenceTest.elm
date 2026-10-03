module Compiler.AST.VarSupersEquivalenceTest exposing (suite)

{-| Cache-serialization plan S2: `TOpt.varSupersOfType` runs the string
collectors in `StringTable.collectSupers` mode. It must equal the reference
"collect every string, then keep those `superOfName` maps to `Just`", so the
encoded `varSupers` bytes are unchanged. This also pins
`StringTable.isSuperName` to `TOpt.superOfName`.
-}

import Compiler.AST.Canonical as Can
import Compiler.AST.StringTable as StringTable
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as N exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict
import Expect
import Fuzz exposing (Fuzzer)
import Set
import Test exposing (Test)


names : List String
names =
    [ "number", "number1", "numbers!", "comparable", "comparableX", "appendable", "compappend", "compappendY", "a", "msg", "Basics", "elm", "core" ]


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| Test-local mirror of `TOpt.superOfName` (same `Name.is*Type` order). -}
mirrorSuper : String -> Maybe String
mirrorSuper name =
    if N.isNumberType name then
        Just "Number"

    else if N.isComparableType name then
        Just "Comparable"

    else if N.isAppendableType name then
        Just "Appendable"

    else if N.isCompappendType name then
        Just "CompAppend"

    else
        Nothing


{-| The pre-S2 computation: every collected string, filtered by superOfName. -}
reference : Can.Type Name -> List ( Name, String )
reference t =
    StringTable.collected (Can.collectStringsFromType t StringTable.collectAll)
        |> Set.toList
        |> List.filterMap (\s -> mirrorSuper s |> Maybe.map (\sup -> ( s, sup )))


actual : Can.Type Name -> List ( Name, String )
actual t =
    TOpt.varSupersOfType t
        |> Dict.toList
        |> List.map (\( k, v ) -> ( k, Debug.toString v ))


nameFuzzer : Fuzzer String
nameFuzzer =
    Fuzz.oneOfValues names


typeFuzzer : Int -> Fuzzer (Can.Type Name)
typeFuzzer depth =
    let
        leaf =
            Fuzz.oneOf
                [ Fuzz.map Can.TVar nameFuzzer
                , Fuzz.constant Can.TUnit
                ]
    in
    if depth <= 0 then
        leaf

    else
        let
            sub =
                typeFuzzer (depth - 1)
        in
        Fuzz.oneOf
            [ leaf
            , Fuzz.map2 (Can.TLambda TypeIds.NoArrow) sub sub
            , Fuzz.map2 (\n args -> Can.TType home n args) nameFuzzer (Fuzz.listOfLengthBetween 0 2 sub)
            , Fuzz.map3
                (\f ft ext -> Can.TRecord (Dict.fromList [ ( f, Can.FieldType 0 ft ) ]) ext)
                nameFuzzer
                sub
                (Fuzz.maybe nameFuzzer)
            , Fuzz.map3 (\a b cs -> Can.TTuple a b cs) sub sub (Fuzz.listOfLengthBetween 0 1 sub)
            , Fuzz.map3
                (\n argName body -> Can.TAlias home n [ ( argName, body ) ] (Can.Filled body))
                nameFuzzer
                nameFuzzer
                sub
            ]


suite : Test
suite =
    Test.describe "TOpt.varSupersOfType (plan S2 collectSupers mode)"
        [ Test.test "alias arg names count (comparable only as an alias parameter)" <|
            \_ ->
                let
                    t =
                        Can.TAlias home "Set" [ ( "comparable", Can.TUnit ) ] (Can.Holey Can.TUnit)
                in
                Expect.equal (reference t) (actual t)
        , Test.test "spurious non-type-variable names are kept (byte identity)" <|
            \_ ->
                let
                    t =
                        Can.TType home "numbers!" [ Can.TVar "number", Can.TVar "msg" ]
                in
                Expect.equal (reference t) (actual t)
        , Test.fuzz (typeFuzzer 3) "equals the collect-all-then-filter reference" <|
            \t -> Expect.equal (reference t) (actual t)
        ]
