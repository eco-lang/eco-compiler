module TestLogic.Monomorphize.MonoRecordUpdateShape exposing (expectMonoRecordUpdateShape, Violation)

{-| Checks that no record update in a monomorphized program drops a field of
the record it updates.

A record update `{ r | f = v }` copies `r` with some fields replaced, so its
result has every field that `r` has. In the monomorphized graph a
`MonoRecordUpdate` carries its own result type, and nothing in the types makes
that type agree with the type of the record being updated. Code generation
builds the new record with the layout of the input record's type, but a field
read on the result works out the field's position from the result's type. If
the result type lacked one of the input's fields, the read would use a
different layout from the one the record was built with.

`expectMonoRecordUpdateShape` compiles one source module to the monomorphized
graph and searches every expression of every node, including closure bodies
and captures, let-bound definitions, case branches and expressions inlined into
case decision trees. Each `MonoRecordUpdate` whose input record has an
`MRecord` type gives one `Violation` when:

  - the result type is a record that lacks some of the input record's field
    names, or
  - the result type is not a record.

Among what is not checked: field types are not compared, only field names; an
update whose input record's type is not an `MRecord`, such as a type variable,
is skipped; and the graph is the substitution engine's output before global
optimization, so neither the solver engine nor the optimized graph is examined.

@docs expectMonoRecordUpdateShape, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One record update that drops a field of its input record.

`context` names where it was found: `SpecId n` for the node at index `n` of the
graph's nodes, followed by a space and `inline-leaf` once for each case
decision-tree leaf the update is inlined into. `message` names the missing
fields, or says the result is not a record, and prints both types.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` to the monomorphized graph with
`TestLogic.TestPipeline.runToMono` and passes when no record update in it drops
a field of the record it updates.

An update whose input record has an `MRecord` type fails when its result type
is not a record or lacks one of the input's field names; field types are not
compared, and an update whose input record's type is not an `MRecord` is not
checked. A compilation failure fails the test with the pipeline's message.
Otherwise the failure message lists every violation, each as its context and
message, separated by blank lines.

-}
expectMonoRecordUpdateShape : Src.Module -> Expectation
expectMonoRecordUpdateShape srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkMonoRecordUpdateShape monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns the violations in every node of the graph, in node order. A node's
SpecId is its index in `nodes`; empty slots are skipped but still counted.
-}
checkMonoRecordUpdateShape : Mono.MonoGraph -> List Violation
checkMonoRecordUpdateShape (Mono.MonoGraph data) =
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


{-| Returns the violations in the expression of one node, with context
`SpecId specId`. Constructor, enum, extern and manager-leaf nodes hold no
expression and give none.
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


{-| Returns the violations in `expr` and every expression nested in it, with
context `ctx`. A record update's own violation comes before those found in its
record and new field values.
-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoRecordUpdate record updates resultType ->
            let
                recordType =
                    Mono.typeOf record

                shapeViolations =
                    checkShape ctx recordType resultType

                inner =
                    checkExpr ctx record
                        ++ List.concatMap (\( _, e ) -> checkExpr ctx e) updates
            in
            shapeViolations ++ inner

        Mono.MonoCase _ _ decider jumps _ ->
            checkDecider ctx decider
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


{-| Returns the violation, if any, for one record update whose input record has
type `recordType` and whose result has type `resultType`.

When both are records, it reports the input's field names that the result
lacks. When only the input is a record, it reports the result as not a record.
When the input is not a record there is no field list to compare, and it
reports nothing.

-}
checkShape : String -> Mono.MonoType -> Mono.MonoType -> List Violation
checkShape ctx recordType resultType =
    case ( recordType, resultType ) of
        ( Mono.MRecord _ rFields, Mono.MRecord _ resFields ) ->
            let
                missing =
                    Dict.keys rFields
                        |> List.filter (\k -> not (Dict.member k resFields))
            in
            if List.isEmpty missing then
                []

            else
                [ { context = ctx
                  , message =
                        "MonoRecordUpdate shape violation: result type is missing fields present on source record\n"
                            ++ "  missing fields: "
                            ++ String.join ", " missing
                            ++ "\n"
                            ++ "  source record type: "
                            ++ Debug.toString recordType
                            ++ "\n"
                            ++ "  result type: "
                            ++ Debug.toString resultType
                  }
                ]

        ( Mono.MRecord _ _, _ ) ->
            [ { context = ctx
              , message =
                    "MonoRecordUpdate shape violation: result type is not Mono.mRecord\n"
                        ++ "  source record type: "
                        ++ Debug.toString recordType
                        ++ "\n"
                        ++ "  result type: "
                        ++ Debug.toString resultType
              }
            ]

        _ ->
            []


{-| Returns the violations in the expressions inlined into the leaves of
`decider`, with a space and `inline-leaf` appended to `ctx`. A leaf that jumps
to a shared branch holds no expression here; `checkExpr` searches those
branches from the case's own list.
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
            checkDecider ctx yes ++ checkDecider ctx no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx d) edges
                ++ checkDecider ctx fallback


{-| Builds one failure message from `violations`, each as its context, a colon
and its message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"
