module TestLogic.GlobalOpt.CafDedupeTest exposing (suite)

{-| Unit tests for the CAF spec-dedupe pass (Compiler.GlobalOpt.CafDedupe)
on hand-built synthetic MonoGraphs — exact control over structural
equality, canonical selection, reference remapping, and the fixpoint
cascade.
-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.GlobalOpt.CafDedupe as CafDedupe
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CafDedupe"
        [ Test.test "identical thunks merge onto the lowest specId; refs and ports remap" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafDedupe.run testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 1 stats.groups
                    , \_ -> Expect.equal 1 stats.removed

                    -- exactly the MonoVarGlobal ref in node 3 (the port
                    -- decoder remap is a field rewrite, not an expr ref)
                    , \_ -> Expect.equal 1 stats.refsRewritten
                    , \_ ->
                        -- array length unchanged; victim (spec 2) is a gap
                        Expect.equal 4 (Array.length g1.nodes)
                    , \_ ->
                        case Array.get 2 g1.nodes of
                            Just Nothing ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected victim spec 2 nulled out"
                    , \_ ->
                        -- canonical (spec 0) survives untouched
                        case Array.get 0 g1.nodes of
                            Just (Just (Mono.MonoDefine _ _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected canonical spec 0 intact"
                    , \_ ->
                        -- consumer's reference redirected 2 → 0 (inside
                        -- the closure body, like CafHoistTest's pattern)
                        case Array.get 3 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoClosure _ (Mono.MonoCall _ _ [ Mono.MonoVarGlobal _ 0 _, Mono.MonoVarLocal _ _ ] _ _) _) _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected node 3 arg remapped to MonoVarGlobal 0"
                    , \_ ->
                        -- port decoder spec redirected 2 → 0
                        Expect.equal [ Just 0 ]
                            (List.map .decoderSpecId g1.ports)
                    ]
                    ()
        , Test.test "different bodies do not merge" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafDedupe.run distinctGraph
                in
                Expect.equal ( 0, 0 ) ( stats.groups, stats.removed )
        , Test.test "different types do not merge even with equal bodies" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafDedupe.run typeSplitGraph
                in
                Expect.equal ( 0, 0 ) ( stats.groups, stats.removed )
        , Test.test "idempotent: re-running the deduped graph removes nothing" <|
            \_ ->
                let
                    ( g1, _ ) =
                        CafDedupe.run testGraph

                    ( _, stats2 ) =
                        CafDedupe.run g1
                in
                Expect.equal 0 stats2.removed
        , Test.test "cascade: aliases of merged specs merge on a later round" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafDedupe.run cascadeGraph
                in
                Expect.all
                    [ -- round 1 merges thunks 1→0; round 2 merges the two
                      -- aliases (now both `MonoVarGlobal 0`) 3→2
                      \_ -> Expect.equal 2 stats.groups
                    , \_ -> Expect.equal 2 stats.removed
                    , \_ -> Expect.atLeast 2 stats.rounds
                    , \_ ->
                        case ( Array.get 1 g1.nodes, Array.get 3 g1.nodes ) of
                            ( Just Nothing, Just Nothing ) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected specs 1 and 3 nulled out"
                    ]
                    ()
        ]



-- ====== SYNTHETIC GRAPHS ======


home : IO.Canonical
home =
    IO.Canonical ( "author", "proj" ) "M"


strTy : Mono.MonoType
strTy =
    Mono.MString


fnTy : Mono.MonoType
fnTy =
    Mono.MFunction Mono.LTop [ strTy ] strTy


thunkBody : String -> Mono.MonoExpr
thunkBody lit =
    -- strRepeat 3 lit : String — a computed nullary body
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "repeat" fnTy)
        [ Mono.MonoLiteral (Mono.LInt 3) Mono.MInt
        , Mono.MonoLiteral (Mono.LStr lit) strTy
        ]
        strTy
        Mono.defaultCallInfo


thunkNode : String -> Mono.MonoNode
thunkNode lit =
    Mono.MonoDefine (thunkBody lit) strTy


consumerNode : Int -> Mono.MonoNode
consumerNode refId =
    -- k = \x -> strApp <ref> x
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home 0
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( "x", strTy ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (Mono.MonoCall A.zero
                (Mono.MonoVarKernel A.zero "Elm" "String" "append" fnTy)
                [ Mono.MonoVarGlobal A.zero refId strTy
                , Mono.MonoVarLocal "x" strTy
                ]
                strTy
                Mono.defaultCallInfo
            )
            fnTy
        )
        fnTy


baseRegistry : Int -> Mono.SpecializationRegistry
baseRegistry n =
    { nextId = n
    , mapping = Dict.empty
    , reverseMapping =
        Array.fromList
            (List.map
                (\i -> Just ( Mono.Global home ("g" ++ String.fromInt i), strTy ))
                (List.range 0 (n - 1))
            )
    }


mkGraph : List (Maybe Mono.MonoNode) -> List Mono.PortRegistration -> Mono.MonoGraph
mkGraph nodes ports =
    Mono.MonoGraph
        { nodes = Array.fromList nodes
        , main = Nothing
        , registry = baseRegistry (List.length nodes)
        , ctorShapes = Dict.empty
        , nextLambdaIndex = 1
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = ports
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        }


{-| specs 0/2 identical thunks (2 is the victim), 1 a distinct thunk,
3 a consumer referencing the victim; a port decoder also points at the
victim.
-}
testGraph : Mono.MonoGraph
testGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "cd")
        , Just (thunkNode "ab")
        , Just (consumerNode 2)
        ]
        [ { name = "p", key = "p", incoming = True, decoderSpecId = Just 2 } ]


distinctGraph : Mono.MonoGraph
distinctGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "cd")
        ]
        []


{-| Equal zeroed bodies but different define types must NOT merge
(FORBID_OPT_003: layouts must be identical; type equality is the proxy).
-}
typeSplitGraph : Mono.MonoGraph
typeSplitGraph =
    mkGraph
        [ Just (Mono.MonoDefine (Mono.MonoVarKernel A.zero "Elm" "String" "empty" strTy) strTy)
        , Just (Mono.MonoDefine (Mono.MonoVarKernel A.zero "Elm" "String" "empty" strTy) fnTy)
        ]
        []


{-| specs 0/1 identical thunks; specs 2/3 alias DIFFERENT members of that
group (`MonoVarGlobal 0` vs `MonoVarGlobal 1`) so they only become equal
after round 1 merges 1→0 — exercises the fixpoint.
-}
cascadeGraph : Mono.MonoGraph
cascadeGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "ab")
        , Just (Mono.MonoDefine (Mono.MonoVarGlobal A.zero 0 strTy) strTy)
        , Just (Mono.MonoDefine (Mono.MonoVarGlobal A.zero 1 strTy) strTy)
        ]
        []
