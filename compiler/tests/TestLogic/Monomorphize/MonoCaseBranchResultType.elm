module TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes, Violation)

{-| Checks that every branch of every `case` in a monomorphized program has
exactly the type the case records for itself, so that `Mono.typeOf` of a case
expression is true of each of its branches.

A `MonoCase` stores its result type in its last field, and `Mono.typeOf` of the
case returns that stored type without looking at the branches. Anything that
asks a case for its type therefore relies on every branch having that type. A
branch whose type differs, for example a function whose `MFunction` type groups
its parameters into stages differently from the stored type, makes the case's
type wrong for that branch.

A case's branch bodies are held in two places, and both are checked. The jump
list holds the bodies the decision tree reaches by `Jump n`; a body can instead
sit in a leaf of the decision tree itself, as `Inline expr`. Each body's
`Mono.typeOf` is compared with the stored type by `==`, structural equality on
the whole `MonoType`, so the lambda-set annotations on function types and the
ids of type variables must also agree.

`expectMonoCaseBranchResultTypes` checks the graph that
`TestLogic.TestPipeline.runToMono` produces: the substitution engine's output,
before inlining or any GlobalOpt pass has run. Every expression in every node
that has a body is walked, so cases nested anywhere are checked too.

Among what is not checked: the branches of an `if`, and the types on the
decision tree's paths.

@docs expectMonoCaseBranchResultTypes, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One branch whose type differs from its case's stored result type.

`context` names the node by its index in the graph's node array and ends with
`jump=<n>` for a jump-list body or `inline-leaf` for an inline one. `message`
gives both types as `Debug.toString` prints them.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Builds `srcModule` with `TestLogic.TestPipeline.runToMono` and passes when
every case branch in the resulting graph, jump-list or inline, has a type `==`
to its case's stored result type.

It fails with the pipeline's message if the build fails, and otherwise with
every mismatch found, one paragraph each.

-}
expectMonoCaseBranchResultTypes : Src.Module -> Expectation
expectMonoCaseBranchResultTypes srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkMonoCaseBranchResultTypes monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns the violations in every node of the graph, in node order, each
labelled with the node's index in the node array. Empty slots are skipped.
-}
checkMonoCaseBranchResultTypes : Mono.MonoGraph -> List Violation
checkMonoCaseBranchResultTypes (Mono.MonoGraph data) =
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


{-| Returns the violations in `node`'s body, labelled `SpecId <specId>`.
Constructor, enum, extern and effect-manager-leaf nodes have no body and give
none.
-}
checkNode : Int -> Mono.MonoNode -> List Violation
checkNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            checkExpr ctx expr

        Mono.MonoTailFunc _ expr _ ->
            checkExpr ctx expr

        Mono.MonoPortIncoming expr _ ->
            checkExpr ctx expr

        Mono.MonoPortOutgoing expr _ ->
            checkExpr ctx expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Returns the violations in `expr` and every expression inside it, labelled
with `ctx`. Only a `MonoCase` is compared with anything; every other expression
is walked through to its children.
-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoCase _ _ decider jumps resultType ->
            checkDecider ctx resultType decider
                ++ checkJumps ctx resultType jumps
                ++ List.concatMap (\( _, branchExpr ) -> checkExpr ctx branchExpr) jumps

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> checkExpr ctx c ++ checkExpr ctx t) branches
                ++ checkExpr ctx final

        Mono.MonoLet def body _ ->
            let
                defViolations =
                    case def of
                        Mono.MonoDef _ bound ->
                            checkExpr ctx bound

                        Mono.MonoTailDef _ _ bound ->
                            checkExpr ctx bound
            in
            defViolations ++ checkExpr ctx body

        Mono.MonoClosure info body _ ->
            let
                captureViolations =
                    List.concatMap (\( _, e, _ ) -> checkExpr ctx e) info.captures
            in
            captureViolations ++ checkExpr ctx body

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


{-| Returns a violation for each body in `jumps` whose type is not `==` to
`resultType`. It does not look inside the bodies.
-}
checkJumps : String -> Mono.MonoType -> List ( Int, Mono.MonoExpr ) -> List Violation
checkJumps ctx resultType jumps =
    List.concatMap
        (\( idx, branchExpr ) ->
            let
                branchTy =
                    Mono.typeOf branchExpr
            in
            if branchTy == resultType then
                []

            else
                [ { context = ctx ++ " jump=" ++ String.fromInt idx
                  , message =
                        "MONO_018 violation: branch type != MonoCase resultType\n"
                            ++ "  resultType: "
                            ++ Debug.toString resultType
                            ++ "\n"
                            ++ "  branch type: "
                            ++ Debug.toString branchTy
                  }
                ]
        )
        jumps


{-| Returns the violations of every `Inline` leaf of `decider`: one if the
leaf's body has a type not `==` to `resultType`, then those inside the body,
all labelled with `inline-leaf` added to `ctx`.

A `Jump` leaf gives nothing here: the body it names is in the jump list, which
`checkJumps` compares.

-}
checkDecider : String -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx resultType decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    []

                Mono.Inline expr ->
                    let
                        ty =
                            Mono.typeOf expr
                    in
                    if ty == resultType then
                        checkExpr (ctx ++ " inline-leaf") expr

                    else
                        { context = ctx ++ " inline-leaf"
                        , message =
                            "MONO_018 violation: inline leaf type != MonoCase resultType\n"
                                ++ "  resultType: "
                                ++ Debug.toString resultType
                                ++ "\n"
                                ++ "  inline type: "
                                ++ Debug.toString ty
                        }
                            :: checkExpr (ctx ++ " inline-leaf") expr

        Mono.Chain _ yes no ->
            checkDecider ctx resultType yes
                ++ checkDecider ctx resultType no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx resultType d) edges
                ++ checkDecider ctx resultType fallback


{-| Joins `violations` into one failure message, each written as
`context: message`, with a blank line between them.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"
