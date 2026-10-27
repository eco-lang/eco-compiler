module Compiler.Generate.MLIR.TailRec exposing (compileTailFuncToWhile)

{-| Compiles the body of a self-tail-recursive function into one `scf.while`
loop, so that each tail call becomes another iteration of the loop instead of a
call.

The body of such a function is a tree of `case`, `if`, `let` and destructuring
expressions whose leaves are either a tail call back to the function or a value
to return. The loop evaluates that tree once per iteration. Its state is the
function's parameters, then a _done flag_ of type `i1`, then the _result slots_
that hold the value to return. There is one result slot, or, when the caller
passes a `Ctx.SretInfo`, one per element of the tuple the function returns.

    scf.while (%params..., %done, %results...) {
        // before-region: continue while %done is false
        scf.condition(%continue) %params..., %done, %results...
    } do {
        // after-region: one step
        scf.yield %next_params..., %next_done, %next_results...
    }

The state starts as the function's arguments, `done = false` and placeholder
results, and when the loop ends its result slots are returned with
`eco.return`.

Most of the module compiles a _step_: the after-region's computation of the
next state from the current one. A tail call is a step that sets new parameter
values and `done = false`. Any other leaf sets `done = true` and puts its value
in the result slots. A `case` or an `if` becomes an `eco.case` with one result
per state slot, each of its alternatives compiled as a step of its own, and a
`let` or a destructuring binds its names and then steps into its body. These
forms are compiled here rather than by `Compiler.Generate.MLIR.Expr` because
`Expr.generateExpr` crashes on a tail call.

A _scalar-split parameter_ is one carried as one state slot per field instead
of as one boxed value, so that a tail call that builds a fresh value for it
allocates nothing. Only when `aggPromote` is on is a parameter considered, and
only a boxed tuple of two or three elements, or a value of a custom type with a
single constructor of two to six fields. It is split only when every use of it
in the body reads a field (`Expr.paramSplitAdmissible`), and every tail-call
argument for it is the parameter itself, a let-bound fresh construct of the
same shape, or such a construct written inline, with at least one construct.
Inside the loop a split parameter has no ordinary variable mapping: it is found
through the context's `splitAggParams`, which is emptied after the loop.

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
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Set
import Utils.Crash exposing (crash)



-- ============================================================================
-- ====== TYPES ======
-- ============================================================================


{-| The shape of the loop being compiled, which every step needs.

`paramVars` are the parameter slots of the loop state, in order, so a split
parameter contributes several. `groups` has one entry per parameter of the
function. `resultSlots` are the types of the result slots, `[ retType ]` unless
`resultPlan` is `Just`, in which case they are the tuple's element types.

-}
type alias LoopSpec =
    { funcName : String
    , paramVars : List ( String, MlirType )
    , groups : List ParamGroup
    , retType : MlirType
    , resultSlots : List MlirType
    , resultPlan : Maybe Ctx.SretInfo
    }


{-| How one parameter of the function is carried in the loop state.

An unsplit parameter has one slot of its own ABI type and `split` is
`Nothing`. A scalar-split parameter has one slot per field, `!eco.value` for a
boxed field and the primitive type for an unboxed one, and `split` says how
the fields are laid out.

-}
type alias ParamGroup =
    { origSsaName : String -- the incoming argument, e.g. "%p"
    , elmName : String
    , slotTypes : List MlirType
    , split : Maybe Ctx.SplitSpec
    }


{-| The compiled form of one step: its ops, and the state it yields.

`nextParams`, `doneVar` and `results` are the values of the parameter slots,
the done flag and the result slots at the end of the step. Their types are
those of the loop state: building the `eco.case` for a `case` or an `if`
crashes the compile when an alternative yields a value whose type differs
from the loop-state slot at its position. `results` holds
placeholders in a step that continues the loop.

-}
type alias StepResult =
    { ops : List MlirOp
    , nextParams : List ( String, MlirType )
    , doneVar : String
    , results : List ( String, MlirType )
    , ctx : Ctx.Context
    }



-- ============================================================================
-- ====== MAIN ENTRY POINT ======
-- ============================================================================


{-| Builds the ops of a function body that runs `body` as a loop: the
initial state, the `scf.while`, and an `eco.return` of the result slots.

`paramPairs` are the function's arguments, already mapped in `ctx`, and
`paramMonoTypes` their types, in the same order. With `Just` an `SretInfo` the
result is returned as the tuple's elements, one operand each, rather than as
`retTy`.

-}
compileTailFuncToWhile :
    Ctx.Context
    -> String
    -> List ( String, MlirType )
    -> List Mono.MonoType
    -> Mono.MonoExpr
    -> MlirType
    -> Maybe Ctx.SretInfo
    -> ( List MlirOp, Ctx.Context )
compileTailFuncToWhile ctx funcName paramPairs paramMonoTypes body retTy resultPlan =
    let
        groups =
            planParamGroups ctx paramPairs paramMonoTypes body

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

        stateTypes =
            flatParamTypes ++ [ I1 ] ++ resultSlots

        initVars =
            paramInitVars ++ [ doneInitVar ] ++ resInitVars

        ( resultVars, ctx4 ) =
            allocateFreshVars ctx3e (List.length stateTypes)

        triples =
            List.map3 (\r i t -> ( r, i, t )) resultVars initVars stateTypes

        ( beforeRegion, beforeArgs, ctx5 ) =
            buildBeforeRegion ctx4 stateTypes (List.length resultSlots)

        loopSpec =
            { funcName = funcName
            , paramVars =
                List.take (List.length flatParamTypes) (zip beforeArgs stateTypes)
            , groups = groups
            , retType = retTy
            , resultSlots = resultSlots
            , resultPlan = resultPlan
            }

        ( afterRegion, ctx6 ) =
            buildAfterRegion ctx5 stateTypes loopSpec body

        ( ctx7, whileOp ) =
            Ops.scfWhile ctx6 triples beforeRegion afterRegion

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


{-| Builds the before-region of the loop, which continues the loop while the
done flag is false and passes the whole state on, and returns its block
arguments.

`stateTypes` are the types of the whole loop state, of which the last
`numResultSlots` are result slots and the one before them the done flag.

-}
buildBeforeRegion :
    Ctx.Context
    -> List MlirType
    -> Int
    -> ( MlirRegion, List String, Ctx.Context )
buildBeforeRegion ctx stateTypes numResultSlots =
    let
        numParams =
            List.length stateTypes - 1 - numResultSlots

        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        doneArg =
            List.drop numParams blockArgs
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        ( continueVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( trueVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, trueOp ) =
            Ops.arithConstantBool ctx3 trueVar True

        ( ctx5, xorOp ) =
            Ops.ecoBinaryOp ctx4 "arith.xori" continueVar ( doneArg, I1 ) ( trueVar, I1 ) I1

        ( ctx6, conditionOp ) =
            Ops.scfCondition ctx5 continueVar blockArgPairs

        region =
            mkSingleBlockRegion blockArgPairs [ trueOp, xorOp ] conditionOp
    in
    ( region, blockArgs, ctx6 )



-- ============================================================================
-- ====== AFTER REGION (LOOP BODY) ======
-- ============================================================================


{-| Builds the after-region of the loop, which runs `body` as one step and
yields the state it produces.

The returned context has an empty `splitAggParams`, so no split parameter of
this loop can be found through it after the loop.

-}
buildAfterRegion :
    Ctx.Context
    -> List MlirType
    -> LoopSpec
    -> Mono.MonoExpr
    -> ( MlirRegion, Ctx.Context )
buildAfterRegion ctx stateTypes loopSpec body =
    let
        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        numParams =
            List.length loopSpec.paramVars

        newParamBlockArgs =
            List.take numParams blockArgPairs

        updatedLoopSpec =
            { loopSpec | paramVars = newParamBlockArgs }

        ctxWithArgs =
            setupVarMappings ctx1 loopSpec.groups newParamBlockArgs

        stepResult =
            compileStep ctxWithArgs updatedLoopSpec body

        yieldOperands =
            stepResult.nextParams ++ [ ( stepResult.doneVar, I1 ) ] ++ stepResult.results

        ( ctx2, yieldOp ) =
            Ops.scfYieldMany stepResult.ctx yieldOperands

        region =
            mkSingleBlockRegion blockArgPairs stepResult.ops yieldOp
    in
    ( region, { ctx2 | splitAggParams = Dict.empty } )


{-| Returns `ctx` with each parameter in `groups` bound to its slots among
`newBlockArgPairs`, which are in the same order.

An unsplit parameter is mapped to its one slot as an ordinary variable. A split
parameter is entered in `splitAggParams` with its slots, and its ordinary
mapping is removed, so that any read of it that does not go through
`splitAggParams` crashes in `Ctx.lookupVar` instead of reading the value from
before the loop. `splitAggParams` is replaced by the split parameters of these
groups.

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
-- ====== SCALAR-SPLIT PLANNING ======
-- ============================================================================


{-| Returns one `ParamGroup` per argument in `paramPairs`, deciding which
parameters are carried as scalar slots.

A parameter is split only when `aggPromote` is on, its ABI type is
`!eco.value`, and its type is a tuple of two or three elements or a custom type
whose one constructor has two to six fields, and then only when every use of it
in `body` is admissible and its tail-call arguments pass `splitArgPolicy`. Both
conditions are needed for the split to save work: a use of the whole value
would rebuild it, and a tail-call argument that is not a construct or the
parameter itself would have to be taken apart into slots on every iteration.

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
                    Mono.MTuple _ ts ->
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

                    Mono.MCustom _ _ _ _ ->
                        case Mono.layoutMapGet monoTy ctx.typeRegistry.ctorShapes of
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


{-| Tells whether `e` builds a new value of the split shape: a tuple literal of
its arity, or a call of its constructor with one argument per field.
`inlineConstructSlots` recognises the same expressions.
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


{-| Tells whether the tail-call arguments for parameter `pName` in `body`
allow it to be split: there is at least one, each is `pName` itself, a name
bound by a `let` to a fresh construct of the shape, or such a construct
written inline, and at least one is a construct.

Tail calls inside a closure or a local tail-recursive function are not
counted, because they belong to another function.

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
    not (List.isEmpty argsAt)
        && List.all (\c -> c /= Nothing) classes
        && List.member (Just True) classes


{-| Adds to `acc` the names bound by a `let` to a fresh construct of the split
shape, and the argument named `pName` of every tail call in `expr`, looking
through `let`, destructuring, `if` and `case` but not into closures or the
definitions of local tail-recursive functions.
-}
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
            scanSplitPolicy ctx spec pName inner acc

        Mono.MonoClosure _ _ _ ->
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


{-| Does what `scanSplitPolicy` does for every inline branch of a decision
tree. A jump branch is skipped here, because the caller scans the jump targets.
-}
scanSplitPolicyDecider : Ctx.Context -> Ctx.SplitSpec -> String -> Mono.Decider Mono.MonoChoice -> ( Set.Set String, List Mono.MonoExpr ) -> ( Set.Set String, List Mono.MonoExpr )
scanSplitPolicyDecider ctx spec pName decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            scanSplitPolicy ctx spec pName e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            scanSplitPolicyDecider ctx
                spec
                pName
                failure
                (scanSplitPolicyDecider ctx spec pName success acc)

        Mono.FanOut _ edges fallback ->
            scanSplitPolicyDecider ctx
                spec
                pName
                fallback
                (List.foldl (\( _, d ) a -> scanSplitPolicyDecider ctx spec pName d a) acc edges)


{-| Returns the initial values of one parameter's slots: the incoming
argument itself when it is not split, or each of its fields read from the
heap, once, before the loop.
-}
emitEntrySlotProjections : Ctx.Context -> ParamGroup -> ( List MlirOp, List String, Ctx.Context )
emitEntrySlotProjections ctx g =
    case g.split of
        Nothing ->
            ( [], [ g.origSsaName ], ctx )

        Just spec ->
            projectSlotsFromHeap ctx spec g.slotTypes g.origSsaName


{-| Returns ops reading every field of the boxed value `containerVar`, at the
types in `slotTypes`, and the values read.
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


{-| Returns ops reading every field of the value aggregate `aggOperand` (an
SSA tuple or custom value, not a heap object), at the types in `slotTypes`,
and the values read.
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


{-| Compiles `expr` as one step of the loop: a tail call continues the loop,
a `case`, `if`, `let` or destructuring is compiled by the matching step
function, and any other expression ends the loop with its value.
-}
compileStep : Ctx.Context -> LoopSpec -> Mono.MonoExpr -> StepResult
compileStep ctx loopSpec expr =
    case expr of
        Mono.MonoTailCall _ args _ ->
            compileTailCallStep ctx loopSpec args

        Mono.MonoCase _ _ decider jumps _ ->
            compileCaseStep ctx loopSpec decider jumps

        Mono.MonoIf branches final _ ->
            compileIfStep ctx loopSpec branches final

        Mono.MonoLet def body _ ->
            compileLetStep ctx loopSpec def body

        Mono.MonoDestruct destructor body _ ->
            compileDestructStep ctx loopSpec destructor body

        _ ->
            compileBaseReturnStep ctx loopSpec expr



-- ============================================================================
-- ====== TAIL CALL STEP ======
-- ============================================================================


{-| Compiles a tail call as a step that continues the loop with the values of
`args` as the new parameters, with placeholder results.

The arguments are matched to the parameters by position, not by the names
they carry. An unsplit parameter's argument is converted to the slot's type.
A split parameter's slots are filled as `compileSplitTailArg` describes.

-}
compileTailCallStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Name.Name, Mono.MonoExpr )
    -> StepResult
compileTailCallStep ctx loopSpec args =
    let
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

        ( doneVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( ctx3, doneOp ) =
            Ops.arithConstantBool ctx2 doneVar False

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


{-| Returns the next values of the slots of split parameter `g` from its
tail-call argument `argExpr`.

A split parameter of the same slot types passed on as it is reuses its slots
with no ops. A construct written inline has its elements compiled straight
into the slots, so it is never built. Any other argument is compiled, and its
fields are read from it: from the value aggregate when it compiles to one, and
otherwise from the heap after boxing it.

-}
compileSplitTailArg : Ctx.Context -> Ctx.SplitSpec -> ParamGroup -> Mono.MonoExpr -> ( List MlirOp, List String, Ctx.Context )
compileSplitTailArg ctx spec g argExpr =
    let
        passThrough =
            case argExpr of
                Mono.MonoVarLocal v _ ->
                    case Dict.get v ctx.splitAggParams of
                        Just info ->
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


{-| Returns the ops and values of the elements of `argExpr`, each converted to
its slot's type, when `argExpr` is a construct that `isFreshConstruct`
accepts, and `Nothing` otherwise. The two functions must recognise the same
expressions.
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


{-| Compiles `expr` as a step that ends the loop with `expr` as the result,
leaving the parameters as they are.

With a `resultPlan`, `expr` is generated with `sretTailLayout` set, converted
to a value tuple and split into the result slots, and `sretTailLayout` is put
back as it was in the returned context so that it does not reach code compiled
later. An `expr` whose generated code ends in a terminator crashes the
compile.

-}
compileBaseReturnStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoExpr
    -> StepResult
compileBaseReturnStep ctx loopSpec expr =
    let
        exprResult =
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


{-| Returns `operands` unchanged, but crashes the compile when an operand's
type differs from the loop-state slot at the same position, naming the
function, `label` and the first operand that differs. A difference in the
number of operands is not checked.

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


{-| Compiles a `case`, given its decision tree and its shared branches
`jumps`, as one step.
-}
compileCaseStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> StepResult
compileCaseStep ctx loopSpec decider jumps =
    let
        jumpLookup : Array (Maybe Mono.MonoExpr)
        jumpLookup =
            pairsToSparseArray jumps
    in
    compileCaseDeciderStep ctx loopSpec decider jumpLookup


{-| Compiles a decision tree as one step. It follows
`Expr.generateDeciderWithJumps`, but every branch is compiled as a step and
yields the whole loop state.
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


{-| Compiles the branch a decision-tree leaf chooses as a step, looking a
jump up in `jumpLookup`. A jump with no entry crashes the compile.
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


{-| Compiles a chain of tests, leading to `success` if all pass and to
`failure` otherwise, as one step.

Each test is placed inside the region where the previous one passed, so a test
runs only after the earlier ones have passed. This matters because a later
test may read a field that exists only when an earlier test passed, such as a
field of a constructor the earlier test checked for. Each test becomes an
`eco.case` on `i1` of kind `"bool"`, as in `Expr.generateChainGeneralWithJumps`.

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


{-| Compiles a multi-way branch on the value at `path` as one step: an
`eco.case` with one alternative per edge and a last one for `fallback`. For
strings its kind is `"str"` and it carries the edge strings as patterns.

The kind of case is taken from the first edge's test, and is `"ctor"` when
there are no edges. A string case numbers its alternatives in order.

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

        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars fallbackYieldCtx (numParams + 1 + List.length loopSpec.resultSlots)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1 ] ++ loopSpec.resultSlots)

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


{-| Returns the string a string test compares with, and crashes the compile
for any other test.
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


{-| Compiles an `if` with its `branches` and `final` else-branch as one step.

Each condition becomes an `eco.case` on `i1` of kind `"bool"`, whose
then-region is that branch's step and whose else-region is the rest of the
`if`. A boxed condition is unboxed first.

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
            compileStep ctx loopSpec final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                condRes =
                    Expr.generateExpr ctx condExpr

                ( condUnboxOps, condVar, condCtx ) =
                    if Types.isEcoValueType condRes.resultType then
                        Intrinsics.unboxToType condRes.ctx condRes.resultVar I1

                    else
                        ( [], condRes.resultVar, condRes.ctx )

                thenStep =
                    compileStep condCtx loopSpec thenExpr

                thenYieldOperands =
                    checkedYieldOperands loopSpec "if-then" (thenStep.nextParams ++ [ ( thenStep.doneVar, I1 ) ] ++ thenStep.results)

                ( thenYieldCtx, thenYieldOp ) =
                    Ops.ecoYieldMany thenStep.ctx thenYieldOperands

                thenRegion =
                    mkSingleBlockRegion [] thenStep.ops thenYieldOp

                elseStep =
                    compileIfStep (Ctx.ctxForSiblingRegion condCtx thenYieldCtx) loopSpec restBranches final

                elseYieldOperands =
                    checkedYieldOperands loopSpec "if-else" (elseStep.nextParams ++ [ ( elseStep.doneVar, I1 ) ] ++ elseStep.results)

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

                -- tag 1 is True (then), tag 0 is False (else)
                ( ctxAfterCase, caseOp ) =
                    Ops.ecoCaseMany ctxWithResults condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] caseResultPairs

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


{-| Compiles a `let` as a step: the definition is generated by
`Expr.generateExpr`, as a `let` with an empty body, and `body` is then compiled
as a step, so that a tail call in it still continues the loop.

Before the definition is generated, every name bound from here to the end of
the chain of `let`s is given a placeholder mapping and made the current
siblings, as `Expr.generateLet` does, so that closures defined in the chain can
refer to themselves and to each other. Only those names are siblings, not every
variable in scope. The outer siblings are restored for the body.

For an ordinary definition, `tailRecLetBody` is set to `body` while it is
generated, so that the analysis of where a promoted binding is used sees its
real uses rather than the empty body. With `aggPromote` on, the names of the
chain referred to before they are defined are added to `fwdRefdLetNames` too,
and `fwdRefdLetNames` is put back afterwards.

-}
compileLetStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDef
    -> Mono.MonoExpr
    -> StepResult
compileLetStep ctx loopSpec def body =
    let
        boundNames =
            Expr.collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        outerSiblings =
            ctx.currentLetSiblings

        ctxWithPlaceholders =
            Expr.addPlaceholderMappings boundNames ctx

        -- Outer variables in the siblings would let a closure refer to an SSA
        -- value of another function.
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

                -- Unioned: earlier links' scans reach here through ctxForBody.
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
            let
                defSetupExpr =
                    Mono.MonoLet def Mono.MonoUnit Mono.MUnit

                defSetupResult =
                    Expr.generateExpr ctxReady defSetupExpr

                ctxAfterDef =
                    defSetupResult.ctx

                ctxForBody =
                    { ctxAfterDef | currentLetSiblings = outerSiblings }

                bodyStep =
                    compileStep ctxForBody loopSpec body
            in
            { ops = defSetupResult.ops ++ bodyStep.ops
            , nextParams = bodyStep.nextParams
            , doneVar = bodyStep.doneVar
            , results = bodyStep.results
            , ctx = bodyStep.ctx
            }


{-| Compiles a destructuring as a step: the value at the destructor's path is
bound to its name, and `body` is compiled as a step, as
`Expr.generateDestruct` does for an expression.

The bound value's type is the type the path resolves to. When that type still
has a type variable and the destructor's own type has none, the destructor's
type is used.

-}
compileDestructStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDestructor
    -> Mono.MonoExpr
    -> StepResult
compileDestructStep ctx loopSpec (Mono.MonoDestructor name path destructorMonoType) body =
    let
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

        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path destructorMlirType

        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar destructorMlirType ctx1

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


{-| Builds a region of one block with block arguments `args`, the ops `body`
and the op `terminator`.
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


{-| Returns `n` fresh SSA names, in order.
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


{-| Builds an array indexed by the numbers in `pairs`, holding `Just` the
paired value at each index given and `Nothing` elsewhere. A later pair wins
over an earlier one with the same index.
-}
pairsToSparseArray : List ( Int, a ) -> Array (Maybe a)
pairsToSparseArray pairs =
    let
        maxIdx =
            List.foldl (\( i, _ ) acc -> max i acc) -1 pairs
    in
    List.foldl (\( i, v ) arr -> Array.set i (Just v) arr) (Array.repeat (maxIdx + 1) Nothing) pairs


{-| Pairs the elements of two lists in order, stopping at the end of the
shorter one.
-}
zip : List a -> List b -> List ( a, b )
zip xs ys =
    List.map2 Tuple.pair xs ys
