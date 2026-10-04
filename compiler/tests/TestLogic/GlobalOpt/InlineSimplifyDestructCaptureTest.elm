module TestLogic.GlobalOpt.InlineSimplifyDestructCaptureTest exposing (suite)

{-| Tests that the pre-monomorphization inliner,
`Compiler.GlobalOpt.InlineSimplify`, renames the destructuring binders of a
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
`a` twice. The module is compiled with `TestLogic.TestPipeline.runToAssigned`,
and `InlineSimplify.optimize` is run on the resulting graph with
`inlineConfig`.

The test establishes:

  - "an inlined Destruct binder does not shadow a caller binder": after the
    pass, no `Define` or `TrackedDefine` body in the graph binds any name more
    than once, as `binders` counts binders. The check reads the names bound,
    not the value `testValue` computes.

Among what is not tested:

  - That `split` is inlined at all. If the pass left the call in place, no
    body would bind a name twice and the test would pass.
  - The value `testValue` computes after the pass.
  - Binders inside a `case`, a record, a record update or a tail call, which
    `binders` does not look at, and the bodies of `Cycle` nodes. The fixture
    has none of these.
  - One function inlined twice into the same caller.

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


{-| The one test described in the module docstring. It fails with the
pipeline's message if `runToAssigned` fails, and otherwise names each
top-level body that binds a name more than once, with the repeated names.
-}
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


{-| Returns one entry for each `Define` or `TrackedDefine` node in the graph
whose body binds a name more than once, as `binders` counts binders. The
entry is the node's global followed by its repeated names. Nodes of other
kinds, `Cycle` included, are not checked.
-}
duplicateBinders : TOpt.GlobalGraph TypeIds.MVarId -> List String
duplicateBinders (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl
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


{-| Returns every occurrence in `names` of a name already seen earlier in the
list, so a name that appears three times is returned twice. The result is
empty when the names are all different.
-}
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
            binders a ++ binders b ++ List.concatMap binders rest

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
