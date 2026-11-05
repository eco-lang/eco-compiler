module Compiler.PreMono.InlineSimplifyDestructCaptureTest exposing (suite)

{-| Tests that the pre-monomorphization inliner,
`Compiler.PreMono.InlineSimplify`, renames the destructuring binders of a
body it copies into a caller. It is there to catch an inliner that renames
`let` binders but copies a destructuring binder unchanged, which gives the
caller two binders of one name.

_Binder capture_ is that failure: a binder in the inlined copy has the same
name as a binder in the caller, so inside the caller's body one shadows the
other. `InlineSimplify` avoids it by appending one suffix, `_pi` and a number
unique to the copy, to every local name in the copied body, binders and uses
alike.

The fixture is `captureModule`, a module `Test` with two definitions.
`split` takes a pair `p` and returns its first component through
`let ( a, b ) = p in a`, so its body binds `a` by destructuring. `testValue`
binds its own `a` to `100` and returns `split ( 1, 2 ) + a`. If `split` is
inlined into `testValue` and its `a` is not renamed, `testValue`'s body binds
`a` twice. The module is compiled with `TestLogic.TestPipeline.runToAssigned`.
The first test runs the pre-monomorphization passes on the resulting graph
through the checker it calls; the second runs `InlineSimplify.optimize` on it
directly, with `inlineConfig`.

The tests establish:

  - "an inlined Destruct binder does not shadow a caller binder":
    `TestLogic.Monomorphize.PreMonoBinderHygiene.expectPreMonoBinderHygiene`
    finds no binder that the pre-monomorphization passes
    (`Compiler.Pipeline.Steps.preMono`, with the pre-mono inliner switched on)
    bind where its name is already in scope. The check reads the names bound,
    not the value `testValue` computes. The same check runs over the standard
    catalogue in `TestLogic.Monomorphize.PreMonoBinderHygieneTest`; it is kept
    here for this fixture, which the catalogue does not hold.
  - "split is inlined into testValue, ...": after the pass, `testValue`'s body
    no longer refers to `split` and binds exactly two names beginning with
    `a`, its own and the renamed copy of `split`'s. Without the inlining the
    first test would have nothing to catch.

Among what is not tested:

  - The value `testValue` computes after the pass.
  - In the second test, binders inside a `case`, a record, a record update or
    a tail call, which `binders` does not look at, and the bodies of `Cycle`
    nodes. The fixture has none of these.
  - One function inlined twice into the same caller.

-}

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
import Compiler.Config as Config
import Compiler.Core.Annotation as A
import Compiler.Core.Name exposing (Name)
import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Source as Src
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.PreMono.InlineSimplify as InlineSimplify
import Data.Map
import Expect
import Maybe.Extra as Maybe
import Test exposing (Test)
import TestLogic.Monomorphize.PreMonoBinderHygiene exposing (expectPreMonoBinderHygiene)
import TestLogic.TestPipeline as Pipeline


{-| The two tests described in the module docstring. Each fails with the
pipeline's message if `runToAssigned` fails. The first otherwise names each
captured binder, with the global whose body holds it.
-}
suite : Test
suite =
    Test.describe "InlineSimplify destructure-binder capture"
        [ Test.test "an inlined Destruct binder does not shadow a caller binder" <|
            \_ -> expectPreMonoBinderHygiene captureModule
        , Test.test "split is inlined into testValue, so the capture check has a copy to look at" <|
            \_ ->
                -- Without the inlining there is nothing for the test above to
                -- catch. After it, `testValue` binds its own `a` and split's
                -- destructured `a` under a renamed name, and no longer calls
                -- `split`.
                case Pipeline.runToAssigned captureModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( after, _, _ ) =
                                InlineSimplify.optimize inlineConfig assigned.mvarState assigned.graph
                        in
                        case topLevelBody after "testValue" of
                            Nothing ->
                                Expect.fail "found no testValue body"

                            Just body ->
                                Expect.equal
                                    { callsSplit = False, namesStartingWithA = 2 }
                                    { callsSplit = mentionsGlobal "split" body
                                    , namesStartingWithA = List.length (List.filter (String.startsWith "a") (binders body))
                                    }
        ]


{-| The default inline configuration with `preMono` switched on.

`InlineSimplify.optimize` does not read `preMono`; `Builder.Generate` checks it
before calling the pass. The pass reads its inlining threshold (`preMonoThreshold`),
its round limit (`preMonoFixpointIterations`) and `report` from this record,
and those are the defaults.

-}
inlineConfig : Config.InlineConfig
inlineConfig =
    let
        base =
            Config.default.inline
    in
    { base | preMono = True }


{-| Returns the body of the `Define` or `TrackedDefine` node whose value name
is `name`, in any module.
-}
topLevelBody : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (TOpt.Expr TypeIds.MVarId)
topLevelBody (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case bodyExpr node of
                    Just e ->
                        Just e

                    Nothing ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| Returns whether `expr` refers to the global whose value name is `name`,
looking where `binders` looks.
-}
mentionsGlobal : Name -> TOpt.Expr TypeIds.MVarId -> Bool
mentionsGlobal name expr =
    case expr of
        TOpt.VarGlobal _ (TOpt.Global _ n) _ ->
            n == name

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ bound _ ->
                    mentionsGlobal name bound

                TOpt.TailDef _ _ _ b _ _ ->
                    mentionsGlobal name b
            )
                || mentionsGlobal name body

        TOpt.Destruct _ body _ ->
            mentionsGlobal name body

        TOpt.Function _ _ body _ ->
            mentionsGlobal name body

        TOpt.TrackedFunction _ _ body _ ->
            mentionsGlobal name body

        TOpt.Call _ f args _ ->
            List.any (mentionsGlobal name) (f :: args)

        TOpt.If branches final _ ->
            List.any (\( c, t ) -> mentionsGlobal name c || mentionsGlobal name t) branches
                || mentionsGlobal name final

        TOpt.Tuple _ a b rest _ ->
            List.any (mentionsGlobal name) (a :: b :: Maybe.toList rest)

        TOpt.List _ items _ ->
            List.any (mentionsGlobal name) items

        TOpt.Access inner _ _ _ ->
            mentionsGlobal name inner

        _ ->
            False


{-| Returns the body of a `Define` or `TrackedDefine` node, and `Nothing` for
any other kind of node.
-}
bodyExpr : TOpt.Node TypeIds.MVarId -> Maybe (TOpt.Expr TypeIds.MVarId)
bodyExpr node =
    case node of
        TOpt.Define e _ _ ->
            Just e

        TOpt.TrackedDefine _ e _ _ ->
            Just e

        _ ->
            Nothing


{-| Returns the names bound in `expr` outside any `Case`, record, record update
or tail call: the names of `Let` definitions and the parameters of a `TailDef`,
`Destruct` binders, and `Function` and `TrackedFunction` parameters.

It descends through calls, `If` conditions and branches, tuples, lists and
field access, and it collects from sibling branches alike, so two `If`
branches that each bind `x` count as binding `x` twice. It does not look
inside a `Case`, whose separate branches may each bind the same name, nor
inside a record, a record update or a tail call.

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
            binders a ++ binders b ++ List.concatMap binders (Maybe.toList rest)

        TOpt.List _ items _ ->
            List.concatMap binders items

        TOpt.Access inner _ _ _ ->
            binders inner

        _ ->
            []


{-| Returns the names a `let` definition binds: its own name, the parameters
of a `TailDef`, and the names `binders` finds in its bound expression or body.
-}
defBinders : TOpt.Def TypeIds.MVarId -> List String
defBinders def =
    case def of
        TOpt.Def _ n bound _ ->
            n :: binders bound

        TOpt.TailDef _ n args body _ _ ->
            (n :: List.map (\( ln, _ ) -> located ln) args) ++ binders body


{-| Returns the name in a located name, without its region.
-}
located : A.Located Name -> String
located =
    A.toValue



-- ============================================================================
-- FIXTURE
-- ============================================================================


{-| Builds the source expression `a + b`.
-}
plus : Src.Expr -> Src.Expr -> Src.Expr
plus a b =
    binopsExpr [ ( a, "+" ) ] b


{-| The fixture module `Test`, which is this Elm source:

    split : ( Int, Int ) -> Int
    split p =
        let
            ( a, b ) =
                p
        in
        a

    testValue : Int
    testValue =
        let
            a =
                100
        in
        split ( 1, 2 ) + a

`split`'s body binds `a` by destructuring, and `testValue` binds its own `a`
and calls `split`, so inlining `split` into `testValue` puts both binders in
one body.

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
