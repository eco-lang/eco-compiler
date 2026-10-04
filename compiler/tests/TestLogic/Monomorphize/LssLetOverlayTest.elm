module TestLogic.Monomorphize.LssLetOverlayTest exposing (suite)

{-| Tests that the solver engine of monomorphization gives a local binding the
lambda-set annotations of what it is bound to, not the placeholder top of a
type built from the local's type alone.

Without them, a local `let` value or a local tail-recursive function's
parameters could read ⊤ (top: no set is named, so any function may arrive at
that arrow) at every arrow, and a function the local is passed to would then
be specialized with ⊤ at that arrow, unnoticed, since the program still
compiles.

For locals like the two in these fixtures, `Compiler.MonoSolver.Translate`
first classifies the local's type as the type checker gives it, and every
arrow written in that type carries `LTop tkClassLet` (`tkClassParam` for a
tail-def's parameters). The fixtures' types have no type variables; one already bound in the solver's
store would be read from it instead. With lambda-set specialization (LSS)
enabled, the plain `let` value of the first fixture then takes that structure
with the annotations of the translated right-hand side, as
`Mono.overlayAnnotations` describes, unless the binding takes the right-hand
side's type whole. The local tail-def of the second fixture has one instance,
and with LSS enabled takes them from the local's type unified with that
instance's demanded type. The lambda-set annotations themselves are described
with `Mono.LambdaSetAnno`.

Each test builds a one-module program with `makeModuleWithTypedDefs`, runs it
to a monomorphized graph with LSS enabled, and reads, for every
specialization of a named callee, the first arrow's annotation found at the
top of that specialization's first parameter type or among its tuple
components.

  - "1. PLAIN LET" uses `tupleLet`, where a local tuple holding a closure is
    passed to `applyPair`. Every such annotation must differ from
    `LTop tkClassLet`. The test does not require a set: a top of any other
    kind passes.
  - "2. TAIL-DEF" uses `tailDef`, where a local tail-recursive `go` passes its
    callback parameter to `apply`. Every such annotation must be an `LSet`,
    and an empty `LSet` passes.

In both, a program in which no specialization of the callee has an arrow in
its first parameter fails as a broken fixture.

Among what is not tested: which members a set holds, a local with more than
one instance, a `let` whose right-hand side is a tuple literal or a function,
and the substitution engine.

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


{-| The two binding-overlay tests, one for a plain `let` and one for a local
tail-def.
-}
suite : Test
suite =
    Test.describe "F3-b let / tail-def binding overlay"
        [ Test.test "1. PLAIN LET: the callee reads the RHS's annotation, not the classify's clsLet ⊤" <|
            \() ->
                expectHead tupleLet "applyPair" (\a -> a /= Mono.LTop Mono.tkClassLet) "the RHS's annotation, not clsLet ⊤"
        , Test.test "2. TAIL-DEF: a callback param of the local tail-def carries the single instance's demand set" <|
            \() ->
                expectHead tailDef "apply" (\a -> isSet a) "a set"
        ]


{-| Runs `fixture` and passes when `ok` holds for the head annotation of every
specialization of `callee` that has one, as `calleeArrowHeads` reads them.

It fails with the pipeline's error, with a "fixture broken" message when no
such annotation is found, or with a message naming `what` and every annotation
read when any one of them fails `ok`.

-}
expectHead : Src.Module -> String -> (Mono.LambdaSetAnno -> Bool) -> String -> Expect.Expectation
expectHead fixture callee ok what =
    case runWith fixture of
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


{-| The source type `Int -> Int`, the type of the function values the fixtures
pass around.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A program whose `testValue` is `let pair = mkPair 1 in applyPair pair`.

`mkPair n` returns `( \x -> x + n, n )`, annotated
`Int -> ( Int -> Int, Int )`, and `applyPair` takes such a pair and returns
`0` without reading it. So `pair` is a local value that is not a function and
whose type has no type variables, which sends it down the plain-`let` path;
its type holds an arrow, which is what the test reads; and its right-hand side
is a call rather than a tuple literal.

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
          , body = intExpr 0 -- the test reads only the parameter type of this callee's specializations
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


{-| A program whose `testValue` is
`let go h n = if n > 0 then go h (n - 1) else apply h n in go inc 3`.

`go` is a local tail-recursive function called once from the `let` body, so
it has one instance, and its callback parameter `h` is passed to `apply`,
annotated `(Int -> Int) -> Int -> Int`. `inc x` is `x + 1`.

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


{-| Runs `srcModule` to a monomorphized graph with the solver engine, the
default specialization limits and the default LSS configuration with LSS
enabled.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns, for each specialization in the graph's registry of a global named
`target` whose type is a function, the annotation `firstArrowHead` finds in
its first parameter type.

The global is matched by name alone, in any module. A specialization
contributes nothing when `firstArrowHead` finds no arrow in its first
parameter, so the list can be empty.

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


{-| Returns the annotation on the outermost arrow of `t` when `t` is a
function type, or, when `t` is a tuple, the first such annotation found
searching its components in order, nested tuples included.
-}
firstArrowHead : Mono.MonoType -> Maybe Mono.LambdaSetAnno
firstArrowHead t =
    case t of
        Mono.MFunction _ anno _ _ ->
            Just anno

        Mono.MTuple _ ts ->
            List.head (List.filterMap firstArrowHead ts)

        _ ->
            Nothing


{-| Reports whether `anno` is an `LSet`, whatever its members, the empty list
included.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet anno =
    case anno of
        Mono.LSet _ ->
            True

        _ ->
            False


{-| Renders `anno` for a failure message, with its member ids, variable number
or top kind code.
-}
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
