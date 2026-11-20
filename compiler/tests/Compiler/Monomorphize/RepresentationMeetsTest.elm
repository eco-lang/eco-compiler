module Compiler.Monomorphize.RepresentationMeetsTest exposing (suite)

{-| Tests for the slot kinds and components of
`Compiler.Monomorphize.RepresentationMeets` (plans/constructor-representation-levels.md
unit V).

The tests establish that only Int, Float and Char have unboxed slot kinds, that
two types joined by a meet are in one component and a third joined to either is
in it too, and that a type no meet involves is its own component.

-}

import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Mono as Mono
import Compiler.Monomorphize.RepresentationMeets as RM
import Expect
import Test exposing (Test, describe, test)


var : Mono.MonoType
var =
    Mono.MVar TypeIds.firstMVarId Mono.CEcoValue


suite : Test
suite =
    describe "Compiler.Monomorphize.RepresentationMeets"
        [ test "slot kinds" <|
            \_ ->
                List.map RM.slotKindOf [ Mono.MInt, Mono.MFloat, Mono.MChar, Mono.MBool, Mono.MString, var ]
                    |> Expect.equal [ RM.KInt, RM.KFloat, RM.KChar, RM.KBoxed, RM.KBoxed, RM.KBoxed ]
        , test "components join meets transitively" <|
            \_ ->
                let
                    comps =
                        RM.components (\_ -> True)
                            [ { a = Mono.mList Mono.MInt, b = Mono.mList var, root = True, spec = 0, site = "" }
                            , { a = Mono.mList var, b = Mono.mList Mono.MString, root = True, spec = 0, site = "" }
                            ]
                in
                RM.componentOf comps (Mono.mList Mono.MInt)
                    |> List.length
                    |> Expect.equal 3
        , test "a type in no meet is its own component" <|
            \_ ->
                RM.componentOf (RM.components (\_ -> True) []) Mono.MInt
                    |> Expect.equal [ Mono.MInt ]
        ]
