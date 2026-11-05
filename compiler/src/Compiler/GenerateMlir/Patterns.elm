module Compiler.GenerateMlir.Patterns exposing
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
an `!eco.value` (see `Compiler.GenerateMlir.Types` for the layouts). Most of
this module is therefore the matching of stored form to target type, adding
an `eco.box` or an `eco.unbox` where they differ.

The second question is "does that value pass this decision-tree test?".
`generateMonoTest` returns an `i1` for one test, and `testToTagInt`,
`caseKindFromTest`, `scrutineeTypeFromCaseKind` and `computeFallbackTag`
supply the attributes of an `eco.case` that dispatches on several tests at
once. A constructor's tag is the one `Compiler.IR.Runtime.CtorTag` assigns.

A path may also start at a _scalar-split_ loop parameter, a tuple or
constructor that a tail-recursive loop holds as one SSA variable per field
(`Ctx.SplitParamInfo`). A projection of such a root reads the field's
variable directly. A path never reads the whole value or tests its shape;
`materializeSplitParam` rebuilds it on the heap for the expression code.

@docs generateMonoPath, generateMonoDtPath, generateMonoTest, testToTagInt, caseKindFromTest, scrutineeTypeFromCaseKind, computeFallbackTag, resolvePathResultType
@docs materializeSplitParam

-}

import Compiler.Core.Index as Index
import Compiler.Core.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateMlir.Context as Ctx
import Compiler.GenerateMlir.Intrinsics as Intrinsics
import Compiler.GenerateMlir.Ops as Ops
import Compiler.GenerateMlir.Types as Types
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Mono as Mono
import Compiler.IR.Runtime.CtorTag as CtorTag
import Compiler.IR.Source.StringLiteral as StringLiteral
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Dict
import Mlir.Mlir exposing (MlirOp, MlirType(..))
import System.Crash



-- ====== HELPERS ======


{-| Returns the fields of a record type. A `MonoField` step reads a record
(MONO\_001), so any other type crashes the compile.
-}
getRecordFields : Mono.MonoType -> Dict.Dict Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord _ fields ->
            fields

        _ ->
            System.Crash.crash "Patterns.getRecordFields: MONO_001 record field path whose container is not an MRecord"


{-| Returns the first field layout entry named `targetName`, if any.
-}
findFieldInfoByName : Name.Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInfoByName targetName fields =
    List.filter (\fi -> fi.name == targetName) fields
        |> List.head



-- ====== MONO PATH GENERATION ======


{-| Returns the ops that read the value at `path`, the variable holding it at
`targetType`, and the updated context.

A read whose target disagrees with how the heap layout stores the value,
boxed against unboxed, crashes the compiler (`layoutDisagreement`, MONO_029);
a stored `!eco.value` read at `i1` is unboxed.

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

A constructor, cons or nil test compares the value's `eco.get_tag` with the
constructor's `ctorTagInt`, with 1 for cons, or with `CtorTag.constantTag` for
nil. An Int or Char test compares the unboxed value with the literal. A String
test uses `eco.value.eq` when `ecoConfig.valueEq` is on and otherwise calls
`Elm_Kernel_Utils_equal` and unboxes its result. A Bool test is the value
itself, or its negation.

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

        ( pathOps, valVar, ctx1 ) =
            generateMonoDtPath ctx dtPath targetType
    in
    case test of
        Test.IsCtor home ctorName index _ _ ->
            let
                -- The same tag an eco.case dispatch uses, so both agree.
                expectedTag =
                    ctorTagInt home ctorName index

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
                    Ops.arithCmpI ctx6 Ops.CmpEq resVar ( tagVar, I32 ) ( constVar, I32 )
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
                    Ops.arithCmpI ctx4 Ops.CmpEq resVar ( valVar, Types.ecoChar ) ( constVar, Types.ecoChar )
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
                    Ops.arithConstantInt32 ctx4 constVar 1

                ( resVar, ctx6 ) =
                    Ctx.freshVar ctx5

                ( ctx7, cmpOp ) =
                    Ops.arithCmpI ctx6 Ops.CmpEq resVar ( tagVar, I32 ) ( constVar, I32 )
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
                    Ops.arithConstantInt32 ctx4 constVar CtorTag.constantTag

                ( resVar, ctx6 ) =
                    Ctx.freshVar ctx5

                ( ctx7, cmpOp ) =
                    Ops.arithCmpI ctx6 Ops.CmpEq resVar ( tagVar, I32 ) ( constVar, I32 )
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )


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
                    System.Crash.crash "materializeSplitParam: tuple slot arity not 2/3"

        Ctx.SplitCtor layout ->
            let
                ( ctx2, op ) =
                    Ops.ecoConstructCustom ctx1 resultVar layout.tag layout.name (List.map2 (\( v, t ) k -> ( v, t, k )) info.slots (Types.ctorSlotKinds layout))
            in
            ( [ op ], resultVar, ctx2 )


{-| Returns `slotVar`, held at `storedType`, converted to `targetType`:
unchanged when the types agree, and unboxed when an `!eco.value` meets an
`i1` or primitive target. Any other pair is a layout disagreement.
-}
coerceSlotToTarget : Ctx.Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Ctx.Context )
coerceSlotToTarget ctx slotVar storedType targetType =
    if storedType == targetType then
        ( [], slotVar, ctx )

    else if Types.isEcoValueType storedType && (targetType == I1 || Types.isUnboxable targetType) then
        Intrinsics.unboxToType ctx slotVar targetType

    else
        layoutDisagreement "scalar-split slot read at a type other than its stored type"


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
            System.Crash.crash "splitSlotRead: slot index out of range"


{-| Returns what `generateMonoPath` returns, with the ops pushed onto
`revAcc` in reverse order.
-}
generateMonoPathHelper : Ctx.Context -> Mono.MonoPath -> MlirType -> List MlirOp -> ( List MlirOp, String, Ctx.Context )
generateMonoPathHelper ctx path targetType revAcc =
    case path of
        Mono.MonoRoot name _ ->
            -- A scalar-split name is never read whole by a path: the escape
            -- walk that admits a split refuses a bare root.
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
            -- No split check: an unbox reads the field of a one-field
            -- constructor, and a split constructor has two to six fields.
            generateMonoUnboxOnHeap ctx targetType revAcc subPath

        Mono.MonoField fieldName _ subPath ->
            -- No split check: a split value is a tuple or constructor, never
            -- a record, and a split root reached by the descent is handled
            -- there.
            generateMonoFieldOnHeap ctx targetType revAcc fieldName subPath


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
shape registry (`lookupCtorFieldInfo`).

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
                            layoutDisagreement "unboxed tuple2 element read as !eco.value"

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
                            layoutDisagreement "erased tuple2 element vs unboxable destructor target"

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
                            layoutDisagreement "unboxed tuple3 element read as !eco.value"

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
                            layoutDisagreement "erased tuple3 element vs unboxable destructor target"

                        else
                            ( [ projectOp ], valVar, ctx4 )

                Mono.CustomContainer ctorName ->
                    let
                        containerType =
                            Mono.getMonoPathType subPath

                        fieldInfo =
                            lookupCtorFieldInfo ctx2 containerType ctorName index
                    in
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
                            layoutDisagreement "unboxed constructor field read as !eco.value"

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
    in
    ( List.foldl (::) revAcc1 projectOps
    , projectVar
    , ctx3
    )


{-| Returns the ops that read the record field `fieldName` of the record that
`subPath` reaches, at `targetType`.

The field's slot and stored form come from `Types.computeRecordLayout` of the
record's type, and the target must be the stored form (CGEN\_001, MONO\_029). A
field missing from that layout crashes the compiler.

-}
generateMonoFieldOnHeap : Ctx.Context -> MlirType -> List MlirOp -> Name.Name -> Mono.MonoPath -> ( List MlirOp, String, Ctx.Context )
generateMonoFieldOnHeap ctx targetType revAcc fieldName subPath =
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
                    System.Crash.crash ("generateMonoFieldOnHeap: field " ++ fieldName ++ " is not in the record layout")

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

    else
        -- A record field is read only by a destructuring `let`, at the ABI
        -- type of the field's type, which is the type its slot stores.
        layoutDisagreement "record field read at a type other than its stored type"


{-| Returns the ops that read the one field of the single-constructor value
that `subPath` reaches, at `targetType`.

The field's stored form comes from the first registered shape for the
container's type. Every unboxed wrapper type has a registered one-field shape
(MONO\_026), so a container type with no shape, or whose shape has no fields,
crashes the compile.

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

        fieldInfo =
            case Mono.layoutMapGet containerType ctx1.typeRegistry.ctorShapes of
                Just (shape :: _) ->
                    case (Types.computeCtorLayout shape).fields of
                        info :: _ ->
                            info

                        [] ->
                            unboxWithoutField ()

                _ ->
                    unboxWithoutField ()

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
            layoutDisagreement "unboxed single-constructor field read as !eco.value"

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
            layoutDisagreement "erased unboxed-custom field vs unboxable destructor target"

        else
            ( projectOp :: revAcc1, resultVar, ctx3 )


{-| Returns the type of the value at `path`, with a constructor field's type
taken from the shape registry when the path's own type contains a type
variable.

A specialized polymorphic constructor such as `Done a` at `a = Int` can reach
here with its path type still holding `a`, while the field is stored as an
unboxed `i64`. Only a constructor-field index is resolved this way, from the
shape registered for the container's own type (`lookupCtorFieldInfo`), and
only to a field type with no type variable; in every other case the path's own
type is returned.

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
                let
                    fieldInfo =
                        lookupCtorFieldInfo ctx containerType ctorName index
                in
                if fieldIsConcrete fieldInfo then
                    fieldInfo.monoType

                else
                    raw

            _ ->
                raw

    else
        raw


{-| Returns the layout entry of field `fieldIndex` of constructor `ctorName`,
from the shapes registered for `containerType` itself.

The entry is the container's own answer even when its type still contains a
type variable: such a field is boxed in every view of the value (MONO\_003,
MONO\_029), so no other specialization of the union is consulted. Every
custom type reaching code generation has its constructors' shapes registered
(MONO\_013), so a container type with no shapes, or none with that field,
crashes the compile.

-}
lookupCtorFieldInfo : Ctx.Context -> Mono.MonoType -> Name.Name -> Int -> Types.FieldInfo
lookupCtorFieldInfo ctx containerType ctorName fieldIndex =
    let
        shapes : List Mono.CtorShape
        shapes =
            Mono.layoutMapGet containerType ctx.typeRegistry.ctorShapes
                |> Maybe.withDefault []
    in
    case ctorFieldFromShapes ctorName fieldIndex shapes of
        Just info ->
            info

        Nothing ->
            System.Crash.crash
                ("Patterns.lookupCtorFieldInfo: MONO_013 no registered shape gives field "
                    ++ String.fromInt fieldIndex
                    ++ " of constructor "
                    ++ ctorName
                )


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


{-| Crashes the compile on a `MonoUnbox` step whose container type has no
registered shape with a field (MONO\_026).
-}
unboxWithoutField : () -> a
unboxWithoutField () =
    System.Crash.crash "Patterns.generateMonoUnboxOnHeap: MONO_026 unbox of a type with no registered one-field shape"


{-| Returns whether a field's type contains no type variable.
-}
fieldIsConcrete : Types.FieldInfo -> Bool
fieldIsConcrete info =
    not (Mono.containsAnyMVar info.monoType)


{-| Crashes the compile on a layout disagreement (MONO\_029): a path reads a
value at a type other than the one the heap layout stores it as, boxed
against unboxed. The two views come from different passes, so codegen cannot
repair it. `what` names the read.
-}
layoutDisagreement : String -> a
layoutDisagreement what =
    System.Crash.crash ("Patterns: MONO_029 layout disagreement: " ++ what ++ " (see plans/solver-layout-connectivity-reconciliation.md)")


{-| Returns the integer an `eco.case` alternative uses for the fan-out edge
test `test`.

A constructor test gives `ctorTagInt` of the constructor, an Int test its
literal and a Char test its code point. A String test gives 0.

-}
testToTagInt : Test.FanTest -> Int
testToTagInt test =
    case test of
        Test.FCtor home ctorName index _ _ ->
            ctorTagInt home ctorName index

        Test.FInt i ->
            i

        Test.FChr c ->
            decodeChrPatternCode c

        Test.FStr _ ->
            0


{-| Returns the tag of the constructor `ctorName` of a type defined in `home`,
whose position among the type's constructors is `index`:
`CtorTag.constantTag` for `Maybe.Nothing`, `Basics.True` and `Basics.False`,
which the runtime represents as fixed constants, and `CtorTag.effective` for
every other constructor.
-}
ctorTagInt : ModuleName.Canonical -> Name.Name -> Index.ZeroBased -> Int
ctorTagInt home ctorName index =
    if CtorTag.isEmbeddedConstantCtor home ctorName then
        CtorTag.constantTag

    else
        CtorTag.effective home ctorName index


{-| Returns the code point of a Char pattern's text. The text is written by
the parser (`Compiler.IR.Source.StringLiteral`): one character, or an escape
such as `\n` or `\uXXXX`, where a code point above `0xFFFF` is a surrogate
pair of two `\uXXXX` escapes. So it always denotes exactly one code point;
any other text crashes the compiler.
-}
decodeChrPatternCode : String -> Int
decodeChrPatternCode c =
    case StringLiteral.codePoints c of
        [ code ] ->
            code

        _ ->
            System.Crash.crash ("Patterns.decodeChrPatternCode: Char pattern text is not one code point: " ++ c)


{-| Returns the `case_kind` attribute of an `eco.case` whose alternatives are
fan-out edge tests like `test`: `"int"`, `"chr"` or `"str"` for literal tests,
and `"ctor"` for constructor tests.
-}
caseKindFromTest : Test.FanTest -> String
caseKindFromTest test =
    case test of
        Test.FCtor _ _ _ _ _ ->
            "ctor"

        Test.FInt _ ->
            "int"

        Test.FChr _ ->
            "chr"

        Test.FStr _ ->
            "str"


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
alternatives are the fan-out edge tests `edgeTests`: the smallest non-negative
integer that no edge's `testToTagInt` uses.
-}
computeFallbackTag : List Test.FanTest -> Int
computeFallbackTag edgeTests =
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
