module TestLogic.Monomorphize.LocalUseEnrichment exposing
    ( Found
    , check
    , expectLocalUsesEnriched
    )

{-| A check that, once the solver engine has monomorphized a program with
lambda-set specialization on, each use of a let-bound name carries the
lambda-set annotations of the definition it refers to. A use left with ⊤ where
its definition has a set is still sound, only less precise, so the compiled
program would not show the loss.

A lambda-set annotation, defined in `Compiler.IR.Mono`, says which function
values can flow through an arrow of a function type; an `LSet` lists the ones
that can flow, and ⊤ means the analysis could not bound the set. The solver
translates the body of a `let` that binds a function before the function
itself, so each use is emitted with a type whose annotations can be weaker than
those of the instance it is bound to. Only afterwards is the right-hand side
translated, once for each type the function is used at, giving one definition
per instance (`f`, `f$1`, ...), or once at its declared type if it is unused; a
tail-recursive function gets a single definition. Copying each instance's
annotations onto its uses is _use enrichment_, and `flushLocalMultiEnrich` in
`Compiler.Monomorphize.Solver.Translate` does it; a let-function in the body
of another hands its enrichment to the enclosing one, so that the outermost
does it for all of them in a single walk of its body.

The property is this: for a use `MonoVarLocal n t` in the body of a `let` whose
definition is `MonoDef n rhs`, `Mono.overlayAnnotations t (Mono.typeOf rhs)`
equals `t`, that is, copying the definition's annotations onto the use's type
changes nothing. Every `MonoDef` is bound, plain values as well as functions,
and only for the body of its `let`, not for its own right-hand side. A
`MonoTailDef` binds nothing in the check, so uses of its name are not checked.
Every node of the graph is walked, not only `testValue`.

`expectLocalUsesEnriched` monomorphizes a program with
`TestLogic.TestPipeline.runToMono`, under the default configuration (the
solver engine, lambda-set specialization on), and fails on any use that
disagrees with its definition. `check` returns what the walk found in a graph,
for tests that also want to know that a program had something to check.

Among what is not checked: the substitution engine, or the solver with
lambda-set specialization off; whether the sets are the right ones, rather than
the same on the use as on the definition; uses of a name inside its own
right-hand side; names bound by a `MonoTailDef` or by destructuring.

-}

import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` monomorphizes and `check` finds no use that
disagrees with its definition in the graph; fails with the pipeline's message,
or with one line per disagreeing use.
-}
expectLocalUsesEnriched : Src.Module -> Expect.Expectation
expectLocalUsesEnriched srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            case (check monoGraph).violations of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (String.join "\n" violations)


{-| What `check` has gathered so far from a graph.

`violations` holds one message per use whose type copying the definition's
annotations would change, newest first. `enriched` counts the uses that agree
with their definition and whose definition has an `LSet` on its outermost arrow.
`defs` names each `MonoDef` met, with its right-hand side's type, newest first.

-}
type alias Found =
    { violations : List String, enriched : Int, defs : List String }


{-| Returns what `checkExpr` finds in every expression of every node of the
graph, each walked with no names bound. Only define, tail-function and port
nodes hold expressions.
-}
check : Mono.MonoGraph -> Found
check (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Nothing ->
                    acc

                Just node ->
                    List.foldl (checkExpr Dict.empty) acc (nodeExprs node)
        )
        { violations = [], enriched = 0, defs = [] }
        data.nodes


{-| Adds to `acc` what is found in `expr`, given `env`, which maps each name
bound by an enclosing `MonoDef` to the type of its right-hand side.

A use of a name in `env` is recorded as a violation if overlaying the
definition's annotations changes its type, and otherwise counted in `enriched`
when the definition's outermost arrow has an `LSet`. A use of any other name is
ignored. A `MonoDef` is checked under `env` and binds its name for the `let`
body only. A `let` of a `MonoTailDef`, like every other expression, has its
children walked under the same `env`, so its name is never bound. Nothing is
removed from `env` either, so a lambda parameter or destructured name is not
told apart from an enclosing `MonoDef` of the same name.

-}
checkExpr : Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Found -> Found
checkExpr env expr acc =
    case expr of
        Mono.MonoVarLocal n t ->
            case Dict.get n env of
                Just src ->
                    if Mono.overlayAnnotations t src == t then
                        { acc | enriched = acc.enriched + boolToInt (headIsSet src) }

                    else
                        { acc
                            | violations =
                                ("use of `" ++ n ++ "` is not enriched: " ++ Mono.monoTypeToDebugString t ++ "  vs def  " ++ Mono.monoTypeToDebugString src)
                                    :: acc.violations
                        }

                Nothing ->
                    acc

        Mono.MonoLet (Mono.MonoDef n rhs) body _ ->
            let
                seen =
                    { acc | defs = (n ++ " : " ++ Mono.monoTypeToDebugString (Mono.typeOf rhs)) :: acc.defs }
            in
            checkExpr (Dict.insert n (Mono.typeOf rhs) env) body (checkExpr env rhs seen)

        _ ->
            List.foldl (checkExpr env) acc (MonoTraverse.childrenOf expr)


{-| Returns whether `t` is a function type whose outermost arrow is annotated
with an `LSet`, of any size, the empty set included.
-}
headIsSet : Mono.MonoType -> Bool
headIsSet t =
    case t of
        Mono.MFunction _ (Mono.LSet _) _ _ ->
            True

        _ ->
            False


{-| Returns 1 for `True` and 0 for `False`.
-}
boolToInt : Bool -> Int
boolToInt b =
    if b then
        1

    else
        0


{-| Returns the expression a node holds: the body of a define or a tail
function, or a port's expression. Constructor, enum, extern and effect-manager
leaf nodes hold none.
-}
nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []
