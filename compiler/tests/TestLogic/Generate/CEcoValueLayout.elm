module TestLogic.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)

{-| A checker for the rule that no type variable left open by
monomorphization decides how a value is laid out at run time (MONO\_003 with
MONO\_002).

After monomorphization a `MonoType` can still contain a type variable, an
`MVar`, with one of two constraints (`Compiler.AST.Monomorphized`,
`Constraint`). A `CEcoValue` variable stands for a value the back end always
holds as a boxed `eco.value`, so it can sit anywhere, a constructor field or a
function parameter included, without deciding a layout or a calling
convention: MONO\_003 allows it. A `CNumber` variable is a `number` not yet
decided between `Int` and `Float`, which are stored unboxed and differently,
so it would decide layout; MONO\_002 and MONO\_028 require
`Compiler.Monomorphize.Prune` to close every such variable before the graph
leaves monomorphization.

`expectValidCEcoValueLayout` runs a source module through the test pipeline as
far as monomorphization (`TestLogic.TestPipeline.runToMono`) and reports every
`MVar _ CNumber`, at any depth, in:

  - each node's type, and the parameter types of tail functions;
  - each constructor node's field types, and the field types of every shape in
    the graph's `ctorShapes`;
  - the type of every expression in a node's body, as
    `Compiler.Monomorphize.MonoTraverse.foldExpr` visits them (the inline
    leaves of a `case`'s decision tree included), the parameter types of each
    closure and let-bound tail definition, and the type of each destructor.

The walk is built on the expression walk, not on the type walk
(`MonoTraverse.anyNodeType` / `mapNodeTypes`) that `Prune` itself uses to
close the variables, so it is an independent check of that closing.

Not checked: decision-tree and destructor path types, call ABI records, and
where a `CEcoValue` variable appears (which MONO\_003 allows anywhere).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through the test pipeline to monomorphization and passes
when no type the walk visits holds an `MVar _ CNumber`.

A pipeline error fails with the pipeline's message, and found issues fail with
one issue per line.

-}
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
expectValidCEcoValueLayout srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                issues =
                    collectCEcoValueLayoutIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- RESIDUAL NUMBER VARIABLE CHECK
-- ============================================================================


{-| Returns the issues found in every node of the graph, each labelled with the
SpecId of its node, followed by those in the graph's constructor shapes.
-}
collectCEcoValueLayoutIssues : Mono.MonoGraph -> List String
collectCEcoValueLayoutIssues (Mono.MonoGraph data) =
    let
        nodeIssues =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just node ->
                            ( specId + 1, checkNode specId node ++ acc )
                )
                ( 0, [] )
                data.nodes
                |> Tuple.second

        shapeIssues =
            Mono.layoutMapValues data.ctorShapes
                |> List.concat
                |> List.concatMap (\shape -> checkTypes ("ctorShapes " ++ shape.name) shape.fieldTypes)
    in
    nodeIssues ++ shapeIssues


{-| Returns the issues in one node, labelled `SpecId <specId>`.
-}
checkNode : Int -> Mono.MonoNode -> List String
checkNode specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkType context monoType
                ++ checkExprTree context expr

        Mono.MonoTailFunc params expr monoType ->
            checkType context monoType
                ++ checkTypes (context ++ " parameter") (List.map Tuple.second params)
                ++ checkExprTree context expr

        Mono.MonoCtor ctorShape monoType ->
            checkTypes (context ++ " constructor field") ctorShape.fieldTypes
                ++ checkType context monoType

        Mono.MonoEnum _ monoType ->
            checkType context monoType

        Mono.MonoExtern monoType ->
            checkType context monoType

        Mono.MonoManagerLeaf _ monoType ->
            checkType context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkType context monoType
                ++ checkExprTree context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkType context monoType
                ++ checkExprTree context expr


{-| Returns the issues in every expression of `expr`, itself included: its
type, and the parameter types of a closure or a let-bound tail definition, and
the type of a destructor.
-}
checkExprTree : String -> Mono.MonoExpr -> List String
checkExprTree context expr =
    MonoTraverse.foldExpr (\e acc -> checkOneExpr context e ++ acc) [] expr


{-| Returns the issues held directly by one expression, not by its children.
-}
checkOneExpr : String -> Mono.MonoExpr -> List String
checkOneExpr context expr =
    let
        extra =
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    checkTypes (context ++ " closure parameter") (List.map Tuple.second closureInfo.params)

                Mono.MonoLet (Mono.MonoTailDef name params _) _ _ ->
                    checkTypes (context ++ " parameter of " ++ name) (List.map Tuple.second params)

                Mono.MonoDestruct (Mono.MonoDestructor name _ destructType) _ _ ->
                    checkType (context ++ " destructor " ++ name) destructType

                _ ->
                    []
    in
    checkType (context ++ " expression") (Mono.typeOf expr) ++ extra


{-| Returns the issues in each of `types`.
-}
checkTypes : String -> List Mono.MonoType -> List String
checkTypes context types =
    List.concatMap (checkType context) types


{-| Returns one issue, prefixed with `context`, if `monoType` holds an
`MVar _ CNumber` at any depth.
-}
checkType : String -> Mono.MonoType -> List String
checkType context monoType =
    if hasNumberVar monoType then
        [ context ++ ": residual number variable in a type that reaches code generation" ]

    else
        []


{-| True when `monoType` holds an `MVar _ CNumber` at any depth.
-}
hasNumberVar : Mono.MonoType -> Bool
hasNumberVar monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ elemType ->
            hasNumberVar elemType

        Mono.MTuple _ elementTypes ->
            List.any hasNumberVar elementTypes

        Mono.MRecord _ fields ->
            List.any hasNumberVar (Dict.values fields)

        Mono.MCustom _ _ _ typeArgs ->
            List.any hasNumberVar typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.any hasNumberVar paramTypes || hasNumberVar returnType

        _ ->
            False
