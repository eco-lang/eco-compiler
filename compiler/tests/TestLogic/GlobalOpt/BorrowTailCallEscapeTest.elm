module TestLogic.GlobalOpt.BorrowTailCallEscapeTest exposing (suite)

{-| BORROW_005 scaffold (borrow-inference Phase 3, §U3.3): a `MonoTailCall`'s
heap-typed args must be escape-seeded so their approximate lifetime never ends
at or before the tail call — the analysis fact Phase 5 relies on to never
place a drop after a tail call.

Fixture (source-first, via `SourceBuilder`): a top-level tail-recursive
`loop : Int -> List Int -> List Int` whose accumulator `acc` is heap-typed.
After GlobalOpt it becomes a `MonoTailFunc` with a `MonoTailCall`; the borrow
analysis must seed the tail args to escape.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.SourceBuilder as B
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime(..))
import Compiler.GlobalOpt.Borrow.Solve as Solve
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.test "BORROW_005: MonoTailCall heap args are escape-seeded (never dead at/before the tail call)" <|
        \_ ->
            case Pipeline.runToGlobalOpt fixtureModule of
                Err msg ->
                    Expect.fail ("pipeline: " ++ msg)

                Ok { optimizedMonoGraph } ->
                    checkGraph optimizedMonoGraph


{-| loop n acc = if n <= 0 then acc else loop (n - 1) (n :: acc)
-}
fixtureModule =
    let
        intType =
            B.tType "Int" []

        listIntType =
            B.tType "List" [ intType ]

        loopBody =
            B.ifExpr
                (B.binopsExpr [ ( B.varExpr "n", "<=" ) ] (B.intExpr 0))
                (B.varExpr "acc")
                (B.callExpr (B.varExpr "loop")
                    [ B.binopsExpr [ ( B.varExpr "n", "-" ) ] (B.intExpr 1)
                    , B.binopsExpr [ ( B.varExpr "n", "::" ) ] (B.varExpr "acc")
                    ]
                )
    in
    B.makeModuleWithTypedDefs "Test"
        [ { name = "loop"
          , args = [ B.pVar "n", B.pVar "acc" ]
          , tipe = B.tLambda intType (B.tLambda listIntType listIntType)
          , body = loopBody
          }
        , { name = "testValue"
          , args = []
          , tipe = listIntType
          , body = B.callExpr (B.varExpr "loop") [ B.intExpr 10, B.listExpr [] ]
          }
        ]


checkGraph : Mono.MonoGraph -> Expect.Expectation
checkGraph graph =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        -- SpecIds of MonoTailFunc nodes.
        tailFuncSpecIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just (Mono.MonoTailFunc _ _ _) ->
                            ( specId + 1, specId :: acc )

                        _ ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second

        -- Analyze each; keep those with escape-seeded tail args.
        analyses =
            List.filterMap (\sid -> Borrow.analyzeDefForTest graph sid) tailFuncSpecIds

        withTailArgs =
            List.filter (\( _, tailArgRes, _ ) -> not (List.isEmpty tailArgRes)) analyses
    in
    case withTailArgs of
        [] ->
            Expect.fail "no MonoTailFunc with escape-seeded tail-call args was found (expected `loop`)"

        ( solved, tailArgRes, nRes ) :: _ ->
            let
                -- Positive: every tail-call arg resource is live at the tail
                -- call (ltA non-empty and not dead before the body completion).
                escapeOk =
                    List.all
                        (\r ->
                            ltaNonEmpty (Solve.ltAOf r solved)
                                && not (L.endsBefore (Solve.ltAOf r solved) [])
                        )
                        tailArgRes

                -- Negative control: some resource in the same def IS dead before
                -- the body completes (proves endsBefore isn't vacuously False).
                someDies =
                    List.any
                        (\r -> L.endsBefore (Solve.ltAOf r solved) [])
                        (List.range 0 (nRes - 1))
            in
            Expect.equal ( True, True ) ( escapeOk, someDies )


ltaNonEmpty : Lifetime -> Bool
ltaNonEmpty lt =
    case lt of
        LEmpty ->
            False

        _ ->
            True
