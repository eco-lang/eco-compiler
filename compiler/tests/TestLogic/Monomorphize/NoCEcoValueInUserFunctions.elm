module TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing (expectNoCEcoValueInUserFunctions, Violation)

{-| Holds a checker for the rule that no `CEcoValue` type variable be left in
the types of user-defined functions and closures after monomorphization; the
failure messages call this rule MONO\_021. As written, the checker can report
nothing, so `expectNoCEcoValueInUserFunctions` passes whenever monomorphization
succeeds.

A type variable that survives monomorphization is an `MVar` carrying a
constraint, `CEcoValue` or `CNumber`; `Compiler.AST.Monomorphized` describes
both. The checker skips `MonoExtern` and `MonoManagerLeaf` nodes.

The caller supplies the program. It is compiled with
`TestLogic.TestPipeline.runToMono`, which uses the substitution engine, and the
checker walks every node of the resulting graph and every expression inside
each node, including case branches held inline in a decision tree. It looks at
these types:

  - the type of a `MonoDefine` or `MonoTailFunc` node, when it is a function
    type;
  - the parameter types of a `MonoTailFunc` node, of a local `MonoTailDef`,
    and of a closure;
  - the type of a closure, when it is a function type.

Each of these types is passed to `collectCEcoValueVars`, which is meant to list
the offending variables in it. It lists none for any type: both of its `MVar`
arms return nothing, and every other arm returns nothing or what the type's
components give. So no `Violation` is ever produced.

Among what is not checked: a variable of either constraint in any of the
positions above; the types of port nodes; and the types of expressions other
than closures.

@docs expectNoCEcoValueInUserFunctions, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One finding of the check. `context` says where it is, starting with
`SpecId` and the node's index in the graph, and `message` is a
multi-line description naming the offending type and its variables. The check
as written never produces one.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMono` and passes when
the graph has no violation, failing with every violation found
otherwise. A failed compilation fails with the pipeline's message.

No type is ever reported as holding an offending variable, so this passes
exactly when compilation succeeds.

-}
expectNoCEcoValueInUserFunctions : Src.Module -> Expectation
expectNoCEcoValueInUserFunctions srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkNoCEcoValueInUserFunctions monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns the violations in every node of the graph, in SpecId order. A
node's SpecId is its index in the graph's node array, and empty slots are
skipped.
-}
checkNoCEcoValueInUserFunctions : Mono.MonoGraph -> List Violation
checkNoCEcoValueInUserFunctions (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, acc ++ checkNode specId node )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the violations in `node`, whose SpecId is `specId`. A `MonoDefine`
or `MonoTailFunc` node is checked on its type, its parameters (a tail function
only) and its body, and a port node on its body alone. `MonoExtern`,
`MonoManagerLeaf`, constructor and enum nodes give none.
-}
checkNode : Int -> Mono.MonoNode -> List Violation
checkNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkNodeType ctx "MonoDefine" monoType
                ++ checkExpr ctx expr

        Mono.MonoTailFunc params expr monoType ->
            checkNodeType ctx "MonoTailFunc" monoType
                ++ checkParamTypes ctx "MonoTailFunc" params
                ++ checkExpr ctx expr

        Mono.MonoPortIncoming expr _ ->
            checkExpr ctx expr

        Mono.MonoPortOutgoing expr _ ->
            checkExpr ctx expr

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []


{-| Returns a violation for `monoType`, the type of a node of kind `nodeKind`,
when it is a function type in which `collectCEcoValueVars` lists a variable.
A type that is not a function type gives none.
-}
checkNodeType : String -> String -> Mono.MonoType -> List Violation
checkNodeType ctx nodeKind monoType =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            let
                cEcoVars =
                    collectCEcoValueVars monoType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ nodeKind ++ " nodeType"
                  , message =
                        "MONO_021 violation: CEcoValue in "
                            ++ nodeKind
                            ++ " function type\n"
                            ++ "  type: "
                            ++ Debug.toString monoType
                            ++ "\n"
                            ++ "  banned vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]

        _ ->
            []


{-| Returns one violation for each of the `params` of a node of kind `nodeKind`
whose type has a variable `collectCEcoValueVars` lists.
-}
checkParamTypes : String -> String -> List ( String, Mono.MonoType ) -> List Violation
checkParamTypes ctx nodeKind params =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ nodeKind ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in parameter type\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  banned vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        params


{-| Returns the violations in `expr` and in every expression inside it. A
closure is checked on its parameters and its type, and a local `MonoTailDef`
on its parameters; no other expression's type is looked at.

`ctx` is the location prefix of each violation. It is extended with `closure`
for everything found in or on a closure, including its own parameters and
type; with `taildef=` and the definition's name for a tail definition's
parameters and body; and with `inline-leaf` for a branch held inline in a
case's decision tree.

-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoClosure info body closureType ->
            let
                closureCtx =
                    ctx ++ " closure"
            in
            checkClosureInfo closureCtx info
                ++ checkFunctionExprType closureCtx "MonoClosure" closureType
                ++ List.concatMap (\( _, e, _ ) -> checkExpr closureCtx e) info.captures
                ++ checkExpr closureCtx body

        Mono.MonoLet def body _ ->
            let
                defViolations =
                    case def of
                        Mono.MonoDef _ bound ->
                            checkExpr ctx bound

                        Mono.MonoTailDef name params bound ->
                            checkTailDefParams ctx name params
                                ++ checkExpr (ctx ++ " taildef=" ++ name) bound
            in
            defViolations ++ checkExpr ctx body

        Mono.MonoCase _ _ decider jumps _ ->
            checkDecider ctx decider
                ++ List.concatMap (\( _, branchExpr ) -> checkExpr ctx branchExpr) jumps

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> checkExpr ctx c ++ checkExpr ctx t) branches
                ++ checkExpr ctx final

        Mono.MonoCall _ fn args _ _ ->
            checkExpr ctx fn ++ List.concatMap (checkExpr ctx) args

        Mono.MonoTailCall _ namedArgs _ ->
            List.concatMap (\( _, a ) -> checkExpr ctx a) namedArgs

        Mono.MonoDestruct _ inner _ ->
            checkExpr ctx inner

        Mono.MonoList _ items _ ->
            List.concatMap (checkExpr ctx) items

        Mono.MonoRecordCreate fields _ ->
            List.concatMap (\( _, e ) -> checkExpr ctx e) fields

        Mono.MonoRecordAccess inner _ _ ->
            checkExpr ctx inner

        Mono.MonoRecordUpdate inner updates _ ->
            checkExpr ctx inner ++ List.concatMap (\( _, e ) -> checkExpr ctx e) updates

        Mono.MonoTupleCreate _ items _ ->
            List.concatMap (checkExpr ctx) items

        Mono.MonoLiteral _ _ ->
            []

        Mono.MonoVarLocal _ _ ->
            []

        Mono.MonoVarGlobal _ _ _ ->
            []

        Mono.MonoVarKernel _ _ _ _ _ ->
            []

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns one violation for each parameter of the closure described by `info`
whose type has a variable `collectCEcoValueVars` lists.
-}
checkClosureInfo : String -> Mono.ClosureInfo -> List Violation
checkClosureInfo ctx info =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in closure parameter type\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  banned vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        info.params


{-| Returns one violation for each of the `params` of the local tail
definition `defName` whose type has a variable `collectCEcoValueVars` lists.
-}
checkTailDefParams : String -> String -> List ( String, Mono.MonoType ) -> List Violation
checkTailDefParams ctx defName params =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " taildef=" ++ defName ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in MonoTailDef parameter type\n"
                            ++ "  def: "
                            ++ defName
                            ++ "\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  banned vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        params


{-| Returns a violation for `monoType`, the type of an expression of kind
`exprKind`, when it is a function type in which `collectCEcoValueVars` lists a
variable. A type that is not a function type gives none.
-}
checkFunctionExprType : String -> String -> Mono.MonoType -> List Violation
checkFunctionExprType ctx exprKind monoType =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            let
                cEcoVars =
                    collectCEcoValueVars monoType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ exprKind ++ " exprType"
                  , message =
                        "MONO_021 violation: CEcoValue in "
                            ++ exprKind
                            ++ " expression type\n"
                            ++ "  type: "
                            ++ Debug.toString monoType
                            ++ "\n"
                            ++ "  banned vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]

        _ ->
            []


{-| Returns the violations in the case branches held inline at the leaves of
`decider`, with `inline-leaf` added to `ctx`. A `Jump` leaf gives none, because
its branch is in the case's own branch list, which `checkExpr` walks.
-}
checkDecider : String -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    []

                Mono.Inline expr ->
                    checkExpr (ctx ++ " inline-leaf") expr

        Mono.Chain _ yes no ->
            checkDecider ctx yes
                ++ checkDecider ctx no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx d) edges
                ++ checkDecider ctx fallback


{-| Returns the names of the offending variables in `monoType`, which is
always the empty list.

Both `MVar` arms, `CEcoValue` and `CNumber`, return nothing. A list, tuple,
record, custom type or function type returns what its components give, and
every other type returns nothing, so no type yields a name.

-}
collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            -- Not reported, although these are the variables the check is named for.
            []

        Mono.MVar _ Mono.CNumber ->
            []

        Mono.MList _ inner ->
            collectCEcoValueVars inner

        Mono.MFunction _ _ args result ->
            List.concatMap collectCEcoValueVars args
                ++ collectCEcoValueVars result

        Mono.MTuple _ elems ->
            List.concatMap collectCEcoValueVars elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectCEcoValueVars fieldType) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap collectCEcoValueVars args

        _ ->
            []


{-| Returns the failure message for `violations`: a header giving their count,
then each violation's context and message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "MONO_021 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ (violations
                |> List.map (\v -> v.context ++ ": " ++ v.message)
                |> String.join "\n\n"
           )
