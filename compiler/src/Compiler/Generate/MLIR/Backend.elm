module Compiler.Generate.MLIR.Backend exposing
    ( backend, generateMlirModule, streamMlirToWriter, streamMlirBytecode
    , constThunkReport
    )

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

@docs backend, generateMlirModule, streamMlirToWriter, streamMlirBytecode
@docs constThunkReport

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.CtorTag as CtorTag
import Compiler.Eco.Config as Config
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.ConstThunks as ConstThunks
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Functions as Functions
import Compiler.Generate.MLIR.Lambdas as Lambdas
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.Borrow.Facts as BorrowFacts
import Compiler.GlobalOpt.MapTemplate as MapTemplate
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Registry as Registry
import Dict
import Eco.File
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType)
import Mlir.Pretty as Pretty
import Set
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils



-- ====== BACKEND ======


{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved.
-}
backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            generateProgram config.mode config.graph |> CodeGen.TextOutput
    }



-- ====== GENERATE WHOLE PROGRAM ======


{-| Generate an MlirModule directly, for use in invariant testing.
-}
generateMlirModule : Mode.Mode -> Mono.MonoGraph -> MlirModule
generateMlirModule mode monoGraph0 =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes, ports, flagsDecoder }) =
            monoGraph0

        signatures : Array (Maybe Ctx.FuncSignature)
        signatures =
            Ctx.buildSignatures nodes

        ctx : Ctx.Context
        ctx =
            Ctx.initContext mode registry signatures ctorShapes
                |> Ctx.withInlineBodies (MonoInlineSimplify.buildBodyLookup monoGraph0)

        ( revOpChunks, ctxAfterNodes, _ ) =
            Array.foldl
                (\maybeNode ( accChunks, accCtx, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( accChunks, accCtx, specId + 1 )

                        Just node ->
                            let
                                ( nodeOps, newCtx ) =
                                    Functions.generateNode accCtx specId node
                            in
                            ( nodeOps :: accChunks, newCtx, specId + 1 )
                )
                ( [], ctx, 0 )
                nodes

        ops =
            List.concat (List.reverse revOpChunks)

        ( lambdaOps, finalCtx ) =
            Lambdas.processLambdas ctxAfterNodes

        -- ctorShapes are already complete from MonoGraph - no fill step needed
        ( mainOps, ctxAfterMain ) =
            case main of
                Just mainInfo ->
                    Functions.generateMainEntry finalCtx ports flagsDecoder mainInfo

                Nothing ->
                    ( [], finalCtx )

        -- Generate kernel function declarations from tracked calls
        ( kernelDeclOps, _ ) =
            Dict.foldl
                (\_ info ( accOps, accCtx ) ->
                    let
                        ( newCtx, declOp ) =
                            Functions.generateKernelDecl accCtx info
                    in
                    ( declOp :: accOps, newCtx )
                )
                ( [], ctxAfterMain )
                ctxAfterMain.kernelDecls

        -- Generate the type table op for debug printing
        typeTableOp : MlirOp
        typeTableOp =
            TypeTable.generateTypeTable finalCtx
    in
    { body = lambdaOps ++ ops ++ mainOps ++ List.reverse kernelDeclOps ++ [ typeTableOp ]
    , loc = Loc.unknown
    }


generateProgram : Mode.Mode -> Mono.MonoGraph -> String
generateProgram mode monoGraph =
    Pretty.ppModule (generateMlirModule mode monoGraph)



-- ====== STREAMING ======


{-| OC0.3 (plans/borrow-oracle-consumers.md): derive the distilled
borrow-oracle facts from the graph being emitted — by construction the FINAL
post-CafHoist graph, so the SpecId-keyed facts can never go stale against a
pass that runs after GlobalOpt. Empty (and free) unless `borrow.oracleOpt`.
-}
deriveOracleFacts : Config.EcoConfig -> Mono.MonoGraph -> BorrowFacts.OracleFacts
deriveOracleFacts ecoConfig monoGraph =
    if ecoConfig.borrow.oracleOpt then
        Borrow.deriveFacts monoGraph

    else
        BorrowFacts.emptyFacts


{-| Stream MLIR text output to a writer function, emitting the module header,
each top-level operation, and footer sequentially.
-}
streamMlirToWriter :
    Config.EcoConfig
    -> Mode.Mode
    -> Mono.MonoGraph
    -> (String -> Task Never ())
    -> Task Never ()
streamMlirToWriter ecoConfig mode monoGraph0 writeChunk =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes, ports, flagsDecoder }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes

        ctx =
            Ctx.initContext mode registry signatures ctorShapes
                |> Ctx.withInlineBodies (MonoInlineSimplify.buildBodyLookup monoGraph0)
                |> Ctx.withEcoConfig ecoConfig
                |> Ctx.withCtorBySpec (buildCtorBySpec nodes)
                |> Ctx.withNullConsBySpec (buildNullConsBySpec registry nodes)
                |> Ctx.withConstCtorBySpec (buildConstCtorBySpec registry nodes)
                |> Ctx.withConstThunkBySpec
                    (ConstThunks.build ecoConfig.constThunks
                        registry
                        signatures
                        nodes
                        main
                        (buildNullConsBySpec registry nodes)
                        (buildConstCtorBySpec registry nodes)
                    )
                |> Ctx.withSretPromoted (buildSretPromoted ecoConfig nodes)
                |> Ctx.withPsplitPromoted (buildPsplitPromoted ecoConfig ctorShapes (buildCtorBySpec nodes) (buildSretPromoted ecoConfig nodes) nodes)
                |> Ctx.withOracleFacts (deriveOracleFacts ecoConfig monoGraph0)
                |> Ctx.withMapTemplates (MapTemplate.derive ecoConfig monoGraph0)

        nodesList =
            Array.toIndexedList nodes
    in
    -- 1. Header
    writeChunk Pretty.ppModuleHeader
        |> Task.andThen (\_ -> streamNodesList ctx nodesList writeChunk)
        |> Task.andThen
            (\ctxAfterNodes ->
                -- 2. Lambdas
                let
                    ( lambdaOps, finalCtx ) =
                        Lambdas.processLambdas ctxAfterNodes

                    -- 3. Main + kernel decls + type table
                    ( mainOps, ctxAfterMain ) =
                        case main of
                            Just mainInfo ->
                                Functions.generateMainEntry finalCtx ports flagsDecoder mainInfo

                            Nothing ->
                                ( [], finalCtx )

                    ( kernelDeclOps, _ ) =
                        Dict.foldl
                            (\_ info ( accOps, accCtx ) ->
                                let
                                    ( newCtx, declOp ) =
                                        Functions.generateKernelDecl accCtx info
                                in
                                ( declOp :: accOps, newCtx )
                            )
                            ( [], ctxAfterMain )
                            ctxAfterMain.kernelDecls

                    typeTableOp =
                        TypeTable.generateTypeTable finalCtx
                in
                writeOps lambdaOps writeChunk
                    |> Task.andThen (\_ -> writeOps mainOps writeChunk)
                    |> Task.andThen (\_ -> writeOps (List.reverse kernelDeclOps) writeChunk)
                    |> Task.andThen (\_ -> writeOps [ typeTableOp ] writeChunk)
                    |> Task.andThen (\_ -> writeChunk Pretty.ppModuleFooter)
            )


streamNodesList :
    Ctx.Context
    -> List ( Int, Maybe Mono.MonoNode )
    -> (String -> Task Never ())
    -> Task Never Ctx.Context
streamNodesList ctx0 remaining writeChunk =
    case remaining of
        [] ->
            Task.succeed ctx0

        ( _, Nothing ) :: rest ->
            -- Empty slot
            streamNodesList ctx0 rest writeChunk

        ( specId, Just node ) :: rest ->
            let
                ( nodeOps, newCtx ) =
                    Functions.generateNode ctx0 specId node

                -- Clear per-function fields to avoid accumulating across nodes.
                -- decoderExprs caches let-bound decoder expressions for BytesFusion;
                -- externBoxedVars tracks extern/kernel aliases — both are function-local.
                cleanCtx =
                    { newCtx
                        | decoderExprs = Dict.empty
                        , externBoxedVars = Set.empty
                    }
            in
            writeOps nodeOps writeChunk
                |> Task.andThen (\_ -> streamNodesList cleanCtx rest writeChunk)


writeOps : List MlirOp -> (String -> Task Never ()) -> Task Never ()
writeOps ops writeChunk =
    case ops of
        [] ->
            Task.succeed ()

        [ single ] ->
            writeChunk (Pretty.ppTopLevelOp single)

        _ ->
            writeChunk (ops |> List.map Pretty.ppTopLevelOp |> String.concat)



-- ====== BYTECODE OUTPUT ======


{-| Generate MLIR bytecode using the streaming encoder.

The node loop runs as a chain of Task steps, `codegenBatchSize` nodes per
step (plans/frontend-heap-release.md §7.6 row 12). Calling this function only
builds the codegen context and the node list (step A); after it returns, the
`MonoGraph` itself is no longer referenced (the continuations capture `main`,
`ports` and `flagsDecoder` separately), and each step's root is just
`( ctx, remaining nodes, tables )`, so the nodes already emitted become
garbage while the rest are generated. Ops, ctx and tables are threaded in
exactly the order of the former pure recursion, so the output is
byte-identical.

-}
streamMlirBytecode :
    Config.EcoConfig
    -> Mode.Mode
    -> Mono.MonoGraph
    -> String
    -> Task Never ()
streamMlirBytecode ecoConfig mode monoGraph0 target =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes, ports, flagsDecoder }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes

        ctx =
            Ctx.initContext mode registry signatures ctorShapes
                |> Ctx.withInlineBodies (MonoInlineSimplify.buildBodyLookup monoGraph0)
                |> Ctx.withEcoConfig ecoConfig
                |> Ctx.withCtorBySpec (buildCtorBySpec nodes)
                |> Ctx.withNullConsBySpec (buildNullConsBySpec registry nodes)
                |> Ctx.withConstCtorBySpec (buildConstCtorBySpec registry nodes)
                |> Ctx.withConstThunkBySpec
                    (ConstThunks.build ecoConfig.constThunks
                        registry
                        signatures
                        nodes
                        main
                        (buildNullConsBySpec registry nodes)
                        (buildConstCtorBySpec registry nodes)
                    )
                |> Ctx.withSretPromoted (buildSretPromoted ecoConfig nodes)
                |> Ctx.withPsplitPromoted (buildPsplitPromoted ecoConfig ctorShapes (buildCtorBySpec nodes) (buildSretPromoted ecoConfig nodes) nodes)
                |> Ctx.withOracleFacts (deriveOracleFacts ecoConfig monoGraph0)
                |> Ctx.withMapTemplates (MapTemplate.derive ecoConfig monoGraph0)

        nodesList =
            Array.toIndexedList nodes

        initTables =
            StreamEncode.emptyStreamTables
    in
    -- Phase 1: Stream node functions — collect tables + encode per func, in
    -- batches, each batch its own step.
    Task.succeed ( ctx, nodesList, initTables )
        |> Task.andThen streamNodesStep
        |> Task.andThen (finishBytecode main ports flagsDecoder target)


{-| Nodes generated per Task step. Any value gives the same output; it only
bounds how many already-emitted nodes a step keeps rooted.
-}
codegenBatchSize : Int
codegenBatchSize =
    256


{-| One step of the node loop: emit a batch, then continue in a NEW step whose
root no longer holds the emitted nodes.
-}
streamNodesStep :
    ( Ctx.Context, List ( Int, Maybe Mono.MonoNode ), StreamEncode.StreamTables )
    -> Task Never ( Ctx.Context, StreamEncode.StreamTables )
streamNodesStep ( ctx0, remaining, tables ) =
    case remaining of
        [] ->
            Task.succeed ( ctx0, tables )

        _ :: _ ->
            Task.succeed (encodeNodeBatch codegenBatchSize ctx0 remaining tables)
                |> Task.andThen streamNodesStep


{-| Generate and encode up to `budget` node-list entries (pure, tail
recursive). Same per-node work, in the same order, as the former
`streamNodesCollectEncode`.
-}
encodeNodeBatch :
    Int
    -> Ctx.Context
    -> List ( Int, Maybe Mono.MonoNode )
    -> StreamEncode.StreamTables
    -> ( Ctx.Context, List ( Int, Maybe Mono.MonoNode ), StreamEncode.StreamTables )
encodeNodeBatch budget ctx0 remaining tables =
    if budget <= 0 then
        ( ctx0, remaining, tables )

    else
        case remaining of
            [] ->
                ( ctx0, [], tables )

            ( _, Nothing ) :: rest ->
                encodeNodeBatch (budget - 1) ctx0 rest tables

            ( specId, Just node ) :: rest ->
                let
                    ( nodeOps, newCtx ) =
                        Functions.generateNode ctx0 specId node

                    cleanCtx =
                        { newCtx
                            | decoderExprs = Dict.empty
                            , externBoxedVars = Set.empty
                        }

                    newTables =
                        StreamEncode.collectAndEncodeOps nodeOps tables
                in
                encodeNodeBatch (budget - 1) cleanCtx rest newTables


{-| After the node loop: lambdas, main entry, kernel declarations, type table,
then assemble and write the module. A top-level function so the pending
continuation captures exactly these arguments, never the MonoGraph.
-}
finishBytecode :
    Maybe Mono.MainInfo
    -> List Mono.PortRegistration
    -> Maybe Mono.SpecId
    -> String
    -> ( Ctx.Context, StreamEncode.StreamTables )
    -> Task Never ()
finishBytecode main ports flagsDecoder target ( ctxAfterNodes, tablesAfterNodes ) =
    let
        -- Process lambdas
        ( lambdaOps, finalCtx ) =
            Lambdas.processLambdas ctxAfterNodes

        tablesAfterLambdas =
            StreamEncode.collectAndEncodeOps lambdaOps tablesAfterNodes

        -- Main entry
        ( mainOps, ctxAfterMain ) =
            case main of
                Just mainInfo ->
                    Functions.generateMainEntry finalCtx ports flagsDecoder mainInfo

                Nothing ->
                    ( [], finalCtx )

        tablesAfterMain =
            StreamEncode.collectAndEncodeOps mainOps tablesAfterLambdas

        -- Kernel declarations
        ( kernelDeclOps, _ ) =
            Dict.foldl
                (\_ info ( accOps, accCtx ) ->
                    let
                        ( newCtx, declOp ) =
                            Functions.generateKernelDecl accCtx info
                    in
                    ( declOp :: accOps, newCtx )
                )
                ( [], ctxAfterMain )
                ctxAfterMain.kernelDecls

        tablesAfterKernels =
            StreamEncode.collectAndEncodeOps (List.reverse kernelDeclOps) tablesAfterMain

        -- Type table
        typeTableOp =
            TypeTable.generateTypeTable finalCtx

        finalTables =
            StreamEncode.collectAndEncodeOps [ typeTableOp ] tablesAfterKernels

        -- Assemble final bytecode
        bytecodeBytes =
            StreamEncode.assembleModule finalTables Loc.unknown
    in
    Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
        |> Task.andThen (\_ -> Eco.File.writeBytes target bytecodeBytes |> IO.crashOnError)


{-| U-T1.3.3 result-promotion selection (census-revised rule,
plans/opt-tier1-aggregate-promotion.md): a spec is promoted iff
(a) it is a zero-capture function whose result is a tuple2/3,
(b) every RESULT-spine leaf of its body is a tuple literal of that
arity (spine = let/destruct bodies + case branches + if branches, the
last admitted by step 10a), and
(c) at least one LET-BOUND direct call site exists somewhere in the
graph (otherwise the worker+shim would be pure overhead).
Leaf-ness is NOT required — the census measured it empty and it buys no
soundness. Workers/shims emit in `Functions.generateSretWorkerAndShim`;
sites migrate per-site in `Expr.trySretLetBinding`.
-}
buildSretPromoted : Config.EcoConfig -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Ctx.SretInfo
buildSretPromoted config nodes =
    if not config.sretResults then
        Dict.empty

    else
        let
            candidates =
                Tuple.second
                    (Array.foldl
                        (\maybeNode ( specId, acc ) ->
                            case maybeNode of
                                Just (Mono.MonoDefine (Mono.MonoClosure cinfo cbody _) monoType) ->
                                    if List.isEmpty cinfo.captures && not (List.isEmpty cinfo.params) then
                                        case closureResultType monoType of
                                            Mono.MTuple _ ts ->
                                                let
                                                    arity =
                                                        List.length ts
                                                in
                                                if (arity == 2 || arity == 3) && sretTailOk (Types.tupleSlotTypes (Types.computeTupleLayout ts)) cbody then
                                                    let
                                                        layout =
                                                            Types.computeTupleLayout ts
                                                    in
                                                    ( specId + 1
                                                    , Dict.insert specId
                                                        { layout = layout
                                                        , slotTypes = Types.tupleSlotTypes layout
                                                        }
                                                        acc
                                                    )

                                                else
                                                    ( specId + 1, acc )

                                            _ ->
                                                ( specId + 1, acc )

                                    else
                                        ( specId + 1, acc )

                                Just (Mono.MonoTailFunc tparams tbody monoType) ->
                                    -- U-T1.3.6: tail funcs promote too — the loop
                                    -- carries DECOMPOSED result columns; a
                                    -- MonoTailCall leaf is a continue, not a result.
                                    -- Independently gated (ECO_SRET_TAILFUNC=0) so
                                    -- the widening can be A/B'd apart from T1.3.3.
                                    case Ctx.residualResultType (List.length tparams) monoType of
                                        Mono.MTuple _ ts ->
                                            let
                                                arity =
                                                    List.length ts
                                            in
                                            if config.sretTailFuncs && (arity == 2 || arity == 3) && sretTailFuncOk (Types.tupleSlotTypes (Types.computeTupleLayout ts)) tbody then
                                                let
                                                    layout =
                                                        Types.computeTupleLayout ts
                                                in
                                                ( specId + 1
                                                , Dict.insert specId
                                                    { layout = layout
                                                    , slotTypes = Types.tupleSlotTypes layout
                                                    }
                                                    acc
                                                )

                                            else
                                                ( specId + 1, acc )

                                        _ ->
                                            ( specId + 1, acc )

                                _ ->
                                    ( specId + 1, acc )
                        )
                        ( 0, Dict.empty )
                        nodes
                    )

            calledInLetPosition =
                Array.foldl
                    (\maybeNode acc ->
                        case maybeNode of
                            Just node ->
                                nodeExprs node
                                    |> List.foldl
                                        (\e acc2 ->
                                            MonoTraverse.foldExpr collectSretSites acc2 e
                                        )
                                        acc

                            Nothing ->
                                acc
                    )
                    Set.empty
                    nodes

            base =
                Dict.filter (\specId _ -> Set.member specId calledInLetPosition) candidates

            -- Step 10g: the OPTIMISTIC start set for the greatest fixpoint —
            -- every SHAPE-eligible zero-capture tuple2/3 define with a
            -- let-bound call site, admitted without looking at its body.
            optimistic =
                Tuple.second
                    (Array.foldl
                        (\maybeNode ( specId, acc ) ->
                            case maybeNode of
                                Just (Mono.MonoDefine (Mono.MonoClosure cinfo _ _) monoType) ->
                                    if List.isEmpty cinfo.captures && not (List.isEmpty cinfo.params) && Set.member specId calledInLetPosition && not (Dict.member specId acc) then
                                        case closureResultType monoType of
                                            Mono.MTuple _ ts ->
                                                if List.length ts == 2 || List.length ts == 3 then
                                                    let
                                                        layout =
                                                            Types.computeTupleLayout ts
                                                    in
                                                    ( specId + 1
                                                    , Dict.insert specId
                                                        { layout = layout, slotTypes = Types.tupleSlotTypes layout }
                                                        acc
                                                    )

                                                else
                                                    ( specId + 1, acc )

                                            _ ->
                                                ( specId + 1, acc )

                                    else
                                        ( specId + 1, acc )

                                _ ->
                                    ( specId + 1, acc )
                        )
                        ( 0, base )
                        nodes
                    )
        in
        if config.sretFresh then
            case sretFreshGreatest nodes 0 optimistic of
                Just settled ->
                    settled

                Nothing ->
                    -- Did not converge inside the round budget: the table would
                    -- not be self-consistent, and an inconsistent table is a
                    -- MISCOMPILE (emission feeds a multi-result call to a
                    -- callee that has no worker). Fall back to the least
                    -- fixpoint, which is always consistent.
                    sretFreshFixpoint calledInLetPosition nodes 0 base

        else
            base


{-| Step 10g: the GREATEST fixpoint of the same admission rule.

`sretFreshFixpoint` below is a LEAST fixpoint over an already-admitted table,
so a group of functions whose result leaves are calls to EACH OTHER can never
bootstrap: each one is waiting for the other to be admitted first, and neither
ever is. That is not a rare shape — it is the normal shape of a recursive
descent over a syntax tree, where `translate` and `translateDispatch` and the
twenty `translateX` arms all tail-call one another. Under the least fixpoint
only the functions whose every leaf is a literal tuple get promoted, which in
`MonoSolver` was 16 of about 95.

The greatest fixpoint answers the question the least one cannot: start with
every SHAPE-eligible spec assumed promoted, then repeatedly DROP any whose
body fails the check against the current table. Removal only ever shrinks the
table, so the iteration terminates, and at the fixpoint every surviving
member's call leaves point at surviving members — exactly the self-consistency
`trySretFreshLeaf` needs at emission.

The one thing the greatest fixpoint could admit that the least cannot justify
is a cycle with NO tuple literal anywhere in it (`f` yields `g`, `g` yields
`f`). Such a function has no result leaf at all and cannot terminate, so it
cannot occur in a program that runs; and were it to occur, the members agree
with each other, so emission stays consistent.

Returns `Nothing` if the round budget runs out, because a table left mid-cascade
is NOT self-consistent and using it would be a miscompile.

-}
sretFreshGreatest : Array (Maybe Mono.MonoNode) -> Int -> Dict.Dict Int Ctx.SretInfo -> Maybe (Dict.Dict Int Ctx.SretInfo)
sretFreshGreatest nodes iter table =
    let
        ( _, dropped, next ) =
            Array.foldl
                (\maybeNode ( sid, shrank, acc ) ->
                    case ( maybeNode, Dict.get sid acc ) of
                        ( Just (Mono.MonoDefine (Mono.MonoClosure _ cbody _) _), Just info ) ->
                            if sretFreshTailOk acc info.slotTypes cbody then
                                ( sid + 1, shrank, acc )

                            else
                                ( sid + 1, True, Dict.remove sid acc )

                        _ ->
                            -- Not a define, or already dropped. Tail-func
                            -- entries admitted by `sretTailFuncOk` are not
                            -- table-relative and are never revisited here.
                            ( sid + 1, shrank, acc )
                )
                ( 0, False, table )
                nodes
    in
    if not dropped then
        Just next

    else if iter >= 30 then
        Nothing

    else
        sretFreshGreatest nodes (iter + 1) next


{-| U-T1.3.8 (`ECO_SRET_FRESH`): widen selection to helper-mediated
results — a leaf that IS a direct call to a table member with identical
slot types is fresh by construction (the member's worker constructs it,
and emission feeds the multi-result call straight through,
`trySretFreshLeaf`). Iterated on the FILTERED (site-gated) table so
admission stays self-consistent with emission — the T1.3.7 discipline.
MonoDefine only in v1: tail-func bases stay under `sretTailFuncs`.
-}
sretFreshFixpoint : Set.Set Int -> Array (Maybe Mono.MonoNode) -> Int -> Dict.Dict Int Ctx.SretInfo -> Dict.Dict Int Ctx.SretInfo
sretFreshFixpoint letPos nodes iter table =
    let
        -- The admission guard already requires `not (Dict.member sid acc)`, so
        -- an insert is always a new key and "did this round add anything" is
        -- exactly the flag below. Comparing `Dict.size` against the previous
        -- table walked both trees to recover the same bit.
        ( _, added, next ) =
            Array.foldl
                (\maybeNode ( sid, grew, acc ) ->
                    case maybeNode of
                        Just (Mono.MonoDefine (Mono.MonoClosure cinfo cbody _) monoType) ->
                            if List.isEmpty cinfo.captures && not (List.isEmpty cinfo.params) && not (Dict.member sid acc) && Set.member sid letPos then
                                case closureResultType monoType of
                                    Mono.MTuple _ ts ->
                                        let
                                            ar =
                                                List.length ts

                                            layout =
                                                Types.computeTupleLayout ts

                                            slotTys =
                                                Types.tupleSlotTypes layout
                                        in
                                        if (ar == 2 || ar == 3) && sretFreshTailOk acc slotTys cbody then
                                            ( sid + 1, True, Dict.insert sid { layout = layout, slotTypes = slotTys } acc )

                                        else
                                            ( sid + 1, grew, acc )

                                    _ ->
                                        ( sid + 1, grew, acc )

                            else
                                ( sid + 1, grew, acc )

                        _ ->
                            ( sid + 1, grew, acc )
                )
                ( 0, False, table )
                nodes
    in
    if not added || iter >= 6 then
        next

    else
        sretFreshFixpoint letPos nodes (iter + 1) next


sretFreshTailOk : Dict.Dict Int Ctx.SretInfo -> List MlirType -> Mono.MonoExpr -> Bool
sretFreshTailOk table slotTys e =
    case e of
        Mono.MonoTupleCreate _ _ leafTy ->
            sretLeafMatches slotTys leafTy

        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) _ _ _ ->
            (Dict.get sid table |> Maybe.map .slotTypes) == Just slotTys

        Mono.MonoLet _ b _ ->
            sretFreshTailOk table slotTys b

        Mono.MonoDestruct _ b _ ->
            sretFreshTailOk table slotTys b

        Mono.MonoIf brs fin _ ->
            -- Step 10a: without this the fresh fixpoint rejects an if-spine
            -- whose leaves are calls to promoted callees, and the whole
            -- function falls back to a heap tuple.
            List.all (sretFreshTailOk table slotTys) (fin :: List.map Tuple.second brs)

        Mono.MonoCase _ _ decider jumps _ ->
            sretFreshDeciderOk table slotTys decider
                && List.all (\( _, je ) -> sretFreshTailOk table slotTys je) jumps

        _ ->
            False


sretFreshDeciderOk : Dict.Dict Int Ctx.SretInfo -> List MlirType -> Mono.Decider Mono.MonoChoice -> Bool
sretFreshDeciderOk table slotTys d =
    case d of
        Mono.Leaf (Mono.Inline e) ->
            sretFreshTailOk table slotTys e

        Mono.Leaf (Mono.Jump _) ->
            True

        Mono.Chain _ s f ->
            sretFreshDeciderOk table slotTys s && sretFreshDeciderOk table slotTys f

        Mono.FanOut _ edges fb ->
            List.all (\( _, sub ) -> sretFreshDeciderOk table slotTys sub) edges
                && sretFreshDeciderOk table slotTys fb


closureResultType : Mono.MonoType -> Mono.MonoType
closureResultType monoType =
    case monoType of
        Mono.MFunction _ _ _ retType ->
            retType

        _ ->
            monoType


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


collectSretSites : Mono.MonoExpr -> Set.Set Int -> Set.Set Int
collectSretSites e acc =
    case e of
        Mono.MonoLet (Mono.MonoDef _ (Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _)) _ _ ->
            Set.insert specId acc

        _ ->
            acc


{-| U-T1.3.6: the result-spine walk for TAIL FUNCS — `MonoTailCall` is a
loop CONTINUE (not a result leaf). `MonoIf` was admissible here before it
was admissible anywhere else, because TailRec's `compileIfStep` threads the
spine flag through `compileStep`; step 10a taught `Expr.generateIf` the same
protocol, so `sretTailOk` and `sretFreshTailOk` now admit it too.
-}
sretTailFuncOk : List MlirType -> Mono.MonoExpr -> Bool
sretTailFuncOk slotTys e =
    case e of
        Mono.MonoTailCall _ _ _ ->
            True

        Mono.MonoTupleCreate _ _ leafTy ->
            sretLeafMatches slotTys leafTy

        Mono.MonoLet _ b _ ->
            sretTailFuncOk slotTys b

        Mono.MonoDestruct _ b _ ->
            sretTailFuncOk slotTys b

        Mono.MonoIf brs fin _ ->
            List.all (sretTailFuncOk slotTys) (fin :: List.map Tuple.second brs)

        Mono.MonoCase _ _ decider jumps _ ->
            sretTailFuncDeciderOk slotTys decider
                && List.all (\( _, je ) -> sretTailFuncOk slotTys je) jumps

        _ ->
            False


sretTailFuncDeciderOk : List MlirType -> Mono.Decider Mono.MonoChoice -> Bool
sretTailFuncDeciderOk slotTys d =
    case d of
        Mono.Leaf (Mono.Inline e) ->
            sretTailFuncOk slotTys e

        Mono.Leaf (Mono.Jump _) ->
            True

        Mono.Chain _ s f ->
            sretTailFuncDeciderOk slotTys s && sretTailFuncDeciderOk slotTys f

        Mono.FanOut _ edges fb ->
            List.all (\( _, sub ) -> sretTailFuncDeciderOk slotTys sub) edges
                && sretTailFuncDeciderOk slotTys fb


{-| Leaf check compares the leaf tuple's SLOT TYPES against the
function's result plan — arity alone is unsound: node-level result
types can be differently specialized than the body's tuples (the
stale-MVar hazard the TailRec destructor path documents), and a
boxed-slot make where the plan says unboxed crashes emission.
-}
sretLeafMatches : List MlirType -> Mono.MonoType -> Bool
sretLeafMatches slotTys leafMonoType =
    case leafMonoType of
        Mono.MTuple _ ts ->
            (List.length ts == List.length slotTys)
                && (Types.tupleSlotTypes (Types.computeTupleLayout ts) == slotTys)

        _ ->
            False


sretTailOk : List MlirType -> Mono.MonoExpr -> Bool
sretTailOk slotTys e =
    case e of
        Mono.MonoTupleCreate _ _ leafTy ->
            sretLeafMatches slotTys leafTy

        Mono.MonoLet _ b _ ->
            sretTailOk slotTys b

        Mono.MonoDestruct _ b _ ->
            sretTailOk slotTys b

        Mono.MonoIf brs fin _ ->
            -- Step 10a: `if` joins the result spine, exactly as `sretTailFuncOk`
            -- already admits it. `Expr.generateIf` now implements the same
            -- spine-yield protocol `generateCase` does (decomposed
            -- `eco.yieldMany` per branch, `eco.caseMany` at the join), so an
            -- if-shaped tail is a result producer like any other.
            List.all (sretTailOk slotTys) (fin :: List.map Tuple.second brs)

        Mono.MonoCase _ _ decider jumps _ ->
            sretDeciderTailOk slotTys decider
                && List.all (\( _, je ) -> sretTailOk slotTys je) jumps

        _ ->
            False


sretDeciderTailOk : List MlirType -> Mono.Decider Mono.MonoChoice -> Bool
sretDeciderTailOk slotTys d =
    case d of
        Mono.Leaf (Mono.Inline e) ->
            sretTailOk slotTys e

        Mono.Leaf (Mono.Jump _) ->
            True

        Mono.Chain _ s f ->
            sretDeciderTailOk slotTys s && sretDeciderTailOk slotTys f

        Mono.FanOut _ edges fb ->
            List.all (\( _, sub ) -> sretDeciderTailOk slotTys sub) edges
                && sretDeciderTailOk slotTys fb


{-| U-T1.3.5 param-side promotion selection
(plans/opt-tier1-aggregate-promotion.md): a spec gains a `$psplit`
worker iff it is a zero-capture non-tail function, NOT sret-promoted
(v1 mutual exclusion), with ≥1 param whose shape is tuple2/3 or a
single-ctor custom (2–6 fields) and whose EVERY body use is a
projection (`Expr.paramSplitAdmissible` — the T1.3.3L walk, so worker
bodies can never materialize), and ≥1 direct call site somewhere in the
graph passes a CONSTRUCTISH argument at an eligible position (inline
matching construct, or a var let-bound to one) — the win pre-check:
without such a site the worker+shim pair is pure shim-hop overhead.
-}
buildPsplitPromoted : Config.EcoConfig -> Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Ctx.PsplitInfo
buildPsplitPromoted config ctorShapes ctorBySpec sretPromoted nodes =
    if not config.psplitParams then
        Dict.empty

    else
        psplitFixpoint ctorShapes ctorBySpec sretPromoted nodes 0 Dict.empty


{-| U-T1.3.7: iterate selection to a fixpoint. Round N runs with round
N-1's RESULT as the walker's pass-through allowance and the site scan's
forwarded-param seed, so a param forwarded to an already-promoted callee
position no longer vetoes, and a call inside a promoted worker justifies
its callee. Both uses of `prev` are monotone (allowances only admit
more, seeds only justify more), so the table only grows and the
iteration terminates; the cap is a safety net, not a tuning knob. The
fixpoint table is self-consistent — every member's admissibility and
justification hold under the FINAL table, which is exactly what emission
requires (it consults the same table via `ctx.psplitPromoted`), so no
admitted pass-through ever rematerializes in a worker body.
-}
psplitFixpoint : Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Array (Maybe Mono.MonoNode) -> Int -> Dict.Dict Int Ctx.PsplitInfo -> Dict.Dict Int Ctx.PsplitInfo
psplitFixpoint ctorShapes ctorBySpec sretPromoted nodes iter prev =
    let
        next =
            psplitOnePass ctorShapes ctorBySpec sretPromoted nodes prev
    in
    if next == prev || iter >= 4 then
        next

    else
        psplitFixpoint ctorShapes ctorBySpec sretPromoted nodes (iter + 1) next


psplitOnePass : Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Ctx.PsplitInfo -> Dict.Dict Int Ctx.PsplitInfo
psplitOnePass ctorShapes ctorBySpec sretPromoted nodes prev =
    let
        planForParam ( name, monoTy ) body =
            case monoTy of
                Mono.MTuple _ ts ->
                    let
                        ar =
                            List.length ts
                    in
                    if ar == 2 || ar == 3 then
                        let
                            layout =
                                Types.computeTupleLayout ts

                            kind =
                                if ar == 2 then
                                    Mono.Tuple2Container

                                else
                                    Mono.Tuple3Container
                        in
                        if Expr.paramSplitAdmissible prev kind name body then
                            Just { spec = Ctx.SplitTuple layout, slotTypes = Types.tupleSlotTypes layout }

                        else
                            Nothing

                    else
                        Nothing

                Mono.MCustom _ _ _ _ ->
                    case Mono.layoutMapGet monoTy ctorShapes of
                        Just [ shape ] ->
                            if List.length shape.fieldTypes >= 2 && List.length shape.fieldTypes <= 6 then
                                let
                                    clayout =
                                        Types.computeCtorLayout shape
                                in
                                if Expr.paramSplitAdmissible prev (Mono.CustomContainer shape.name) name body then
                                    Just { spec = Ctx.SplitCtor clayout, slotTypes = Types.ctorSlotTypes clayout }

                                else
                                    Nothing

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        candidates =
            Tuple.second
                (Array.foldl
                    (\maybeNode ( specId, acc ) ->
                        case maybeNode of
                            Just (Mono.MonoDefine (Mono.MonoClosure cinfo cbody _) _) ->
                                if
                                    List.isEmpty cinfo.captures
                                        && not (List.isEmpty cinfo.params)
                                        && not (Dict.member specId sretPromoted)
                                then
                                    let
                                        plans =
                                            List.map (\p -> planForParam p cbody) cinfo.params
                                    in
                                    if List.any ((/=) Nothing) plans then
                                        ( specId + 1, Dict.insert specId { paramPlans = plans } acc )

                                    else
                                        ( specId + 1, acc )

                                else
                                    ( specId + 1, acc )

                            _ ->
                                ( specId + 1, acc )
                    )
                    ( 0, Dict.empty )
                    nodes
                )

        -- U-T1.3.7: seed the binder-shape dict with the node's own
        -- params that round N-1 already split — inside the (future)
        -- worker they are slot-form, so passing one to a callee's
        -- admitted position is a free, migrating site.
        seedShapes specId node =
            case ( Dict.get specId prev, node ) of
                ( Just info, Mono.MonoDefine (Mono.MonoClosure cinfo _ _) _ ) ->
                    List.map2 Tuple.pair cinfo.params info.paramPlans
                        |> List.foldl
                            (\( ( pname, _ ), mPlan ) sh ->
                                case mPlan of
                                    Just plan ->
                                        Dict.insert pname (psplitPlanShape plan) sh

                                    Nothing ->
                                        sh
                            )
                            Dict.empty

                _ ->
                    Dict.empty

        justified =
            Tuple.second
                (Array.foldl
                    (\maybeNode ( specId, acc ) ->
                        case maybeNode of
                            Just node ->
                                ( specId + 1
                                , nodeExprs node
                                    |> List.foldl
                                        (\e acc2 ->
                                            Tuple.second
                                                (psplitScanExpr ctorBySpec sretPromoted candidates e ( seedShapes specId node, acc2 ))
                                        )
                                        acc
                                )

                            Nothing ->
                                ( specId + 1, acc )
                    )
                    ( 0, Set.empty )
                    nodes
                )
    in
    Dict.filter (\specId _ -> Set.member specId justified) candidates


psplitPlanShape : Ctx.SlotPlan -> ( String, Int )
psplitPlanShape plan =
    case plan.spec of
        Ctx.SplitTuple layout ->
            ( "t", layout.arity )

        Ctx.SplitCtor clayout ->
            ( "c:" ++ clayout.name, List.length clayout.fields )


{-| U-T1.3.7: PRE-ORDER site scan. The previous `MonoTraverse.foldExpr`
driver was BOTTOM-UP (children before parent), so a binder registered at
a `MonoLet` was never visible to the call sites inside its body — the
binder-shape channel was dead from v1 (masked by inline-construct
justifications). This walker threads `shapes` lexically: let RHS first,
then the registered binder, then the body. Scope is otherwise ignored
(overapproximate — a win pre-check, not a soundness gate; emission's
`psplitArgFree` is the exact per-site check).
-}
psplitScanExpr :
    Dict.Dict Int Mono.CtorShape
    -> Dict.Dict Int Ctx.SretInfo
    -> Dict.Dict Int Ctx.PsplitInfo
    -> Mono.MonoExpr
    -> ( Dict.Dict String ( String, Int ), Set.Set Int )
    -> ( Dict.Dict String ( String, Int ), Set.Set Int )
psplitScanExpr ctorBySpec sretPromoted candidates e (( shapes, justified ) as acc) =
    let
        go e2 a =
            psplitScanExpr ctorBySpec sretPromoted candidates e2 a

        goList es a =
            List.foldl go a es
    in
    case e of
        Mono.MonoLet (Mono.MonoDef x rhs) body _ ->
            let
                ( _, j1 ) =
                    go rhs acc

                binderShape =
                    case psplitConstructShape ctorBySpec rhs of
                        Just sh ->
                            Just sh

                        Nothing ->
                            -- an sret-promoted call result is slot-form at
                            -- emission (trySretLetBinding migrates through
                            -- the same walker/allowances), so it justifies
                            -- a matching admitted position too
                            case rhs of
                                Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) _ _ _ ->
                                    Dict.get sid sretPromoted
                                        |> Maybe.map (\sinfo -> ( "t", sinfo.layout.arity ))

                                _ ->
                                    Nothing

                shapes1 =
                    case binderShape of
                        Just sh ->
                            Dict.insert x sh shapes

                        Nothing ->
                            shapes
            in
            go body ( shapes1, j1 )

        Mono.MonoLet (Mono.MonoTailDef _ _ rhs) body _ ->
            go body (go rhs acc)

        Mono.MonoCall _ f args _ _ ->
            let
                accJ =
                    case f of
                        Mono.MonoVarGlobal _ fsid _ ->
                            case Dict.get fsid candidates of
                                Just info ->
                                    if psplitSiteHit ctorBySpec sretPromoted shapes info args then
                                        ( shapes, Set.insert fsid justified )

                                    else
                                        acc

                                Nothing ->
                                    acc

                        _ ->
                            acc
            in
            goList args (go f accJ)

        Mono.MonoClosure info body _ ->
            go body (goList (List.map (\( _, ce, _ ) -> ce) info.captures) acc)

        Mono.MonoTailCall _ args _ ->
            goList (List.map Tuple.second args) acc

        Mono.MonoIf branches final _ ->
            go final (List.foldl (\( c, b ) a -> go b (go c a)) acc branches)

        Mono.MonoDestruct _ inner _ ->
            go inner acc

        Mono.MonoCase _ _ decider jumps _ ->
            goList (List.map Tuple.second jumps) (psplitScanDecider ctorBySpec sretPromoted candidates decider acc)

        Mono.MonoList _ items _ ->
            goList items acc

        Mono.MonoRecordCreate fields _ ->
            goList (List.map Tuple.second fields) acc

        Mono.MonoRecordAccess inner _ _ ->
            go inner acc

        Mono.MonoRecordUpdate base updates _ ->
            goList (List.map Tuple.second updates) (go base acc)

        Mono.MonoTupleCreate _ elements _ ->
            goList elements acc

        Mono.MonoLiteral _ _ ->
            acc

        Mono.MonoVarLocal _ _ ->
            acc

        Mono.MonoVarGlobal _ _ _ ->
            acc

        Mono.MonoVarKernel _ _ _ _ _ ->
            acc

        Mono.MonoUnit ->
            acc

        Mono.MonoAccessorValue _ _ _ ->
            acc


psplitScanDecider :
    Dict.Dict Int Mono.CtorShape
    -> Dict.Dict Int Ctx.SretInfo
    -> Dict.Dict Int Ctx.PsplitInfo
    -> Mono.Decider Mono.MonoChoice
    -> ( Dict.Dict String ( String, Int ), Set.Set Int )
    -> ( Dict.Dict String ( String, Int ), Set.Set Int )
psplitScanDecider ctorBySpec sretPromoted candidates decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            psplitScanExpr ctorBySpec sretPromoted candidates e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            psplitScanDecider ctorBySpec
                sretPromoted
                candidates
                failure
                (psplitScanDecider ctorBySpec sretPromoted candidates success acc)

        Mono.FanOut _ edges fallback ->
            psplitScanDecider ctorBySpec
                sretPromoted
                candidates
                fallback
                (List.foldl (\( _, d ) a -> psplitScanDecider ctorBySpec sretPromoted candidates d a) acc edges)


{-| Does one call site justify its candidate callee? ≥1 admitted position
receives a free-slot arg: a matching inline construct, a tracked binder,
or (U-T1.3.7) a direct sret-promoted call feeding slots straight through
(arity-level here; `psplitArgFree` rechecks slot-type-exact at emission).
-}
psplitSiteHit : Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Dict.Dict String ( String, Int ) -> Ctx.PsplitInfo -> List Mono.MonoExpr -> Bool
psplitSiteHit ctorBySpec sretPromoted shapes info args =
    List.map2 Tuple.pair info.paramPlans args
        |> List.any
            (\( mPlan, arg ) ->
                case mPlan of
                    Just plan ->
                        case psplitConstructShape ctorBySpec arg of
                            Just sh ->
                                psplitShapeMatches plan sh

                            Nothing ->
                                case arg of
                                    Mono.MonoVarLocal v _ ->
                                        Dict.get v shapes
                                            |> Maybe.map (psplitShapeMatches plan)
                                            |> Maybe.withDefault False

                                    Mono.MonoCall _ (Mono.MonoVarGlobal _ sid2 _) _ _ _ ->
                                        case ( plan.spec, Dict.get sid2 sretPromoted ) of
                                            ( Ctx.SplitTuple layout, Just sinfo ) ->
                                                sinfo.layout.arity == layout.arity

                                            _ ->
                                                False

                                    _ ->
                                        False

                    Nothing ->
                        False
            )


psplitConstructShape : Dict.Dict Int Mono.CtorShape -> Mono.MonoExpr -> Maybe ( String, Int )
psplitConstructShape ctorBySpec e =
    case e of
        Mono.MonoTupleCreate _ es _ ->
            Just ( "t", List.length es )

        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) cargs _ _ ->
            case Dict.get sid ctorBySpec of
                Just shape ->
                    if List.length cargs == List.length shape.fieldTypes then
                        Just ( "c:" ++ shape.name, List.length cargs )

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


psplitShapeMatches : Ctx.SlotPlan -> ( String, Int ) -> Bool
psplitShapeMatches plan ( tag, n ) =
    case plan.spec of
        Ctx.SplitTuple layout ->
            tag == "t" && n == layout.arity

        Ctx.SplitCtor clayout ->
            tag == ("c:" ++ clayout.name) && n == List.length clayout.fields


{-| U-T1.3.2: SpecId → CtorShape for every `MonoCtor` node (aggregate
promotion recognises saturated ctor calls at let bindings through this).
-}
buildCtorBySpec : Array (Maybe Mono.MonoNode) -> Dict.Dict Int Mono.CtorShape
buildCtorBySpec nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                case maybeNode of
                    Just (Mono.MonoCtor shape _) ->
                        ( specId + 1, Dict.insert specId shape acc )

                    _ ->
                        ( specId + 1, acc )
            )
            ( 0, Dict.empty )
            nodes
        )


{-| The constant-thunk census (`ECO_CONST_THUNK_REPORT=1`, CGEN\_082) over the
graph codegen is about to emit.
-}
constThunkReport : Config.EcoConfig -> Mono.MonoGraph -> String
constThunkReport ecoConfig (Mono.MonoGraph { nodes, main, registry }) =
    ConstThunks.report ecoConfig.constThunks
        registry
        (Ctx.buildSignatures nodes)
        nodes
        main
        (buildNullConsBySpec registry nodes)
        (buildConstCtorBySpec registry nodes)


{-| SpecId -> ctor name for nullary specs that embed as a WELL-KNOWN constant.

`CtorTag.embedsAsNullCons` excludes `Nothing` / `True` / `False` from
`buildNullConsBySpec` because they predate the null-cons mechanism and carry no
declaration-index tag — `Nothing` IS the merged Empty (REP\_CONSTANT\_001,
`eco.constant` kind 2). Their spec still compiles to a func.func whose whole
body is that constant, so every reference paid an arity-0 CALL to fetch a
compile-time constant (7,913 call sites across 436 duplicate `Maybe_Nothing`
specs on the self-compile). This map lets `generateVarGlobal` emit the constant
directly, exactly as it already does for null-cons ctors.

Scoped to `Nothing`: its result is a custom type, so the ABI is always
`!eco.value` and the folded constant matches the call's result type. `True` /
`False` are Bool-typed and reach codegen through `Test.IsBool` paths with their
own ABI handling (CGEN\_009), so they are deliberately left alone.

-}
buildConstCtorBySpec : Mono.SpecializationRegistry -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int String
buildConstCtorBySpec registry nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                ( specId + 1
                , case maybeNode of
                    Just (Mono.MonoCtor shape _) ->
                        if List.isEmpty shape.fieldTypes && isMaybeNothing registry specId then
                            Dict.insert specId "Nothing" acc

                        else
                            acc

                    Just (Mono.MonoEnum _ _) ->
                        if isMaybeNothing registry specId then
                            Dict.insert specId "Nothing" acc

                        else
                            acc

                    _ ->
                        acc
                )
            )
            ( 0, Dict.empty )
            nodes
        )


{-| Whether the spec `specId` is `elm/core`'s `Maybe.Nothing`, by its
registry key (module and name), not by its name alone: a program's own
`Nothing` constructor is an ordinary null-cons constructor.
-}
isMaybeNothing : Mono.SpecializationRegistry -> Int -> Bool
isMaybeNothing registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home ctorName, _ ) ->
            ctorName == "Nothing" && CtorTag.isEmbeddedConstantCtor home ctorName

        _ ->
            False


{-| HEAP\_044/CGEN\_079: SpecId → effective tag for every spec that embeds as
a null-cons constant — nullary `MonoCtor`s and `MonoEnum`s, excluding the
legacy elm/core True/False/Nothing set (their bit patterns predate the
mechanism; a program's own constructors of those names are ordinary).
`Expr.generateVarGlobal` consults this to emit the constant directly instead
of an arity-0 call. Tags are already effective (CtorShape.tag / MonoEnum's
tag are minted through `CtorTag.effective`); the capacity check runs at the
emission sites.
-}
buildNullConsBySpec : Mono.SpecializationRegistry -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Int
buildNullConsBySpec registry nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                ( specId + 1
                , case maybeNode of
                    Just (Mono.MonoCtor shape _) ->
                        case Registry.lookupSpecKey specId registry of
                            Just ( Mono.Global home _, _ ) ->
                                if List.isEmpty shape.fieldTypes && CtorTag.embedsAsNullCons home shape.name then
                                    Dict.insert specId shape.tag acc

                                else
                                    acc

                            _ ->
                                acc

                    Just (Mono.MonoEnum tag _) ->
                        case Registry.lookupSpecKey specId registry of
                            Just ( Mono.Global home ctorName, _ ) ->
                                if CtorTag.embedsAsNullCons home ctorName then
                                    Dict.insert specId tag acc

                                else
                                    acc

                            _ ->
                                acc

                    _ ->
                        acc
                )
            )
            ( 0, Dict.empty )
            nodes
        )
