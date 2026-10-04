module TestLogic.Generate.DebugPolymorphism exposing (expectDebugPolymorphismResolved)

{-| A `Debug` kernel function such as `Debug.log` or `Debug.toString` accepts a
value of any type, so once a program is monomorphized the type variables left
in its uses should be boxed values or have become concrete types. This module
holds the check that none of them is still a number variable.

In a `MonoType`, a type variable that monomorphization has not replaced is an
`MVar` carrying a constraint, as `Compiler.AST.Monomorphized` describes. A
`CEcoValue` variable stands for a value that is always boxed, and may remain
until code generation. A `CNumber` variable is known only to be `Int` or
`Float`, and has to be resolved before code generation.

`expectDebugPolymorphismResolved` runs a test program to the monomorphized
graph with `TestLogic.TestPipeline.runToMono` and walks the expression of
every node that has one. It examines two kinds of type: the function type of
each reference to a kernel function whose home module is `Debug`, and the type
of each argument of a call whose function is such a reference. In those types it
reports every `MVar _ CNumber`, looking inside list element types, the
arguments of custom types, and the parameter and result types of functions. A
`CEcoValue` variable and a concrete type both pass, and a program with no
`Debug` kernel reference passes as long as it compiles.

The graph `runToMono` returns has already been through
`Compiler.Monomorphize.Prune`, which closes residual number variables to
`MInt` in the nodes it keeps, so a `CNumber` found here is one that closing
did not reach.

Among what is not checked: the element types of tuples and the field types of
records are not looked inside; the branch expressions held inline in a `case`
expression's decision tree are not walked, only its jump targets; and nothing
is run, so the values `Debug` functions print or return are not examined.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Checks that, in the monomorphized graph of `srcModule`, no reference to a
`Debug` kernel function and no argument of a call to one has a `CNumber` type
variable in its type, looking where the module docstring describes.

It fails with the pipeline's message if `runToMono` fails. Otherwise it passes
when there is no such variable, and fails with one line per occurrence of one,
naming the node's `SpecId`, the `Debug` function, and the parameter, result or
call argument the variable is in, with positions counted from 0.

-}
expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
expectDebugPolymorphismResolved srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                issues =
                    collectDebugPolymorphismIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- DEBUG POLYMORPHISM VERIFICATION
-- ============================================================================


{-| Returns the problem lines for every node of the graph, labelling each node
with its index in the node array, which is its `SpecId`. Empty slots are
skipped. The lines of a later node come before those of an earlier one.
-}
collectDebugPolymorphismIssues : Mono.MonoGraph -> List String
collectDebugPolymorphismIssues (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeDebugPolymorphism specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the problem lines for the expression of one node, each prefixed with
`SpecId` followed by the value of `specId`. A node with no expression (a
constructor, enum, extern or effect-manager leaf) gives none.
-}
checkNodeDebugPolymorphism : Int -> Mono.MonoNode -> List String
checkNodeDebugPolymorphism specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprDebugIssues context expr

        _ ->
            []


{-| Returns the problem lines for `expr` and every expression inside it: those
for the type of each `Debug` kernel reference, and those for the argument types
of each call whose function is a `Debug` kernel reference.

The branch expressions held inline in a `case` decision tree are not visited,
only the `case`'s jump targets.

-}
collectExprDebugIssues : String -> Mono.MonoExpr -> List String
collectExprDebugIssues context expr =
    case expr of
        Mono.MonoVarKernel _ _ moduleName name monoType ->
            if moduleName == "Debug" then
                checkDebugKernelType context name monoType

            else
                []

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            let
                debugCallIssues =
                    case fnExpr of
                        Mono.MonoVarKernel _ _ moduleName name _ ->
                            if moduleName == "Debug" then
                                checkDebugCallArgs context name argExprs

                            else
                                []

                        _ ->
                            []
            in
            debugCallIssues
                ++ collectExprDebugIssues context fnExpr
                ++ List.concatMap (collectExprDebugIssues context) argExprs

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprDebugIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprDebugIssues context e) closureInfo.captures
                ++ collectExprDebugIssues context bodyExpr

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprDebugIssues context c ++ collectExprDebugIssues context t) branches
                ++ collectExprDebugIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefDebugIssues context def
                ++ collectExprDebugIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprDebugIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprDebugIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprDebugIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprDebugIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprDebugIssues context) elementExprs

        _ ->
            []


{-| Returns the problem lines for the body of a `let` definition.
-}
collectDefDebugIssues : String -> Mono.MonoDef -> List String
collectDefDebugIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprDebugIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprDebugIssues context expr


{-| Returns the problem lines for the type of a reference to the `Debug` kernel
function `name`: one for each `CNumber` variable that `checkNoCNumberInDebugArg`
finds in its result type and in each of its parameter types. A type that is not
a function type gives none.
-}
checkDebugKernelType : String -> String -> Mono.MonoType -> List String
checkDebugKernelType context name monoType =
    case monoType of
        Mono.MFunction _ _ paramTypes returnType ->
            checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " return") returnType
                ++ (List.indexedMap
                        (\idx paramType ->
                            checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " param " ++ String.fromInt idx) paramType
                        )
                        paramTypes
                        |> List.concat
                   )

        _ ->
            []


{-| Returns the problem lines for the arguments of a call to the `Debug` kernel
function `name`: one for each `CNumber` variable that `checkNoCNumberInDebugArg`
finds in each argument's type.
-}
checkDebugCallArgs : String -> String -> List Mono.MonoExpr -> List String
checkDebugCallArgs context name argExprs =
    List.indexedMap
        (\idx argExpr ->
            let
                argType =
                    Mono.typeOf argExpr
            in
            checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " call arg " ++ String.fromInt idx) argType
        )
        argExprs
        |> List.concat


{-| Returns one problem line, prefixed with `context`, for each `CNumber`
variable in `monoType`, looking inside list element types, custom-type
arguments, and function parameter and result types. Tuple element and record
field types are not looked inside.
-}
checkNoCNumberInDebugArg : String -> Mono.MonoType -> List String
checkNoCNumberInDebugArg context monoType =
    case monoType of
        Mono.MVar mvarId Mono.CNumber ->
            [ context ++ ": Found CNumber constraint on type variable '" ++ String.fromInt (Id.toComparable mvarId) ++ "' in Debug call (should be CEcoValue or concrete type)" ]

        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MList _ elemType ->
            checkNoCNumberInDebugArg context elemType

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkNoCNumberInDebugArg context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkNoCNumberInDebugArg context) paramTypes
                ++ checkNoCNumberInDebugArg context returnType

        _ ->
            []
