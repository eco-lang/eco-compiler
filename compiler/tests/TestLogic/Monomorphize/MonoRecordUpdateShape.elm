module TestLogic.Monomorphize.MonoRecordUpdateShape exposing (expectMonoRecordUpdateShape, Violation)

{-| Test logic for the MonoRecordUpdate shape-subset invariant.

For every MonoRecordUpdate node, the set of fields on the input record's type
must be a subset of the set of fields on the update node's result type. In
other words, record update must never narrow the record layout — doing so
would cause MLIR codegen to emit a construct.record with too few fields,
producing out-of-bounds projections at runtime.

This directly guards the class of bugs described in
plans/fix-record-update-source-layout.md.

@docs expectMonoRecordUpdateShape, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


type alias Violation =
    { context : String
    , message : String
    }


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
            -- Source record type not MRecord (e.g. MVar flowing through a
            -- polymorphic wrapper). Shape subset is vacuous; skip.
            []


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


formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"
