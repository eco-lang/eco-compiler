module Compiler.Generate.MLIR.Patterns exposing (generateMonoPath, generateMonoDtPath, generateMonoChainCondition, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag)

{-| Pattern matching and path generation for MLIR code generation.

This module handles:

  - Path navigation (MonoPath and MonoDtPath)
  - Test generation for pattern matching
  - Case kind determination
  - Scrutinee type determination
  - Fallback tag computation

@docs generateMonoPath, generateMonoDtPath, generateMonoChainCondition, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag

-}

import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Data.Map as DataMap
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== HELPERS ======


{-| Extract record fields from a MonoType. Returns empty dict if not a record.
-}
getRecordFields : Mono.MonoType -> Dict.Dict Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            fields

        _ ->
            Dict.empty


{-| Find a FieldInfo by name in a list of FieldInfos.
-}
findFieldInfoByName : Name.Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInfoByName targetName fields =
    List.filter (\fi -> fi.name == targetName) fields
        |> List.head



-- ====== MONO PATH GENERATION ======


{-| Generate MLIR ops to navigate a MonoPath and extract a value.
-}
generateMonoPath : Ctx.Context -> Mono.MonoPath -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateMonoPath ctx path targetType =
    let
        ( revOps, var, ctx_ ) =
            generateMonoPathHelper ctx path targetType []
    in
    ( List.reverse revOps, var, ctx_ )


{-| Generate MLIR ops to navigate a MonoDtPath and extract a value.

Converts MonoDtPath to MonoPath and delegates to generateMonoPath.

-}
generateMonoDtPath : Ctx.Context -> Mono.MonoDtPath -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateMonoDtPath ctx dtPath targetType =
    generateMonoPath ctx (dtPathToMonoPath dtPath) targetType


{-| Convert MonoDtPath to MonoPath for reuse of existing generateMonoPath machinery.
-}
dtPathToMonoPath : Mono.MonoDtPath -> Mono.MonoPath
dtPathToMonoPath monoDt =
    case monoDt of
        Mono.DtRoot name ty ->
            Mono.MonoRoot name ty

        Mono.DtIndex idx kind resultTy sub ->
            Mono.MonoIndex idx kind resultTy (dtPathToMonoPath sub)

        Mono.DtUnbox resultTy sub ->
            Mono.MonoUnbox resultTy (dtPathToMonoPath sub)


{-| Generate a test condition from a MonoDtPath and a DT.Test.
-}
generateMonoTest : Ctx.Context -> ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateMonoTest ctx ( dtPath, test ) =
    let
        targetType =
            case test of
                Test.IsCtor _ _ _ _ _ ->
                    Types.ecoValue

                Test.IsBool _ ->
                    I1

                Test.IsInt _ ->
                    I64

                Test.IsChr _ ->
                    Types.ecoChar

                Test.IsStr _ ->
                    Types.ecoValue

                Test.IsCons ->
                    Types.ecoValue

                Test.IsNil ->
                    Types.ecoValue

                Test.IsTuple ->
                    Types.ecoValue

        ( pathOps, valVar, ctx1 ) =
            generateMonoDtPath ctx dtPath targetType
    in
    case test of
        Test.IsCtor _ _ index _ _ ->
            let
                expectedTag =
                    Index.toMachine index

                ( tagVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, tagOp ) =
                    Ops.ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, constOp ) =
                    Ops.arithConstantInt32 ctx4 constVar expectedTag

                ( resVar, ctx6 ) =
                    Ctx.freshVar ctx5

                ( ctx7, cmpOp ) =
                    Ops.arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

        Test.IsBool expected ->
            if expected then
                ( pathOps, valVar, ctx1 )

            else
                let
                    ( resVar, ctx2 ) =
                        Ctx.freshVar ctx1

                    ( constVar, ctx3 ) =
                        Ctx.freshVar ctx2

                    ( ctx4, constOp ) =
                        Ops.arithConstantBool ctx3 constVar True

                    ( ctx5, xorOp ) =
                        Ops.ecoBinaryOp ctx4 "arith.xori" resVar ( valVar, I1 ) ( constVar, I1 ) I1
                in
                ( pathOps ++ [ constOp, xorOp ], resVar, ctx5 )

        Test.IsInt i ->
            let
                ( constVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, constOp ) =
                    Ops.arithConstantInt ctx2 constVar i

                ( resVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, cmpOp ) =
                    Ops.ecoBinaryOp ctx4 "eco.int.eq" resVar ( valVar, I64 ) ( constVar, I64 ) I1
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        Test.IsChr c ->
            let
                charCode =
                    String.toList c |> List.head |> Maybe.map Char.toCode |> Maybe.withDefault 0

                ( constVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, constOp ) =
                    Ops.arithConstantChar ctx2 constVar charCode

                ( resVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, cmpOp ) =
                    Ops.arithCmpI ctx4 "eq" resVar ( valVar, Types.ecoChar ) ( constVar, Types.ecoChar )
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        Test.IsStr s ->
            let
                ( strVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, strOp ) =
                    if s == "" then
                        Ops.ecoConstantEmptyString ctx2 strVar

                    else
                        Ops.ecoStringLiteral ctx2 strVar s

                ( eqVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, cmpOp ) =
                    Ops.ecoCallNamed ctx4 eqVar "Elm_Kernel_Utils_equal" [ ( valVar, Types.ecoValue ), ( strVar, Types.ecoValue ) ] Types.ecoValue

                ( unboxOps, resVar, ctx6 ) =
                    Intrinsics.unboxToType ctx5 eqVar I1
            in
            ( pathOps ++ [ strOp, cmpOp ] ++ unboxOps, resVar, ctx6 )

        Test.IsCons ->
            let
                ( tagVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, tagOp ) =
                    Ops.ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, constOp ) =
                    Ops.arithConstantInt32 ctx4 constVar 1

                ( resVar, ctx6 ) =
                    Ctx.freshVar ctx5

                ( ctx7, cmpOp ) =
                    Ops.arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

        Test.IsNil ->
            let
                ( tagVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, tagOp ) =
                    Ops.ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, constOp ) =
                    Ops.arithConstantInt32 ctx4 constVar 0

                ( resVar, ctx6 ) =
                    Ctx.freshVar ctx5

                ( ctx7, cmpOp ) =
                    Ops.arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

        Test.IsTuple ->
            let
                ( resVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, constOp ) =
                    Ops.arithConstantBool ctx2 resVar True
            in
            ( pathOps ++ [ constOp ], resVar, ctx3 )


{-| Generate a chain condition from a list of MonoDtPath tests.
-}
generateMonoChainCondition : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateMonoChainCondition ctx tests =
    case tests of
        [] ->
            let
                ( resVar, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, constOp ) =
                    Ops.arithConstantBool ctx1 resVar True
            in
            ( [ constOp ], resVar, ctx2 )

        [ singleTest ] ->
            generateMonoTest ctx singleTest

        firstTest :: restTests ->
            let
                ( firstOps, firstVar, ctx1 ) =
                    generateMonoTest ctx firstTest

                ( revOps, finalVar, finalCtx ) =
                    List.foldl
                        (\test ( accRevOps, prevVar, accCtx ) ->
                            let
                                ( testOps, testVar, ctx2 ) =
                                    generateMonoTest accCtx test

                                ( resVar, ctx3 ) =
                                    Ctx.freshVar ctx2

                                ( ctx4, andOp ) =
                                    Ops.ecoBinaryOp ctx3 "arith.andi" resVar ( prevVar, I1 ) ( testVar, I1 ) I1
                            in
                            ( andOp :: List.foldl (::) accRevOps testOps, resVar, ctx4 )
                        )
                        ( List.foldl (::) [] firstOps, firstVar, ctx1 )
                        restTests
            in
            ( List.reverse revOps, finalVar, finalCtx )


{-| Internal helper for generateMonoPath that accumulates ops in reverse order
to avoid quadratic ++ [ behavior.
-}
generateMonoPathHelper : Ctx.Context -> Mono.MonoPath -> MlirType -> List MlirOp -> ( List MlirOp, String, Ctx.Context )
generateMonoPathHelper ctx path targetType revAcc =
    case path of
        Mono.MonoRoot name _ ->
            let
                ( varName, actualType ) =
                    Ctx.lookupVar ctx name
            in
            if Types.isEcoValueType actualType && targetType == I1 then
                -- Bool variable stored as eco.value (per ABI) needs unboxing to i1
                let
                    ( unboxOps, unboxedVar, ctxU ) =
                        Intrinsics.unboxToType ctx varName I1
                in
                ( List.foldl (::) revAcc unboxOps, unboxedVar, ctxU )

            else
                ( revAcc, varName, ctx )

        Mono.MonoIndex index containerKind resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( revAcc1, subVar, ctx1 ) =
                    generateMonoPathHelper ctx subPath Types.ecoValue revAcc

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Use type-specific projection ops based on ContainerKind.
                -- This ensures correct heap layout access for each container type.
                ( projectOps, projectVar, ctx3 ) =
                    case containerKind of
                        Mono.ListContainer ->
                            if index == 0 then
                                -- List head projection. Use targetType directly so the
                                -- projection result matches what the caller stores in the
                                -- context. Bool is !eco.value in heap storage (not unboxed),
                                -- so targetType=EcoValue is correct for Bool.
                                let
                                    ( ctx_, op ) =
                                        Ops.ecoProjectListHead ctx2 resultVar targetType subVar
                                in
                                ( [ op ], resultVar, ctx_ )

                            else
                                -- List tail (index 1)
                                let
                                    ( ctx_, op ) =
                                        Ops.ecoProjectListTail ctx2 resultVar subVar
                                in
                                ( [ op ], resultVar, ctx_ )

                        Mono.Tuple2Container ->
                            let
                                fieldAbiType =
                                    Types.monoTypeToAbi resultType
                            in
                            if Types.isUnboxable fieldAbiType then
                                -- Field is stored unboxed (Int/Float/Char) in the tuple
                                let
                                    ( primitiveVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        Ops.ecoProjectTuple2 ctx3_ primitiveVar index fieldAbiType subVar
                                in
                                if Types.isEcoValueType targetType then
                                    let
                                        ( boxedVar, ctx5 ) =
                                            Ctx.freshVar ctx4

                                        ( ctx6, boxOp ) =
                                            boxPrimitive ctx5 boxedVar primitiveVar fieldAbiType
                                    in
                                    ( [ projectOp, boxOp ], boxedVar, ctx6 )

                                else
                                    ( [ projectOp ], primitiveVar, ctx4 )

                            else
                                -- Field is stored boxed (!eco.value) in the tuple (includes Bool)
                                let
                                    ( valVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        Ops.ecoProjectTuple2 ctx3_ valVar index Types.ecoValue subVar
                                in
                                if targetType == I1 then
                                    let
                                        ( unboxOps, unboxedVar, ctxU ) =
                                            Intrinsics.unboxToType ctx4 valVar I1
                                    in
                                    ( projectOp :: unboxOps, unboxedVar, ctxU )

                                else
                                    ( [ projectOp ], valVar, ctx4 )

                        Mono.Tuple3Container ->
                            let
                                fieldAbiType =
                                    Types.monoTypeToAbi resultType
                            in
                            if Types.isUnboxable fieldAbiType then
                                -- Field is stored unboxed (Int/Float/Char) in the tuple
                                let
                                    ( primitiveVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        Ops.ecoProjectTuple3 ctx3_ primitiveVar index fieldAbiType subVar
                                in
                                if Types.isEcoValueType targetType then
                                    let
                                        ( boxedVar, ctx5 ) =
                                            Ctx.freshVar ctx4

                                        ( ctx6, boxOp ) =
                                            boxPrimitive ctx5 boxedVar primitiveVar fieldAbiType
                                    in
                                    ( [ projectOp, boxOp ], boxedVar, ctx6 )

                                else
                                    ( [ projectOp ], primitiveVar, ctx4 )

                            else
                                -- Field is stored boxed (!eco.value) in the tuple (includes Bool)
                                let
                                    ( valVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        Ops.ecoProjectTuple3 ctx3_ valVar index Types.ecoValue subVar
                                in
                                if targetType == I1 then
                                    let
                                        ( unboxOps, unboxedVar, ctxU ) =
                                            Intrinsics.unboxToType ctx4 valVar I1
                                    in
                                    ( projectOp :: unboxOps, unboxedVar, ctxU )

                                else
                                    ( [ projectOp ], valVar, ctx4 )

                        Mono.CustomContainer ctorName ->
                            -- For custom types, we need to check if the field is stored unboxed
                            -- by looking up the CtorLayout for this constructor.
                            let
                                containerType =
                                    Mono.getMonoPathType subPath

                                maybeIsUnboxed =
                                    lookupFieldIsUnboxed ctx2 containerType ctorName index
                            in
                            case maybeIsUnboxed of
                                Just True ->
                                    -- Field is stored unboxed (as primitive).
                                    -- Project as primitive type, then box if caller needs eco.value.
                                    let
                                        fieldMlirType =
                                            Types.monoTypeToAbi resultType

                                        ( primitiveVar, ctx3_ ) =
                                            Ctx.freshVar ctx2

                                        ( ctx4, projectOp ) =
                                            Ops.ecoProjectCustom ctx3_ primitiveVar index fieldMlirType subVar
                                    in
                                    if Types.isEcoValueType targetType then
                                        -- Caller wants eco.value, need to box the primitive
                                        let
                                            ( boxedVar, ctx5 ) =
                                                Ctx.freshVar ctx4

                                            ( ctx6, boxOp ) =
                                                boxPrimitive ctx5 boxedVar primitiveVar fieldMlirType
                                        in
                                        ( [ projectOp, boxOp ], boxedVar, ctx6 )

                                    else
                                        -- Caller wants primitive, return directly
                                        ( [ projectOp ], primitiveVar, ctx4 )

                                _ ->
                                    -- Field is stored boxed (as eco.value) or no layout found.
                                    -- Use the MonoPath's declared resultType to determine the
                                    -- correct projection type (CGEN_004).
                                    let
                                        fieldMlirType =
                                            Types.monoTypeToAbi resultType
                                    in
                                    if Types.isUnboxable fieldMlirType then
                                        -- Field has a primitive type but layout lookup failed.
                                        -- Project as the primitive type directly so we don't
                                        -- introduce a spurious project→unbox sequence.
                                        let
                                            ( primitiveVar, ctx3_ ) =
                                                Ctx.freshVar ctx2

                                            ( ctx4, projectOp ) =
                                                Ops.ecoProjectCustom ctx3_ primitiveVar index fieldMlirType subVar
                                        in
                                        if Types.isEcoValueType targetType then
                                            let
                                                ( boxedVar, ctx5 ) =
                                                    Ctx.freshVar ctx4

                                                ( ctx6, boxOp ) =
                                                    boxPrimitive ctx5 boxedVar primitiveVar fieldMlirType
                                            in
                                            ( [ projectOp, boxOp ], boxedVar, ctx6 )

                                        else
                                            ( [ projectOp ], primitiveVar, ctx4 )

                                    else
                                        -- Field is non-primitive (eco.value), project as eco.value.
                                        let
                                            ( ctx_, op ) =
                                                Ops.ecoProjectCustom ctx2 resultVar index targetType subVar
                                        in
                                        ( [ op ], resultVar, ctx_ )
            in
            ( List.foldl (::) revAcc1 projectOps
            , projectVar
            , ctx3
            )

        Mono.MonoField fieldName resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( revAcc1, subVar, ctx1 ) =
                    generateMonoPathHelper ctx subPath Types.ecoValue revAcc

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Compute record layout to get the field index
                containerType =
                    Mono.getMonoPathType subPath

                layout =
                    Types.computeRecordLayout (DataMap.fromList identity (Dict.toList (getRecordFields containerType)))

                fieldInfo =
                    findFieldInfoByName fieldName layout.fields
                        |> Maybe.withDefault
                            { name = fieldName
                            , index = 0
                            , monoType = resultType
                            , isUnboxed = False
                            }

                -- Project directly to the targetType using record projection.
                -- MonoField is generated from TOpt.Field which is record field access.
                -- Primitive types are stored unboxed and should be read directly.
                ( ctx3, projectOp ) =
                    Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
            in
            ( projectOp :: revAcc1
            , resultVar
            , ctx3
            )

        Mono.MonoUnbox _ subPath ->
            -- MonoUnbox represents unwrapping a single-constructor type (Can.Unbox).
            -- For types like `Wrapper = Wrap Int`, MonoUnbox extracts the inner value.
            -- The resultType is the type of the inner value (the single field's type).
            --
            -- We need to:
            -- 1. Get the container (wrapper) value
            -- 2. Look up the unbox type's single constructor layout
            -- 3. Project field 0 with the appropriate type
            -- 4. Box/unbox if needed to match targetType
            let
                containerType =
                    Mono.getMonoPathType subPath

                -- Navigate to the container object (always !eco.value)
                ( revAcc1, subVar, ctx1 ) =
                    generateMonoPathHelper ctx subPath Types.ecoValue revAcc

                -- Look up the shape for this unbox type
                typeKey =
                    Mono.toComparableMonoType containerType

                maybeShapes =
                    Dict.get typeKey ctx1.typeRegistry.ctorShapes
            in
            case maybeShapes of
                Just (shape :: _) ->
                    -- Found shape - compute layout and check if the single field is unboxed
                    let
                        layout =
                            Types.computeCtorLayout shape
                    in
                    case layout.fields of
                        fieldInfo :: _ ->
                            let
                                ( resultVar, ctx2 ) =
                                    Ctx.freshVar ctx1

                                fieldMlirType =
                                    Types.monoTypeToAbi fieldInfo.monoType
                            in
                            if fieldInfo.isUnboxed then
                                -- Field is stored unboxed (as primitive)
                                let
                                    ( ctx3, projectOp ) =
                                        Ops.ecoProjectCustom ctx2 resultVar 0 fieldMlirType subVar
                                in
                                if Types.isEcoValueType targetType then
                                    -- Caller wants eco.value, need to box
                                    let
                                        ( boxedVar, ctx4 ) =
                                            Ctx.freshVar ctx3

                                        ( ctx5, boxOp ) =
                                            boxPrimitive ctx4 boxedVar resultVar fieldMlirType
                                    in
                                    ( boxOp :: projectOp :: revAcc1, boxedVar, ctx5 )

                                else
                                    -- Caller wants primitive, return directly
                                    ( projectOp :: revAcc1, resultVar, ctx3 )

                            else
                                -- Field is stored boxed (as eco.value)
                                let
                                    ( ctx3, projectOp ) =
                                        Ops.ecoProjectCustom ctx2 resultVar 0 Types.ecoValue subVar
                                in
                                if targetType == I1 then
                                    -- Bool is stored as eco.value in custom types (never unboxed).
                                    -- Project as eco.value, then unbox to i1.
                                    let
                                        ( unboxOps, unboxedVar, ctxU ) =
                                            Intrinsics.unboxToType ctx3 resultVar I1
                                    in
                                    ( List.foldl (::) (projectOp :: revAcc1) unboxOps, unboxedVar, ctxU )

                                else if Types.isUnboxable targetType then
                                    -- Caller wants primitive, need to unbox
                                    let
                                        ( unboxedVar, ctx4 ) =
                                            Ctx.freshVar ctx3

                                        attrs =
                                            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

                                        ( ctx5, unboxOp ) =
                                            Ops.mlirOp ctx4 "eco.unbox"
                                                |> Ops.opBuilder.withOperands [ resultVar ]
                                                |> Ops.opBuilder.withResults [ ( unboxedVar, targetType ) ]
                                                |> Ops.opBuilder.withAttrs attrs
                                                |> Ops.opBuilder.build
                                    in
                                    ( unboxOp :: projectOp :: revAcc1, unboxedVar, ctx5 )

                                else
                                    -- Caller wants eco.value, return directly
                                    ( projectOp :: revAcc1, resultVar, ctx3 )

                        [] ->
                            -- No fields in layout - fall back to pass-through
                            ( revAcc1, subVar, ctx1 )

                _ ->
                    -- No layout found - fall back to pass-through (treat as eco.value)
                    -- This preserves backward compatibility for cases where layout isn't available.
                    ( revAcc1, subVar, ctx1 )


{-| Look up whether a field in a custom type constructor is stored unboxed.

Returns Just True if unboxed, Just False if boxed, Nothing if no layout found.

-}
lookupFieldIsUnboxed : Ctx.Context -> Mono.MonoType -> Name.Name -> Int -> Maybe Bool
lookupFieldIsUnboxed ctx containerType ctorName fieldIndex =
    let
        typeKey =
            Mono.toComparableMonoType containerType

        maybeShapes =
            Dict.get typeKey ctx.typeRegistry.ctorShapes
    in
    case maybeShapes of
        Nothing ->
            Nothing

        Just shapes ->
            -- Find the constructor by name
            case List.filter (\shape -> shape.name == ctorName) shapes of
                shape :: _ ->
                    -- Compute layout and find the field by index
                    let
                        layout =
                            Types.computeCtorLayout shape
                    in
                    case List.drop fieldIndex layout.fields of
                        fieldInfo :: _ ->
                            Just fieldInfo.isUnboxed

                        [] ->
                            Nothing

                [] ->
                    Nothing


{-| Box a primitive value into an eco.value.
-}
boxPrimitive : Ctx.Context -> String -> String -> MlirType -> ( Ctx.Context, MlirOp )
boxPrimitive ctx resultVar primitiveVar primType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr primType ])
    in
    Ops.mlirOp ctx "eco.box"
        |> Ops.opBuilder.withOperands [ primitiveVar ]
        |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> Ops.opBuilder.withAttrs attrs
        |> Ops.opBuilder.build


{-| Get the tag from a DT.Test for use with eco.case
-}
testToTagInt : DT.Test -> Int
testToTagInt test =
    case test of
        Test.IsCtor _ _ index _ _ ->
            Index.toMachine index

        Test.IsCons ->
            1

        Test.IsNil ->
            0

        Test.IsBool True ->
            1

        Test.IsBool False ->
            0

        Test.IsInt i ->
            i

        Test.IsChr c ->
            decodeChrPatternCode c

        Test.IsStr _ ->
            0

        Test.IsTuple ->
            0


{-| Decode a char pattern string to its character code.

Char patterns from the parser may contain raw escape sequences (e.g., the 2-char
string backslash+n for a newline). This function decodes such escape sequences
to the actual character code.

-}
decodeChrPatternCode : String -> Int
decodeChrPatternCode c =
    case String.toList c of
        [ single ] ->
            Char.toCode single

        [ '\\', escaped ] ->
            case escaped of
                'n' ->
                    0x0A

                'r' ->
                    0x0D

                't' ->
                    0x09

                _ ->
                    -- '"', '\'', '\\' — the escaped char IS the value
                    Char.toCode escaped

        '\\' :: 'u' :: hexChars ->
            List.foldl (\ch acc -> acc * 16 + hexDigitToInt ch) 0 hexChars

        _ ->
            0


hexDigitToInt : Char -> Int
hexDigitToInt c =
    let
        code =
            Char.toCode c
    in
    if code >= 0x30 && code <= 0x39 then
        code - 0x30

    else if code >= 0x61 && code <= 0x66 then
        code - 0x61 + 10

    else if code >= 0x41 && code <= 0x46 then
        code - 0x41 + 10

    else
        0


{-| Determine the case kind from a DT.Test for use with eco.case.

Returns a string indicating how the runtime should handle the case:

  - "ctor" for ADT constructor matching (uses GetTagOp)
  - "int" for integer matching (unboxes to i64 and compares)
  - "chr" for character matching (unboxes to i16 and compares)
  - "str" for string matching (uses string comparison)

-}
caseKindFromTest : DT.Test -> String
caseKindFromTest test =
    case test of
        Test.IsCtor _ _ _ _ _ ->
            "ctor"

        Test.IsCons ->
            "ctor"

        Test.IsNil ->
            "ctor"

        Test.IsBool _ ->
            "ctor"

        Test.IsInt _ ->
            "int"

        Test.IsChr _ ->
            "chr"

        Test.IsStr _ ->
            "str"

        Test.IsTuple ->
            "ctor"


{-| Get the MLIR type for the scrutinee based on case\_kind.

Int cases need i64 scrutinee, Char cases need i16, all others use eco.value.

-}
scrutineeTypeFromCaseKind : String -> MlirType
scrutineeTypeFromCaseKind caseKind =
    case caseKind of
        "int" ->
            I64

        "chr" ->
            Types.ecoChar

        "str" ->
            Types.ecoValue

        -- "ctor" and anything else: boxed ADTs
        _ ->
            Types.ecoValue


{-| Compute the fallback tag for a fan-out based on the edge tests.
For two-way branches (Bool, Cons/Nil), this computes the "other" tag.
For N-way branches (custom types), this finds the first missing tag.
-}
computeFallbackTag : List DT.Test -> Int
computeFallbackTag edgeTests =
    case edgeTests of
        [ Test.IsBool True ] ->
            0

        [ Test.IsBool False ] ->
            1

        [ Test.IsCons ] ->
            0

        [ Test.IsNil ] ->
            1

        _ ->
            -- For custom types with multiple edges, find the first unused tag
            let
                usedTags =
                    List.map testToTagInt edgeTests

                maxTag =
                    List.maximum usedTags |> Maybe.withDefault 0
            in
            -- Find first unused tag from 0 to maxTag+1
            List.range 0 (maxTag + 1)
                |> List.filter (\t -> not (List.member t usedTags))
                |> List.head
                |> Maybe.withDefault (maxTag + 1)
