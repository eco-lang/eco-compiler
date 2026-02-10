module Compiler.Generate.MLIR.Patterns exposing (generateMonoPath, generateDTPath, generateChainCondition, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag)

{-| Pattern matching and path generation for MLIR code generation.

This module handles:

  - Path navigation (MonoPath and DT.Path)
  - Test generation for pattern matching
  - Case kind determination
  - Scrutinee type determination
  - Fallback tag computation

@docs generateMonoPath, generateDTPath, generateChainCondition, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag

-}

import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Data.Map as EveryDict
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== HELPERS ======


{-| Extract record fields from a MonoType. Returns empty dict if not a record.
-}
getRecordFields : Mono.MonoType -> EveryDict.Dict String Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            fields

        _ ->
            EveryDict.empty


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
    case path of
        Mono.MonoRoot name _ ->
            let
                ( varName, _ ) =
                    Ctx.lookupVar ctx name
            in
            ( [], varName, ctx )

        Mono.MonoIndex index containerKind resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Use type-specific projection ops based on ContainerKind.
                -- This ensures correct heap layout access for each container type.
                ( projectOps, projectVar, ctx3 ) =
                    case containerKind of
                        Mono.ListContainer ->
                            if index == 0 then
                                -- List head projection. Element may be stored unboxed (Int, Float, Char)
                                -- or boxed (!eco.value) depending on the element type.
                                -- The runtime helper functions (eco_cons_head_i64, etc.) handle
                                -- both boxed and unboxed storage transparently.
                                let
                                    -- Determine the MLIR type to project based on the element's MonoType
                                    elementMlirType =
                                        Types.monoTypeToOperand resultType

                                    ( ctx_, op ) =
                                        Ops.ecoProjectListHead ctx2 resultVar elementMlirType subVar
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
                                ( ctx_, op ) =
                                    Ops.ecoProjectTuple2 ctx2 resultVar index targetType subVar
                            in
                            ( [ op ], resultVar, ctx_ )

                        Mono.Tuple3Container ->
                            let
                                ( ctx_, op ) =
                                    Ops.ecoProjectTuple3 ctx2 resultVar index targetType subVar
                            in
                            ( [ op ], resultVar, ctx_ )

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
                                    -- Project as eco.value, which is the default behavior.
                                    let
                                        ( ctx_, op ) =
                                            Ops.ecoProjectCustom ctx2 resultVar index targetType subVar
                                    in
                                    ( [ op ], resultVar, ctx_ )
            in
            ( subOps ++ projectOps
            , projectVar
            , ctx3
            )

        Mono.MonoField fieldName resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Compute record layout to get the field index
                containerType =
                    Mono.getMonoPathType subPath

                layout =
                    Types.computeRecordLayout (getRecordFields containerType)

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
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoUnbox resultType subPath ->
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
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath Types.ecoValue

                -- Look up the shape for this unbox type
                typeKey =
                    Mono.toComparableMonoType containerType

                maybeShapes =
                    EveryDict.get identity typeKey ctx1.typeRegistry.ctorShapes
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
                                    ( subOps ++ [ projectOp, boxOp ], boxedVar, ctx5 )

                                else
                                    -- Caller wants primitive, return directly
                                    ( subOps ++ [ projectOp ], resultVar, ctx3 )

                            else
                                -- Field is stored boxed (as eco.value)
                                let
                                    ( ctx3, projectOp ) =
                                        Ops.ecoProjectCustom ctx2 resultVar 0 Types.ecoValue subVar
                                in
                                if Types.isUnboxable targetType then
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
                                    ( subOps ++ [ projectOp, unboxOp ], unboxedVar, ctx5 )

                                else
                                    -- Caller wants eco.value, return directly
                                    ( subOps ++ [ projectOp ], resultVar, ctx3 )

                        [] ->
                            -- No fields in layout - fall back to pass-through
                            ( subOps, subVar, ctx1 )

                _ ->
                    -- No layout found - fall back to pass-through (treat as eco.value)
                    -- This preserves backward compatibility for cases where layout isn't available.
                    ( subOps, subVar, ctx1 )


{-| Look up whether a field in a custom type constructor is stored unboxed.

Returns Just True if unboxed, Just False if boxed, Nothing if no layout found.

-}
lookupFieldIsUnboxed : Ctx.Context -> Mono.MonoType -> Name.Name -> Int -> Maybe Bool
lookupFieldIsUnboxed ctx containerType ctorName fieldIndex =
    let
        typeKey =
            Mono.toComparableMonoType containerType

        maybeShapes =
            EveryDict.get identity typeKey ctx.typeRegistry.ctorShapes
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


{-| Look up field layout info by constructor name only.

This searches through all ctorShapes entries to find a constructor with the given name.
For non-polymorphic types, this will find a unique match.
For polymorphic types, there may be multiple instantiations with the same constructor name
but different field layouts - in that case, we return the first match (which may not be correct).

This is a pragmatic workaround for decision tree paths (DT.Path) which don't carry MonoType
information. The proper fix would be to augment the decision tree with type information
during monomorphization.

Returns Just (isUnboxed, fieldMonoType) if found, Nothing otherwise.

-}
lookupFieldInfoByCtorName : Ctx.Context -> Name.Name -> Int -> Maybe ( Bool, Mono.MonoType )
lookupFieldInfoByCtorName ctx ctorName fieldIndex =
    let
        allShapeLists =
            EveryDict.values compare ctx.typeRegistry.ctorShapes

        allShapes =
            List.concatMap identity allShapeLists

        -- Flatten all shapes and find matching constructor
        matchingShape =
            allShapes
                |> List.filter (\shape -> shape.name == ctorName)
                |> List.head
    in
    case matchingShape of
        Nothing ->
            Nothing

        Just shape ->
            let
                layout =
                    Types.computeCtorLayout shape
            in
            case List.drop fieldIndex layout.fields of
                fieldInfo :: _ ->
                    Just ( fieldInfo.isUnboxed, fieldInfo.monoType )

                [] ->
                    Nothing


{-| Find if there's a single-constructor single-field type with an unboxed field.

This is used by TypedPath.Unbox handling to determine if the inner field is stored unboxed.
Returns Just (fieldMonoType, isUnboxed) if found, Nothing otherwise.

-}
findSingleCtorUnboxedField : Ctx.Context -> Maybe ( Mono.MonoType, Bool )
findSingleCtorUnboxedField ctx =
    let
        allShapeLists =
            EveryDict.values compare ctx.typeRegistry.ctorShapes

        -- Find types with exactly one constructor
        singleCtorShapes =
            allShapeLists
                |> List.filter (\shapes -> List.length shapes == 1)
                |> List.filterMap List.head
                |> List.filter (\shape -> List.length shape.fieldTypes == 1)

        -- Check if any has an unboxed field
        findUnboxed shapes =
            case shapes of
                [] ->
                    Nothing

                shape :: rest ->
                    let
                        layout =
                            Types.computeCtorLayout shape
                    in
                    case layout.fields of
                        fieldInfo :: _ ->
                            if fieldInfo.isUnboxed then
                                Just ( fieldInfo.monoType, True )

                            else
                                findUnboxed rest

                        [] ->
                            findUnboxed rest
    in
    findUnboxed singleCtorShapes


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



-- ====== DECISION TREE PATH GENERATION ======


{-| Generate MLIR ops to navigate a DT.Path from the root scrutinee.

Returns the ops needed to project to the target, the result variable name,
and the updated context.

The targetType parameter specifies what type the final value should be:

  - For primitive tests (IsBool, IsInt, IsChr), this is the primitive type
  - For ctor tests, this is !eco.value

-}
generateDTPath : Ctx.Context -> Name.Name -> DT.Path -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateDTPath ctx root dtPath targetType =
    case dtPath of
        TypedPath.Empty ->
            -- The root is the scrutinee variable; look it up in varMappings.
            -- This correctly handles both boxed (!eco.value) and unboxed (i1, i64) parameters.
            let
                ( rootVar, rootTy ) =
                    Ctx.lookupVar ctx root
            in
            if rootTy == targetType then
                -- Already the right type (e.g. Bool param already i1)
                ( [], rootVar, ctx )

            else if Types.isEcoValueType rootTy && not (Types.isEcoValueType targetType) then
                -- Currently boxed, need primitive -> unbox and update mapping
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        Intrinsics.unboxToType ctx rootVar targetType

                    -- Make future uses of root see the unboxed SSA value
                    ctx2 =
                        Ctx.addVarMapping root unboxedVar targetType ctx1
                in
                ( unboxOps, unboxedVar, ctx2 )

            else
                -- Types differ but we don't have a boxing rule here; just use rootVar.
                ( [], rootVar, ctx )

        TypedPath.Index index hint subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                fieldIndex : Int
                fieldIndex =
                    Index.toMachine index

                -- Use type-specific projection ops based on ContainerHint.
                -- This ensures correct heap layout access for each container type.
                ( projectOps, projectVar, ctx3 ) =
                    case hint of
                        TypedPath.HintList ->
                            if fieldIndex == 0 then
                                -- List head projection. Project with the target type directly.
                                -- The runtime helper functions (eco_cons_head_i64, etc.) handle
                                -- both boxed and unboxed storage transparently.
                                let
                                    ( ctxL, op ) =
                                        Ops.ecoProjectListHead ctx2 resultVar targetType subVar
                                in
                                ( [ op ], resultVar, ctxL )

                            else
                                -- List tail (index 1)
                                let
                                    ( ctxL, op ) =
                                        Ops.ecoProjectListTail ctx2 resultVar subVar
                                in
                                ( [ op ], resultVar, ctxL )

                        TypedPath.HintTuple2 ->
                            let
                                ( ctxT, op ) =
                                    Ops.ecoProjectTuple2 ctx2 resultVar fieldIndex targetType subVar
                            in
                            ( [ op ], resultVar, ctxT )

                        TypedPath.HintTuple3 ->
                            let
                                ( ctxT, op ) =
                                    Ops.ecoProjectTuple3 ctx2 resultVar fieldIndex targetType subVar
                            in
                            ( [ op ], resultVar, ctxT )

                        TypedPath.HintCustom ctorName ->
                            -- Custom ADTs (Maybe, Result, user types, big tuples)
                            -- Look up field layout by constructor name to determine if field is unboxed.
                            case lookupFieldInfoByCtorName ctx2 ctorName fieldIndex of
                                Just ( True, fieldMonoType ) ->
                                    -- Field is stored unboxed (as primitive).
                                    -- Project as primitive type, then box if caller needs eco.value.
                                    let
                                        fieldMlirType =
                                            Types.monoTypeToAbi fieldMonoType

                                        ( primitiveVar, ctx3_ ) =
                                            Ctx.freshVar ctx2

                                        ( ctx4, projectOp ) =
                                            Ops.ecoProjectCustom ctx3_ primitiveVar fieldIndex fieldMlirType subVar
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
                                    -- Project as eco.value, which is the default behavior.
                                    let
                                        ( ctxC, op ) =
                                            Ops.ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar
                                    in
                                    ( [ op ], resultVar, ctxC )

                        TypedPath.HintUnknown ->
                            -- Fallback: treat like custom
                            let
                                ( ctxU, op ) =
                                    Ops.ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar
                            in
                            ( [ op ], resultVar, ctxU )
            in
            ( subOps ++ projectOps, projectVar, ctx3 )

        TypedPath.Unbox subPath ->
            -- TypedPath.Unbox represents unwrapping a single-constructor type to access its single field.
            -- This is used for types like `Wrapper = Wrap Int` when pattern matching `Wrap x`.
            --
            -- We need to:
            -- 1. Get the container (wrapper) value by navigating subPath
            -- 2. Project field 0 to extract the inner value
            -- 3. If the field is stored unboxed, project as primitive; box if needed
            -- 4. If the field is stored boxed, project as eco.value; unbox if needed
            --
            -- The challenge is that DT.Path doesn't carry MonoType information.
            -- We search through ctorShapes for single-constructor single-field types
            -- that might have unboxed fields.
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Look for single-field single-constructor types with unboxed fields
                maybeUnboxedFieldInfo =
                    findSingleCtorUnboxedField ctx2

                ( projectOps, projectVar, ctx3 ) =
                    case maybeUnboxedFieldInfo of
                        Just ( fieldMonoType, True ) ->
                            -- Found a single-constructor type with an unboxed single field
                            let
                                fieldMlirType =
                                    Types.monoTypeToAbi fieldMonoType

                                ( primitiveVar, ctxP1 ) =
                                    Ctx.freshVar ctx2

                                ( ctxP2, projectOp ) =
                                    Ops.ecoProjectCustom ctxP1 primitiveVar 0 fieldMlirType subVar
                            in
                            if Types.isEcoValueType targetType then
                                -- Caller wants eco.value, need to box the primitive
                                let
                                    ( boxedVar, ctxP3 ) =
                                        Ctx.freshVar ctxP2

                                    ( ctxP4, boxOp ) =
                                        boxPrimitive ctxP3 boxedVar primitiveVar fieldMlirType
                                in
                                ( [ projectOp, boxOp ], boxedVar, ctxP4 )

                            else
                                -- Caller wants primitive, return directly
                                ( [ projectOp ], primitiveVar, ctxP2 )

                        _ ->
                            -- Either no single-ctor type found or field is boxed
                            -- Project field 0 as eco.value, then unbox if needed
                            let
                                ( ctxP1, projectOp ) =
                                    Ops.ecoProjectCustom ctx2 resultVar 0 Types.ecoValue subVar
                            in
                            if Types.isUnboxable targetType then
                                -- Caller wants primitive, need to unbox
                                let
                                    ( unboxedVar, ctxP2 ) =
                                        Ctx.freshVar ctxP1

                                    attrs =
                                        Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

                                    ( ctxP3, unboxOp ) =
                                        Ops.mlirOp ctxP2 "eco.unbox"
                                            |> Ops.opBuilder.withOperands [ resultVar ]
                                            |> Ops.opBuilder.withResults [ ( unboxedVar, targetType ) ]
                                            |> Ops.opBuilder.withAttrs attrs
                                            |> Ops.opBuilder.build
                                in
                                ( [ projectOp, unboxOp ], unboxedVar, ctxP3 )

                            else
                                -- Caller wants eco.value, return directly
                                ( [ projectOp ], resultVar, ctxP1 )
            in
            ( subOps ++ projectOps, projectVar, ctx3 )


{-| Generate MLIR ops to evaluate a DT.Test, returning a boolean result.

For constructor tests (IsCtor), we return the value to be tested with eco.case directly.
For other tests (IsBool, IsInt, etc.), we generate comparison ops that produce a boolean.

-}
generateTest : Ctx.Context -> Name.Name -> ( DT.Path, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateTest ctx root ( path, test ) =
    let
        -- Determine target type based on the test
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
            generateDTPath ctx root path targetType
    in
    case test of
        Test.IsCtor _ _ index _ _ ->
            -- Produce a boolean (i1) by comparing the tag
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
            -- valVar is a Bool; if expected is False, invert it
            if expected then
                ( pathOps, valVar, ctx1 )

            else
                let
                    ( resVar, ctx2 ) =
                        Ctx.freshVar ctx1

                    -- Invert boolean: result = 1 - valVar (xor with 1)
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
            -- Compare character codes
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
                    Ops.ecoBinaryOp ctx4 "arith.cmpi" resVar ( valVar, Types.ecoChar ) ( constVar, Types.ecoChar ) I1
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        Test.IsStr s ->
            -- String comparison - use kernel function
            let
                ( strVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Empty strings must use eco.constant EmptyString (invariant: never heap-allocated)
                ( ctx3, strOp ) =
                    if s == "" then
                        Ops.ecoConstantEmptyString ctx2 strVar

                    else
                        Ops.ecoStringLiteral ctx2 strVar s

                ( resVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, cmpOp ) =
                    Ops.ecoCallNamed ctx4 resVar "Elm_Kernel_Utils_equal" [ ( valVar, Types.ecoValue ), ( strVar, Types.ecoValue ) ] I1
            in
            ( pathOps ++ [ strOp, cmpOp ], resVar, ctx5 )

        Test.IsCons ->
            -- Test if list is non-empty (tag == 1)
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
            -- Test if list is empty (tag == 0)
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
            -- Tuples always match (we just need the value)
            let
                ( resVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, constOp ) =
                    Ops.arithConstantBool ctx2 resVar True
            in
            ( pathOps ++ [ constOp ], resVar, ctx3 )


{-| Generate the condition for a Chain node by ANDing all test booleans.
-}
generateChainCondition : Ctx.Context -> Name.Name -> List ( DT.Path, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateChainCondition ctx root tests =
    case tests of
        [] ->
            -- No tests means always true
            let
                ( resVar, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, constOp ) =
                    Ops.arithConstantBool ctx1 resVar True
            in
            ( [ constOp ], resVar, ctx2 )

        [ singleTest ] ->
            generateTest ctx root singleTest

        firstTest :: restTests ->
            let
                ( firstOps, firstVar, ctx1 ) =
                    generateTest ctx root firstTest

                ( restOps, restVar, ctx2 ) =
                    generateChainCondition ctx1 root restTests

                ( resVar, ctx3 ) =
                    Ctx.freshVar ctx2

                ( ctx4, andOp ) =
                    Ops.ecoBinaryOp ctx3 "arith.andi" resVar ( firstVar, I1 ) ( restVar, I1 ) I1
            in
            ( firstOps ++ restOps ++ [ andOp ], resVar, ctx4 )


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
            String.toList c |> List.head |> Maybe.map Char.toCode |> Maybe.withDefault 0

        Test.IsStr _ ->
            0

        Test.IsTuple ->
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
