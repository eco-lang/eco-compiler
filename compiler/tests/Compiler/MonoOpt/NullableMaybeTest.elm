module Compiler.MonoOpt.NullableMaybeTest exposing (suite)

{-| Tests for the admissibility rules of `Compiler.MonoOpt.NullableMaybe`
(plans/constructor-representation-levels.md N1, invariant MONO_033): which
payload types let `Maybe t` represent `Just x` as `x`, and which let a
Maybe-shaped user type do so (decision D2, no embedded constants).

The tests establish, for `admissible`: Int, Float, Char, String, unit, lists,
the empty record, `Maybe`, a kernel-owned type (`Bytes`) and a type variable
are refused; Bool, a tuple, a non-empty record, a function and an ordinary
custom type are accepted. For `admissibleNoConstants`: Bool, an enum, and a
custom type with a nullary constructor are refused; a record, a tuple, a
function and a custom type whose constructors all have fields are accepted.

-}

import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Dict
import Expect
import Test exposing (Test, describe, test)


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


rec : Mono.MonoType
rec =
    Mono.mRecord (Dict.fromList [ ( "x", Mono.MInt ) ])


color : Mono.MonoType
color =
    Mono.mCustom home "Color" []


shapeT : Mono.MonoType
shapeT =
    Mono.mCustom home "Shape" []


shapesOf : Mono.MonoType -> Maybe (List Mono.CtorShape)
shapesOf t =
    if t == color then
        Just [ { name = "Red", tag = 0, fieldTypes = [] }, { name = "Rgb", tag = 1, fieldTypes = [ Mono.MInt ] } ]

    else if t == shapeT then
        Just [ { name = "Circle", tag = 0, fieldTypes = [ Mono.MInt ] }, { name = "Square", tag = 1, fieldTypes = [ Mono.MInt, Mono.MInt ] } ]

    else
        Nothing


suite : Test
suite =
    describe "Compiler.MonoOpt.NullableMaybe admissibility"
        [ test "refused payloads" <|
            \_ ->
                [ Mono.MInt
                , Mono.MFloat
                , Mono.MChar
                , Mono.MString
                , Mono.MUnit
                , Mono.mList Mono.MInt
                , Mono.mRecord Dict.empty
                , Mono.mCustom ModuleName.maybe "Maybe" [ rec ]
                , Mono.mCustom ModuleName.bytes "Bytes" []
                , Mono.MVar TypeIds.firstMVarId Mono.CEcoValue
                ]
                    |> List.map NullableMaybe.admissible
                    |> List.filter identity
                    |> Expect.equal []
        , test "accepted payloads" <|
            \_ ->
                [ Mono.MBool
                , Mono.mTuple (Mono.T2 Mono.MInt Mono.MInt)
                , rec
                , Mono.mFunction Mono.topSynth [ Mono.MInt ] Mono.MInt
                , color
                ]
                    |> List.map NullableMaybe.admissible
                    |> List.all identity
                    |> Expect.equal True
        , test "no embedded constants" <|
            \_ ->
                [ NullableMaybe.admissibleNoConstants shapesOf Mono.MBool
                , NullableMaybe.admissibleNoConstants shapesOf color
                , NullableMaybe.admissibleNoConstants shapesOf rec
                , NullableMaybe.admissibleNoConstants shapesOf (Mono.mTuple (Mono.T2 Mono.MInt Mono.MInt))
                , NullableMaybe.admissibleNoConstants shapesOf (Mono.mFunction Mono.topSynth [ Mono.MInt ] Mono.MInt)
                , NullableMaybe.admissibleNoConstants shapesOf shapeT
                ]
                    |> Expect.equal [ False, False, True, True, True, True ]
        ]
