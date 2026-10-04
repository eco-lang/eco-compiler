module Compiler.AST.VarSupersEquivalenceTest exposing (suite)

{-| Tests that `TOpt.varSupersOfType` finds the same names as collecting every
string in a type and keeping those that imply a super. Without them, the result
of `varSupersOfType` could change unnoticed: it filters names while collecting
them, by `StringTable.isSuperName`, and maps each kept name to its super
afterwards, by a separate function, so the filter and the mapping can drift
apart.

A _super_ is the constraint class a name implies by its prefix: number,
comparable, appendable or compappend. Any name that starts with one of those
words implies it, so `number1` and `numbers!` imply number; `Compiler.Data.Name`
owns these prefix tests. `varSupersOfType` runs `Can.collectStringsFromType`
with the `StringTable.collectSupers` collector, which keeps only the strings
`isSuperName` accepts, and maps each kept string with the private `superOfName`
in `Compiler.AST.TypedOptimized`. The reference, `reference`, runs the same
traversal with `StringTable.collectAll`, which keeps every string, and maps the
result with `mirrorSuper`, a copy of `superOfName`.

`Can.collectStringsFromType` adds every name in a type, not only its type
variables: type and alias names, the package author, project and module name of
their home, record field and extension names, and alias argument names. Both
sides therefore count any of those whose prefix implies a super.

The fixture is the thirteen strings in `names`, eight of which imply a super,
the home module `elm/core` `Basics`, whose three strings imply none, and the
alias name `Set` of the first test, which implies none.

The tests establish:

  - On an alias `Set` whose one argument is named `comparable`, with the unit
    type as its argument type and as its `Holey` body, `reference` and `actual`
    are equal. The argument name is the only string there that implies a super.
    Only equality is asserted, so the test passes whether or not the argument
    name is collected, as long as both sides agree.
  - On a type `numbers!` applied to the type variables `number` and `msg`,
    `reference` and `actual` are equal. The type name implies number.
  - On fuzzed types from `typeFuzzer 3`, `reference` and `actual` are equal.

Among what is not tested:

  - Names outside `names`: `isSuperName` and `superOfName` are compared only on
    those thirteen strings and on `Set`.
  - An `isSuperName` that accepts a string `superOfName` maps to `Nothing`.
    `varSupersOfType` drops such a string when mapping, so the result is the
    same.
  - `TOpt.computeVarSupers`, which computes the same map for a whole local
    graph.
  - Fuzzed `Holey` alias bodies, and records with more than one field.

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


{-| The strings every type in these tests takes its names from, apart from the
alias name `Set` in the first test. The first eight imply a super and the last
five do not; `Basics`, `elm` and `core` are also the strings of `home`.
-}
names : List String
names =
    [ "number", "number1", "numbers!", "comparable", "comparableX", "appendable", "compappend", "compappendY", "a", "msg", "Basics", "elm", "core" ]


{-| The module `Basics` of the package `elm/core`, used as the home of every type
and alias the tests build.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| Returns the name of the super that `name` implies, as `"Number"`,
`"Comparable"`, `"Appendable"` or `"CompAppend"`, or `Nothing` if it implies
none.

It is a copy of the private `superOfName` in `Compiler.AST.TypedOptimized`,
written as text so that it can be compared with `actual`.

-}
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


{-| Returns every string in `t` that implies a super, paired with the name of
that super, in ascending order of the string. It collects every string with
`StringTable.collectAll` and keeps those `mirrorSuper` maps to a super.
-}
reference : Can.Type Name -> List ( Name, String )
reference t =
    StringTable.collected (Can.collectStringsFromType t StringTable.collectAll)
        |> Set.toList
        |> List.filterMap (\s -> mirrorSuper s |> Maybe.map (\sup -> ( s, sup )))


{-| Returns `TOpt.varSupersOfType t` as a list in ascending order of name, with
each super written as text by `Debug.toString`, so that it can be compared with
`reference`.
-}
actual : Can.Type Name -> List ( Name, String )
actual t =
    TOpt.varSupersOfType t
        |> Dict.toList
        |> List.map (\( k, v ) -> ( k, Debug.toString v ))


{-| A fuzzer choosing one of `names`.
-}
nameFuzzer : Fuzzer String
nameFuzzer =
    Fuzz.oneOfValues names


{-| Produces a fuzzer of canonical types with at most `depth` levels of
structure above the leaves. Every name in them except `home` comes from
`names`.

A leaf is a type variable or the unit type. Above a leaf a node is a function
with an unstamped arrow, a type with up to two arguments, a record with one
field and possibly an extension, a tuple of two or three, or an alias with one
argument whose type is also the alias's `Filled` body.

-}
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


{-| The two fixed tests and the fuzz test that the module docstring describes.
-}
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
