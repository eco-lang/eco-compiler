module TestLogic.Monomorphize.AbiCloningFlatPeelTest exposing (suite)

{-| Tests for `AbiCloning.peelStages`, which views a curried function type as
one flat parameter list of a requested length. `AbiCloning` compares the peeled
list against the parameter lists of the compiled instances of the function a
call site calls, so without these tests a peel that collected the wrong
parameters would give it the wrong list to compare.

A function type is a chain of _stages_. Each `MFunction` carries a list of
parameter types and a result, and the result may itself be an `MFunction`.
`Compiler.MonoSolver.Store` turns each arrow of a source type into a stage of
one parameter, so a type such as `Int -> Float -> Char -> Int` has a first stage
of one parameter even when the closure called through it takes all three at
once. `AbiCloning` uses `peelStages` when a call site passes more arguments than
the first stage of its callee type takes.

To _peel_ a type to `n` is to collect the parameters of successive stages until
exactly `n` have been collected, and return them as one list together with the
result of the last stage collected. A stage may carry several parameters
(`MonoInlineSimplify.flattenArrowOnce` builds such stages), so collecting can
pass `n` without landing on it, and then `peelStages` returns `Nothing`.

The fixture is types built from `MInt`, `MFloat` and `MChar` with
`Mono.mFunction`, every stage annotated `topLegacy`. `peelStages` does not look
at the annotation.

The tests establish:

  - Test 1: three one-parameter stages peeled to 3 give `[ MInt, MFloat, MChar ]`
    and `MInt`.
  - Test 2: the same type peeled to 2 gives `[ MInt, MFloat ]` and a result that
    is an `MFunction`. Which function type it is, is not checked.
  - Test 3: a single stage of two parameters peeled to 1 gives `Nothing`.
  - Test 4: two one-parameter stages ending in `MInt`, peeled to 3, give
    `Nothing`.
  - Test 5: a single stage of three parameters peeled to 3 gives those three and
    `MInt`.
  - Test 6: a stage of two parameters followed by a stage of one, peeled to 3,
    gives all three and `MInt`.
  - Test 7: the one-stage type `MInt -> MInt` peeled to 0 gives `Nothing`.
  - Test 8: `MInt` peeled to 1 gives `Nothing`.

Among what is not tested: a stage after the first that passes the count, a
negative count, the annotation on the returned result, and what `AbiCloning`
does with a peel.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Expect
import Test exposing (Test)


{-| The eight `peelStages` tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "Fix A — flattened match for over-applying sites"
        [ Test.test "1. a 3-stage curried type peels to a flat 3-param view" <|
            \() ->
                Expect.equal (Just ( [ Mono.MInt, Mono.MFloat, Mono.MChar ], Mono.MInt ))
                    (AbiCloning.peelStages 3 (curried [ Mono.MInt, Mono.MFloat, Mono.MChar ] Mono.MInt))
        , Test.test "2. a partial peel lands, keeping the remaining stages as the return" <|
            \() ->
                case AbiCloning.peelStages 2 (curried [ Mono.MInt, Mono.MFloat, Mono.MChar ] Mono.MInt) of
                    Just ( params, ret ) ->
                        Expect.all
                            [ \_ -> Expect.equal [ Mono.MInt, Mono.MFloat ] params
                            , \_ -> Expect.equal True (isArrow ret)
                            ]
                            ()

                    Nothing ->
                        Expect.fail "expected a 2-stage peel to land"
        , Test.test "3. OVERSHOOT fails closed — peel-until-EQUAL, never peel-n-times" <|
            \() ->
                Expect.equal Nothing
                    (AbiCloning.peelStages 1 (Mono.mFunction Mono.topLegacy [ Mono.MInt, Mono.MFloat ] Mono.MInt))
        , Test.test "4. running out of arrow before the target fails closed" <|
            \() ->
                Expect.equal Nothing
                    (AbiCloning.peelStages 3 (curried [ Mono.MInt, Mono.MFloat ] Mono.MInt))
        , Test.test "5. an ALREADY-FLAT stage needs no peeling and still lands" <|
            \() ->
                Expect.equal (Just ( [ Mono.MInt, Mono.MFloat, Mono.MChar ], Mono.MInt ))
                    (AbiCloning.peelStages 3 (Mono.mFunction Mono.topLegacy [ Mono.MInt, Mono.MFloat, Mono.MChar ] Mono.MInt))
        , Test.test "6. a mixed chain (2 params then 1) peels to the flat 3" <|
            \() ->
                Expect.equal (Just ( [ Mono.MInt, Mono.MFloat, Mono.MChar ], Mono.MInt ))
                    (AbiCloning.peelStages 3
                        (Mono.mFunction Mono.topLegacy
                            [ Mono.MInt, Mono.MFloat ]
                            (Mono.mFunction Mono.topLegacy [ Mono.MChar ] Mono.MInt)
                        )
                    )
        , Test.test "7. peeling zero stages is not a landing" <|
            \() ->
                Expect.equal Nothing (AbiCloning.peelStages 0 (curried [ Mono.MInt ] Mono.MInt))
        , Test.test "8. a non-arrow type never peels" <|
            \() ->
                Expect.equal Nothing (AbiCloning.peelStages 1 Mono.MInt)
        ]



-- ====== HELPERS ======


{-| Builds `ret` behind one single-parameter stage per element of `params`, in
order (so `ret` itself when `params` is empty). Every stage is annotated
`topLegacy`.
-}
curried : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
curried params ret =
    List.foldr (\p acc -> Mono.mFunction Mono.topLegacy [ p ] acc) ret params


{-| Returns whether a type is a function type, that is an `MFunction`.
-}
isArrow : Mono.MonoType -> Bool
isArrow t =
    case t of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False
