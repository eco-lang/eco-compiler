module Compiler.MonoOpt.TaggedUnionsTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.TaggedUnions` (plans/constructor-representation-followups.md
F1.0), the tagged-word decision the constructor census reports.

With no kernel-visible types and no meets, the tests establish:

  - `type T = A String | B Int | C | D Int Int`: `A` is `bare`, `B`
    `alloc-unboxed`, `C` `nullary`, `D` `alloc-fields`;
  - `type U = U1 Color | U2 Rec` with `Color` an enum-like type with a nullary
    constructor: `U1` is `alloc-constant-type`, `U2` `bare`;
  - `type V = V1 T | V2 Rec`: `V1` holds a tagged type, `alloc-nested`;
  - `type W = W1 Int | W2 Int` has no bare constructor and is dropped
    (`excluded-no-bare`); so is `type Tree = Leaf | Node Tree`, whose only field
    is itself;
  - a type that is the payload of a nullable type is `excluded-nullable-payload`;
  - a kernel-owned type (`Dict`) is `excluded-kernel-owned`;
  - `CtorCensus` writes the label in its `tagged` column.

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateMlir.CtorCensus as CtorCensus
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.TaggedUnions as TaggedUnions
import Dict
import Expect
import Test exposing (Test, describe, test)


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


custom : String -> Mono.MonoType
custom name =
    Mono.mCustom home name []


rec : Mono.MonoType
rec =
    Mono.mRecord (Dict.fromList [ ( "n", Mono.MInt ) ])


ctor : String -> Int -> List Mono.MonoType -> Mono.CtorShape
ctor name tag fields =
    { name = name, tag = tag, fieldTypes = fields }


dict : Mono.MonoType
dict =
    Mono.mCustom ModuleName.dict "Dict" [ Mono.MInt, Mono.MInt ]


shapes : Mono.LayoutMap (List Mono.CtorShape)
shapes =
    [ ( custom "T", [ ctor "A" 0 [ Mono.MString ], ctor "B" 1 [ Mono.MInt ], ctor "C" 2 [], ctor "D" 3 [ Mono.MInt, Mono.MInt ] ] )
    , ( custom "Color", [ ctor "Red" 0 [], ctor "Rgb" 1 [ Mono.MInt, Mono.MInt ] ] )
    , ( custom "U", [ ctor "U1" 0 [ custom "Color" ], ctor "U2" 1 [ rec ] ] )
    , ( custom "V", [ ctor "V1" 0 [ custom "T" ], ctor "V2" 1 [ rec ] ] )
    , ( custom "W", [ ctor "W1" 0 [ Mono.MInt ], ctor "W2" 1 [ Mono.MInt ] ] )
    , ( custom "Tree", [ ctor "Leaf" 0 [], ctor "Node" 1 [ custom "Tree" ] ] )
    , ( custom "P", [ ctor "P1" 0 [ Mono.MString ], ctor "P2" 1 [ rec ] ] )
    , ( custom "Opt", [ ctor "None" 0 [], ctor "Some" 1 [ custom "P" ] ] )
    , ( dict, [ ctor "RBNode_elm_builtin" 0 [ Mono.MInt, Mono.MInt ], ctor "RBEmpty_elm_builtin" 1 [] ] )
    ]
        |> List.foldl (\( k, s ) acc -> Mono.layoutMapInsert k s acc) Mono.layoutMapEmpty


nullable : Mono.LayoutMap Mono.NullableInfo
nullable =
    Mono.layoutMapInsert (custom "Opt") { nullCtor = "None", valueCtor = "Some", nullWord = { nullCons = True, index = 0 } } Mono.layoutMapEmpty


labels : Mono.LayoutMap (List ( String, String ))
labels =
    TaggedUnions.censusLabels shapes (TaggedUnions.choose KernelVisible.empty [] nullable shapes)


labelsOf : String -> Maybe (List ( String, String ))
labelsOf name =
    Mono.layoutMapGet (custom name) labels


suite : Test
suite =
    describe "Compiler.MonoOpt.TaggedUnions"
        [ test "the four constructor forms" <|
            \_ ->
                labelsOf "T"
                    |> Expect.equal (Just [ ( "A", "bare" ), ( "B", "alloc-unboxed" ), ( "C", "nullary" ), ( "D", "alloc-fields" ) ])
        , test "a field type with a nullary constructor cannot be bare" <|
            \_ -> labelsOf "U" |> Expect.equal (Just [ ( "U1", "alloc-constant-type" ), ( "U2", "bare" ) ])
        , test "a field of a tagged type is nested" <|
            \_ -> labelsOf "V" |> Expect.equal (Just [ ( "V1", "alloc-nested" ), ( "V2", "bare" ) ])
        , test "a type with no bare constructor is dropped, and so is a self-recursive one" <|
            \_ ->
                [ labelsOf "W", labelsOf "Tree" ]
                    |> Expect.equal
                        [ Just [ ( "W1", "excluded-no-bare" ), ( "W2", "excluded-no-bare" ) ]
                        , Just [ ( "Leaf", "excluded-no-bare" ), ( "Node", "excluded-no-bare" ) ]
                        ]
        , test "a nullable type's payload is excluded" <|
            \_ ->
                labelsOf "P"
                    |> Expect.equal (Just [ ( "P1", "excluded-nullable-payload" ), ( "P2", "excluded-nullable-payload" ) ])
        , test "a kernel-owned type is excluded" <|
            \_ ->
                Mono.layoutMapGet dict labels
                    |> Maybe.andThen List.head
                    |> Expect.equal (Just ( "RBNode_elm_builtin", "excluded-kernel-owned" ))
        , test "the census writes the label in its tagged column" <|
            \_ ->
                CtorCensus.render (CtorCensus.build True [] labels shapes)
                    |> String.lines
                    |> List.filter (String.contains "\tA\t")
                    |> List.map (String.split "\t" >> List.reverse >> List.head)
                    |> Expect.equal [ Just "bare" ]
        ]
