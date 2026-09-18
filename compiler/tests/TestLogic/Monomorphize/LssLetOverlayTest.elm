module TestLogic.Monomorphize.LssLetOverlayTest exposing (suite)

{-| F3-b — LET / TAIL-DEF BINDING OVERLAY (`lss.flow.letOverlay`,
`plans/lss-container-payload-transport.md` §12.9.5).

A plain `let` binds its name to `classifyAs tkClassLet`'s STORELESS type — ⊤ at
every arrow — unless a structural reason makes it take the body's type. When
the RHS carries arrows (a tuple holding a closure, say) the translated RHS's
set annotations never reach `varEnv`, and every use of the local enriches the
callee's demand from ⊤: the LSS\_026 `leak|letAnno` class. A local tail-def
binds its params the same storeless way even when a single-instance demand
was unified into the item store one line earlier.

The fix copies the top-level `TailDef` recipe: classify for STRUCTURE, the
translated RHS (let) or the demand-seeded var's zonk (tail-def) for
ANNOTATIONS. Pins: the callee's demand reads a SET flag-on and a ⊤ flag-off
(the differential is not vacuous).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "F3-b let / tail-def binding overlay"
        [ Test.test "1. PLAIN LET, FLAG-OFF: the callee reads the classify's clsLet ⊤ (leak|letAnno)" <|
            \() ->
                expectHead False tupleLet "applyPair" (\a -> a == Mono.LTop Mono.tkClassLet) "LTop clsLet"
        , Test.test "2. PLAIN LET, FLAG-ON: the callee reads the RHS's annotation instead (the overlay happened)" <|
            \() ->
                expectHead True tupleLet "applyPair" (\a -> a /= Mono.LTop Mono.tkClassLet) "the RHS's annotation, not clsLet ⊤"
        , Test.test "3. TAIL-DEF, FLAG-OFF: a callback param of the local tail-def reaches the callee as ⊤" <|
            \() ->
                expectHead False tailDef "apply" (\a -> isTop a) "⊤"
        , Test.test "4. TAIL-DEF, FLAG-ON: the same param carries the single instance's demand set" <|
            \() ->
                expectHead True tailDef "apply" (\a -> isSet a) "a set"
        ]


expectHead : Bool -> Src.Module -> String -> (Mono.LambdaSetAnno -> Bool) -> String -> Expect.Expectation
expectHead on fixture callee ok what =
    case runWith on fixture of
        Err e ->
            Expect.fail e

        Ok g ->
            let
                heads =
                    calleeArrowHeads callee g
            in
            if List.isEmpty heads then
                Expect.fail ("fixture broken: no " ++ callee ++ " spec with an arrow at its first parameter")

            else if List.all ok heads then
                Expect.pass

            else
                Expect.fail ("expected " ++ what ++ " at " ++ callee ++ "'s callback, got " ++ String.join ", " (List.map describeAnno heads))



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| `let pair = mkPair 1 in applyPair pair` — a NON-function let (a tuple
holding a function, no free vars) on the plain-let path, with a CALL as its
RHS so the classify wins (`useBodyType` False): the `leak|letAnno` shape.

What a one-module fixture CANNOT show: a SET at the tuple's arrow. Every
route into a tuple payload arrow here crosses the E14 literal-field edge
(F4, unbuilt): a tuple LITERAL RHS types its arrow `LVar` and takes the body
type in both arms; a call RHS reads the callee's registered result, whose
tuple payload arrow is a `declZonk` ⊤ manufactured inside the callee. So the
pin is the MECHANISM — flag-on the binding carries the RHS's annotation
(here that ⊤, kind `declZonk`), flag-off the classify's `clsLet` ⊤ — and the
corpus A/B carries the yield.

-}
tupleLet : Src.Module
tupleLet =
    makeModuleWithTypedDefs "Test"
        [ { name = "mkPair"
          , args = [ pVar "n" ]
          , tipe = tLambda (tType "Int" []) (tTuple hInt (tType "Int" []))
          , body = tupleExpr (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))) (varExpr "n")
          }
        , { name = "applyPair"
          , args = [ pVar "p" ]
          , tipe = tLambda (tTuple hInt (tType "Int" [])) (tType "Int" [])
          , body = intExpr 0 -- the pin reads the DEMAND's annotation; the body is irrelevant
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "pair" [] (callExpr (varExpr "mkPair") [ intExpr 1 ]) ]
                    (callExpr (varExpr "applyPair") [ varExpr "pair" ])
          }
        ]


{-| `let go h n = if n > 0 then go h (n - 1) else apply h n in go inc 3` — a
local tail-recursive function with ONE instance whose callback param `h`
reaches `apply`.
-}
tailDef : Src.Module
tailDef =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "apply"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "go"
                        [ pVar "h", pVar "n" ]
                        (ifExpr (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                            (callExpr (varExpr "go") [ varExpr "h", binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ])
                            (callExpr (varExpr "apply") [ varExpr "h", varExpr "n" ])
                        )
                    ]
                    (callExpr (varExpr "go") [ varExpr "inc", intExpr 3 ])
          }
        ]



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith on srcModule =
    let
        defaults =
            Config.defaultLss

        fl =
            Config.defaultLss.flow
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        -- Per-mechanism isolation: the other flow repairs (E15 access flow, F4-sig
        -- literal facts) are pinned OFF so the differential is letOverlay's alone —
        -- with them on, the call-RHS fixture's field arrow arrives already
        -- annotated and the flag-off arm no longer reads the classify's ⊤.
        { defaults | enabled = True, keyed = True, flow = { fl | letOverlay = on, accessFlow = False, litFacts = False } }
        srcModule



-- ====== READERS ======


{-| The head annotation of the FIRST arrow found inside the callee's first
parameter type (the param itself, or the first arrow-typed tuple component).
-}
calleeArrowHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
calleeArrowHeads target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, Mono.MFunction _ _ (p0 :: _) _ ) ->
                    if name == target then
                        case firstArrowHead p0 of
                            Just a ->
                                a :: acc

                            Nothing ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


firstArrowHead : Mono.MonoType -> Maybe Mono.LambdaSetAnno
firstArrowHead t =
    case t of
        Mono.MFunction _ anno _ _ ->
            Just anno

        Mono.MTuple _ ts ->
            List.head (List.filterMap firstArrowHead ts)

        _ ->
            Nothing


isSet : Mono.LambdaSetAnno -> Bool
isSet anno =
    case anno of
        Mono.LSet _ ->
            True

        _ ->
            False


isTop : Mono.LambdaSetAnno -> Bool
isTop anno =
    case anno of
        Mono.LTop _ ->
            True

        _ ->
            False


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LSet ms ->
            "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

        Mono.LVar v ->
            "LVar" ++ String.fromInt v

        Mono.LTop k ->
            "LTop" ++ String.fromInt k

        Mono.LPartial ms ->
            "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
