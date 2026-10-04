module TestLogic.Generate.MonoNumericResolution exposing
    ( expectNoNumericPolymorphism
    , expectNumericTypesResolved
    )

{-| A `number` type variable stands for either `Int` or `Float`, and the two
are represented differently in generated code. `Compiler.AST.Monomorphized`
treats such a variable, an `MVar _ CNumber`, as a compiler bug if it reaches
MLIR code generation. The checks here look for one in a monomorphized program.
Any other type variable is an `MVar _ CEcoValue`, a variable whose values are
always boxed, and which may remain; both checks pass it, as they pass every
concrete type.

Each check runs one source module through `TestLogic.TestPipeline.runToMono`,
which needs the module to define `testValue`. The graph checked is the output
of the substitution engine, which is not the engine a default build uses, and
it is taken before any global optimization or MLIR generation. A pipeline
failure fails the check with the pipeline's message.

The substitution engine already enforces the rule. It finishes with
`Compiler.Monomorphize.Prune.pruneUnreachableSpecs`, which rewrites every
`MVar _ CNumber` in the types of the nodes it keeps to `MInt`, and crashes if
one survives. Every type these checks inspect is among those, so on a graph
`runToMono` returns they find nothing, and they pass whenever `runToMono`
succeeds.

  - `expectNoNumericPolymorphism` inspects the type of every node, of the
    expressions in it, of the parameters of tail functions, closures and tail
    definitions, and of each `let` definition. It skips expressions held inline
    in a case's decision tree and the type of an accessor value, except as a
    `let` definition's body.
  - `expectNumericTypesResolved` inspects only the type of each argument of
    each call and tail call.

Inside a type, both look through list element types, custom type arguments,
and function parameter and result types. A failing check reports one variable,
with the SpecId of the node it was found in, not every variable found.

Among what is not tested: a variable inside a tuple or record type, the field
types of a constructor node, the types in a case's decision tree, case branch
bodies held inline in the decision tree and the calls in them, the types in a
destructuring path or in a call's metadata, an accessor value's type except as
a `let` definition's body in the first check or as a call argument in the
second, the graph after global optimization, the generated MLIR, and the
solver engine.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Checks that the monomorphized graph of `srcModule` holds no
`MVar _ CNumber` in the type of any node or expression, in any tail function,
closure or tail definition parameter type, or in the type of any `let`
definition. A variable inside a tuple or record type, or inside a case branch
body held inline in the decision tree, is not reported, nor is one in an
accessor value's type unless the accessor is a `let` definition's body. It
fails with the pipeline's message when `runToMono` fails.
-}
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectCNumberChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Checks that the monomorphized graph of `srcModule` holds no
`MVar _ CNumber` in the type of any argument of a call or tail call. Calls in
case branch bodies held inline in the decision tree are not searched, and tuple
and record types are not looked into. It fails with the pipeline's message when
`runToMono` fails.
-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectCallSiteNumericChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- CHECKS OVER NODE AND EXPRESSION TYPES
-- ============================================================================


{-| Returns a failing check for each `MVar _ CNumber` found in the graph's
nodes, labelled with the SpecId of its node, which is the node's index in
`nodes`.
-}
collectCNumberChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCNumberChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, collectNodeCNumberChecks specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns a failing check for each `MVar _ CNumber` in `node`'s own type, in
a tail function's parameter types, and in the node's body as
`collectExprCNumberChecks` walks it.
`specId` only labels the failures.
-}
collectNodeCNumberChecks : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
collectNodeCNumberChecks specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr

        Mono.MonoTailFunc params expr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberChecks context expr

        Mono.MonoCtor _ monoType ->
            checkForCNumber context monoType

        Mono.MonoEnum _ monoType ->
            checkForCNumber context monoType

        Mono.MonoExtern monoType ->
            checkForCNumber context monoType

        Mono.MonoManagerLeaf _ monoType ->
            checkForCNumber context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr


{-| Returns a failing check for each `MVar _ CNumber` in the type of `expr` or
of any expression inside it, in closure parameter types, and in `let`
definitions. A case is followed only into the branch bodies in its jump list;
bodies held inline in its decision tree are not visited. The types in a
case's decision tree, a destructuring path or a call's metadata, and an
accessor value's type unless it is a `let` definition's body, are not
inspected.
-}
collectExprCNumberChecks : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprCNumberChecks context expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarLocal _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarGlobal _ _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarKernel _ _ _ _ monoType ->
            checkForCNumber context monoType

        Mono.MonoList _ exprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberChecks context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) closureInfo.params
                ++ List.concatMap (\( _, captureExpr, _ ) -> collectExprCNumberChecks context captureExpr) closureInfo.captures
                ++ collectExprCNumberChecks context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType _ ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context fnExpr
                ++ List.concatMap (collectExprCNumberChecks context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, argExpr ) -> collectExprCNumberChecks context argExpr) args

        Mono.MonoIf branches elseExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( condExpr, thenExpr ) -> collectExprCNumberChecks context condExpr ++ collectExprCNumberChecks context thenExpr) branches
                ++ collectExprCNumberChecks context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkForCNumber context monoType
                ++ collectDefCNumberChecks context def
                ++ collectExprCNumberChecks context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, branchExpr ) -> collectExprCNumberChecks context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, e ) -> collectExprCNumberChecks context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCNumberChecks context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberChecks context) elementExprs

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns a failing check for each `MVar _ CNumber` in a `let` definition's
type, in a tail definition's parameter types, and in its body.

The definition's type is taken to be its body's type, which
`collectExprCNumberChecks` also inspects, so a variable there is reported
twice, except when the body is an accessor value, whose type only this function
checks.

-}
collectDefCNumberChecks : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefCNumberChecks context def =
    case def of
        Mono.MonoDef _ expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ collectExprCNumberChecks context expr

        Mono.MonoTailDef _ params expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberChecks context expr


{-| Returns one failing check, labelled with `context` and the variable's id,
for each `MVar _ CNumber` in `monoType`. It looks through list element types,
custom type arguments, and function parameter and result types, but not into
tuple or record types.
-}
checkForCNumber : String -> Mono.MonoType -> List (() -> Expect.Expectation)
checkForCNumber context monoType =
    case monoType of
        Mono.MVar mvarId Mono.CNumber ->
            [ \() -> Expect.fail (context ++ ": Unresolved numeric type variable '" ++ String.fromInt (Id.toComparable mvarId) ++ "' with CNumber constraint") ]

        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MList _ elemType ->
            checkForCNumber context elemType

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkForCNumber context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkForCNumber context) paramTypes
                ++ checkForCNumber context returnType

        _ ->
            []



-- ============================================================================
-- CHECKS OVER CALL ARGUMENT TYPES
-- ============================================================================


{-| Returns a failing check for each `MVar _ CNumber` in the type of a call or
tail-call argument in the graph's nodes, except calls in case bodies held
inline in a decision tree, labelled with the SpecId of its node, which is the
node's index in `nodes`.
-}
collectCallSiteNumericChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCallSiteNumericChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, collectNodeCallSiteChecks specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the failing call-argument checks for the body of `node`. A
constructor, enum, extern or manager-leaf node has no body and gives none.
`specId` only labels the failures.
-}
collectNodeCallSiteChecks : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
collectNodeCallSiteChecks specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoPortIncoming expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprCallSiteChecks context expr


{-| Returns a failing check for each `MVar _ CNumber` in the type of an
argument of a call or tail call within `expr`. Each failure names the argument
by its position in the call or, for a tail call, by its parameter name. The
search for calls goes into closures, `if`s, `let`s, destructuring, the case
branch bodies in a case's jump list (not those inline in its decision tree),
records, tuples and lists, into the function and arguments of a call, and into
tail-call arguments.
-}
collectExprCallSiteChecks : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprCallSiteChecks context expr =
    case expr of
        Mono.MonoCall _ fnExpr argExprs _ _ ->
            let
                argChecks =
                    List.indexedMap
                        (\idx argExpr ->
                            let
                                argType =
                                    Mono.typeOf argExpr
                            in
                            checkNumericTypeResolved (context ++ ", call arg " ++ String.fromInt idx) argType
                        )
                        argExprs
                        |> List.concat
            in
            argChecks
                ++ collectExprCallSiteChecks context fnExpr
                ++ List.concatMap (collectExprCallSiteChecks context) argExprs

        Mono.MonoTailCall _ args _ ->
            let
                argChecks =
                    List.concatMap
                        (\( name, argExpr ) ->
                            let
                                argType =
                                    Mono.typeOf argExpr
                            in
                            checkNumericTypeResolved (context ++ ", tail call arg " ++ name) argType
                        )
                        args
            in
            argChecks
                ++ List.concatMap (\( _, argExpr ) -> collectExprCallSiteChecks context argExpr) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCallSiteChecks context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, captureExpr, _ ) -> collectExprCallSiteChecks context captureExpr) closureInfo.captures
                ++ collectExprCallSiteChecks context bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( condExpr, thenExpr ) -> collectExprCallSiteChecks context condExpr ++ collectExprCallSiteChecks context thenExpr) branches
                ++ collectExprCallSiteChecks context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCallSiteChecks context def
                ++ collectExprCallSiteChecks context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCallSiteChecks context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprCallSiteChecks context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprCallSiteChecks context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprCallSiteChecks context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprCallSiteChecks context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCallSiteChecks context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprCallSiteChecks context) elementExprs

        _ ->
            []


{-| Returns the failing call-argument checks for the body of a `let`
definition.
-}
collectDefCallSiteChecks : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefCallSiteChecks context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCallSiteChecks context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprCallSiteChecks context expr


{-| Returns one failing check, labelled with `context` and the variable's id,
for each `MVar _ CNumber` in `monoType`. It looks into types exactly as
`checkForCNumber` does, not into tuple or record types, and differs from it
only in the failure message.
-}
checkNumericTypeResolved : String -> Mono.MonoType -> List (() -> Expect.Expectation)
checkNumericTypeResolved context monoType =
    case monoType of
        Mono.MVar mvarId Mono.CNumber ->
            [ \() -> Expect.fail (context ++ ": Numeric type variable '" ++ String.fromInt (Id.toComparable mvarId) ++ "' not resolved to MInt or MFloat") ]

        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MList _ elemType ->
            checkNumericTypeResolved context elemType

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkNumericTypeResolved context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkNumericTypeResolved context) paramTypes
                ++ checkNumericTypeResolved context returnType

        _ ->
            []
