module TestLogic.CrossPhase.TypeConsistency exposing
    ( expectTypePreservation, checkTypePreservation
    , Violation
    )

{-| Test logic for XPHASE\_011: Types preserved except MFunction canonicalization.

Between Monomorphization and GlobalOpt, MonoTypes are preserved up to MFunction
staging canonicalization. GlobalOpt may flatten nested function types to match
closure parameter counts but may not otherwise change types or layout metadata.

@docs expectTypePreservation, checkTypePreservation, Violation

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| XPHASE\_011: Verify types are preserved between Monomorphization and GlobalOpt.
-}
expectTypePreservation : Src.Module -> Expectation
expectTypePreservation srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph, optimizedMonoGraph } ->
            let
                violations =
                    checkTypePreservation monoGraph optimizedMonoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check that types are preserved between pre- and post-GlobalOpt MonoGraphs.
-}
checkTypePreservation : Mono.MonoGraph -> Mono.MonoGraph -> List Violation
checkTypePreservation (Mono.MonoGraph before) (Mono.MonoGraph after) =
    -- Compare nodes that exist in both graphs
    Dict.foldl compare
        (\specId beforeNode acc ->
            case Dict.get identity specId after.nodes of
                Nothing ->
                    -- Node removed - this might be OK due to inlining, skip
                    acc

                Just afterNode ->
                    acc ++ checkNodeTypePreservation specId beforeNode afterNode
        )
        []
        before.nodes


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- XPHASE_011: TYPE PRESERVATION VERIFICATION
-- ============================================================================


{-| Check type preservation for a single node.
-}
checkNodeTypePreservation : Int -> Mono.MonoNode -> Mono.MonoNode -> List Violation
checkNodeTypePreservation specId beforeNode afterNode =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case ( beforeNode, afterNode ) of
        ( Mono.MonoDefine beforeExpr beforeType, Mono.MonoDefine afterExpr afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkExprTypePreservation ctx beforeExpr afterExpr

        ( Mono.MonoTailFunc _ beforeExpr beforeType, Mono.MonoTailFunc _ afterExpr afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkExprTypePreservation ctx beforeExpr afterExpr

        ( Mono.MonoPortIncoming beforeExpr beforeType, Mono.MonoPortIncoming afterExpr afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkExprTypePreservation ctx beforeExpr afterExpr

        ( Mono.MonoPortOutgoing beforeExpr beforeType, Mono.MonoPortOutgoing afterExpr afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkExprTypePreservation ctx beforeExpr afterExpr

        ( Mono.MonoCtor beforeShape beforeType, Mono.MonoCtor afterShape afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkCtorShapeEquivalent ctx beforeShape afterShape

        ( Mono.MonoEnum beforeIdx beforeType, Mono.MonoEnum afterIdx afterType ) ->
            if beforeIdx /= afterIdx then
                [ { context = ctx
                  , message = "XPHASE_011 violation: Enum index changed"
                  }
                ]

            else
                checkTypeEquivalent ctx beforeType afterType

        ( Mono.MonoExtern beforeType, Mono.MonoExtern afterType ) ->
            checkTypeEquivalent ctx beforeType afterType

        ( Mono.MonoCycle beforeDefs beforeType, Mono.MonoCycle afterDefs afterType ) ->
            checkTypeEquivalent ctx beforeType afterType
                ++ checkCycleDefsTypePreservation ctx beforeDefs afterDefs

        _ ->
            -- Node kind changed - this is a violation
            [ { context = ctx
              , message = "XPHASE_011 violation: Node kind changed between phases"
              }
            ]


{-| Check cycle definitions for type preservation.
-}
checkCycleDefsTypePreservation : String -> List ( String, Mono.MonoExpr ) -> List ( String, Mono.MonoExpr ) -> List Violation
checkCycleDefsTypePreservation ctx beforeDefs afterDefs =
    if List.length beforeDefs /= List.length afterDefs then
        [ { context = ctx
          , message = "XPHASE_011 violation: Cycle definition count changed"
          }
        ]

    else
        List.map2
            (\( beforeName, beforeExpr ) ( afterName, afterExpr ) ->
                if beforeName /= afterName then
                    [ { context = ctx ++ " cycle=" ++ beforeName
                      , message = "XPHASE_011 violation: Cycle definition name changed"
                      }
                    ]

                else
                    checkExprTypePreservation (ctx ++ " cycle=" ++ beforeName) beforeExpr afterExpr
            )
            beforeDefs
            afterDefs
            |> List.concat


{-| Check that two expressions have equivalent types (allowing MFunction canonicalization).
-}
checkExprTypePreservation : String -> Mono.MonoExpr -> Mono.MonoExpr -> List Violation
checkExprTypePreservation ctx beforeExpr afterExpr =
    let
        beforeType =
            Mono.typeOf beforeExpr

        afterType =
            Mono.typeOf afterExpr
    in
    checkTypeEquivalent ctx beforeType afterType


{-| Check that two types are equivalent, allowing MFunction canonicalization.

MFunction canonicalization allows: `a -> b -> c` to become `(a, b) -> c`
But other structural changes are not allowed.

-}
checkTypeEquivalent : String -> Mono.MonoType -> Mono.MonoType -> List Violation
checkTypeEquivalent ctx beforeType afterType =
    if typesEquivalentModuloCanonicalization beforeType afterType then
        []

    else
        [ { context = ctx
          , message =
                "XPHASE_011 violation: Type changed beyond MFunction canonicalization\n"
                    ++ "  before: "
                    ++ Debug.toString beforeType
                    ++ "\n"
                    ++ "  after: "
                    ++ Debug.toString afterType
          }
        ]


{-| Check that two type lists are equivalent.
-}
checkTypeListEquivalent : String -> List Mono.MonoType -> List Mono.MonoType -> List Violation
checkTypeListEquivalent ctx beforeTypes afterTypes =
    if List.length beforeTypes /= List.length afterTypes then
        [ { context = ctx
          , message = "XPHASE_011 violation: Type list length changed"
          }
        ]

    else
        List.map2 (checkTypeEquivalent ctx) beforeTypes afterTypes
            |> List.concat


{-| Check that two CtorShapes are equivalent.
-}
checkCtorShapeEquivalent : String -> Mono.CtorShape -> Mono.CtorShape -> List Violation
checkCtorShapeEquivalent ctx beforeShape afterShape =
    if beforeShape.name /= afterShape.name then
        [ { context = ctx
          , message = "XPHASE_011 violation: Ctor name changed"
          }
        ]

    else if beforeShape.tag /= afterShape.tag then
        [ { context = ctx
          , message = "XPHASE_011 violation: Ctor tag changed"
          }
        ]

    else
        checkTypeListEquivalent ctx beforeShape.fieldTypes afterShape.fieldTypes



-- ============================================================================
-- TYPE EQUIVALENCE (MODULO CANONICALIZATION)
-- ============================================================================


{-| Check if two types are equivalent, allowing MFunction staging canonicalization.

This allows:

  - `MFunction [a] (MFunction [b] c)` == `MFunction [a, b] c` (flattening)
  - But NOT changes to non-function type structure

-}
typesEquivalentModuloCanonicalization : Mono.MonoType -> Mono.MonoType -> Bool
typesEquivalentModuloCanonicalization before after =
    case ( before, after ) of
        ( Mono.MFunction _ _, Mono.MFunction _ _ ) ->
            -- For functions, allow canonicalization: compare flattened forms
            let
                ( flatBeforeParams, flatBeforeResult ) =
                    flattenFunction before

                ( flatAfterParams, flatAfterResult ) =
                    flattenFunction after
            in
            (List.length flatBeforeParams == List.length flatAfterParams)
                && List.all identity (List.map2 typesEquivalentModuloCanonicalization flatBeforeParams flatAfterParams)
                && typesEquivalentModuloCanonicalization flatBeforeResult flatAfterResult

        ( Mono.MVar beforeName beforeConstraint, Mono.MVar afterName afterConstraint ) ->
            beforeName == afterName && beforeConstraint == afterConstraint

        ( Mono.MUnit, Mono.MUnit ) ->
            True

        ( Mono.MBool, Mono.MBool ) ->
            True

        ( Mono.MChar, Mono.MChar ) ->
            True

        ( Mono.MInt, Mono.MInt ) ->
            True

        ( Mono.MFloat, Mono.MFloat ) ->
            True

        ( Mono.MString, Mono.MString ) ->
            True

        ( Mono.MList beforeElem, Mono.MList afterElem ) ->
            typesEquivalentModuloCanonicalization beforeElem afterElem

        ( Mono.MTuple beforeElems, Mono.MTuple afterElems ) ->
            (List.length beforeElems == List.length afterElems)
                && List.all identity (List.map2 typesEquivalentModuloCanonicalization beforeElems afterElems)

        ( Mono.MRecord beforeFields, Mono.MRecord afterFields ) ->
            let
                beforeList =
                    Dict.toList compare beforeFields

                afterList =
                    Dict.toList compare afterFields
            in
            (List.length beforeList == List.length afterList)
                && List.all identity
                    (List.map2
                        (\( beforeName, beforeTy ) ( afterName, afterTy ) ->
                            (beforeName == afterName) && typesEquivalentModuloCanonicalization beforeTy afterTy
                        )
                        beforeList
                        afterList
                    )

        ( Mono.MCustom beforeCanonical beforeName beforeArgs, Mono.MCustom afterCanonical afterName afterArgs ) ->
            (beforeCanonical == afterCanonical)
                && (beforeName == afterName)
                && (List.length beforeArgs == List.length afterArgs)
                && List.all identity (List.map2 typesEquivalentModuloCanonicalization beforeArgs afterArgs)

        _ ->
            False


{-| Flatten a function type into (params, result) where result is not a function.
-}
flattenFunction : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunction monoType =
    case monoType of
        Mono.MFunction params result ->
            let
                ( innerParams, innerResult ) =
                    flattenFunction result
            in
            ( params ++ innerParams, innerResult )

        _ ->
            ( [], monoType )
