module Compiler.Generate.MLIR.TailRec exposing (compileTailFuncToWhile)

{-| SCF-based tail-recursion compilation.

This module compiles self-tail-recursive functions to scf.while loops.
It replaces the joinpoint+eco.jump pattern with direct loop emission.

The key insight is that a tail-recursive function can be compiled to:

    scf.while (%params..., %done, %result) : (...) -> (...) {
        // before-region: check if done
        %continue = arith.xori %done, true
        scf.condition(%continue) %params..., %done, %result
    } do {
        // after-region: compute next state via eco.case
        %next_params..., %next_done, %next_result = eco.case ... { eco.yield ... }
        scf.yield %next_params..., %next_done, %next_result
    }

@docs compileTailFuncToWhile

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Patterns as Patterns
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Dict
import Set
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Utils.Crash exposing (crash)



-- ============================================================================
-- ====== TYPES ======
-- ============================================================================


{-| Specification of the loop being compiled.
Contains information needed to compile step expressions.
-}
type alias LoopSpec =
    { funcName : String
    , paramVars : List ( String, MlirType ) -- FLAT state slot vars (scf.while after-region block args; a split param contributes several)
    , groups : List ParamGroup -- one per ORIGINAL param, in order (U-T1.3.3L)
    , retType : MlirType
    , resultSlots : List MlirType -- U-T1.3.6: [ retType ] unpromoted; the N slot types for an sret tail func
    , resultPlan : Maybe Ctx.SretInfo -- U-T1.3.6: Just = the loop result is carried DECOMPOSED (base steps project the make-form into slots)
    }


{-| U-T1.3.3L scalar-split loop variables: one group per ORIGINAL function
param. An unsplit param contributes exactly one state slot (its ABI type);
a split param (tuple2/3 or single-ctor custom, boxed at the ABI) is carried
as its per-field slots instead — each boxed field its own `!eco.value`,
each unboxed field its raw primitive. No aggregate crosses an iteration
boundary, so RS4GC never sees a first-class struct live across an in-loop
statepoint, and the per-iteration heap re-allocation of the carried value
disappears wherever tail-call args can be slot-fed.
-}
type alias ParamGroup =
    { origSsaName : String -- e.g. "%p" (the incoming function argument)
    , elmName : String -- e.g. "p"
    , slotTypes : List MlirType -- singleton for unsplit params
    , split : Maybe Ctx.SplitSpec -- Just for split params
    }


{-| Result of compiling a single step of the loop body.

Invariant: resultType must always equal loopSpec.retType for the enclosing
compileStep/LoopSpec. All step forms (tail calls, base returns, cases, ifs)
are responsible for producing a resultVar of this type.

-}
type alias StepResult =
    { ops : List MlirOp
    , nextParams : List ( String, MlirType ) -- SSA vars for next iteration
    , doneVar : String -- i1: true = done, false = continue
    , results : List ( String, MlirType ) -- result columns when done (singleton unless U-T1.3.6 promoted; types == loopSpec.resultSlots)
    , ctx : Ctx.Context
    }



-- ============================================================================
-- ====== MAIN ENTRY POINT ======
-- ============================================================================


{-| Compile a tail-recursive function body to an scf.while loop.

Returns the ops for the function body (init-ops + scf.while + eco.return).

-}
compileTailFuncToWhile :
    Ctx.Context
    -> String -- func name
    -> List ( String, MlirType ) -- function args (already in context)
    -> List Mono.MonoType -- Mono types of the function args (parallel list)
    -> Mono.MonoExpr -- body expression
    -> MlirType -- return type
    -> Maybe Ctx.SretInfo -- U-T1.3.6: Just = emit the loop with DECOMPOSED result columns (the $sret worker form)
    -> ( List MlirOp, Ctx.Context )
compileTailFuncToWhile ctx funcName paramPairs paramMonoTypes body retTy resultPlan =
    let
        -- U-T1.3.3L: plan the loop-state layout — which params carry as
        -- scalar slots instead of one boxed aggregate.
        groups =
            planParamGroups ctx paramPairs paramMonoTypes body

        -- Step 1: Define initial state
        -- Loop state = (slots..., done, result) where done starts as false
        -- and result starts as a dummy value
        ( doneInitVar, ctx1 ) =
            Ctx.freshVar ctx

        ( ctx2, doneInitOp ) =
            Ops.arithConstantBool ctx1 doneInitVar False

        resultSlots =
            case resultPlan of
                Just info ->
                    info.slotTypes

                Nothing ->
                    [ retTy ]

        ( resInitOpsRev, resInitVarsRev, ctx3 ) =
            List.foldl
                (\slotTy ( oAcc, vAcc, cAcc ) ->
                    let
                        ( dOps, dVar, cNext ) =
                            Expr.createDummyValue cAcc slotTy
                    in
                    ( List.reverse dOps ++ oAcc, dVar :: vAcc, cNext )
                )
                ( [], [], ctx2 )
                resultSlots

        resInitOps =
            List.reverse resInitOpsRev

        resInitVars =
            List.reverse resInitVarsRev

        -- Step 2: Collect initial values for loop state.
        -- Unsplit params enter as-is; split params enter as heap
        -- projections of the incoming boxed argument (one per slot).
        ( entryProjOpsRev, paramInitVarsRev, ctx3e ) =
            List.foldl
                (\g ( opsAcc, varsAcc, ctxAcc ) ->
                    let
                        ( gOps, gVars, ctxG ) =
                            emitEntrySlotProjections ctxAcc g
                    in
                    ( List.reverse gOps ++ opsAcc, List.reverse gVars ++ varsAcc, ctxG )
                )
                ( [], [], ctx3 )
                groups

        paramInitVars =
            List.reverse paramInitVarsRev

        initOps =
            (doneInitOp :: resInitOps) ++ List.reverse entryProjOpsRev

        flatParamTypes =
            List.concatMap .slotTypes groups

        -- State types: (flat slot types..., i1, result slots...)
        stateTypes =
            flatParamTypes ++ [ I1 ] ++ resultSlots

        initVars =
            paramInitVars ++ [ doneInitVar ] ++ resInitVars

        -- Step 3: Allocate fresh SSA names for scf.while results
        ( resultVars, ctx4 ) =
            allocateFreshVars ctx3e (List.length stateTypes)

        -- Build triples for scf.while: (resultVar, initVar, type)
        triples =
            List.map3 (\r i t -> ( r, i, t )) resultVars initVars stateTypes

        -- Step 4: Build before-region (condition check)
        ( beforeRegion, beforeArgs, ctx5 ) =
            buildBeforeRegion ctx4 stateTypes (List.length resultSlots)

        -- Step 5: Build after-region (loop body)
        loopSpec =
            { funcName = funcName
            , paramVars =
                -- The after-region block args for the flat param slots
                List.take (List.length flatParamTypes) (zip beforeArgs stateTypes)
            , groups = groups
            , retType = retTy
            , resultSlots = resultSlots
            , resultPlan = resultPlan
            }

        ( afterRegion, ctx6 ) =
            buildAfterRegion ctx5 stateTypes loopSpec body

        -- Step 6: Emit scf.while
        ( ctx7, whileOp ) =
            Ops.scfWhile ctx6 triples beforeRegion afterRegion

        -- Step 7: Return the result column(s) — the last N scf.while results
        -- (N = 1 unpromoted; the byte-identical historical path).
        resFinalPairs =
            List.drop (List.length stateTypes - List.length resultSlots) resultVars
                |> (\vs -> List.map2 Tuple.pair vs resultSlots)

        ( ctx8, returnOp ) =
            case resFinalPairs of
                [ ( v, ty ) ] ->
                    Ops.ecoReturn ctx7 v ty

                _ ->
                    Ops.ecoReturnMulti ctx7 resFinalPairs
    in
    ( initOps ++ [ whileOp, returnOp ], ctx8 )



-- ============================================================================
-- ====== BEFORE REGION (CONDITION) ======
-- ============================================================================


{-| Build the before-region for scf.while.

The before-region checks if we should continue looping:
%continue = arith.xori %done, true : i1
scf.condition(%continue) %params..., %done, %result

-}
buildBeforeRegion :
    Ctx.Context
    -> List MlirType
    -> Int -- U-T1.3.6: number of trailing RESULT columns (1 unpromoted)
    -> ( MlirRegion, List String, Ctx.Context )
buildBeforeRegion ctx stateTypes numResultSlots =
    let
        numParams =
            List.length stateTypes - 1 - numResultSlots

        -- Allocate block args
        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        -- done is at index numParams (second-to-last)
        doneArg =
            List.drop numParams blockArgs
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        -- Compute continue = xor(done, true)
        ( continueVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( trueVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, trueOp ) =
            Ops.arithConstantBool ctx3 trueVar True

        ( ctx5, xorOp ) =
            Ops.ecoBinaryOp ctx4 "arith.xori" continueVar ( doneArg, I1 ) ( trueVar, I1 ) I1

        -- scf.condition
        ( ctx6, conditionOp ) =
            Ops.scfCondition ctx5 continueVar blockArgPairs

        region =
            mkSingleBlockRegion blockArgPairs [ trueOp, xorOp ] conditionOp
    in
    ( region, blockArgs, ctx6 )



-- ============================================================================
-- ====== AFTER REGION (LOOP BODY) ======
-- ============================================================================


{-| Build the after-region for scf.while.

The after-region computes the next loop state by compiling the body expression.

-}
buildAfterRegion :
    Ctx.Context
    -> List MlirType
    -> LoopSpec
    -> Mono.MonoExpr
    -> ( MlirRegion, Ctx.Context )
buildAfterRegion ctx stateTypes loopSpec body =
    let
        -- Allocate block args
        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        -- Set up context with block args as variables
        numParams =
            List.length loopSpec.paramVars

        -- The new block args for the flat param slots (first numParams items)
        newParamBlockArgs =
            List.take numParams blockArgPairs

        -- Update loopSpec to use actual after-region block args
        updatedLoopSpec =
            { loopSpec | paramVars = newParamBlockArgs }

        -- Set up variable mappings for the block args
        -- Map original Elm names to new block argument SSA names
        ctxWithArgs =
            setupVarMappings ctx1 loopSpec.groups newParamBlockArgs

        -- Compile the step
        stepResult =
            compileStep ctxWithArgs updatedLoopSpec body

        -- Build scf.yield with (nextParams..., done, result)
        -- Use actual types from stepResult
        yieldOperands =
            stepResult.nextParams ++ [ ( stepResult.doneVar, I1 ) ] ++ stepResult.results

        ( ctx2, yieldOp ) =
            Ops.scfYieldMany stepResult.ctx yieldOperands

        region =
            mkSingleBlockRegion blockArgPairs stepResult.ops yieldOp
    in
    -- The split-param table is loop-scoped: nothing outside the after-region
    -- may resolve a param through it (the incoming boxed argument mapping is
    -- restored by the caller's context discipline).
    ( region, { ctx2 | splitAggParams = Dict.empty } )


{-| Set up variable mappings so that parameter names in the body can be resolved.

Walks the param GROUPS against the flat after-region block args. An unsplit
param maps its Elm name to its single block arg. A split param instead (a)
REMOVES its normal varMapping — any bypass read would silently see the
pre-loop value, so `lookupVar` must crash loudly — and (b) registers its
slot block-args in `ctx.splitAggParams`, which the emission layer
(Patterns/Expr) consults FIRST for projections and whole-value uses.

-}
setupVarMappings : Ctx.Context -> List ParamGroup -> List ( String, MlirType ) -> Ctx.Context
setupVarMappings ctx groups newBlockArgPairs =
    let
        go gs argPairs accCtx accSplits =
            case gs of
                [] ->
                    { accCtx | splitAggParams = accSplits }

                g :: rest ->
                    let
                        n =
                            List.length g.slotTypes

                        slotArgs =
                            List.take n argPairs

                        remaining =
                            List.drop n argPairs
                    in
                    case g.split of
                        Nothing ->
                            case slotArgs of
                                [ ( newSsaName, newType ) ] ->
                                    go rest remaining (Ctx.addVarMapping g.elmName newSsaName newType accCtx) accSplits

                                _ ->
                                    crash "TailRec.setupVarMappings: unsplit param group without exactly one block arg"

                        Just spec ->
                            go rest
                                remaining
                                { accCtx | varMappings = Dict.remove g.elmName accCtx.varMappings }
                                (Dict.insert g.elmName { slots = slotArgs, split = spec } accSplits)
    in
    go groups newBlockArgPairs ctx Dict.empty



-- ============================================================================
-- ====== SCALAR-SPLIT PLANNING (U-T1.3.3L) ======
-- ============================================================================


{-| Decide, per original param, whether to carry it as scalar slots.

Split iff the flag is on, the param is boxed (`!eco.value`) at the ABI, and
its Mono type is a tuple2/3 or a SINGLE-constructor custom with 2..6 fields
(single-FIELD customs are excluded: Can.Unbox types have no container to
project — the value IS the field). Everything else carries unchanged.

-}
planParamGroups : Ctx.Context -> List ( String, MlirType ) -> List Mono.MonoType -> Mono.MonoExpr -> List ParamGroup
planParamGroups ctx paramPairs paramMonoTypes body =
    List.map2
        (\( ssaName, mlirTy ) monoTy ->
            let
                elmName =
                    String.dropLeft 1 ssaName

                noSplit =
                    { origSsaName = ssaName
                    , elmName = elmName
                    , slotTypes = [ mlirTy ]
                    , split = Nothing
                    }

                -- WIN GATE (both must hold, or the split is a pessimization):
                --   (a) admissibility — every body use of the param is a
                --       projection (or the param at its own tail position);
                --       a whole-value use would REMATERIALIZE (an added
                --       allocation) each occurrence;
                --   (b) argument policy — every tail-call arg at this
                --       position is slot-feedable for free (pass-through,
                --       a fresh matching local construct, or an inline
                --       construct), and at least one is a fresh construct
                --       (the allocation the split removes). A call-result
                --       or projected-subtree arg would force EAGER per-slot
                --       heap projections each iteration (e.g. Dict.get's
                --       descent) — a loss, so it vetoes.
                gated kind spec slotTys =
                    if
                        Expr.paramSplitAdmissible ctx.psplitPromoted kind elmName body
                            && splitArgPolicy ctx spec elmName body
                    then
                        { origSsaName = ssaName
                        , elmName = elmName
                        , slotTypes = slotTys
                        , split = Just spec
                        }

                    else
                        noSplit
            in
            if not ctx.ecoConfig.aggPromote || not (Types.isEcoValueType mlirTy) then
                noSplit

            else
                case monoTy of
                    Mono.MTuple ts ->
                        if List.length ts == 2 || List.length ts == 3 then
                            let
                                layout =
                                    Types.computeTupleLayout ts

                                kind =
                                    if List.length ts == 2 then
                                        Mono.Tuple2Container

                                    else
                                        Mono.Tuple3Container
                            in
                            gated kind
                                (Ctx.SplitTuple layout)
                                (List.map
                                    (\( elemTy, isUnboxed ) ->
                                        if isUnboxed then
                                            Types.monoTypeToAbi elemTy

                                        else
                                            Types.ecoValue
                                    )
                                    layout.elements
                                )

                        else
                            noSplit

                    Mono.MCustom _ _ _ ->
                        case Dict.get (Mono.toComparableLayoutKey monoTy) ctx.typeRegistry.ctorShapes of
                            Just [ shape ] ->
                                if List.length shape.fieldTypes >= 2 && List.length shape.fieldTypes <= 6 then
                                    let
                                        clayout =
                                            Types.computeCtorLayout shape
                                    in
                                    gated (Mono.CustomContainer shape.name)
                                        (Ctx.SplitCtor clayout)
                                        (List.map
                                            (\f ->
                                                if f.isUnboxed then
                                                    Types.monoTypeToAbi f.monoType

                                                else
                                                    Types.ecoValue
                                            )
                                            clayout.fields
                                        )

                                else
                                    noSplit

                            _ ->
                                noSplit

                    _ ->
                        noSplit
        )
        paramPairs
        paramMonoTypes


{-| Does an expression construct a FRESH value of the split shape? (A tuple
literal of the right arity, or a saturated call of the single ctor.)
-}
isFreshConstruct : Ctx.Context -> Ctx.SplitSpec -> Mono.MonoExpr -> Bool
isFreshConstruct ctx spec e =
    case ( spec, e ) of
        ( Ctx.SplitTuple layout, Mono.MonoTupleCreate _ es _ ) ->
            List.length es == layout.arity

        ( Ctx.SplitCtor clayout, Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) cargs _ _ ) ->
            case Dict.get specId ctx.ctorBySpec of
                Just shape ->
                    shape.name == clayout.name && List.length cargs == List.length clayout.fields

                Nothing ->
                    False

        _ ->
            False


{-| The tail-call argument policy of the win gate. Scans the loop body
(excluding nested function bodies — their tail calls target inner loops)
collecting (1) let binders whose RHS is a fresh matching construct and
(2) every tail-call argument at this param position, then classifies.
-}
splitArgPolicy : Ctx.Context -> Ctx.SplitSpec -> String -> Mono.MonoExpr -> Bool
splitArgPolicy ctx spec pName body =
    let
        ( binders, argsAt ) =
            scanSplitPolicy ctx spec pName body ( Set.empty, [] )

        classify e =
            case e of
                Mono.MonoVarLocal v _ ->
                    if v == pName then
                        Just False

                    else if Set.member v binders then
                        Just True

                    else
                        Nothing

                _ ->
                    if isFreshConstruct ctx spec e then
                        Just True

                    else
                        Nothing

        classes =
            List.map classify argsAt
    in
    (not (List.isEmpty argsAt))
        && List.all (\c -> c /= Nothing) classes
        && List.member (Just True) classes


scanSplitPolicy : Ctx.Context -> Ctx.SplitSpec -> String -> Mono.MonoExpr -> ( Set.Set String, List Mono.MonoExpr ) -> ( Set.Set String, List Mono.MonoExpr )
scanSplitPolicy ctx spec pName expr (( binders, argsAcc ) as acc) =
    case expr of
        Mono.MonoLet (Mono.MonoDef x rhs) inner _ ->
            let
                acc1 =
                    if isFreshConstruct ctx spec rhs then
                        ( Set.insert x binders, argsAcc )

                    else
                        acc
            in
            scanSplitPolicy ctx spec pName inner acc1

        Mono.MonoLet (Mono.MonoTailDef _ _ _) inner _ ->
            -- nested tail func: its rhs's tail calls target the INNER loop
            scanSplitPolicy ctx spec pName inner acc

        Mono.MonoClosure _ _ _ ->
            -- different function; no outer tail calls inside
            acc

        Mono.MonoTailCall _ args _ ->
            let
                atP =
                    args
                        |> List.filter (\( n, _ ) -> n == pName)
                        |> List.map Tuple.second
            in
            ( binders, atP ++ argsAcc )

        Mono.MonoCase _ _ decider jumps _ ->
            let
                accD =
                    scanSplitPolicyDecider ctx spec pName decider acc
            in
            List.foldl (\( _, je ) a -> scanSplitPolicy ctx spec pName je a) accD jumps

        Mono.MonoIf branches final _ ->
            List.foldl (\( _, b ) a -> scanSplitPolicy ctx spec pName b a)
                (scanSplitPolicy ctx spec pName final acc)
                branches

        Mono.MonoDestruct _ inner _ ->
            scanSplitPolicy ctx spec pName inner acc

        _ ->
            acc


scanSplitPolicyDecider : Ctx.Context -> Ctx.SplitSpec -> String -> Mono.Decider Mono.MonoChoice -> ( Set.Set String, List Mono.MonoExpr ) -> ( Set.Set String, List Mono.MonoExpr )
scanSplitPolicyDecider ctx spec pName decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            scanSplitPolicy ctx spec pName e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            scanSplitPolicyDecider ctx spec pName failure
                (scanSplitPolicyDecider ctx spec pName success acc)

        Mono.FanOut _ edges fallback ->
            scanSplitPolicyDecider ctx
                spec
                pName
                fallback
                (List.foldl (\( _, d ) a -> scanSplitPolicyDecider ctx spec pName d a) acc edges)


{-| Entry values for one param group. Unsplit: the incoming argument var
itself, no ops. Split: heap-project each field of the incoming boxed
argument at its STORED slot type (the same per-slot projections the body
would have emitted; one-time cost at loop entry).
-}
emitEntrySlotProjections : Ctx.Context -> ParamGroup -> ( List MlirOp, List String, Ctx.Context )
emitEntrySlotProjections ctx g =
    case g.split of
        Nothing ->
            ( [], [ g.origSsaName ], ctx )

        Just spec ->
            projectSlotsFromHeap ctx spec g.slotTypes g.origSsaName


{-| Heap-project all slots of a split shape out of a boxed container var.
-}
projectSlotsFromHeap : Ctx.Context -> Ctx.SplitSpec -> List MlirType -> String -> ( List MlirOp, List String, Ctx.Context )
projectSlotsFromHeap ctx spec slotTypes containerVar =
    let
        projectOne idx slotTy ctxA rv =
            case spec of
                Ctx.SplitTuple layout ->
                    if layout.arity == 2 then
                        Ops.ecoProjectTuple2 ctxA rv idx slotTy containerVar

                    else
                        Ops.ecoProjectTuple3 ctxA rv idx slotTy containerVar

                Ctx.SplitCtor _ ->
                    Ops.ecoProjectCustom ctxA rv idx slotTy containerVar

        ( opsRev, varsRev, ctxOut ) =
            List.foldl
                (\( idx, slotTy ) ( opsAcc, varsAcc, ctxAcc ) ->
                    let
                        ( rv, ctxF ) =
                            Ctx.freshVar ctxAcc

                        ( ctxP, op ) =
                            projectOne idx slotTy ctxF rv
                    in
                    ( op :: opsAcc, rv :: varsAcc, ctxP )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair slotTypes)
    in
    ( List.reverse opsRev, List.reverse varsRev, ctxOut )


{-| Aggregate-project all slots of a split shape out of an SSA value
aggregate (`!eco.tuple2/3<...>` / `!eco.custom<...>`) — folded to nothing
by SROA/FoldExtractValue when the aggregate came from an `eco.make.*`.
-}
projectSlotsFromAgg : Ctx.Context -> Ctx.SplitSpec -> List MlirType -> ( String, MlirType ) -> ( List MlirOp, List String, Ctx.Context )
projectSlotsFromAgg ctx spec slotTypes aggOperand =
    let
        projectOne idx slotTy ctxA rv =
            case spec of
                Ctx.SplitTuple layout ->
                    if layout.arity == 2 then
                        Ops.ecoProjectTuple2Agg ctxA rv idx slotTy aggOperand

                    else
                        Ops.ecoProjectTuple3Agg ctxA rv idx slotTy aggOperand

                Ctx.SplitCtor _ ->
                    Ops.ecoProjectCustomAgg ctxA rv idx slotTy aggOperand

        ( opsRev, varsRev, ctxOut ) =
            List.foldl
                (\( idx, slotTy ) ( opsAcc, varsAcc, ctxAcc ) ->
                    let
                        ( rv, ctxF ) =
                            Ctx.freshVar ctxAcc

                        ( ctxP, op ) =
                            projectOne idx slotTy ctxF rv
                    in
                    ( op :: opsAcc, rv :: varsAcc, ctxP )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair slotTypes)
    in
    ( List.reverse opsRev, List.reverse varsRev, ctxOut )



-- ============================================================================
-- ====== STEP COMPILATION ======
-- ============================================================================


{-| Compile a single step of the loop body.

This is the main dispatcher that handles different expression types:

  - MonoTailCall -> continue looping with new args
  - MonoCase -> multi-result eco.case for step computation
  - MonoIf -> treat as 2-way case
  - Other -> base case return (done=true)

-}
compileStep : Ctx.Context -> LoopSpec -> Mono.MonoExpr -> StepResult
compileStep ctx loopSpec expr =
    case expr of
        Mono.MonoTailCall _ args _ ->
            -- Inside a MonoTailFunc, MonoTailCall is always a self-recursive call
            -- (the IR structure guarantees this - MonoTailCall only appears in
            -- MonoTailFunc bodies and always refers back to the enclosing function)
            compileTailCallStep ctx loopSpec args

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps resultType ->
            -- Case expression -> multi-result eco.case
            compileCaseStep ctx loopSpec scrutinee1 scrutinee2 decider jumps resultType

        Mono.MonoIf branches final _ ->
            -- If expression -> treat as multi-way case
            compileIfStep ctx loopSpec branches final

        Mono.MonoLet def body _ ->
            -- Let expression -> compile def, then recurse on body
            compileLetStep ctx loopSpec def body

        Mono.MonoDestruct destructor body _ ->
            -- Destruct expression -> generate path + binding, then recurse on body
            compileDestructStep ctx loopSpec destructor body

        _ ->
            -- All other expressions -> base return (done=true)
            compileBaseReturnStep ctx loopSpec expr



-- ============================================================================
-- ====== TAIL CALL STEP ======
-- ============================================================================


{-| Compile a MonoTailCall as a "continue" step.

Sets done=false and evaluates new argument values.

-}
compileTailCallStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Name.Name, Mono.MonoExpr )
    -> StepResult
compileTailCallStep ctx loopSpec args =
    let
        -- U-T1.3.3L: args come per ORIGINAL param; each group expands to its
        -- state slots. Unsplit groups keep the historical generate+coerce
        -- path. Split groups feed their slots directly:
        --   1. the SAME split param passed through -> reuse its current slot
        --      vars, zero ops;
        --   2. an SSA value-aggregate result (a promoted let-bound construct)
        --      -> aggregate projections (folded away by SROA);
        --   3. anything else -> coerce to a boxed value and heap-project
        --      (never worse than the pre-split code).
        ( argOpsRev, argVarsRev, ctx1 ) =
            List.foldl
                (\( g, ( _, argExpr ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    case g.split of
                        Nothing ->
                            let
                                argResult =
                                    Expr.generateExpr ctxAcc argExpr

                                expectedTy : MlirType
                                expectedTy =
                                    case g.slotTypes of
                                        [ ty ] ->
                                            ty

                                        _ ->
                                            crash
                                                ("TailRec.compileTailCallStep: unsplit group arity in "
                                                    ++ loopSpec.funcName
                                                )

                                ( coerceOps, finalVar, ctxCoerced ) =
                                    Expr.coerceResultToType
                                        argResult.ctx
                                        argResult.resultVar
                                        argResult.resultType
                                        expectedTy

                                chunkOps =
                                    argResult.ops ++ coerceOps
                            in
                            ( List.reverse chunkOps ++ opsAcc
                            , ( finalVar, expectedTy ) :: varsAcc
                            , ctxCoerced
                            )

                        Just spec ->
                            let
                                ( chunkOps, slotVars, ctxSlots ) =
                                    compileSplitTailArg ctxAcc spec g argExpr

                                slotPairs =
                                    List.map2 Tuple.pair slotVars g.slotTypes
                            in
                            ( List.reverse chunkOps ++ opsAcc
                            , List.reverse slotPairs ++ varsAcc
                            , ctxSlots
                            )
                )
                ( [], [], ctx )
                (List.map2 Tuple.pair loopSpec.groups args)

        argOps =
            List.reverse argOpsRev

        argVars =
            List.reverse argVarsRev

        -- done = false (continue looping)
        ( doneVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( ctx3, doneOp ) =
            Ops.arithConstantBool ctx2 doneVar False

        -- result = dummies (not used when continuing); one per result slot
        ( dummyOpsRev, dummyPairsRev, ctx4 ) =
            List.foldl
                (\slotTy ( oAcc, pAcc, cAcc ) ->
                    let
                        ( dOps, dVar, cNext ) =
                            Expr.createDummyValue cAcc slotTy
                    in
                    ( List.reverse dOps ++ oAcc, ( dVar, slotTy ) :: pAcc, cNext )
                )
                ( [], [], ctx3 )
                loopSpec.resultSlots
    in
    { ops = argOps ++ [ doneOp ] ++ List.reverse dummyOpsRev
    , nextParams = argVars
    , doneVar = doneVar
    , results = List.reverse dummyPairsRev
    , ctx = ctx4
    }


{-| Produce the next-iteration slot vars for one SPLIT param position.
-}
compileSplitTailArg : Ctx.Context -> Ctx.SplitSpec -> ParamGroup -> Mono.MonoExpr -> ( List MlirOp, List String, Ctx.Context )
compileSplitTailArg ctx spec g argExpr =
    let
        passThrough =
            case argExpr of
                Mono.MonoVarLocal v _ ->
                    case Dict.get v ctx.splitAggParams of
                        Just info ->
                            -- Same-shape pass-through only (slot types must
                            -- agree exactly); otherwise fall to the generic
                            -- explode below.
                            if List.map Tuple.second info.slots == g.slotTypes then
                                Just (List.map Tuple.first info.slots)

                            else
                                Nothing

                        Nothing ->
                            Nothing

                _ ->
                    Nothing
    in
    case passThrough of
        Just slotVars ->
            ( [], slotVars, ctx )

        Nothing ->
            case inlineConstructSlots ctx spec g argExpr of
                Just result ->
                    -- Fresh INLINE construct in tail position: compile the
                    -- elements straight into the slots — the construction
                    -- itself vanishes.
                    result

                Nothing ->
                    let
                        argResult =
                            Expr.generateExpr ctx argExpr
                    in
                    if Types.isAggValueType argResult.resultType then
                        projectSlotsFromAgg argResult.ctx spec g.slotTypes ( argResult.resultVar, argResult.resultType )
                            |> (\( pOps, pVars, pCtx ) -> ( argResult.ops ++ pOps, pVars, pCtx ))

                    else
                        let
                            ( coerceOps, boxedVar, ctxBoxed ) =
                                Expr.coerceResultToType argResult.ctx argResult.resultVar argResult.resultType Types.ecoValue

                            ( pOps, pVars, pCtx ) =
                                projectSlotsFromHeap ctxBoxed spec g.slotTypes boxedVar
                        in
                        ( argResult.ops ++ coerceOps ++ pOps, pVars, pCtx )


{-| Compile a fresh inline construct's elements directly to this group's
slot types (the mirror of `isFreshConstruct` — keep the two in sync).
-}
inlineConstructSlots : Ctx.Context -> Ctx.SplitSpec -> ParamGroup -> Mono.MonoExpr -> Maybe ( List MlirOp, List String, Ctx.Context )
inlineConstructSlots ctx spec g argExpr =
    let
        elementsFor =
            case ( spec, argExpr ) of
                ( Ctx.SplitTuple layout, Mono.MonoTupleCreate _ es _ ) ->
                    if List.length es == layout.arity then
                        Just es

                    else
                        Nothing

                ( Ctx.SplitCtor clayout, Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) cargs _ _ ) ->
                    case Dict.get specId ctx.ctorBySpec of
                        Just shape ->
                            if shape.name == clayout.name && List.length cargs == List.length clayout.fields then
                                Just cargs

                            else
                                Nothing

                        Nothing ->
                            Nothing

                _ ->
                    Nothing
    in
    Maybe.map
        (\es ->
            let
                ( opsRev, varsRev, ctxOut ) =
                    List.foldl
                        (\( e, slotTy ) ( opsAcc, varsAcc, ctxAcc ) ->
                            let
                                r =
                                    Expr.generateExpr ctxAcc e

                                ( co, fv, ctxC ) =
                                    Expr.coerceResultToType r.ctx r.resultVar r.resultType slotTy
                            in
                            ( List.reverse (r.ops ++ co) ++ opsAcc, fv :: varsAcc, ctxC )
                        )
                        ( [], [], ctx )
                        (List.map2 Tuple.pair es g.slotTypes)
            in
            ( List.reverse opsRev, List.reverse varsRev, ctxOut )
        )
        elementsFor



-- ============================================================================
-- ====== BASE RETURN STEP ======
-- ============================================================================


{-| Compile a non-tail expression as a "done" step.

Sets done=true and evaluates the expression as the result.

-}
compileBaseReturnStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoExpr
    -> StepResult
compileBaseReturnStep ctx loopSpec expr =
    let
        exprResult =
            -- U-T1.3.6: base exprs of a promoted tail func are RESULT-spine
            -- positions — the T1.3.3 machinery (make-form tail literals,
            -- decomposed case yields) applies via the same flag. The flag is
            -- RESTORED on the result ctx: it would otherwise thread out of
            -- the step machinery, across the node boundary, and poison the
            -- NEXT function's emission (the postSolveDef incident).
            case loopSpec.resultPlan of
                Just info ->
                    let
                        raw =
                            Expr.generateExpr { ctx | sretTailLayout = Just info.layout } expr

                        rawCtx =
                            raw.ctx
                    in
                    { raw | ctx = { rawCtx | sretTailLayout = ctx.sretTailLayout } }

                Nothing ->
                    Expr.generateExpr ctx expr
    in
    if exprResult.isTerminated then
        crash
            "TailRec.compileBaseReturnStep: encountered terminated ExprResult; extend compileStep to handle this expression shape directly."

    else
        let
            -- U-T1.3.6: for a promoted (sret) tail func the base value is
            -- carried DECOMPOSED — coerce to the aggregate (make-form spine
            -- results are already there; boxed fallbacks bridge via
            -- eco.from_heap) and project the N slots block-locally.
            ( coerceOps, resultPairs, ctx1 ) =
                case loopSpec.resultPlan of
                    Just info ->
                        let
                            aggTy =
                                Ops.aggTupleType info.slotTypes

                            ( cOps, aggVar, cCtx ) =
                                Expr.coerceResultToType
                                    exprResult.ctx
                                    exprResult.resultVar
                                    exprResult.resultType
                                    aggTy

                            ( projOpsRev, pairsRev, pCtx ) =
                                List.foldl
                                    (\( idx, slotTy ) ( oAcc, pAcc, cAcc ) ->
                                        let
                                            ( pv, cF ) =
                                                Ctx.freshVar cAcc

                                            ( cP, projOp ) =
                                                if info.layout.arity == 2 then
                                                    Ops.ecoProjectTuple2Agg cF pv idx slotTy ( aggVar, aggTy )

                                                else
                                                    Ops.ecoProjectTuple3Agg cF pv idx slotTy ( aggVar, aggTy )
                                        in
                                        ( projOp :: oAcc, ( pv, slotTy ) :: pAcc, cP )
                                    )
                                    ( [], [], cCtx )
                                    (List.indexedMap Tuple.pair info.slotTypes)
                        in
                        ( cOps ++ List.reverse projOpsRev, List.reverse pairsRev, pCtx )

                    Nothing ->
                        let
                            ( cOps, finalVar, cCtx ) =
                                Expr.coerceResultToType
                                    exprResult.ctx
                                    exprResult.resultVar
                                    exprResult.resultType
                                    loopSpec.retType
                        in
                        ( cOps, [ ( finalVar, loopSpec.retType ) ], cCtx )

            -- done = true (base case)
            ( doneVar, ctx2 ) =
                Ctx.freshVar ctx1

            ( ctx3, doneOp ) =
                Ops.arithConstantBool ctx2 doneVar True

            nextParams =
                loopSpec.paramVars
        in
        { ops = exprResult.ops ++ coerceOps ++ [ doneOp ]
        , nextParams = nextParams
        , doneVar = doneVar
        , results = resultPairs
        , ctx = ctx3
        }



{-| Invariant guard (kept from the 2026-07 solver self-compile bug hunt):
crash with function/branch context when an alternative's yield operand
types disagree with the loop state types the eco.case will declare. A
mismatch here is always a miscompile-in-progress (the backend verifier
rejects it later, but with no source location); a loud, located crash at
emission is strictly better. Cost: a few type compares per yield.
-}
checkedYieldOperands : LoopSpec -> String -> List ( String, MlirType ) -> List ( String, MlirType )
checkedYieldOperands loopSpec label operands =
    let
        expected =
            List.map Tuple.second loopSpec.paramVars ++ [ I1 ] ++ loopSpec.resultSlots

        mismatches =
            List.map2 (\( _, actual ) exp -> ( actual, exp )) operands expected
                |> List.indexedMap Tuple.pair
                |> List.filter (\( _, ( actual, exp ) ) -> actual /= exp)
    in
    case mismatches of
        [] ->
            operands

        ( idx, ( actual, exp ) ) :: _ ->
            crash
                ("TailRec yield ABI mismatch in "
                    ++ loopSpec.funcName
                    ++ " ["
                    ++ label
                    ++ "] operand "
                    ++ String.fromInt idx
                    ++ ": yields "
                    ++ Types.mlirTypeToString actual
                    ++ " but loop state declares "
                    ++ Types.mlirTypeToString exp
                )


-- ============================================================================
-- ====== CASE STEP ======
-- ============================================================================


{-| Compile a MonoCase as a multi-result eco.case step.

Each case alternative recursively calls compileStep, and the results
are yielded via eco.yieldMany. This mirrors Expr.generateCase but produces
StepResult instead of ExprResult.

-}
compileCaseStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> Name.Name
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> Mono.MonoType
    -> StepResult
compileCaseStep ctx loopSpec _ _ decider jumps _ =
    let
        jumpLookup : Array (Maybe Mono.MonoExpr)
        jumpLookup =
            pairsToSparseArray jumps
    in
    compileCaseDeciderStep ctx loopSpec decider jumpLookup


{-| Compile a decision tree for a case expression as a single loop step.

This mirrors Expr.generateDeciderWithJumps, but instead of producing
an ExprResult for the case _value_, it produces a StepResult for the
loop state (nextParams..., done, result).

-}
compileCaseDeciderStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseDeciderStep ctx loopSpec decider jumpLookup =
    case decider of
        Mono.Leaf choice ->
            compileCaseLeafStep ctx loopSpec choice jumpLookup

        Mono.Chain testChain success failure ->
            compileCaseChainStep ctx loopSpec testChain success failure jumpLookup

        Mono.FanOut path edges fallback ->
            compileCaseFanOutStep ctx loopSpec path edges fallback jumpLookup


{-| Leaf node in the decision tree.

Inline the branch expression and treat it as the step body.
This lets compileStep see any MonoTailCall and compile it into a continue
state, instead of going through Expr.generateTailCall/eco.jump.

-}
compileCaseLeafStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseLeafStep ctx loopSpec choice jumpLookup =
    case choice of
        Mono.Inline branchExpr ->
            compileStep ctx loopSpec branchExpr

        Mono.Jump index ->
            case Array.get index jumpLookup |> Maybe.andThen identity of
                Just branchExpr ->
                    compileStep ctx loopSpec branchExpr

                Nothing ->
                    crash
                        ("compileCaseLeafStep: Jump index "
                            ++ String.fromInt index
                            ++ " not found in jumpLookup"
                        )


{-| Chain node: sequence of tests culminating in success/failure subtrees.

Tests in the chain must be evaluated with short-circuit semantics: the path
navigations inside a later test are only valid after earlier guards pass (e.g.
projecting a field from an RBNode is undefined if the scrutinee is actually an
RBEmpty embedded constant). We achieve this by nesting each remaining test
inside the preceding test's "then" region, so a failing guard skips all
subsequent projections. This mirrors `Expr.generateChainGeneralWithJumps`.

-}
compileCaseChainStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Mono.MonoDtPath, DT.Test )
    -> Mono.Decider Mono.MonoChoice
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseChainStep ctx loopSpec testChain success failure jumpLookup =
    case testChain of
        [] ->
            compileCaseDeciderStep ctx loopSpec success jumpLookup

        firstTest :: restTests ->
            let
                ( firstOps, firstVar, ctx1 ) =
                    Patterns.generateMonoTest ctx firstTest

                -- Then: evaluate remaining tests (or success if none remain)
                thenStep =
                    compileCaseChainStep ctx1 loopSpec restTests success failure jumpLookup

                thenYieldOperands =
                    checkedYieldOperands loopSpec
                        "then"
                        (thenStep.nextParams
                            ++ [ ( thenStep.doneVar, I1 ) ]
                            ++ thenStep.results
                        )

                ( thenYieldCtx, thenYieldOp ) =
                    Ops.ecoYieldMany thenStep.ctx thenYieldOperands

                thenRegion =
                    mkSingleBlockRegion [] thenStep.ops thenYieldOp

                ctxForElse =
                    Ctx.ctxForSiblingRegion ctx1 thenYieldCtx

                -- Else: first test failed, go to failure subtree
                elseStep =
                    compileCaseDeciderStep ctxForElse loopSpec failure jumpLookup

                elseYieldOperands =
                    checkedYieldOperands loopSpec
                        "else"
                        (elseStep.nextParams
                            ++ [ ( elseStep.doneVar, I1 ) ]
                            ++ elseStep.results
                        )

                ( elseYieldCtx, elseYieldOp ) =
                    Ops.ecoYieldMany elseStep.ctx elseYieldOperands

                elseRegion =
                    mkSingleBlockRegion [] elseStep.ops elseYieldOp

                numParams =
                    List.length loopSpec.paramVars

                paramTypes =
                    List.map Tuple.second loopSpec.paramVars

                ( caseResultNames, ctxWithResults ) =
                    allocateFreshVars elseYieldCtx (numParams + 1 + List.length loopSpec.resultSlots)

                caseResultPairs =
                    zip caseResultNames (paramTypes ++ [ I1 ] ++ loopSpec.resultSlots)

                ( ctxAfterCase, caseOp ) =
                    Ops.ecoCaseMany
                        ctxWithResults
                        firstVar
                        I1
                        "bool"
                        [ 1, 0 ]
                        [ thenRegion, elseRegion ]
                        caseResultPairs

                nextParamVars =
                    List.take numParams caseResultPairs

                doneResultVar =
                    List.drop numParams caseResultNames
                        |> List.head
                        |> Maybe.withDefault "%error_no_done"

                resultPairsOut =
                    List.drop (numParams + 1) caseResultPairs
            in
            { ops = firstOps ++ [ caseOp ]
            , nextParams = nextParamVars
            , doneVar = doneResultVar
            , results = resultPairsOut
            , ctx = Ctx.ctxAfterBranchOp ctx1 ctxAfterCase caseResultNames
            }


{-| FanOut node: multi-way branching on constructor tags, ints, chars, or strings.

We generate an eco.case/eco.case\_string whose result tuple is
(nextParams..., done, result). Each alternative region yields this tuple
via eco.yieldMany.

-}
compileCaseFanOutStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDtPath
    -> List ( DT.Test, Mono.Decider Mono.MonoChoice )
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseFanOutStep ctx loopSpec path edges fallback jumpLookup =
    let
        edgeTests =
            List.map Tuple.first edges

        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateMonoDtPath ctx path scrutineeType

        -- Tags and (optional) string patterns
        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount =
                        List.length edges

                    altCount =
                        edgeCount + 1

                    patterns =
                        edges
                            |> List.map Tuple.first
                            |> List.map extractStringPatternForStep

                    sequentialTags =
                        List.range 0 (altCount - 1)
                in
                ( sequentialTags, Just patterns )

            else
                let
                    edgeTags =
                        List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                    fallbackTag =
                        Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        -- Compile edge regions
        ( edgeRegionsRev, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        branchCtx =
                            Ctx.ctxForSiblingRegion ctx1 accCtx

                        subStep =
                            compileCaseDeciderStep branchCtx loopSpec subTree jumpLookup

                        yieldOperands =
                            checkedYieldOperands loopSpec
                                "fanout-edge"
                                (subStep.nextParams
                                    ++ [ ( subStep.doneVar, I1 ) ]
                                    ++ subStep.results
                                )

                        ( yieldCtx, yieldOp ) =
                            Ops.ecoYieldMany subStep.ctx yieldOperands

                        region =
                            mkSingleBlockRegion [] subStep.ops yieldOp
                    in
                    ( region :: accRegions, yieldCtx )
                )
                ( [], ctx1 )
                edges

        edgeRegions =
            List.reverse edgeRegionsRev

        -- Fallback region
        fallbackStep =
            compileCaseDeciderStep (Ctx.ctxForSiblingRegion ctx1 ctx2) loopSpec fallback jumpLookup

        fallbackYieldOperands =
            checkedYieldOperands loopSpec
                "fanout-fallback"
                (fallbackStep.nextParams
                    ++ [ ( fallbackStep.doneVar, I1 ) ]
                    ++ fallbackStep.results
                )

        ( fallbackYieldCtx, fallbackYieldOp ) =
            Ops.ecoYieldMany fallbackStep.ctx fallbackYieldOperands

        fallbackRegion =
            mkSingleBlockRegion [] fallbackStep.ops fallbackYieldOp

        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        -- Step tuple result types
        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars fallbackYieldCtx (numParams + 1 + List.length loopSpec.resultSlots)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1 ] ++ loopSpec.resultSlots)

        -- Build eco.case / eco.case_string
        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseStringMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        tags
                        patterns
                        allRegions
                        caseResultPairs

                Nothing ->
                    Ops.ecoCaseMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        caseKind
                        tags
                        allRegions
                        caseResultPairs

        nextParamVars =
            List.take numParams caseResultPairs

        doneResultVar =
            List.drop numParams caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        resultPairsOut =
            List.drop (numParams + 1) caseResultPairs
    in
    { ops = pathOps ++ [ caseOp ]
    , nextParams = nextParamVars
    , doneVar = doneResultVar
    , results = resultPairsOut
    , ctx = Ctx.ctxAfterBranchOp ctx1 ctx3 caseResultNames
    }


{-| Extract string pattern from a DT.Test, crash if not a string test.
-}
extractStringPatternForStep : DT.Test -> String
extractStringPatternForStep test =
    case test of
        Test.IsStr s ->
            s

        _ ->
            crash "extractStringPatternForStep: expected Test.IsStr but got non-string test"



-- ============================================================================
-- ====== IF STEP ======
-- ============================================================================


{-| Compile a MonoIf as a step.

Generates a multi-result eco.case where each branch recursively calls compileStep.
The result is the step tuple (nextParams..., done, result).

-}
compileIfStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> StepResult
compileIfStep ctx loopSpec branches final =
    case branches of
        [] ->
            -- No more branches, compile the final expression
            compileStep ctx loopSpec final

        ( condExpr, thenExpr ) :: restBranches ->
            -- Compile the condition
            let
                condRes =
                    Expr.generateExpr ctx condExpr

                -- Ensure condition is i1 for eco.case
                ( condUnboxOps, condVar, condCtx ) =
                    if Types.isEcoValueType condRes.resultType then
                        -- Unbox Bool to i1 using eco.unbox
                        Intrinsics.unboxToType condRes.ctx condRes.resultVar I1

                    else
                        ( [], condRes.resultVar, condRes.ctx )

                -- Compile then branch with compileStep
                thenStep =
                    compileStep condCtx loopSpec thenExpr

                -- Build then region that yields the step tuple
                thenYieldOperands =
                    checkedYieldOperands loopSpec "if-then" (thenStep.nextParams ++ [ ( thenStep.doneVar, I1 ) ] ++ thenStep.results)

                ( thenYieldCtx, thenYieldOp ) =
                    Ops.ecoYieldMany thenStep.ctx thenYieldOperands

                thenRegion =
                    mkSingleBlockRegion [] thenStep.ops thenYieldOp

                -- Compile else branch recursively (handles nested if-else chains)
                elseStep =
                    compileIfStep (Ctx.ctxForSiblingRegion condCtx thenYieldCtx) loopSpec restBranches final

                -- Build else region that yields the step tuple
                elseYieldOperands =
                    checkedYieldOperands loopSpec "if-else" (elseStep.nextParams ++ [ ( elseStep.doneVar, I1 ) ] ++ elseStep.results)

                ( elseYieldCtx, elseYieldOp ) =
                    Ops.ecoYieldMany elseStep.ctx elseYieldOperands

                elseRegion =
                    mkSingleBlockRegion [] elseStep.ops elseYieldOp

                -- Build multi-result eco.case
                -- Step tuple types: (paramTypes..., i1, retTy)
                numParams =
                    List.length loopSpec.paramVars

                paramTypes =
                    List.map Tuple.second loopSpec.paramVars

                -- Allocate fresh names for the case results
                ( caseResultNames, ctxWithResults ) =
                    allocateFreshVars elseYieldCtx (numParams + 1 + List.length loopSpec.resultSlots)

                caseResultPairs =
                    zip caseResultNames (paramTypes ++ [ I1 ] ++ loopSpec.resultSlots)

                -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
                ( ctxAfterCase, caseOp ) =
                    Ops.ecoCaseMany ctxWithResults condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] caseResultPairs

                -- Extract the step results from the case
                nextParamVars =
                    List.take numParams caseResultPairs

                doneResultVar =
                    List.drop numParams caseResultNames
                        |> List.head
                        |> Maybe.withDefault "%error_no_done"

                resultPairsOut =
                    List.drop (numParams + 1) caseResultPairs
            in
            { ops = condRes.ops ++ condUnboxOps ++ [ caseOp ]
            , nextParams = nextParamVars
            , doneVar = doneResultVar
            , results = resultPairsOut
            , ctx = Ctx.ctxAfterBranchOp condCtx ctxAfterCase caseResultNames
            }



-- ============================================================================
-- ====== LET STEP ======
-- ============================================================================


{-| Compile a MonoLet step.

Delegates to Expr.generateLet (via a synthetic MonoLet wrapping) for each
definition, so that the full let-chain sibling context (placeholder
mappings, currentLetSiblings) is properly set up. This is critical for
self-recursive closures defined in let bindings — without sibling context
their PendingLambda gets empty siblingMappings and lookupVar fails for
the self-reference.

For MonoTailDef, we also delegate to Expr.generateExpr (which routes to
generateLet) for the definition setup, then use compileStep for the body
so that MonoTailCall for the outer function still generates correct loop
continuation.

-}
compileLetStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDef
    -> Mono.MonoExpr
    -> StepResult
compileLetStep ctx loopSpec def body =
    let
        -- Collect ALL let-bound names from this point in the chain, including
        -- the current def and any subsequent MonoLet nodes in body. This mirrors
        -- Expr.collectLetBoundNames so that sibling closures can see each other.
        boundNames =
            Expr.collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        -- Save outer siblings for restoration on exit (lexical scoping)
        outerSiblings =
            ctx.currentLetSiblings

        -- Build placeholder mappings for the whole let-group
        ctxWithPlaceholders =
            Expr.addPlaceholderMappings boundNames ctx

        -- Only include the let-bound names in currentLetSiblings (not all varMappings).
        -- This prevents outer-scope variables from leaking into lambda siblingMappings,
        -- which would cause cross-function SSA references (CGEN_CLOSURE_003).
        letBoundSiblings =
            List.foldl
                (\name acc ->
                    case Dict.get name ctxWithPlaceholders.varMappings of
                        Just info ->
                            Dict.insert name info acc

                        Nothing ->
                            acc
                )
                Dict.empty
                boundNames

        ctxReady =
            { ctxWithPlaceholders | currentLetSiblings = letBoundSiblings }
    in
    case def of
        Mono.MonoDef _ _ ->
            let
                defSetupExpr =
                    Mono.MonoLet def Mono.MonoUnit Mono.MUnit

                -- U-T1.3.2t: hand the promotion hook the REAL loop-body
                -- suffix (the synthetic MonoUnit wrapper would otherwise show
                -- the escape walk zero uses — the T1.3.2 incident), plus the
                -- forward-ref scan over this chain suffix (unioned: earlier
                -- positions' scans already flowed down via ctxForBody, so
                -- position k sees refs from links 1..k-1 as well).
                fwdScanned =
                    if ctxReady.ecoConfig.aggPromote then
                        Set.union ctxReady.fwdRefdLetNames (Expr.scanChainForwardRefs ctxReady def body)

                    else
                        ctxReady.fwdRefdLetNames

                ctxReadyT =
                    { ctxReady | tailRecLetBody = Just body, fwdRefdLetNames = fwdScanned }

                defSetupResult =
                    Expr.generateExpr ctxReadyT defSetupExpr

                ctxAfterDef =
                    defSetupResult.ctx

                ctxForBody =
                    { ctxAfterDef | currentLetSiblings = outerSiblings, tailRecLetBody = Nothing }

                bodyStep =
                    compileStep ctxForBody loopSpec body

                stepCtx =
                    bodyStep.ctx
            in
            { ops = defSetupResult.ops ++ bodyStep.ops
            , nextParams = bodyStep.nextParams
            , doneVar = bodyStep.doneVar
            , results = bodyStep.results
            , ctx = { stepCtx | fwdRefdLetNames = ctx.fwdRefdLetNames }
            }

        Mono.MonoTailDef _ _ _ ->
            -- Compile the MonoTailDef binding (pending lambda, papCreate) using
            -- Expr.generateExpr with a dummy body. This sets up the var mapping
            -- for the defined name without compiling the actual body.
            -- Then compile the actual body via compileStep to maintain the
            -- TailRec context (so MonoTailCall for the outer function generates
            -- correct loop continuation instead of crashing in mkCaseRegionFromDecider).
            let
                -- Compile just the def setup: pending lambda + papCreate + var mapping.
                -- Use MonoUnit as a dummy body since we only need the side effects
                -- on the context (var mappings, pending lambdas).
                defSetupExpr =
                    Mono.MonoLet def Mono.MonoUnit Mono.MUnit

                defSetupResult =
                    Expr.generateExpr ctxReady defSetupExpr

                -- Restore outer siblings before compiling the body
                ctxAfterDef =
                    defSetupResult.ctx

                ctxForBody =
                    { ctxAfterDef | currentLetSiblings = outerSiblings }

                -- Now compile the actual body with compileStep (maintains TailRec context)
                bodyStep =
                    compileStep ctxForBody loopSpec body
            in
            { ops = defSetupResult.ops ++ bodyStep.ops
            , nextParams = bodyStep.nextParams
            , doneVar = bodyStep.doneVar
            , results = bodyStep.results
            , ctx = bodyStep.ctx
            }


{-| Compile a MonoDestruct step.

This mirrors Expr.generateDestruct but returns a StepResult instead of ExprResult:

  - Generate path ops to navigate the MonoPath and extract the value.
  - Bind the destructured name to the extracted SSA value in the context.
  - Recursively compile the body as a step.

This ensures that any MonoTailCall inside the body is still seen by compileStep
and treated as a "continue" step, instead of going through Expr.generateTailCall.

-}
compileDestructStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDestructor
    -> Mono.MonoExpr
    -> StepResult
compileDestructStep ctx loopSpec (Mono.MonoDestructor name path destructorMonoType) body =
    let
        -- Use the path's actual result type, as in Expr.generateDestruct.
        -- The destructor's monoType may still contain unsubstituted vars;
        -- the path carries the correctly-specialized concrete type. If the
        -- path's own top-level annotation is itself a stale MVar (polymorphic
        -- ctor partially specialized — e.g. `Done a` at `a = Int`), fall back
        -- to the ctor shape registry so we agree with the heap layout. If
        -- that also yields a free MVar (multiple disagreeing specializations
        -- in the registry), prefer the destructor's own monoType when the
        -- outer subst pinned it concretely.
        pathResultRaw : Mono.MonoType
        pathResultRaw =
            Patterns.resolvePathResultType ctx path

        pathResultType : Mono.MonoType
        pathResultType =
            if Mono.containsAnyMVar pathResultRaw && not (Mono.containsAnyMVar destructorMonoType) then
                destructorMonoType

            else
                pathResultRaw

        destructorMlirType : MlirType
        destructorMlirType =
            Types.monoTypeToAbi pathResultType

        -- Navigate the path to produce the destructured value.
        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path destructorMlirType

        -- Bind the destructured name to the extracted SSA value.
        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar destructorMlirType ctx1

        -- Recursively compile the body as a loop step.
        bodyStep : StepResult
        bodyStep =
            compileStep ctx2 loopSpec body
    in
    { ops = pathOps ++ bodyStep.ops
    , nextParams = bodyStep.nextParams
    , doneVar = bodyStep.doneVar
    , results = bodyStep.results
    , ctx = bodyStep.ctx
    }



-- ============================================================================
-- ====== HELPERS ======
-- ============================================================================


{-| Create a single-block region with the given args, body ops, and terminator.
-}
mkSingleBlockRegion :
    List ( String, MlirType )
    -> List MlirOp
    -> MlirOp
    -> MlirRegion
mkSingleBlockRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }


{-| Allocate N fresh variable names.
-}
allocateFreshVars : Ctx.Context -> Int -> ( List String, Ctx.Context )
allocateFreshVars ctx n =
    let
        ( varsRev, ctxFinal ) =
            List.foldl
                (\_ ( vars, ctxAcc ) ->
                    let
                        ( v, ctxNew ) =
                            Ctx.freshVar ctxAcc
                    in
                    ( v :: vars, ctxNew )
                )
                ( [], ctx )
                (List.range 1 n)
    in
    ( List.reverse varsRev, ctxFinal )


pairsToSparseArray : List ( Int, a ) -> Array (Maybe a)
pairsToSparseArray pairs =
    let
        maxIdx =
            List.foldl (\( i, _ ) acc -> max i acc) -1 pairs
    in
    List.foldl (\( i, v ) arr -> Array.set i (Just v) arr) (Array.repeat (maxIdx + 1) Nothing) pairs


{-| Zip two lists together.
-}
zip : List a -> List b -> List ( a, b )
zip xs ys =
    List.map2 Tuple.pair xs ys
