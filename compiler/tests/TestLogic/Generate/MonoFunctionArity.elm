module TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)

{-| Checks a program that has been through the global optimizer for functions
whose parameter lists disagree with the arity of their types, and for calls
that pass a function more arguments than its type accepts. Without it, a
monomorphized graph in which the two disagree would pass unnoticed to code
generation.

In the monomorphized IR (`Compiler.AST.Monomorphized`) a function type is an
`MFunction` holding a list of parameter types and a result type, and that
result may itself be an `MFunction`. Each `MFunction` layer is a _stage_, and a
type has two arities:

  - its _stage arity_, the number of parameters of its outermost `MFunction`,
    or 0 for a type that is not an `MFunction`;
  - its _flattened arity_, the number of parameters in all its stages
    together, found by following each stage's result while it is an
    `MFunction`.

`expectFunctionArityMatches` is the check. It compiles the module it is given
with `TestLogic.TestPipeline.runToGlobalOpt`, which monomorphizes with the
substitution engine and then runs the post-monomorphization inliner and the
global optimizer, and it examines every `MonoDefine`, `MonoTailFunc`,
`MonoPortIncoming` and `MonoPortOutgoing` node of the optimized graph. It
reports:

  - a `MonoClosure` whose parameter count differs from the stage arity of its
    own type, found anywhere in the expressions it walks, including a
    closure's captured expressions and the inline leaves of a `case` decision
    tree;
  - a `MonoDefine` node whose body is itself a `MonoClosure` with a parameter
    count different from the stage arity of the node's type;
  - a `MonoTailFunc` node whose parameter count differs from the flattened
    arity of its type;
  - a `MonoCall` with more arguments than the flattened arity of its callee's
    type, when that arity is above 0. A call with fewer arguments, a partial
    application, is accepted.

Each message names the SpecId of the node it was found in. A closure that is
the whole body of a `MonoDefine` is compared with both the node's type and its
own, so one mismatch there can be reported twice.

Among what is not checked:

  - the parameters of a `MonoTailDef` in a `let`, of which only the body is
    walked;
  - a call whose callee type is not an `MFunction`;
  - nodes of any other kind, such as constructors and externs.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Creates an expectation that passes when `srcModule` compiles through the
global optimizer and the optimized graph has none of the arity mismatches
listed in the module docstring.

It fails with the error message when `runToGlobalOpt` returns an error, and
otherwise with one line per mismatch found.
`srcModule` must define `testValue`, as `TestLogic.TestPipeline` describes.

-}
expectFunctionArityMatches : Src.Module -> Expect.Expectation
expectFunctionArityMatches srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectArityIssues optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- FUNCTION ARITY VERIFICATION
-- ============================================================================


{-| Returns a message for every arity mismatch in the nodes of the graph, each
prefixed with the SpecId of its node, which is the node's index in the array.
Empty slots are skipped.
-}
collectArityIssues : Mono.MonoGraph -> List String
collectArityIssues (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeArity specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns a message for every arity mismatch in `node`, the node at `specId`.

A `MonoDefine` is checked with `checkTypeExprArityConsistency` and then walked;
a `MonoTailFunc`'s parameter count is compared with the flattened arity of its
type and its body is walked; a port node's expression is walked. Any other node
gives nothing.

-}
checkNodeArity : Int -> Mono.MonoNode -> List String
checkNodeArity specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkTypeExprArityConsistency context monoType expr
                ++ collectExprArityIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            let
                paramCount =
                    List.length params

                typeArity =
                    getFlattenedArity monoType

                arityIssue =
                    if typeArity /= paramCount then
                        [ context ++ ": MonoTailFunc has " ++ String.fromInt paramCount ++ " params but type has arity " ++ String.fromInt typeArity ]

                    else
                        []
            in
            arityIssue ++ collectExprArityIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprArityIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprArityIssues context expr

        _ ->
            []


{-| Returns the parameter types of all the stages of `monoType`, outermost
first, and the result type that is left once no stage remains.

A type whose outer stage takes `[a]` and returns a stage taking `[b]` and
returning `c` gives `( [a, b], c )`. A type that is not an `MFunction` gives no
parameters and itself.

-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ params result ->
            let
                ( innerParams, innerResult ) =
                    flattenFunctionType result
            in
            ( params ++ innerParams, innerResult )

        _ ->
            ( [], monoType )


{-| Returns the flattened arity of `monoType`: the number of parameters in all
its stages together, 0 for a type that is not an `MFunction`.
-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    let
        ( params, _ ) =
            flattenFunctionType monoType
    in
    List.length params


{-| Returns the stage arity of `monoType`: the number of parameters of its
outermost `MFunction`, 0 for a type that is not an `MFunction`.

A closure's parameter list is compared with this count, not with the
flattened arity, because a closure takes only its first stage of arguments.

-}
getStageArity : Mono.MonoType -> Int
getStageArity monoType =
    case monoType of
        Mono.MFunction _ _ params _ ->
            List.length params

        _ ->
            0


{-| Returns a message when `expr` is a `MonoClosure` whose parameter count
differs from the stage arity of `monoType`, the type it is declared with
outside the expression. Any other expression gives nothing, and nothing inside
`expr` is examined.
-}
checkTypeExprArityConsistency : String -> Mono.MonoType -> Mono.MonoExpr -> List String
checkTypeExprArityConsistency context monoType expr =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity monoType
            in
            if paramCount /= stageArity then
                [ context ++ ": Closure has " ++ String.fromInt paramCount ++ " params but type has stage arity " ++ String.fromInt stageArity ++ " (GOPT_001 violation)" ]

            else
                []

        _ ->
            []


{-| Returns a message, prefixed with `context`, for every arity mismatch in
`expr` and the expressions inside it.

A `MonoClosure` is reported when its parameter count differs from the stage
arity of its own type. A `MonoCall` is reported when it has more arguments
than the flattened arity of its callee's type and that arity is above 0;
fewer arguments, a partial application, is accepted. Every subexpression is
walked, including a closure's captured expressions, the callee of a call, and
both the decision tree and the branches of a `case`.

-}
collectExprArityIssues : String -> Mono.MonoExpr -> List String
collectExprArityIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr monoType ->
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity monoType

                closureIssue =
                    if paramCount /= stageArity then
                        [ context ++ ": Closure expression has " ++ String.fromInt paramCount ++ " params but its type has stage arity " ++ String.fromInt stageArity ++ " (GOPT_001 violation)" ]

                    else
                        []
            in
            closureIssue
                ++ List.concatMap (\( _, e, _ ) -> collectExprArityIssues context e) closureInfo.captures
                ++ collectExprArityIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            let
                fnType =
                    Mono.typeOf fnExpr

                fnArity =
                    getFlattenedArity fnType

                argCount =
                    List.length argExprs

                callIssue =
                    if fnArity > 0 && argCount > fnArity then
                        [ context ++ ": Call has " ++ String.fromInt argCount ++ " args but function has arity " ++ String.fromInt fnArity ]

                    else
                        []
            in
            callIssue
                ++ collectExprArityIssues context fnExpr
                ++ List.concatMap (collectExprArityIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprArityIssues context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprArityIssues context c ++ collectExprArityIssues context t) branches
                ++ collectExprArityIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefArityIssues context def
                ++ collectExprArityIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprArityIssues context valueExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderArityIssues context decider
                ++ List.concatMap (\( _, e ) -> collectExprArityIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprArityIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprArityIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprArityIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprArityIssues context) elementExprs

        _ ->
            []


{-| Returns a message, prefixed with `context`, for every arity mismatch in the
body of a `let` definition. A `MonoTailDef`'s parameters are not compared with
anything.
-}
collectDefArityIssues : String -> Mono.MonoDef -> List String
collectDefArityIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprArityIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprArityIssues context expr


{-| Returns a message for every arity mismatch in the expressions inlined at
the leaves of a `case` decision tree, with `inline-leaf` added to `context`.
-}
collectDeciderArityIssues : String -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderArityIssues context decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprArityIssues (context ++ " inline-leaf") expr

                Mono.Jump _ ->
                    -- The jump's target is in the case's branch list, which
                    -- collectExprArityIssues walks.
                    []

        Mono.Chain _ success failure ->
            collectDeciderArityIssues context success
                ++ collectDeciderArityIssues context failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderArityIssues context d) edges
                ++ collectDeciderArityIssues context fallback
