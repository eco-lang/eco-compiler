module TestLogic.GlobalOpt.CafHoistTest exposing (suite)

{-| Unit tests for the CAF hoisting pass
(plans/caf-hoist-closed-expressions.md H1) on hand-built synthetic
MonoGraphs — exact control over closedness, dedupe, exclusions, and the
append-only registry surgery.
-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CafHoist"
        [ Test.test "closed call is hoisted; duplicate site dedupes; scalar site excluded" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 1 stats.hoisted
                    , \_ -> Expect.equal 2 stats.sites
                    , \_ -> Expect.equal 1 stats.deduped
                    , \_ -> Expect.equal 1 stats.skippedScalar
                    , \_ -> Expect.equal 4 (Array.length g1.nodes)
                    , \_ -> Expect.equal 4 g1.registry.nextId
                    , \_ -> Expect.equal 4 (Array.length g1.registry.reverseMapping)
                    , \_ ->
                        -- the appended spec is the closed expression as a define
                        case Array.get 3 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoCall _ _ _ _ _) ty)) ->
                                Expect.equal Mono.MString ty

                            _ ->
                                Expect.fail "expected appended MonoDefine call spec at id 3"
                    , \_ ->
                        -- site in node 0 replaced by a global ref to spec 3
                        case Array.get 0 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoClosure _ (Mono.MonoCall _ _ [ Mono.MonoVarGlobal _ 3 _, Mono.MonoVarLocal _ _ ] _ _) _) _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected node 0 body arg replaced by MonoVarGlobal 3"
                    ]
                    ()
        , Test.test "re-running on the hoisted graph mints nothing (stability)" <|
            \_ ->
                let
                    ( g1, _ ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } testGraph

                    ( _, stats2 ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } g1
                in
                Expect.equal ( 0, 0 ) ( stats2.hoisted, stats2.sites )
        , Test.test "minNodes floor excludes small candidates" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafHoist.run { minNodes = 10, maxHoists = 100 } testGraph
                in
                Expect.equal ( 0, 0 ) ( stats.hoisted, stats.sites )
        , Test.test "maxHoists budget stops minting and counts overflow" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafHoist.run { minNodes = 3, maxHoists = 0 } testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 0 stats.hoisted
                    , \_ -> Expect.atLeast 1 stats.skippedBudget
                    ]
                    ()
        ]



-- ====== SYNTHETIC GRAPH ======
-- node 0: f = \x -> strApp (CLOSED: strRepeat 3 "ab") x        → hoist
-- node 1: h = \y -> strApp (CLOSED: strRepeat 3 "ab") y        → dedupe with node 0
-- node 2: n = \z -> intAdd (CLOSED-SCALAR: strLen "ab") z      → skippedScalar
--   (result type MInt on the closed subtree ⇒ HEAP_035 exclusion)


home : IO.Canonical
home =
    IO.Canonical ( "author", "proj" ) "M"


strTy : Mono.MonoType
strTy =
    Mono.MString


fnTy : Mono.MonoType
fnTy =
    Mono.mFunction Mono.LTop [ strTy ] strTy


closedCall : Mono.MonoExpr
closedCall =
    -- strRepeat 3 "ab" : String — closed, value-ABI, size 4 (call+kernel+2 lits)
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "repeat" fnTy)
        [ Mono.MonoLiteral (Mono.LInt 3) Mono.MInt
        , Mono.MonoLiteral (Mono.LStr "ab") strTy
        ]
        strTy
        Mono.defaultCallInfo


closedScalarCall : Mono.MonoExpr
closedScalarCall =
    -- strLen "ab" : Int — closed but scalar-ABI ⇒ excluded
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "length" fnTy)
        [ Mono.MonoLiteral (Mono.LStr "ab") strTy ]
        Mono.MInt
        Mono.defaultCallInfo


bodyUsing : String -> Mono.MonoExpr -> Mono.MonoExpr
bodyUsing param closed =
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "append" fnTy)
        [ closed
        , Mono.MonoVarLocal param strTy
        ]
        strTy
        Mono.defaultCallInfo


funcNode : Int -> String -> Mono.MonoExpr -> Mono.MonoNode
funcNode uid param closed =
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home uid
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( param, strTy ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (bodyUsing param closed)
            fnTy
        )
        fnTy


testGraph : Mono.MonoGraph
testGraph =
    Mono.MonoGraph
        { nodes =
            Array.fromList
                [ Just (funcNode 0 "x" closedCall)
                , Just (funcNode 1 "y" closedCall)
                , Just (funcNode 2 "z" closedScalarCall)
                ]
        , main = Nothing
        , registry =
            { nextId = 3
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping =
                Array.fromList
                    [ Just ( Mono.Global home "f", fnTy )
                    , Just ( Mono.Global home "h", fnTy )
                    , Just ( Mono.Global home "n", fnTy )
                    ]
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 3
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        }
