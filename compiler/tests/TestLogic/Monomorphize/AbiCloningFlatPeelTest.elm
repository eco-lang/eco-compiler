module TestLogic.Monomorphize.AbiCloningFlatPeelTest exposing (suite)

{-| FIX A — peel the curried callee type at the over-applying guard
(`plans/lss-instance-qualified-members.md` §15.1/§17).

`Store.classifyGo` builds ONE parameter per `MFunction` stage for every arrow
("one arrow per MFunction"), so `k -> v -> b -> b` has a first stage of ONE
parameter while the closure that flows there is `papCreate arity = 3` and the
call is a flat 3-argument `papExtend`. `AbiCloning` compared 3 against 1 and
declined `arityOver` — 34.8 % of all declines, and 33.2 % of the compiler's
generic dispatch, including its single largest site.

The type is representation-AGNOSTIC (an arrow is inhabited by a flat n-param
closure, a curried chain and PAPs alike) and cannot license a stamp. The
INSTANCE is the representation authority, so the peel matches against that.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Expect
import Test exposing (Test)


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
                -- `zonkFlat` and MonoInlineSimplify.flattenArrowOnce DO emit
                -- multi-parameter stages, so a stage can jump past the target.
                -- Taking the list anyway would stamp the wrong ABI.
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


{-| The shape `Store.classifyGo` produces for every arrow: one parameter per
`MFunction` stage.
-}
curried : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
curried params ret =
    List.foldr (\p acc -> Mono.mFunction Mono.topLegacy [ p ] acc) ret params


isArrow : Mono.MonoType -> Bool
isArrow t =
    case t of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False
