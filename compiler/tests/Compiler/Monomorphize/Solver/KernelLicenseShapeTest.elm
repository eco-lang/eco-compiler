module Compiler.Monomorphize.Solver.KernelLicenseShapeTest exposing (suite)

{-| Unit tests of the shape matching behind `TransportsAs` kernel licenses in
`Compiler.Monomorphize.Solver.KernelSetFacts`, on the forms of occurrence type
that the shipped kernel rows do not exercise: the unit type, aliases, tuples
and records, and a shape with more than one type variable.

A `TransportsAs shape` license applies to an occurrence when the occurrence is
an instance of `shape`: each `TsVar` is bound to the type at its first
position, every later position of the same variable must hold the same type,
and aliases in the occurrence are expanded first.

The tests establish:

  - `TsCon "()" []` matches the unit type, and `TsCon "Int" []` does not.
  - An occurrence written through an alias, `Filled` or `Holey`, is matched by
    its body.
  - With the shape `a -> b -> a`, the binding of `a` is found behind the one
    for `b`; `a` bound to a unit, to a tuple or to a function matches a second
    `a` of the same type, and a tuple whose elements differ does not.
  - A variable bound to a record does not match even the same record, since
    records compare unequal.

The group label contains `coverage run`, so that the coverage loop's quick
runs count these tests.

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.Monomorphize.Solver.KernelSetFacts as KernelSetFacts exposing (TypeShape(..))
import Dict
import Expect
import Test exposing (Test)


{-| The group "coverage run: kernel license shapes".
-}
suite : Test
suite =
    Test.describe "coverage run: kernel license shapes"
        [ Test.test "unit constructor shape" <|
            \_ ->
                Expect.equal ( True, False )
                    ( applies (TsCon "()" []) Can.TUnit
                    , applies (TsCon "Int" []) Can.TUnit
                    )
        , Test.test "aliases are matched by their bodies" <|
            \_ ->
                Expect.equal ( True, True )
                    ( applies (TsCon "Int" []) (Can.TAlias home "Count" [] (Can.Filled int))
                    , applies (TsCon "List" [ TsVar "a" ]) (Can.TAlias home "Many" [ ( "x", int ) ] (Can.Holey (Can.TType home "List" [ Can.TVar "x" ])))
                    )
        , Test.test "a repeated variable is compared with its first binding" <|
            \_ ->
                let
                    keep =
                        TsFun (TsVar "a") (TsFun (TsVar "b") (TsVar "a"))

                    pair =
                        Can.TTuple int int Nothing
                in
                Expect.equal [ True, True, True, False ]
                    [ applies keep (fn Can.TUnit (fn int Can.TUnit))
                    , applies keep (fn pair (fn int pair))
                    , applies keep (fn (fn int int) (fn int (fn int int)))
                    , applies keep (fn pair (fn int (Can.TTuple int (Can.TType home "Float" []) Nothing)))
                    ]
        , Test.test "a variable bound to a record never matches again" <|
            \_ ->
                let
                    rec =
                        Can.TRecord Dict.empty Nothing
                in
                Expect.equal False (applies (TsFun (TsVar "a") (TsVar "a")) (fn rec rec))
        ]


{-| Whether a `TransportsAs shape` license applies to `occurrence`, with no
variable taken as scalar.
-}
applies : TypeShape -> Can.Type String -> Bool
applies shape occurrence =
    KernelSetFacts.licenseApplies (\_ -> False) { scope = KernelSetFacts.TransportsAs shape } occurrence


{-| The home module of the test types.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "elm", "core" ) "Test"


{-| The type `Int`, homed in `home`.
-}
int : Can.Type String
int =
    Can.TType home "Int" []


{-| The function type from `a` to `b`.
-}
fn : Can.Type String -> Can.Type String -> Can.Type String
fn =
    Can.tLambda
