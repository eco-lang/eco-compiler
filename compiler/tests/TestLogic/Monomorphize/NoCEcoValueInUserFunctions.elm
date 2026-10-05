module TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing (expectNoResidualNumberVars, Violation)

{-| Checks that no `number` type variable, `MVar _ CNumber`, is left anywhere
in a monomorphized graph, since such a variable must not reach code
generation (invariant MONO\_002).

This is the check invariant MONO\_021 names. MONO\_021 once asked that no
`CEcoValue` variable be left in the types of user functions and closures; it
now states the opposite, by design: as `Compiler.AST.Monomorphized` describes
`Constraint`, a `CEcoValue` variable stands for a value that is always boxed
and may reach code generation, and type variables nothing fixes keep one. The
only forbidden residual is a `CNumber` variable (MONO\_002):
`Compiler.Monomorphize.Prune` closes every residual number variable to `MInt`
(MONO\_028) and crashes if one survives the close in a node. That crash is detected with
the same node walk (`MonoTraverse.anyNodeType`) that does the closing, so a
type the walk misses is neither closed nor detected; the walk here is written
independently of it.

The caller supplies the program. It is compiled with
`TestLogic.TestPipeline.runToMono`, which uses the substitution engine. The
check looks at these types, at any depth inside them:

  - the type of every node, and the parameter types of a `MonoTailFunc`;
  - the type of every expression in every node body, as `Mono.typeOf` gives
    it, including closure captures, `let` definitions and case branches held
    inline in a decision tree or in its jump list;
  - the parameter types of every closure and of every local `MonoTailDef`.

Among what is not checked: the types written on decision-tree paths and on
call metadata, `CEcoValue` variables anywhere, and the graph after global
optimization.

@docs expectNoResidualNumberVars, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One type holding a residual number variable. `context` says where it is,
starting with `SpecId` and the node's index in the graph, and `message` gives
the type.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMono` and passes when
no type the module docstring lists holds an `MVar _ CNumber`, failing with
every such type otherwise. A failed compilation fails with the pipeline's
message.
-}
expectNoResidualNumberVars : Src.Module -> Expectation
expectNoResidualNumberVars srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            case checkGraph monoGraph of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (formatViolations violations)


{-| Returns the violations in every node of the graph, in SpecId order.
-}
checkGraph : Mono.MonoGraph -> List Violation
checkGraph (Mono.MonoGraph data) =
    List.concatMap
        (\( specId, maybeNode ) ->
            case maybeNode of
                Just node ->
                    checkNode ("SpecId " ++ String.fromInt specId) node

                Nothing ->
                    []
        )
        (Array.toIndexedList data.nodes)


{-| Returns the violations in `node`: its own type, a tail function's
parameters, and the expressions of its body.
-}
checkNode : String -> Mono.MonoNode -> List Violation
checkNode ctx node =
    checkType ctx "node type" (Mono.nodeType node)
        ++ (case node of
                Mono.MonoDefine expr _ ->
                    checkExpr ctx expr

                Mono.MonoTailFunc params expr _ ->
                    checkParams ctx params ++ checkExpr ctx expr

                Mono.MonoPortIncoming expr _ ->
                    checkExpr ctx expr

                Mono.MonoPortOutgoing expr _ ->
                    checkExpr ctx expr

                _ ->
                    []
           )


{-| Returns the violations in `expr`'s own type and in every expression inside
it, with closure and tail-definition parameters.
-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    checkType ctx "expression type" (Mono.typeOf expr)
        ++ (case expr of
                Mono.MonoClosure info body _ ->
                    checkParams (ctx ++ " closure") info.params
                        ++ List.concatMap (\( _, e, _ ) -> checkExpr ctx e) info.captures
                        ++ checkExpr (ctx ++ " closure") body

                Mono.MonoLet def body _ ->
                    (case def of
                        Mono.MonoDef _ bound ->
                            checkExpr ctx bound

                        Mono.MonoTailDef name params bound ->
                            checkParams (ctx ++ " taildef=" ++ name) params
                                ++ checkExpr (ctx ++ " taildef=" ++ name) bound
                    )
                        ++ checkExpr ctx body

                Mono.MonoCase _ _ decider jumps _ ->
                    checkDecider ctx decider
                        ++ List.concatMap (\( _, e ) -> checkExpr ctx e) jumps

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

                _ ->
                    []
           )


{-| Returns the violations in the case branches held inline at the leaves of
`decider`. A `Jump` leaf gives none; its branch is in the jump list.
-}
checkDecider : String -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            checkExpr (ctx ++ " inline-leaf") expr

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ yes no ->
            checkDecider ctx yes ++ checkDecider ctx no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx d) edges
                ++ checkDecider ctx fallback


{-| Returns one violation for each parameter whose type holds a residual
number variable.
-}
checkParams : String -> List ( String, Mono.MonoType ) -> List Violation
checkParams ctx params =
    List.concatMap (\( name, t ) -> checkType (ctx ++ " param=" ++ name) "parameter type" t) params


{-| Returns a violation when `monoType`, described as `what`, holds an
`MVar _ CNumber` at any depth.
-}
checkType : String -> String -> Mono.MonoType -> List Violation
checkType ctx what monoType =
    if hasNumberVar monoType then
        [ { context = ctx
          , message = "residual number var in " ++ what ++ ": " ++ Debug.toString monoType
          }
        ]

    else
        []


{-| Tells whether `monoType` holds an `MVar _ CNumber` at any depth.
-}
hasNumberVar : Mono.MonoType -> Bool
hasNumberVar monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ inner ->
            hasNumberVar inner

        Mono.MFunction _ _ args result ->
            List.any hasNumberVar args || hasNumberVar result

        Mono.MTuple _ elems ->
            List.any hasNumberVar elems

        Mono.MRecord _ fields ->
            List.any hasNumberVar (Dict.values fields)

        Mono.MCustom _ _ _ args ->
            List.any hasNumberVar args

        _ ->
            False


{-| Returns the failure message for `violations`: a header giving their count,
then each violation's context and message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "residual number vars found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ (violations
                |> List.map (\v -> v.context ++ ": " ++ v.message)
                |> String.join "\n\n"
           )
