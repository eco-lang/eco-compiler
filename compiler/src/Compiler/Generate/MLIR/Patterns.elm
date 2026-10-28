module Compiler.Generate.MLIR.Patterns exposing
    ( generateMonoPath, generateMonoDtPath, generateMonoTest, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag, resolvePathResultType
    , materializeSplitParam
    )

{-| Pattern matching compiles to two kinds of question about the value being
matched, the _scrutinee_, and this module emits the MLIR ops that ask them.

The first question is "what is at this position inside the scrutinee?". A
_path_ (`Mono.MonoPath`, or the decision-tree form `Mono.MonoDtPath`) names a
position: the scrutinee itself, an index into a list cell, tuple or
constructor, a record field, or the one field of a single-constructor type.
`generateMonoPath` emits the projections that walk a path and returns the
value at the caller's _target type_, the MLIR type the caller wants it in.
The value may be stored in a different form from the target: Int, Float and
Char fields can be stored unboxed while every other field, Bool included, is
an `!eco.value` (see `Compiler.Generate.MLIR.Types` for the layouts). Most of
this module is therefore the matching of stored form to target type, adding
an `eco.box` or an `eco.unbox` where they differ.

The second question is "does that value pass this decision-tree test?".
`generateMonoTest` returns an `i1` for one test, and `testToTagInt`,
`caseKindFromTest`, `scrutineeTypeFromCaseKind` and `computeFallbackTag`
supply the attributes of an `eco.case` that dispatches on several tests at
once. A constructor's tag is the one `Compiler.Data.CtorTag` assigns.

A path may also start at a _scalar-split_ loop parameter, a tuple or
constructor that a tail-recursive loop holds as one SSA variable per field
(`Ctx.SplitParamInfo`). A projection of such a root reads the field's
variable directly, a shape test on it is decided at compile time, and a use
of the whole value rebuilds it on the heap with `materializeSplitParam`.

@docs generateMonoPath, generateMonoDtPath, generateMonoTest, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag, resolvePathResultType
@docs materializeSplitParam

-}

import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Utils.Crash



-- ====== HELPERS ======


{-| Returns the fields of a record type, or an empty dict for any other type.
-}
getRecordFields : Mono.MonoType -> Dict.Dict Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord _ fields ->
            fields

        _ ->
            Dict.empty


{-| Returns the first field layout entry named `targetName`, if any.
-}
findFieldInfoByName : Name.Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInfoByName targetName fields =
    List.filter (\fi -> fi.name == targetName) fields
        |> List.head



-- ====== MONO PATH GENERATION ======


{-| Returns the ops that read the value at `path`, the variable holding it at
`targetType`, and the updated context.

A tuple field or single-constructor field read from the heap that is stored
boxed while the target is an unboxed primitive crashes the compiler.

-}
generateMonoPath : Ctx.Context -> Mono.MonoPath -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateMonoPath ctx path targetType =
    let
        ( revOps, var, ctx_ ) =
            generateMonoPathHelper ctx path targetType []
    in
    ( List.reverse revOps, var, ctx_ )


{-| Returns the ops that read the value at a decision-tree path, as
`generateMonoPath` does for the equivalent `MonoPath`.
-}
generateMonoDtPath : Ctx.Context -> Mono.MonoDtPath -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateMonoDtPath ctx dtPath targetType =
    generateMonoPath ctx (dtPathToMonoPath dtPath) targetType


{-| Returns the `MonoPath` naming the same position as a decision-tree path.
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


{-| Returns the ops that compute an `i1` saying whether the value at `dtPath`
passes `test`, and the variable holding it.

A constructor, cons or nil test compares the value's `eco.get_tag` with
`testToTagInt`, except on a scalar-split root, where the answer is a
constant. An Int or Char test compares the unboxed value with the
literal. A String test uses `eco.value.eq` when `ecoConfig.valueEq` is on and
otherwise calls `Elm_Kernel_Utils_equal` and unboxes its result. A Bool test
is the value itself, or its negation. A tuple test is always true.

-}
generateMonoTest : Ctx.Context -> ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateMonoTest ctx ( dtPath, test ) =
    case splitTestFastPath ctx dtPath test of
        Just result ->
            result

        Nothing ->
            generateMonoTestGeneral ctx ( dtPath, test )


{-| Returns a constant `i1` for a tuple or constructor test whose path is a
scalar-split parameter itself, or `Nothing` for any other test or path.

The split's layout fixes the value's shape, so the answer is known at compile
time: a tuple test is true, and a constructor test is true exactly when the
layout's tag equals the test's. Answering here avoids rebuilding the value on
the heap only to read its tag.

-}
splitTestFastPath : Ctx.Context -> Mono.MonoDtPath -> DT.Test -> Maybe ( List MlirOp, String, Ctx.Context )
splitTestFastPath ctx dtPath test =
    case dtPath of
        Mono.DtRoot rootName _ ->
            case Dict.get rootName ctx.splitAggParams of
                Just info ->
                    case ( test, info.split ) of
                        ( Test.IsTuple, _ ) ->
                            let
                                ( resVar, ctx1 ) =
                                    Ctx.freshVar ctx

                                ( ctx2, constOp ) =
                                    Ops.arithConstantBool ctx1 resVar True
                            in
                            Just ( [ constOp ], resVar, ctx2 )

                        ( Test.IsCtor _ _ _ _ _, Ctx.SplitCtor clayout ) ->
                            let
                                ( resVar, ctx1 ) =
                                    Ctx.freshVar ctx

                                ( ctx2, constOp ) =
                                    Ops.arithConstantBool ctx1 resVar (clayout.tag == testToTagInt test)
                            in
                            Just ( [ constOp ], resVar, ctx2 )

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the ops for `generateMonoTest` when the answer is not known at
compile time: it reads the value at the type the test compares in, then
compares.
-}
generateMonoTestGeneral : Ctx.Context -> ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateMonoTestGeneral ctx ( dtPath, test ) =
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
        Test.IsCtor _ _ _ _ _ ->
            let
                -- The same tag an eco.case dispatch uses, so both agree.
                expectedTag =
                    testToTagInt test

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
                    decodeChrPatternCode c

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

                -- Both operands are Strings, so both are !eco.value and need
                -- no type check before eco.value.eq.
                ( eqOps, resVar, ctx6 ) =
                    if ctx.ecoConfig.valueEq then
                        let
                            ( ctx5, veqOp ) =
                                Ops.ecoBinaryOp ctx4 "eco.value.eq" eqVar ( valVar, Types.ecoValue ) ( strVar, Types.ecoValue ) I1
                        in
                        ( [ veqOp ], eqVar, ctx5 )

                    else
                        let
                            ( ctx5, cmpOp ) =
                                Ops.ecoCallNamed ctx4 eqVar "Elm_Kernel_Utils_equal" [ ( valVar, Types.ecoValue ), ( strVar, Types.ecoValue ) ] Types.ecoValue

                            ( unboxOps, unboxedVar, ctx5b ) =
                                Intrinsics.unboxToType ctx5 eqVar I1
                        in
                        ( cmpOp :: unboxOps, unboxedVar, ctx5b )
            in
            ( pathOps ++ [ strOp ] ++ eqOps, resVar, ctx6 )

        Test.IsCons ->
            let
                ( tagVar, ctx2 ) =
                    Ctx.freshVar ctx1

                ( ctx3, tagOp ) =
                    Ops.ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( ctx5, constOp ) =
                    Ops.arithConstantInt32 ctx4 constVar (testToTagInt test)

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
                    Ops.arithConstantInt32 ctx4 constVar (testToTagInt test)

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


{-| Returns the ops that build a scalar-split value on the heap from its
current field variables, and the variable holding the new `!eco.value`.

This is how the whole value is read. Elm values are immutable and compared by
structure, so the copy cannot be told apart from the original. A split tuple
with other than two or three fields crashes the compiler.

-}
materializeSplitParam : Ctx.Context -> Ctx.SplitParamInfo -> ( List MlirOp, String, Ctx.Context )
materializeSplitParam ctx info =
    let
        ( resultVar, ctx1 ) =
            Ctx.freshVar ctx
    in
    case info.split of
        Ctx.SplitTuple layout ->
            case info.slots of
                [ a, b ] ->
                    let
                        ( ctx2, op ) =
                            Ops.ecoConstructTuple2 ctx1 resultVar a b layout.unboxedBitmap
                    in
                    ( [ op ], resultVar, ctx2 )

                [ a, b, c ] ->
                    let
                        ( ctx2, op ) =
                            Ops.ecoConstructTuple3 ctx1 resultVar a b c layout.unboxedBitmap
                    in
                    ( [ op ], resultVar, ctx2 )

                _ ->
                    Utils.Crash.crash "materializeSplitParam: tuple slot arity not 2/3"

        Ctx.SplitCtor layout ->
            let
                ( ctx2, op ) =
                    Ops.ecoConstructCustom ctx1 resultVar layout.tag (List.length info.slots) (Types.ctorSlotKinds layout) info.slots (Just layout.name)
            in
            ( [ op ], resultVar, ctx2 )


{-| Returns `slotVar`, held at `storedType`, converted to `targetType`: boxed
when a primitive meets an `!eco.value` target, unboxed when an `!eco.value`
meets an `i1` or primitive target, and returned unchanged otherwise.
-}
coerceSlotToTarget : Ctx.Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Ctx.Context )
coerceSlotToTarget ctx slotVar storedType targetType =
    if storedType == targetType then
        ( [], slotVar, ctx )

    else if Types.isEcoValueType targetType && Types.isUnboxable storedType then
        let
            ( boxedVar, ctx1 ) =
                Ctx.freshVar ctx

            ( ctx2, boxOp ) =
                boxPrimitive ctx1 boxedVar slotVar storedType
        in
        ( [ boxOp ], boxedVar, ctx2 )

    else if Types.isEcoValueType storedType && (targetType == I1 || Types.isUnboxable targetType) then
        Intrinsics.unboxToType ctx slotVar targetType

    else
        ( [], slotVar, ctx )


{-| Returns the split information when `sub` is itself the root and names a
scalar-split parameter, and `Nothing` for any longer path.
-}
splitRootOf : Ctx.Context -> Mono.MonoPath -> Maybe Ctx.SplitParamInfo
splitRootOf ctx sub =
    case sub of
        Mono.MonoRoot rootName _ ->
            Dict.get rootName ctx.splitAggParams

        _ ->
            Nothing


{-| Returns field `index` of a scalar-split value at `targetType`. The field
is already a variable, so the only ops are any box or unbox. An index past
the last field crashes the compiler.
-}
splitSlotRead : Ctx.Context -> Ctx.SplitParamInfo -> Int -> MlirType -> ( List MlirOp, String, Ctx.Context )
splitSlotRead ctx info index targetType =
    case List.head (List.drop index info.slots) of
        Just ( slotVar, storedType ) ->
            coerceSlotToTarget ctx slotVar storedType targetType

        Nothing ->
            Utils.Crash.crash "splitSlotRead: slot index out of range"


{-| Returns what `generateMonoPath` returns, with the ops pushed onto
`revAcc` in reverse order.
-}
generateMonoPathHelper : Ctx.Context -> Mono.MonoPath -> MlirType -> List MlirOp -> ( List MlirOp, String, Ctx.Context )
generateMonoPathHelper ctx path targetType revAcc =
    case path of
        Mono.MonoRoot name _ ->
            case Dict.get name ctx.splitAggParams of
                Just splitInfo ->
                    let
                        ( matOps, matVar, ctxM ) =
                            materializeSplitParam ctx splitInfo

                        ( coOps, finalVar, ctxC ) =
                            coerceSlotToTarget ctxM matVar Types.ecoValue targetType
                    in
                    ( List.foldl (::) revAcc (matOps ++ coOps), finalVar, ctxC )

                Nothing ->
                    generateMonoRootOnHeap ctx name targetType revAcc

        Mono.MonoIndex index containerKind resultType subPath ->
            case splitRootOf ctx subPath of
                Just splitInfo ->
                    let
                        ( slotOps, slotFinalVar, ctxSlot ) =
                            splitSlotRead ctx splitInfo index targetType
                    in
                    ( List.foldl (::) revAcc slotOps, slotFinalVar, ctxSlot )

                Nothing ->
                    generateMonoIndexOnHeap ctx targetType revAcc index containerKind resultType subPath

        Mono.MonoUnbox _ subPath ->
            case splitRootOf ctx subPath of
                Just splitInfo ->
                    let
                        ( slotOps, slotFinalVar, ctxSlot ) =
                            splitSlotRead ctx splitInfo 0 targetType
                    in
                    ( List.foldl (::) revAcc slotOps, slotFinalVar, ctxSlot )

                Nothing ->
                    generateMonoUnboxOnHeap ctx targetType revAcc subPath

        Mono.MonoField fieldName fieldResultType subPath ->
            -- No split check: a split value is a tuple or constructor, never
            -- a record, and a split root reached by the descent is handled
            -- there.
            generateMonoFieldOnHeap ctx targetType revAcc fieldName fieldResultType subPath


{-| Returns the variable bound to the root `name`, unboxed first when it is
an `!eco.value` and the target is `i1` or an unboxed primitive.
-}
generateMonoRootOnHeap : Ctx.Context -> Name.Name -> MlirType -> List MlirOp -> ( List MlirOp, String, Ctx.Context )
generateMonoRootOnHeap ctx name targetType revAcc =
    let
        ( varName, actualType ) =
            Ctx.lookupVar ctx name
    in
    if Types.isEcoValueType actualType && (targetType == I1 || Types.isUnboxable targetType) then
        -- Returning the boxed variable here would give it the wrong SSA type.
        let
            ( unboxOps, unboxedVar, ctxU ) =
                Intrinsics.unboxToType ctx varName targetType
        in
        ( List.foldl (::) revAcc unboxOps, unboxedVar, ctxU )

    else
        ( revAcc, varName, ctx )


{-| Returns the ops that read element `index` of the list cell, tuple or
constructor that `subPath` reaches, at `targetType`.

A list cell's index 0 is its head, read at the target type, and any other
index is its tail. A tuple element is stored unboxed when the ABI type of
`resultType` is a primitive. A constructor field's storage comes from the
shape registry (`lookupCtorFieldInfo`); when the registry has no entry, the
ABI type of `resultType` decides.

-}
generateMonoIndexOnHeap : Ctx.Context -> MlirType -> List MlirOp -> Int -> Mono.ContainerKind -> Mono.MonoType -> Mono.MonoPath -> ( List MlirOp, String, Ctx.Context )
generateMonoIndexOnHeap ctx targetType revAcc index containerKind resultType subPath =
    let
        -- The container is an !eco.value, except a root variable held as a
        -- value aggregate, whose type `aggOperand` carries to the projection.
        ( revAcc1, subVar, ctx1 ) =
            generateMonoPathHelper ctx subPath Types.ecoValue revAcc

        aggOperand =
            case subPath of
                Mono.MonoRoot rootName _ ->
                    let
                        ( _, rootTy ) =
                            Ctx.lookupVar ctx rootName
                    in
                    if Types.isAggValueType rootTy then
                        Just rootTy

                    else
                        Nothing

                _ ->
                    Nothing

        projCustom ctxP rv idx rt =
            case aggOperand of
                Just aggTy ->
                    Ops.ecoProjectCustomAgg ctxP rv idx rt ( subVar, aggTy )

                Nothing ->
                    Ops.ecoProjectCustom ctxP rv idx rt subVar

        projTuple2 ctxP rv idx rt =
            case aggOperand of
                Just aggTy ->
                    Ops.ecoProjectTuple2Agg ctxP rv idx rt ( subVar, aggTy )

                Nothing ->
                    Ops.ecoProjectTuple2 ctxP rv idx rt subVar

        projTuple3 ctxP rv idx rt =
            case aggOperand of
                Just aggTy ->
                    Ops.ecoProjectTuple3Agg ctxP rv idx rt ( subVar, aggTy )

                Nothing ->
                    Ops.ecoProjectTuple3 ctxP rv idx rt subVar

        ( resultVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( projectOps, projectVar, ctx3 ) =
            case containerKind of
                Mono.ListContainer ->
                    if index == 0 then
                        let
                            ( ctx_, op ) =
                                Ops.ecoProjectListHead ctx2 resultVar targetType subVar
                        in
                        ( [ op ], resultVar, ctx_ )

                    else
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
                        let
                            ( primitiveVar, ctx3_ ) =
                                Ctx.freshVar ctx2

                            ( ctx4, projectOp ) =
                                projTuple2 ctx3_ primitiveVar index fieldAbiType
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
                        let
                            ( valVar, ctx3_ ) =
                                Ctx.freshVar ctx2

                            ( ctx4, projectOp ) =
                                projTuple2 ctx3_ valVar index Types.ecoValue
                        in
                        if targetType == I1 then
                            let
                                ( unboxOps, unboxedVar, ctxU ) =
                                    Intrinsics.unboxToType ctx4 valVar I1
                            in
                            ( projectOp :: unboxOps, unboxedVar, ctxU )

                        else if Types.isUnboxable targetType then
                            -- The element is stored boxed but the target is
                            -- an unboxed primitive: the two views of the value
                            -- disagree on its layout, and the compile stops.
                            Utils.Crash.crash "MONO_029 layout disagreement: erased tuple2 element vs unboxable destructor target — see plans/solver-layout-connectivity-reconciliation.md"

                        else
                            ( [ projectOp ], valVar, ctx4 )

                Mono.Tuple3Container ->
                    let
                        fieldAbiType =
                            Types.monoTypeToAbi resultType
                    in
                    if Types.isUnboxable fieldAbiType then
                        let
                            ( primitiveVar, ctx3_ ) =
                                Ctx.freshVar ctx2

                            ( ctx4, projectOp ) =
                                projTuple3 ctx3_ primitiveVar index fieldAbiType
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
                        let
                            ( valVar, ctx3_ ) =
                                Ctx.freshVar ctx2

                            ( ctx4, projectOp ) =
                                projTuple3 ctx3_ valVar index Types.ecoValue
                        in
                        if targetType == I1 then
                            let
                                ( unboxOps, unboxedVar, ctxU ) =
                                    Intrinsics.unboxToType ctx4 valVar I1
                            in
                            ( projectOp :: unboxOps, unboxedVar, ctxU )

                        else if Types.isUnboxable targetType then
                            -- Layouts disagree; see the Tuple2Container arm.
                            Utils.Crash.crash "MONO_029 layout disagreement: erased tuple3 element vs unboxable destructor target — see plans/solver-layout-connectivity-reconciliation.md"

                        else
                            ( [ projectOp ], valVar, ctx4 )

                Mono.CustomContainer ctorName ->
                    let
                        containerType =
                            Mono.getMonoPathType subPath

                        maybeFieldInfo =
                            lookupCtorFieldInfo ctx2 containerType ctorName index
                    in
                    case maybeFieldInfo of
                        Just fieldInfo ->
                            if fieldInfo.isUnboxed then
                                -- The registry's field type, not `resultType`, which
                                -- can still be a type variable for a specialized
                                -- polymorphic constructor such as `Done a` at `a = Int`.
                                let
                                    fieldMlirType =
                                        Types.monoTypeToAbi fieldInfo.monoType

                                    ( primitiveVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        projCustom ctx3_ primitiveVar index fieldMlirType
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
                            -- The slot holds an !eco.value, so an i1 or primitive
                            -- target is read through eco.unbox.
                            if
                                targetType == I1 || Types.isUnboxable targetType
                            then
                                let
                                    ( valVar, ctxV ) =
                                        Ctx.freshVar ctx2

                                    ( ctxP, projectOp ) =
                                        projCustom ctxV valVar index Types.ecoValue

                                    ( unboxOps, unboxedVar, ctxU ) =
                                        Intrinsics.unboxToType ctxP valVar targetType
                                in
                                ( projectOp :: unboxOps, unboxedVar, ctxU )

                            else
                                let
                                    ( ctx_, op ) =
                                        projCustom ctx2 resultVar index targetType
                                in
                                ( [ op ], resultVar, ctx_ )

                        Nothing ->
                            let
                                fieldMlirType =
                                    Types.monoTypeToAbi resultType
                            in
                            if Types.isUnboxable fieldMlirType then
                                let
                                    ( primitiveVar, ctx3_ ) =
                                        Ctx.freshVar ctx2

                                    ( ctx4, projectOp ) =
                                        projCustom ctx3_ primitiveVar index fieldMlirType
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
                            -- Unlike the registry branch, only an i1 target is
                            -- unboxed here.
                            if
                                targetType == I1
                            then
                                let
                                    ( valVar, ctxV ) =
                                        Ctx.freshVar ctx2

                                    ( ctxP, projectOp ) =
                                        projCustom ctxV valVar index Types.ecoValue

                                    ( unboxOps, unboxedVar, ctxU ) =
                                        Intrinsics.unboxToType ctxP valVar I1
                                in
                                ( projectOp :: unboxOps, unboxedVar, ctxU )

                            else
                                let
                                    ( ctx_, op ) =
                                        projCustom ctx2 resultVar index targetType
                                in
                                ( [ op ], resultVar, ctx_ )
    in
    ( List.foldl (::) revAcc1 projectOps
    , projectVar
    , ctx3
    )


{-| Returns the ops that read the record field `fieldName` of the record that
`subPath` reaches, at `targetType`.

The field's slot and stored form come from `Types.computeRecordLayout` of the
record's type, and the read is boxed or unboxed to meet the target. A field
missing from that layout crashes the compiler.

-}
generateMonoFieldOnHeap : Ctx.Context -> MlirType -> List MlirOp -> Name.Name -> Mono.MonoType -> Mono.MonoPath -> ( List MlirOp, String, Ctx.Context )
generateMonoFieldOnHeap ctx targetType revAcc fieldName resultType subPath =
    let
        ( revAcc1, subVar, ctx1 ) =
            generateMonoPathHelper ctx subPath Types.ecoValue revAcc

        ( resultVar, ctx2 ) =
            Ctx.freshVar ctx1

        containerType =
            Mono.getMonoPathType subPath

        layout =
            Types.computeRecordLayout (getRecordFields containerType)

        fieldInfo =
            case findFieldInfoByName fieldName layout.fields of
                Just fi ->
                    fi

                Nothing ->
                    Utils.Crash.crash ("generateMonoFieldOnHeap: field " ++ fieldName ++ " is not in the record layout")

        storedType =
            if fieldInfo.isUnboxed then
                Types.monoTypeToAbi fieldInfo.monoType

            else
                Types.ecoValue
    in
    if storedType == targetType then
        let
            ( ctx3, projectOp ) =
                Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
        in
        ( projectOp :: revAcc1, resultVar, ctx3 )

    else if fieldInfo.isUnboxed && Types.isEcoValueType targetType then
        let
            ( primVar, ctxA ) =
                Ctx.freshVar ctx2

            ( ctxB, projectOp ) =
                Ops.ecoProjectRecord ctxA primVar fieldInfo.index storedType subVar

            ( ctxC, boxOp ) =
                boxPrimitive ctxB resultVar primVar storedType
        in
        ( boxOp :: projectOp :: revAcc1, resultVar, ctxC )

    else if not fieldInfo.isUnboxed && (targetType == I1 || Types.isUnboxable targetType) then
        let
            ( valVar, ctxA ) =
                Ctx.freshVar ctx2

            ( ctxB, projectOp ) =
                Ops.ecoProjectRecord ctxA valVar fieldInfo.index Types.ecoValue subVar

            ( unboxOps, unboxedVar, ctxC ) =
                Intrinsics.unboxToType ctxB valVar targetType
        in
        ( List.foldl (::) (projectOp :: revAcc1) unboxOps, unboxedVar, ctxC )

    else
        let
            ( ctx3, projectOp ) =
                Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
        in
        ( projectOp :: revAcc1, resultVar, ctx3 )


{-| Returns the ops that read the one field of the single-constructor value
that `subPath` reaches, at `targetType`.

The field's stored form comes from the first registered shape for the
container's type. When there is no shape, or the shape has no fields, the
container value itself is returned with no projection added, whatever
`targetType` is.

-}
generateMonoUnboxOnHeap : Ctx.Context -> MlirType -> List MlirOp -> Mono.MonoPath -> ( List MlirOp, String, Ctx.Context )
generateMonoUnboxOnHeap ctx targetType revAcc subPath =
    let
        containerType =
            Mono.getMonoPathType subPath

        ( revAcc1, subVar, ctx1 ) =
            generateMonoPathHelper ctx subPath Types.ecoValue revAcc

        -- A root held as a custom-type value aggregate is projected through
        -- its aggregate type.
        unboxAggOperand =
            case subPath of
                Mono.MonoRoot rootName _ ->
                    let
                        ( _, rootTy ) =
                            Ctx.lookupVar ctx rootName
                    in
                    if Types.isAggCustomType rootTy then
                        Just rootTy

                    else
                        Nothing

                _ ->
                    Nothing

        projCustomUnbox ctxP rv rt =
            case unboxAggOperand of
                Just aggTy ->
                    Ops.ecoProjectCustomAgg ctxP rv 0 rt ( subVar, aggTy )

                Nothing ->
                    Ops.ecoProjectCustom ctxP rv 0 rt subVar

        maybeShapes =
            Mono.layoutMapGet containerType ctx1.typeRegistry.ctorShapes
    in
    case maybeShapes of
        Just (shape :: _) ->
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
                        let
                            ( ctx3, projectOp ) =
                                projCustomUnbox ctx2 resultVar fieldMlirType
                        in
                        if Types.isEcoValueType targetType then
                            let
                                ( boxedVar, ctx4 ) =
                                    Ctx.freshVar ctx3

                                ( ctx5, boxOp ) =
                                    boxPrimitive ctx4 boxedVar resultVar fieldMlirType
                            in
                            ( boxOp :: projectOp :: revAcc1, boxedVar, ctx5 )

                        else
                            ( projectOp :: revAcc1, resultVar, ctx3 )

                    else
                        let
                            ( ctx3, projectOp ) =
                                projCustomUnbox ctx2 resultVar Types.ecoValue
                        in
                        if targetType == I1 then
                            let
                                ( unboxOps, unboxedVar, ctxU ) =
                                    Intrinsics.unboxToType ctx3 resultVar I1
                            in
                            ( List.foldl (::) (projectOp :: revAcc1) unboxOps, unboxedVar, ctxU )

                        else if Types.isUnboxable targetType then
                            -- Layouts disagree; see generateMonoIndexOnHeap's tuple arms.
                            Utils.Crash.crash "MONO_029 layout disagreement: erased unboxed-custom field vs unboxable destructor target — see plans/solver-layout-connectivity-reconciliation.md"

                        else if Types.isUnboxable targetType then
                            -- Unreachable: the branch above has the same condition.
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
                            ( projectOp :: revAcc1, resultVar, ctx3 )

                [] ->
                    ( revAcc1, subVar, ctx1 )

        _ ->
            ( revAcc1, subVar, ctx1 )


{-| Returns the type of the value at `path`, with a constructor field's type
taken from the shape registry when the path's own type contains a type
variable.

A specialized polymorphic constructor such as `Done a` at `a = Int` can reach
here with its path type still holding `a`, while the field is stored as an
unboxed `i64`. Only a constructor-field index is resolved this way, and only
to a registry type with no type variable; in
every other case the path's own type is returned.

-}
resolvePathResultType : Ctx.Context -> Mono.MonoPath -> Mono.MonoType
resolvePathResultType ctx path =
    let
        raw =
            Mono.getMonoPathType path
    in
    if Mono.containsAnyMVar raw then
        case path of
            Mono.MonoIndex index (Mono.CustomContainer ctorName) _ subPath ->
                let
                    containerType =
                        Mono.getMonoPathType subPath
                in
                case lookupCtorFieldInfo ctx containerType ctorName index of
                    Just fieldInfo ->
                        if fieldIsConcrete fieldInfo then
                            fieldInfo.monoType

                        else
                            raw

                    Nothing ->
                        raw

            _ ->
                raw

    else
        raw


{-| Returns the layout entry of field `fieldIndex` of constructor `ctorName`,
from the shapes registered for `containerType`.

When that entry's type still contains a type variable, the entry of a
same-union shape whose type has none is returned instead, if
`findConcreteCtorField` finds one; otherwise the entry with the type variable
is returned. When the registered shapes have no such field, the answer is
`findConcreteCtorField`'s. With no shapes registered for `containerType` the
result is `Nothing`.

-}
lookupCtorFieldInfo : Ctx.Context -> Mono.MonoType -> Name.Name -> Int -> Maybe Types.FieldInfo
lookupCtorFieldInfo ctx containerType ctorName fieldIndex =
    let
        preferredShapes : Maybe (List Mono.CtorShape)
        preferredShapes =
            Mono.layoutMapGet containerType ctx.typeRegistry.ctorShapes

        preferred : Maybe Types.FieldInfo
        preferred =
            Maybe.andThen (ctorFieldFromShapes ctorName fieldIndex) preferredShapes
    in
    case preferred of
        Just info ->
            if fieldIsConcrete info then
                Just info

            else
                Just (Maybe.withDefault info (findConcreteCtorField ctx preferredShapes ctorName fieldIndex))

        Nothing ->
            findConcreteCtorField ctx preferredShapes ctorName fieldIndex


{-| Returns the layout entry of field `fieldIndex` of the first shape named
`ctorName` among `shapes`, if there is one.
-}
ctorFieldFromShapes : Name.Name -> Int -> List Mono.CtorShape -> Maybe Types.FieldInfo
ctorFieldFromShapes ctorName fieldIndex shapes =
    case List.filter (\shape -> shape.name == ctorName) shapes of
        shape :: _ ->
            case List.drop fieldIndex (Types.computeCtorLayout shape).fields of
                fieldInfo :: _ ->
                    Just fieldInfo

                [] ->
                    Nothing

        [] ->
            Nothing


{-| Returns field `fieldIndex` of `ctorName` from the registered shapes of the
same union as `referenceShapes`, when every such entry with no type variable
has the same layout key (`Mono.eqKeyLayout`).

Two shape lists belong to the same union when they hold the same constructor
names. A field that is genuinely polymorphic across specializations, `Int` in
one and `String` in another, gives `Nothing`, as do no concrete entry and no
`referenceShapes`.

-}
findConcreteCtorField : Ctx.Context -> Maybe (List Mono.CtorShape) -> Name.Name -> Int -> Maybe Types.FieldInfo
findConcreteCtorField ctx referenceShapes ctorName fieldIndex =
    case referenceShapes of
        Nothing ->
            Nothing

        Just refShapes ->
            let
                refNames : List Name.Name
                refNames =
                    List.sort (List.map .name refShapes)

                sameUnion : List Mono.CtorShape -> Bool
                sameUnion shapes =
                    List.sort (List.map .name shapes) == refNames

                concreteCandidates : List Types.FieldInfo
                concreteCandidates =
                    Mono.layoutMapValues ctx.typeRegistry.ctorShapes
                        |> List.filter sameUnion
                        |> List.filterMap (ctorFieldFromShapes ctorName fieldIndex)
                        |> List.filter fieldIsConcrete
            in
            case concreteCandidates of
                [] ->
                    Nothing

                firstInfo :: rest ->
                    let
                        allAgree =
                            List.all
                                (\fi -> Mono.eqKeyLayout fi.monoType firstInfo.monoType)
                                rest
                    in
                    if allAgree then
                        Just firstInfo

                    else
                        Nothing


{-| Returns whether a field's type contains no type variable.
-}
fieldIsConcrete : Types.FieldInfo -> Bool
fieldIsConcrete info =
    not (Mono.containsAnyMVar info.monoType)


{-| Returns an `eco.box` op that boxes `primitiveVar`, of type `primType`,
into `resultVar`.
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


{-| Returns the integer an `eco.case` alternative uses for `test`.

A constructor test gives `CtorTag.constantTag` for `Maybe.Nothing`,
`Basics.True` and `Basics.False`, which the runtime represents as fixed
constants, and `CtorTag.effective` for every other constructor. `[]` also
gives `CtorTag.constantTag`, and `::` gives 1. A Bool test gives 1 or 0, an
Int test its literal and a Char test its code point. String and tuple tests
give 0.

-}
testToTagInt : DT.Test -> Int
testToTagInt test =
    case test of
        Test.IsCtor home ctorName index _ _ ->
            if CtorTag.isEmbeddedConstantCtor home ctorName then
                CtorTag.constantTag

            else
                CtorTag.effective home ctorName index

        Test.IsCons ->
            1

        Test.IsNil ->
            CtorTag.constantTag

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


{-| Returns the code point of a Char pattern's text.

The text is one character, or the escape sequence as the parser stores it (a
`\u{...}` source escape is stored as `\uXXXX`):
a backslash followed by `n`, `r`, `t` or any other character, which then
stands for itself, or a single `\uXXXX` escape. Text of any other form gives
0. Two `\u` escapes forming a surrogate pair (the parser's spelling of a
Char above U+FFFF) give the code point they encode, above `0xFFFF`.

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
                    Char.toCode escaped

        '\\' :: 'u' :: hexChars ->
            decodeUnicodeEscapeChars hexChars

        _ ->
            0


{-| Returns the code point of a `\uXXXX` escape whose characters after the
`u` are `chars`. A high surrogate followed by a `\uXXXX` low surrogate gives
the code point the pair encodes, by the same formula as
`Expr.decodeSurrogatePair`.
-}
decodeUnicodeEscapeChars : List Char -> Int
decodeUnicodeEscapeChars chars =
    let
        hexValue digits =
            List.foldl (\ch acc -> acc * 16 + hexDigitToInt ch) 0 digits

        hi =
            hexValue (List.take 4 chars)
    in
    case List.drop 4 chars of
        '\\' :: 'u' :: loChars ->
            if hi >= 0xD800 && hi <= 0xDBFF then
                0x00010000 + ((hi - 0xD800) * 0x0400) + (hexValue (List.take 4 loChars) - 0xDC00)

            else
                hi

        _ ->
            hi


{-| Returns the value of a hexadecimal digit of either case, or 0 for any
other character.
-}
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


{-| Returns the `case_kind` attribute of an `eco.case` whose alternatives are
tests like `test`: `"int"`, `"chr"` or `"str"` for literal tests, and
`"ctor"` for every other test, Bool and tuple tests included.
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


{-| Returns the scrutinee type an `eco.case` of `caseKind` takes: `i64` for
`"int"`, `i32` for `"chr"`, and `!eco.value` for any other kind.
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

        _ ->
            Types.ecoValue


{-| Returns the tag of the fallback alternative of an `eco.case` whose other
alternatives are `edgeTests`.

A single Bool test gives the other Bool tag, a single `::` test gives 0 and a
single `[]` test gives 1. Any other set of tests gives the smallest
non-negative integer that no edge's `testToTagInt` uses.

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
            -- Sorting and scanning makes the cost depend on the number of
            -- edges, not on the size of the largest Int literal.
            firstUnusedTag 0 (List.sort (List.map testToTagInt edgeTests))


{-| Returns the smallest integer, no lower than `candidate`, that is absent
from the ascending list `sortedTags`. Tags below `candidate` and repeated tags
are skipped.
-}
firstUnusedTag : Int -> List Int -> Int
firstUnusedTag candidate sortedTags =
    case sortedTags of
        [] ->
            candidate

        t :: rest ->
            if t < candidate then
                firstUnusedTag candidate rest

            else if t == candidate then
                firstUnusedTag (candidate + 1) rest

            else
                candidate
