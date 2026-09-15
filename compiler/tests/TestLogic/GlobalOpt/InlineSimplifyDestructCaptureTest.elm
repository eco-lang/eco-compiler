module TestLogic.GlobalOpt.InlineSimplifyDestructCaptureTest exposing (suite)

{-| Step 4's binder-capture trap, pinned
(`plans/pre-mono-inline-simplify.md` §6).

The post-monomorphization inliner shipped a bug in which `MonoDestruct`
binders were spliced through VERBATIM while `MonoDef`/`MonoTailDef` binders
were alpha-renamed, so an inlined `let ( _, a ) = …` captured the CALLER's
`a`. `InlineSimplify` avoids that class by suffixing every local name in a
copied body — binders and uses alike, `Destruct` included — with one
per-copy suffix.

This test builds exactly the shape that broke the mono pass: a callee whose
body destructures a tuple into `a`, inlined into a caller that has its own
`a` in scope with a different value. If the callee's `a` captured the
caller's, the two names collide in one scope.

The assertion is structural rather than by evaluation: after the pass, no
name bound by the inlined copy may equal a name bound by the caller. That is
the invariant capture violates, and it holds whether or not the fixture's
arithmetic would happen to agree.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , destruct
        , intExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.InlineSimplify as InlineSimplify
import Compiler.Reporting.Annotation as A
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "InlineSimplify destructure-binder capture"
        [ Test.test "an inlined Destruct binder does not shadow a caller binder" <|
            \_ ->
                case Pipeline.runToAssigned captureModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( after, _, _ ) =
                                InlineSimplify.optimize inlineConfig assigned.mvarState assigned.graph

                            dupes =
                                duplicateBinders after
                        in
                        if List.isEmpty dupes then
                            Expect.pass

                        else
                            Expect.fail
                                ("a name is bound twice in one top-level body after inlining: "
                                    ++ String.join ", " dupes
                                )
        ]


inlineConfig : Config.InlineConfig
inlineConfig =
    let
        base =
            Config.default.inline
    in
    { base | preMono = True }


{-| Names bound more than once inside a single top-level body. A correct
copy-and-rename never produces one; capture always does.
-}
duplicateBinders : TOpt.GlobalGraph TypeIds.MVarId -> List String
duplicateBinders (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl TOpt.compareGlobal
        (\g node acc ->
            case bodyExpr node of
                Just expr ->
                    case repeated (binders expr) of
                        [] ->
                            acc

                        rs ->
                            (TOpt.toComparableGlobal g ++ ": " ++ String.join "/" rs) :: acc

                Nothing ->
                    acc
        )
        []
        nodes


bodyExpr : TOpt.Node TypeIds.MVarId -> Maybe (TOpt.Expr TypeIds.MVarId)
bodyExpr node =
    case node of
        TOpt.Define e _ _ ->
            Just e

        TOpt.TrackedDefine _ e _ _ ->
            Just e

        _ ->
            Nothing


repeated : List String -> List String
repeated names =
    List.foldl
        (\n ( seen, dup ) ->
            if List.member n seen then
                ( seen, n :: dup )

            else
                ( n :: seen, dup )
        )
        ( [], [] )
        names
        |> Tuple.second


{-| Every name introduced by a binder in an expression: `Let` definitions,
`Destruct` binders and lambda parameters. Deliberately does NOT descend into
`Case` deciders — the fixture has none, and a decider's jump targets legally
reuse names.
-}
binders : TOpt.Expr TypeIds.MVarId -> List String
binders expr =
    case expr of
        TOpt.Let def body _ ->
            defBinders def ++ binders body

        TOpt.Destruct (TOpt.Destructor n _ _) body _ ->
            n :: binders body

        TOpt.Function _ params body _ ->
            List.map Tuple.first params ++ binders body

        TOpt.TrackedFunction _ params body _ ->
            List.map (\( ln, _ ) -> located ln) params ++ binders body

        TOpt.Call _ f args _ ->
            binders f ++ List.concatMap binders args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> binders c ++ binders t) branches ++ binders final

        TOpt.Tuple _ a b rest _ ->
            binders a ++ binders b ++ List.concatMap binders rest

        TOpt.List _ items _ ->
            List.concatMap binders items

        TOpt.Access inner _ _ _ ->
            binders inner

        _ ->
            []


defBinders : TOpt.Def TypeIds.MVarId -> List String
defBinders def =
    case def of
        TOpt.Def _ n bound _ ->
            n :: binders bound

        TOpt.TailDef _ n args body _ _ ->
            (n :: List.map (\( ln, _ ) -> located ln) args) ++ binders body


located : A.Located Name -> String
located =
    A.toValue



-- ============================================================================
-- FIXTURE
-- ============================================================================


plus : Src.Expr -> Src.Expr -> Src.Expr
plus a b =
    binopsExpr [ ( a, "+" ) ] b


{-| split : ( Int, Int ) -> Int
split p =
let ( a, b ) = p in a

    testValue : Int
    testValue =
        let
            a =
                100
        in
        split ( 1, 2 ) + a

`split`'s body binds `a`; the caller binds `a` too. Inlining `split` puts both
in one body.

-}
captureModule : Src.Module
captureModule =
    let
        splitDef : TypedDef
        splitDef =
            { name = "split"
            , args = [ pVar "p" ]
            , tipe =
                tLambda (tTuple (tType "Int" []) (tType "Int" []))
                    (tType "Int" [])
            , body =
                letExpr
                    [ destruct (pTuple (pVar "a") (pVar "b")) (varExpr "p") ]
                    (varExpr "a")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr [ define "a" [] (intExpr 100) ]
                    (plus
                        (callExpr (varExpr "split") [ tupleExpr (intExpr 1) (intExpr 2) ])
                        (varExpr "a")
                    )
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test" [ splitDef, testValueDef ] [] []
