module TestLogic.Monomorphize.PreMonoBinderHygiene exposing (expectPreMonoBinderHygiene)

{-| Checks that after the pre-monomorphization passes no local binder in a
definition's body binds a name that is already in scope there: the passes
never introduce _binder capture_.

Elm forbids shadowing, so a type-checked program never binds a local name that
an enclosing scope of the same definition already binds. The
pre-monomorphization passes (`Compiler.Pipeline.Steps.preMono`: alias
forwarding, η-expansion to declared arity, and the pre-mono inliner
`Compiler.PreMono.InlineSimplify`) rewrite bodies, and the inliner copies one
definition's body into another's. A copy whose binders are not renamed can put
two binders of one name in one scope chain, so that inside the inner one the
outer is shadowed and a use meant for the outer reads the inner: binder
capture. `InlineSimplify` avoids it by appending one suffix, `_pi` and a number
unique to the copy, to every local name in the copied body. The P test
`Compiler.PreMono.InlineSimplifyDestructCaptureTest` pins that on one program
whose copied body binds by destructuring; this module checks every program it
is given.

The graph is built with `TestLogic.TestPipeline.runToAssigned` (the typed graph
with its ids, as a build gives it to the pre-monomorphization passes) and then
put through `Steps.preMono` twice, from the same input:

  - under `TestPipeline.productionConfig`, which runs alias forwarding and
    η-expansion but not the pre-mono inliner (`inline.preMono` is off by
    default);
  - under the same configuration with `inline.preMono` switched on, as the P
    test runs it, so the inliner's copies are checked too.

In each result every `Define`, `TrackedDefine`, port and `Cycle` body is walked
with the set of local names in scope, which starts empty for each top-level
definition (top-level names are globals, `VarGlobal`, and never locals). A
_binder_ is a `let` definition's name, a tail-recursive local definition's
parameters, a destructuring's name, and a `Function` or `TrackedFunction`
parameter. A binder is _captured_ when its name is already in scope, or is bound twice in
one parameter list. A `let` definition's name is in scope in its
own bound expression (it may be recursive) and in the `let` body; a parameter in
its function's body; a destructuring's name in the destructuring's body.
Sibling scopes are independent: the two branches of an `if`, the branches of a
`case` (its jump list and the bodies its decision tree holds inline) and the
arguments of a call may each bind the same name, which the P test's own count
would have flagged although it is not capture.

The check fails on a captured binder the passes _introduced_: per top-level
global, the captured names of the result beyond those the same walk finds in
the input graph. The input is not always free of capture, because typed
optimization generates code no source program contains: the encoder of an
outgoing port for a nested record (`Compiler.LocalOpt.Typed.Port`) is a
`\$ -> ...` whose body holds another `\$ -> ...` for the inner record, as elm
0.19.1's generator also writes it. The inner lambda never uses the outer `$`, so
that shadowing is harmless, and it is not the passes' doing.

Among what is not checked: the names that uses refer to (a use of a name not
in scope is not reported); the graph after monomorphization, where
`TestLogic.Generate.MonoGraphIntegrity.expectMonoGraphClosed` checks scoping
and the post-monomorphization inliner has binders of its own; and
configurations other than the two above.

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Name exposing (Name)
import Compiler.IR.Source as Src
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.Pipeline.Steps as Steps
import Data.Map
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Set exposing (Set)
import TestLogic.TestPipeline as Pipeline


{-| Compiles `srcModule` to the prepared graph, runs the pre-monomorphization
passes on it under both configurations the module docstring names, and passes
when neither result has a captured binder the input did not already have. It
fails with
the pipeline's message when the program does not get that far, and otherwise
with one line per captured binder, naming the configuration, the definition and
the name.
-}
expectPreMonoBinderHygiene : Src.Module -> Expectation
expectPreMonoBinderHygiene srcModule =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                production =
                    Pipeline.productionConfig

                baseInline =
                    production.inline

                withInliner =
                    { production | inline = { baseInline | preMono = True } }

                before =
                    graphCaptures assigned.graph

                issues =
                    introducedIssues "default pre-mono passes" before (Steps.preMono production assigned).assigned.graph
                        ++ introducedIssues "pre-mono passes with the inliner" before (Steps.preMono withInliner assigned).assigned.graph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" (List.take 20 issues))


{-| Returns a message for each captured binder in `after` that the passes
introduced, prefixed with `label` and the global whose body it is in: each
name in a global's captures in `after` beyond as many as `before` has for that
global under the same name.
-}
introducedIssues : String -> Dict String (List Name) -> TOpt.GlobalGraph id -> List String
introducedIssues label before after =
    Dict.foldr
        (\global names acc ->
            List.map
                (\name ->
                    label
                        ++ ": in "
                        ++ global
                        ++ ", `"
                        ++ name
                        ++ "` is bound where it is already in scope"
                )
                (removeEach (Maybe.withDefault [] (Dict.get global before)) names)
                ++ acc
        )
        []
        (graphCaptures after)


{-| Returns `names` with one occurrence removed for each element of `known`.
-}
removeEach : List Name -> List Name -> List Name
removeEach known names =
    case known of
        [] ->
            names

        k :: rest ->
            removeEach rest (removeFirst k names)


{-| Returns `names` without the first occurrence of `n`.
-}
removeFirst : Name -> List Name -> List Name
removeFirst n names =
    case names of
        [] ->
            []

        x :: rest ->
            if x == n then
                rest

            else
                x :: removeFirst n rest


{-| Returns, for each global of the graph whose bodies have a captured binder,
the captured names, keyed by `TOpt.toComparableGlobal`.
-}
graphCaptures : TOpt.GlobalGraph id -> Dict String (List Name)
graphCaptures (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl
        (\global node acc ->
            case nodeCaptures node of
                [] ->
                    acc

                names ->
                    Dict.insert (TOpt.toComparableGlobal global) names acc
        )
        Dict.empty
        nodes


{-| Returns the captured binder names in one node's bodies, each top-level body
walked from an empty scope.
-}
nodeCaptures : TOpt.Node id -> List String
nodeCaptures node =
    case node of
        TOpt.Define expr _ _ ->
            exprCaptures Set.empty expr

        TOpt.TrackedDefine _ expr _ _ ->
            exprCaptures Set.empty expr

        TOpt.PortIncoming expr _ _ ->
            exprCaptures Set.empty expr

        TOpt.PortOutgoing expr _ _ ->
            exprCaptures Set.empty expr

        TOpt.Cycle _ values defs _ ->
            List.concatMap (\( _, e ) -> exprCaptures Set.empty e) values
                ++ List.concatMap (topLevelDefCaptures Set.empty) defs

        TOpt.Ctor _ _ _ ->
            []

        TOpt.Enum _ _ ->
            []

        TOpt.Box _ ->
            []

        TOpt.Link _ ->
            []

        TOpt.Manager _ ->
            []

        TOpt.Kernel _ _ ->
            []


{-| Returns the captured binders in a definition of a `Cycle` node, whose name
is a global, so only its parameters and body are walked.
-}
topLevelDefCaptures : Set Name -> TOpt.Def id -> List String
topLevelDefCaptures scope def =
    case def of
        TOpt.Def _ _ bound _ ->
            exprCaptures scope bound

        TOpt.TailDef _ _ args body _ _ ->
            let
                names =
                    List.map (\( ln, _ ) -> A.toValue ln) args
            in
            bindAll scope names (\inner -> exprCaptures inner body)


{-| Returns the names in `names` that are already in `scope` or repeat an
earlier name of the list, followed by what `continue` returns for the scope
with all of `names` added.
-}
bindAll : Set Name -> List Name -> (Set Name -> List String) -> List String
bindAll scope names continue =
    let
        ( finalScope, captured ) =
            List.foldl
                (\n ( s, acc ) ->
                    if Set.member n s then
                        ( s, n :: acc )

                    else
                        ( Set.insert n s, acc )
                )
                ( scope, [] )
                names
    in
    List.reverse captured ++ continue finalScope


{-| Returns the captured binders in `expr`, walked with the local names of
`scope` in scope, as the module docstring describes.
-}
exprCaptures : Set Name -> TOpt.Expr id -> List String
exprCaptures scope expr =
    let
        same =
            exprCaptures scope
    in
    case expr of
        TOpt.Let (TOpt.Def _ n bound _) body _ ->
            bindAll scope [ n ] (\inner -> exprCaptures inner bound ++ exprCaptures inner body)

        TOpt.Let (TOpt.TailDef _ n args tailBody _ _) body _ ->
            bindAll scope
                [ n ]
                (\withName ->
                    bindAll withName (List.map (\( ln, _ ) -> A.toValue ln) args) (\inner -> exprCaptures inner tailBody)
                        ++ exprCaptures withName body
                )

        TOpt.Destruct (TOpt.Destructor n _ _) body _ ->
            bindAll scope [ n ] (\inner -> exprCaptures inner body)

        TOpt.Function _ params body _ ->
            bindAll scope (List.map Tuple.first params) (\inner -> exprCaptures inner body)

        TOpt.TrackedFunction _ params body _ ->
            bindAll scope (List.map (\( ln, _ ) -> A.toValue ln) params) (\inner -> exprCaptures inner body)

        TOpt.Case _ _ decider jumps _ ->
            List.concatMap (\( _, e ) -> same e) jumps ++ deciderCaptures scope decider

        TOpt.Call _ f args _ ->
            List.concatMap same (f :: args)

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, e ) -> same e) args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> same c ++ same t) branches ++ same final

        TOpt.List _ items _ ->
            List.concatMap same items

        TOpt.Access inner _ _ _ ->
            same inner

        TOpt.Update _ record fields _ ->
            same record ++ List.concatMap same (Data.Map.values fields)

        TOpt.Record fields _ ->
            List.concatMap same (Dict.values fields)

        TOpt.TrackedRecord _ fields _ ->
            List.concatMap same (Data.Map.values fields)

        TOpt.Tuple _ a b rest _ ->
            List.concatMap same (a :: b :: rest)

        _ ->
            []


{-| Returns the captured binders in the branch bodies a decision tree holds
inline, each walked in `scope`.
-}
deciderCaptures : Set Name -> TOpt.Decider (TOpt.Choice id) -> List String
deciderCaptures scope decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            exprCaptures scope e

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ yes no ->
            deciderCaptures scope yes ++ deciderCaptures scope no

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> deciderCaptures scope d) edges ++ deciderCaptures scope fallback
