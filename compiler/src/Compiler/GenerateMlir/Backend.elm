module Compiler.GenerateMlir.Backend exposing
    ( streamMlirToWriter, streamMlirBytecode
    , buildContext, generateNodeOps, Trailer, generateTrailer
    , constThunkReport
    )

{-| The entry point of MLIR generation: it turns a whole monomorphized program
into one MLIR module, as text or as bytecode.

Most of the work of generating code for one function is done elsewhere, in
`Compiler.GenerateMlir.Functions` and `Compiler.GenerateMlir.Expr`. What
belongs here is what no single function can decide: tables about the whole
program that every function's code must agree on. They are computed once,
before any code is generated, and put into the code generator context
(`Compiler.GenerateMlir.Context`). Result and parameter promotion and the
constant-constructor tables are decided in this module, and promotion takes up
most of the file.

_Result promotion_ (sret) gives a function that returns a 2- or 3-tuple a
`$sret` worker that returns the tuple's fields as separate results, so a caller
that only takes the tuple apart never allocates it. _Parameter promotion_
(psplit) gives a function a `$psplit` worker that takes a tuple or
single-constructor parameter as its separate fields. Parameter promotion, and
result promotion when `sretFresh` is on, are chosen by repeated passes over the
whole program that stop at a fixpoint or after a fixed number of passes,
because whether one function qualifies can depend on whether the functions it
calls or is called by qualify. The table the passes settle on must be
self-consistent: code generation reads the same table, and a call emitted as
a multi-result call to a function that has no worker is a miscompile. A
function is never given both.

The other tables say which nullary constructors are emitted as constants
instead of calls: null-cons constructors (a nullary constructor whose value is
an `eco.constant.null_cons` carrying its tag) and `Maybe`'s `Nothing`, whose
value is a fixed constant word. `Compiler.IR.Runtime.CtorTag` owns which
constructors are which.

The streaming writers emit the module in a fixed order: every node of the graph
in SpecId order, then the lifted lambdas, then the main entry, then the kernel
declarations collected along the way, then the type table. The type table is
built from the context as it stands after the lambdas, before the main entry
and kernel declarations are generated. Between nodes the function-local fields
of the context are cleared.

The two entry points generate the same ops. `streamMlirToWriter` writes the
module's text a node at a time, and `streamMlirBytecode` encodes it a batch of
nodes at a time, so that the nodes already emitted can be garbage-collected
while the rest are generated. Both are built from `buildContext`,
`generateNodeOps` and `generateTrailer`, which the tests also use to build a
module in memory.

@docs streamMlirToWriter, streamMlirBytecode
@docs buildContext, generateNodeOps, Trailer, generateTrailer
@docs constThunkReport

-}

import Array exposing (Array)
import Compiler.Config as Config
import Compiler.Core.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateMlir.ConstThunks as ConstThunks
import Compiler.GenerateMlir.Context as Ctx
import Compiler.GenerateMlir.Expr as Expr
import Compiler.GenerateMlir.Functions as Functions
import Compiler.GenerateMlir.Lambdas as Lambdas
import Compiler.GenerateMlir.TypeTable as TypeTable
import Compiler.GenerateMlir.Types as Types
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Runtime.CtorTag as CtorTag
import Compiler.MonoOpt.InlineSimplify as MonoInlineSimplify
import Compiler.MonoOpt.MapTemplate as MapTemplate
import Data.NonEmptyList as NE
import Dict
import Eco.File
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirOp, MlirType)
import Mlir.Pretty as Pretty
import Set
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils



-- ====== GENERATE WHOLE PROGRAM ======


{-| Builds the code generator context every entry point starts from: the
functions' signatures, the bodies available for inlining, the configuration,
and the whole-program tables (constructors by SpecId, null-cons constructors,
constant constructors, constant thunks, result and parameter promotion, and
`List.map` templates).
-}
buildContext : Config.EcoConfig -> Mono.MonoGraph -> Ctx.Context
buildContext ecoConfig monoGraph0 =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes
    in
    Ctx.initContext registry signatures ctorShapes
        |> Ctx.withInlineBodies (MonoInlineSimplify.buildBodyLookup monoGraph0)
        |> Ctx.withEcoConfig ecoConfig
        |> Ctx.withCtorBySpec (buildCtorBySpec nodes)
        |> Ctx.withNullConsBySpec (buildNullConsBySpec nodes)
        |> Ctx.withConstCtorBySpec (buildConstCtorBySpec nodes)
        |> Ctx.withConstThunkBySpec
            (ConstThunks.build ecoConfig.constThunks
                registry
                signatures
                nodes
                main
                (buildNullConsBySpec nodes)
                (buildConstCtorBySpec nodes)
            )
        |> Ctx.withSretPromoted (buildSretPromoted ecoConfig nodes)
        |> Ctx.withPsplitPromoted (buildPsplitPromoted ecoConfig ctorShapes (buildCtorBySpec nodes) (buildSretPromoted ecoConfig nodes) nodes)
        |> Ctx.withMapTemplates (MapTemplate.derive ecoConfig monoGraph0)
        |> Ctx.withEntryMain main


{-| Generates the ops of the node `specId`, and returns them with the context
for the next node, whose function-local fields, `decoderExprs` and
`localEvaluatorParams`, are emptied, so that what one node recorded in them is
not seen by the next.
-}
generateNodeOps : Ctx.Context -> Int -> Mono.MonoNode -> ( List MlirOp, Ctx.Context )
generateNodeOps ctx specId node =
    let
        ( nodeOps, newCtx ) =
            Functions.generateNode ctx specId node
    in
    ( nodeOps
    , { newCtx
        | decoderExprs = Dict.empty
        , localEvaluatorParams = Dict.empty
      }
    )


{-| The ops that follow the nodes, in the order they are emitted: the lifted
lambdas, the main entry, the kernel declarations collected along the way, and
the type table.
-}
type alias Trailer =
    { lambdaOps : List MlirOp
    , mainOps : List MlirOp
    , kernelDeclOps : List MlirOp
    , typeTableOp : MlirOp
    }


{-| Generates what follows the nodes, from the context after the last node. The
type table is built from the context as it stands after the lambdas, before
the main entry and kernel declarations are generated.
-}
generateTrailer : Mono.MainInfo -> List Mono.PortRegistration -> Maybe Mono.SpecId -> Ctx.Context -> Trailer
generateTrailer main ports flagsDecoder ctxAfterNodes =
    let
        ( lambdaOps, finalCtx ) =
            Lambdas.processLambdas ctxAfterNodes

        ( mainOps, ctxAfterMain ) =
            Functions.generateMainEntry finalCtx ports flagsDecoder finalCtx.ecoSystemManagers main

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
    in
    { lambdaOps = lambdaOps
    , mainOps = mainOps
    , kernelDeclOps = List.reverse kernelDeclOps
    , typeTableOp = TypeTable.generateTypeTable finalCtx
    }



-- ====== STREAMING ======


{-| Writes the module's MLIR text through `writeChunk`: the header, then one
chunk per node that produces ops, then the lambdas, main entry, kernel
declarations and type table, then the footer.
-}
streamMlirToWriter :
    Config.EcoConfig
    -> Mono.MonoGraph
    -> (String -> Task Never ())
    -> Task Never ()
streamMlirToWriter ecoConfig monoGraph0 writeChunk =
    let
        (Mono.MonoGraph { nodes, main, ports, flagsDecoder }) =
            monoGraph0

        ctx =
            buildContext ecoConfig monoGraph0

        nodesList =
            Array.toIndexedList nodes
    in
    writeChunk Pretty.ppModuleHeader
        |> Task.andThen (\_ -> streamNodesList ctx nodesList writeChunk)
        |> Task.andThen
            (\ctxAfterNodes ->
                let
                    trailer =
                        generateTrailer main ports flagsDecoder ctxAfterNodes
                in
                writeOps trailer.lambdaOps writeChunk
                    |> Task.andThen (\_ -> writeOps trailer.mainOps writeChunk)
                    |> Task.andThen (\_ -> writeOps trailer.kernelDeclOps writeChunk)
                    |> Task.andThen (\_ -> writeOps [ trailer.typeTableOp ] writeChunk)
                    |> Task.andThen (\_ -> writeChunk Pretty.ppModuleFooter)
            )


{-| Writes the text of each node in `remaining`, in order, and returns the
context after the last one. Empty slots are skipped.
-}
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
            streamNodesList ctx0 rest writeChunk

        ( specId, Just node ) :: rest ->
            let
                ( nodeOps, cleanCtx ) =
                    generateNodeOps ctx0 specId node
            in
            writeOps nodeOps writeChunk
                |> Task.andThen (\_ -> streamNodesList cleanCtx rest writeChunk)


{-| Writes the printed text of `ops` as one chunk, or writes nothing when there
are none.
-}
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


{-| Generates the module as MLIR bytecode and writes it to the file `target`,
creating its directory if it is missing.

The nodes are generated in a chain of Task steps, `codegenBatchSize` nodes per
step. Calling this function only builds the context and the list of nodes. The
pending steps hold `main`, `ports` and `flagsDecoder` rather than the
`MonoGraph`, and each step holds only the context, the nodes not yet generated
and the encoder's tables, so the nodes already emitted can be garbage-collected
while the rest are generated. The batch size does not change the output.

-}
streamMlirBytecode :
    Config.EcoConfig
    -> Mono.MonoGraph
    -> String
    -> Task Never ()
streamMlirBytecode ecoConfig monoGraph0 target =
    let
        (Mono.MonoGraph { nodes, main, ports, flagsDecoder }) =
            monoGraph0

        ctx =
            buildContext ecoConfig monoGraph0

        nodesList =
            Array.toIndexedList nodes

        initTables =
            StreamEncode.emptyStreamTables
    in
    Task.succeed ( ctx, nodesList, initTables )
        |> Task.andThen streamNodesStep
        |> Task.andThen (finishBytecode main ports flagsDecoder target)


{-| The number of node slots, empty ones included, generated in one Task step
of `streamMlirBytecode`. Any positive value gives the same output; it bounds
how long the nodes a step generates stay reachable.
-}
codegenBatchSize : Int
codegenBatchSize =
    256


{-| Generates and encodes the remaining nodes, one batch per Task step, and
returns the context and encoder tables after the last. Each batch starts a new
step, which holds only what is left.
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


{-| Generates and encodes the first `budget` entries of `remaining`, and returns
the context, the entries not yet reached and the encoder tables. An empty slot
counts against `budget`.
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
                    ( nodeOps, cleanCtx ) =
                        generateNodeOps ctx0 specId node

                    newTables =
                        StreamEncode.collectAndEncodeOps nodeOps tables
                in
                encodeNodeBatch (budget - 1) cleanCtx rest newTables


{-| Encodes what follows the nodes (the lambdas, the main entry, the kernel
declarations and the type table), assembles the bytecode module and writes it to
`target`, creating its directory if it is missing. It crashes on a write
error.

It is a top-level function so that the step waiting on the node loop holds
only these arguments, not the `MonoGraph`.

-}
finishBytecode :
    Mono.MainInfo
    -> List Mono.PortRegistration
    -> Maybe Mono.SpecId
    -> String
    -> ( Ctx.Context, StreamEncode.StreamTables )
    -> Task Never ()
finishBytecode main ports flagsDecoder target ( ctxAfterNodes, tablesAfterNodes ) =
    let
        trailer =
            generateTrailer main ports flagsDecoder ctxAfterNodes

        finalTables =
            tablesAfterNodes
                |> StreamEncode.collectAndEncodeOps trailer.lambdaOps
                |> StreamEncode.collectAndEncodeOps trailer.mainOps
                |> StreamEncode.collectAndEncodeOps trailer.kernelDeclOps
                |> StreamEncode.collectAndEncodeOps [ trailer.typeTableOp ]

        bytecodeBytes =
            StreamEncode.assembleModule finalTables Loc.unknown
    in
    Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
        |> Task.andThen (\_ -> Eco.File.writeBytes target bytecodeBytes |> IO.crashOnError)


{-| Returns the result promotion of a function whose result type is
`resultType`: its tuple layout and slot types, when `resultType` is a tuple
(of two or three elements), and `Nothing` for any other type.
-}
sretInfoOf : Mono.MonoType -> Maybe Ctx.SretInfo
sretInfoOf resultType =
    case resultType of
        Mono.MTuple _ ts ->
            let
                layout =
                    Types.computeTupleLayout ts
            in
            Just { layout = layout, slotTypes = Types.tupleSlotTypes layout }

        _ ->
            Nothing


{-| Returns the result-promotion table: the specs that get a `$sret` worker,
by SpecId, each with its tuple layout and slot types. It is empty when
`sretResults` is off.

A spec is a base member when all of these hold:

  - it is a function with at least one parameter, whose result
    is a 2- or 3-tuple;
  - every leaf of its _result spine_ is a tuple literal with the same slot types
    as the result. The result spine is the body, followed through the bodies of
    `let` and destructuring and into every branch of an `if` or `case`;
  - somewhere in the graph a `let` binds the result of a direct call to it.
    Without such a call the worker would only add a hop.

When `sretTailFuncs` is on, a tail-recursive function whose residual result is
a 2- or 3-tuple qualifies on the leaf and call-site terms, with a tail call
counting as a leaf.

When `sretFresh` is on, a leaf may also be a direct call to a member (itself
included) with the same slot types. That table is the greatest fixpoint, computed by
`sretFreshGreatest` from the base members and every define of the right shape
that has a let-bound call site; if it does not settle in time, the least
fixpoint grown from the base members is used instead.

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
                                    if not (List.isEmpty cinfo.params) then
                                        case sretInfoOf (Ctx.closureResultType monoType) of
                                            Just info ->
                                                if sretTailOk (Mono.tupleToList info.slotTypes) cbody then
                                                    ( specId + 1, Dict.insert specId info acc )

                                                else
                                                    ( specId + 1, acc )

                                            Nothing ->
                                                ( specId + 1, acc )

                                    else
                                        ( specId + 1, acc )

                                Just (Mono.MonoTailFunc tparams tbody monoType) ->
                                    case sretInfoOf (Ctx.residualResultType (List.length tparams) monoType) of
                                        Just info ->
                                            if config.sretTailFuncs && sretTailFuncOk (Mono.tupleToList info.slotTypes) tbody then
                                                ( specId + 1, Dict.insert specId info acc )

                                            else
                                                ( specId + 1, acc )

                                        Nothing ->
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

            -- The base members plus every define of the right shape with a
            -- let-bound call site, admitted without looking at its body.
            optimistic =
                Tuple.second
                    (Array.foldl
                        (\maybeNode ( specId, acc ) ->
                            case maybeNode of
                                Just (Mono.MonoDefine (Mono.MonoClosure cinfo _ _) monoType) ->
                                    if not (List.isEmpty cinfo.params) && Set.member specId calledInLetPosition && not (Dict.member specId acc) then
                                        case sretInfoOf (Ctx.closureResultType monoType) of
                                            Just info ->
                                                ( specId + 1, Dict.insert specId info acc )

                                            Nothing ->
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
                    -- A least fixpoint only ever adds members whose call leaves
                    -- are already members, so it is consistent at every round.
                    sretFreshFixpoint calledInLetPosition nodes 0 base

        else
            base


{-| Returns the greatest fixpoint of the `sretFresh` admission rule, starting
from `table`, or `Nothing` if it has not settled after 31 passes.

Each pass drops every define whose result spine fails `sretFreshTailOk` against
the current table, and the passes stop when one drops nothing. The table only
shrinks, and at the fixpoint every surviving member's call leaves are surviving
members, which is the consistency code generation needs. Tail-recursive
functions in `table` are never re-checked or dropped.

A least fixpoint cannot admit a group of functions whose result leaves are
calls to each other, as in a recursive descent where each case calls the next:
each waits for another to be admitted first. Starting from every candidate and
removing failures admits them. It would also admit a cycle with no tuple
literal anywhere in it, but such functions agree with each other, so the table
is still consistent.

A table left part-way through the drops may not be consistent, hence `Nothing`
rather than the last table.

-}
sretFreshGreatest : Array (Maybe Mono.MonoNode) -> Int -> Dict.Dict Int Ctx.SretInfo -> Maybe (Dict.Dict Int Ctx.SretInfo)
sretFreshGreatest nodes iter table =
    let
        ( _, dropped, next ) =
            Array.foldl
                (\maybeNode ( sid, shrank, acc ) ->
                    case ( maybeNode, Dict.get sid acc ) of
                        ( Just (Mono.MonoDefine (Mono.MonoClosure _ cbody _) _), Just info ) ->
                            if sretFreshTailOk acc (Mono.tupleToList info.slotTypes) cbody then
                                ( sid + 1, shrank, acc )

                            else
                                ( sid + 1, True, Dict.remove sid acc )

                        _ ->
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


{-| Returns `table` grown by the `sretFresh` admission rule: each pass adds every
define with at least one parameter, a let-bound call site in
`letPos` and a 2- or 3-tuple result whose result spine passes `sretFreshTailOk`
against the table so far. It stops after a pass that adds nothing, or after
seven passes.

Members are only added, and only when their call leaves are already members,
so the table is consistent after any number of passes.

-}
sretFreshFixpoint : Set.Set Int -> Array (Maybe Mono.MonoNode) -> Int -> Dict.Dict Int Ctx.SretInfo -> Dict.Dict Int Ctx.SretInfo
sretFreshFixpoint letPos nodes iter table =
    let
        -- The guard excludes members already in `acc`, so every insert adds one.
        ( _, added, next ) =
            Array.foldl
                (\maybeNode ( sid, grew, acc ) ->
                    case maybeNode of
                        Just (Mono.MonoDefine (Mono.MonoClosure cinfo cbody _) monoType) ->
                            if not (List.isEmpty cinfo.params) && not (Dict.member sid acc) && Set.member sid letPos then
                                case sretInfoOf (Ctx.closureResultType monoType) of
                                    Just info ->
                                        if sretFreshTailOk acc (Mono.tupleToList info.slotTypes) cbody then
                                            ( sid + 1, True, Dict.insert sid info acc )

                                        else
                                            ( sid + 1, grew, acc )

                                    Nothing ->
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


{-| Tells whether every leaf of the result spine of `e` is either a tuple literal
with slot types `slotTys` or a direct call to a member of `table` with those
slot types. Any other leaf fails.
-}
sretFreshTailOk : Dict.Dict Int Ctx.SretInfo -> List MlirType -> Mono.MonoExpr -> Bool
sretFreshTailOk table slotTys e =
    case e of
        Mono.MonoTupleCreate _ _ leafTy ->
            sretLeafMatches slotTys leafTy

        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) _ _ _ ->
            (Dict.get sid table |> Maybe.map (.slotTypes >> Mono.tupleToList)) == Just slotTys

        Mono.MonoLet _ b _ ->
            sretFreshTailOk table slotTys b

        Mono.MonoDestruct _ b _ ->
            sretFreshTailOk table slotTys b

        Mono.MonoIf brs fin _ ->
            List.all (sretFreshTailOk table slotTys) (fin :: List.map Tuple.second brs)

        Mono.MonoCase _ _ decider jumps _ ->
            sretFreshDeciderOk table slotTys decider
                && List.all (\( _, je ) -> sretFreshTailOk table slotTys je) jumps

        _ ->
            False


{-| Applies `sretFreshTailOk` to every inline leaf of a `case` decision tree. A
jump leaf passes here; its target is checked with the `case`'s jumps.
-}
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
            List.all (\( _, sub ) -> sretFreshDeciderOk table slotTys sub) (NE.toList edges)
                && sretFreshDeciderOk table slotTys fb


{-| Returns the body of a define or a tail-recursive function, and nothing for
any other kind of node.
-}
nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


{-| Adds to `acc` the SpecId of the callee when `e` is a `let` whose value is a
direct call to a global, and returns `acc` unchanged otherwise.
-}
collectSretSites : Mono.MonoExpr -> Set.Set Int -> Set.Set Int
collectSretSites e acc =
    case e of
        Mono.MonoLet (Mono.MonoDef _ (Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _)) _ _ ->
            Set.insert specId acc

        _ ->
            acc


{-| Tells whether every leaf of the result spine of a tail-recursive function's
body `e` is a tuple literal with slot types `slotTys` or a tail call. A tail
call goes round the loop again rather than returning, so it passes.
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


{-| Applies `sretTailFuncOk` to every inline leaf of a `case` decision tree. A
jump leaf passes here; its target is checked with the `case`'s jumps.
-}
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
            List.all (\( _, sub ) -> sretTailFuncDeciderOk slotTys sub) (NE.toList edges)
                && sretTailFuncDeciderOk slotTys fb


{-| Tells whether a tuple literal of type `leafMonoType` has exactly the slot
types `slotTys`.

Comparing arity is not enough: a tuple in the body may be specialized
differently from the function's declared result type, and a tuple whose slot is
boxed where the result's is unboxed cannot be returned through the worker.

-}
sretLeafMatches : List MlirType -> Mono.MonoType -> Bool
sretLeafMatches slotTys leafMonoType =
    case leafMonoType of
        Mono.MTuple _ ts ->
            Mono.tupleToList (Types.tupleSlotTypes (Types.computeTupleLayout ts)) == slotTys

        _ ->
            False


{-| Tells whether every leaf of the result spine of `e` is a tuple literal with
slot types `slotTys`.
-}
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
            List.all (sretTailOk slotTys) (fin :: List.map Tuple.second brs)

        Mono.MonoCase _ _ decider jumps _ ->
            sretDeciderTailOk slotTys decider
                && List.all (\( _, je ) -> sretTailOk slotTys je) jumps

        _ ->
            False


{-| Applies `sretTailOk` to every inline leaf of a `case` decision tree. A jump
leaf passes here; its target is checked with the `case`'s jumps.
-}
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
            List.all (\( _, sub ) -> sretDeciderTailOk slotTys sub) (NE.toList edges)
                && sretDeciderTailOk slotTys fb


{-| Returns the parameter-promotion table: the specs that get a `$psplit` worker,
by SpecId, each with a plan for every parameter. It is empty when
`psplitParams` is off.

A spec is a member when all of these hold:

  - it is a define (not a tail-recursive function) with at least one
    parameter, and is not in `sretPromoted`;
  - at least one parameter is a 2- or 3-tuple, or a custom type with one
    constructor of 2 to 6 fields, and `Expr.paramSplitAdmissible` accepts every
    use of it in the body, so the worker never has to rebuild it;
  - somewhere in the graph a direct call to it passes, at such a position, an
    argument already in pieces: a matching tuple literal or constructor call, a
    variable `let`-bound to one, one of the caller's own split parameters, or,
    at a tuple position, a call to a result-promoted function of the same
    arity or a variable `let`-bound to such a call.
    Without such a call the worker would only add a hop.

The table is computed by `psplitFixpoint`.

-}
buildPsplitPromoted : Config.EcoConfig -> Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Ctx.PsplitInfo
buildPsplitPromoted config ctorShapes ctorBySpec sretPromoted nodes =
    if not config.psplitParams then
        Dict.empty

    else
        psplitFixpoint ctorShapes ctorBySpec sretPromoted nodes 0 Dict.empty


{-| Returns the parameter-promotion table, by repeating `psplitOnePass` from
`prev` until a pass returns its input unchanged, or after five passes.

Each pass judges against the previous pass's table, which lets a parameter be
passed whole to a member's split position without disqualifying it, and lets a
call made inside a member's body, with one of the member's own split
parameters, justify its callee. A larger previous table only admits more, so
the table grows from pass to pass. Code generation consults the same table, so
it needs every member to qualify against the final one.

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


{-| Returns the members chosen by one pass of the parameter-promotion rule, judged
against `prev`, the table from the pass before.
-}
psplitOnePass : Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int Mono.CtorShape -> Dict.Dict Int Ctx.SretInfo -> Array (Maybe Mono.MonoNode) -> Dict.Dict Int Ctx.PsplitInfo -> Dict.Dict Int Ctx.PsplitInfo
psplitOnePass ctorShapes ctorBySpec sretPromoted nodes prev =
    let
        planForParam ( name, monoTy ) body =
            case monoTy of
                Mono.MTuple _ ts ->
                    let
                        layout =
                            Types.computeTupleLayout ts
                    in
                    if Expr.paramSplitAdmissible prev (Mono.tupleContainerKind ts) name body then
                        Just { spec = Ctx.SplitTuple layout, slotTypes = Mono.tupleToList (Types.tupleSlotTypes layout) }

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
                                    not (List.isEmpty cinfo.params)
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

        -- The node's own parameters that `prev` splits are already in pieces
        -- inside its worker, so passing one on counts like a literal.
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


{-| Returns the shape key of the value a parameter plan splits: `"t"` for a tuple,
or `"c:"` followed by the constructor name, paired with the number of fields.
-}
psplitPlanShape : Ctx.SlotPlan -> ( String, Int )
psplitPlanShape plan =
    case plan.spec of
        Ctx.SplitTuple layout ->
            ( "t", Mono.tupleArity layout.elements )

        Ctx.SplitCtor clayout ->
            ( "c:" ++ clayout.name, List.length clayout.fields )


{-| Walks `e` and adds to the justified set every candidate called with an
argument already in pieces at a split position (`psplitSiteHit`), returning the
updated shapes and justified set.

`shapes` maps a variable name to the shape key of the value it is bound to.
The walk is pre-order: a `let`'s value is scanned first, then its name is
recorded, then its body is scanned, so the calls in the body see the binding.
Otherwise scope is ignored, and a binding recorded in one branch stays visible
after it. This can only over-count, which is safe because the scan only decides
whether a worker is worth having; each call is checked exactly when it is
generated.

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
                            -- The result of a call to a result-promoted function
                            -- is bound as separate slots, so it counts too.
                            case rhs of
                                Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) _ _ _ ->
                                    Dict.get sid sretPromoted
                                        |> Maybe.map (\sinfo -> ( "t", Mono.tupleArity sinfo.layout.elements ))

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
            goList (Mono.tupleToList elements) acc

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


{-| Applies `psplitScanExpr` to every inline leaf of a `case` decision tree.
-}
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
                (List.foldl (\( _, d ) a -> psplitScanDecider ctorBySpec sretPromoted candidates d a) acc (NE.toList edges))


{-| Tells whether a call passing `args` to a candidate with plans `info` justifies
it: at least one split position receives a matching tuple literal or
constructor call, a variable whose entry in `shapes` matches, or, for a tuple
position, a direct call to a result-promoted function of the same arity. The
last compares arity only.
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
                                                Mono.tupleArity sinfo.layout.elements == Mono.tupleArity layout.elements

                                            _ ->
                                                False

                                    _ ->
                                        False

                    Nothing ->
                        False
            )


{-| Returns the shape key of `e` when it is a tuple literal, or a call to a
constructor in `ctorBySpec` passing all its fields; otherwise `Nothing`.
-}
psplitConstructShape : Dict.Dict Int Mono.CtorShape -> Mono.MonoExpr -> Maybe ( String, Int )
psplitConstructShape ctorBySpec e =
    case e of
        Mono.MonoTupleCreate _ es _ ->
            Just ( "t", Mono.tupleArity es )

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


{-| Tells whether a shape key is the shape `plan` splits: the same kind, the same
constructor name for a constructor, and the same number of fields.
-}
psplitShapeMatches : Ctx.SlotPlan -> ( String, Int ) -> Bool
psplitShapeMatches plan ( tag, n ) =
    case plan.spec of
        Ctx.SplitTuple layout ->
            tag == "t" && n == Mono.tupleArity layout.elements

        Ctx.SplitCtor clayout ->
            tag == ("c:" ++ clayout.name) && n == List.length clayout.fields


{-| Returns the shape of every `MonoCtor` node (enum nodes are not included), by
SpecId.
-}
buildCtorBySpec : Array (Maybe Mono.MonoNode) -> Dict.Dict Int Mono.CtorShape
buildCtorBySpec nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                case maybeNode of
                    Just (Mono.MonoCtor _ shape _) ->
                        ( specId + 1, Dict.insert specId shape acc )

                    _ ->
                        ( specId + 1, acc )
            )
            ( 0, Dict.empty )
            nodes
        )


{-| Returns `ConstThunks.report` for this graph, computed from the same inputs
code generation gives `ConstThunks.build`.
-}
constThunkReport : Config.EcoConfig -> Mono.MonoGraph -> String
constThunkReport ecoConfig (Mono.MonoGraph { nodes, main, registry }) =
    ConstThunks.report ecoConfig.constThunks
        registry
        (Ctx.buildSignatures nodes)
        nodes
        main
        (buildNullConsBySpec nodes)
        (buildConstCtorBySpec nodes)


{-| Returns the specs of `Maybe`'s `Nothing`, by SpecId, each mapped to the name
`"Nothing"`, so that a reference to one can be emitted as the constant instead
of a call.

`Nothing` is not a null-cons constructor (see `Compiler.IR.Runtime.CtorTag`), so
`buildNullConsBySpec` leaves it out, but its spec's whole body is a constant
all the same. `Nothing` is never an enum (`Maybe` has `Just a`), so only
constructor nodes are looked at.

-}
buildConstCtorBySpec : Array (Maybe Mono.MonoNode) -> Dict.Dict Int String
buildConstCtorBySpec nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                ( specId + 1
                , case maybeNode of
                    Just (Mono.MonoCtor home shape _) ->
                        if List.isEmpty shape.fieldTypes && isMaybeNothing home shape.name then
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


{-| Tells whether the constructor `ctorName` of module `home` is `Maybe`'s
`Nothing`, judged by the module as well as the name, so that a program's own
constructor named `Nothing` does not count.
-}
isMaybeNothing : ModuleName.Canonical -> Name.Name -> Bool
isMaybeNothing home ctorName =
    ctorName == "Nothing" && CtorTag.isEmbeddedConstantCtor home ctorName


{-| Returns the tag of every spec that is a null-cons constant, by SpecId: each
nullary constructor node that `CtorTag.embedsAsNullCons` accepts, judged by
the node's home module and the constructor's name, and each enum node
(no enum is one of the embedded constants, see `Functions.generateEnum`). A
reference to one can then be emitted as the constant instead of a call.

The tag is taken from the node as it is. Whether it fits in a null-cons
constant is not checked here.

-}
buildNullConsBySpec : Array (Maybe Mono.MonoNode) -> Dict.Dict Int Int
buildNullConsBySpec nodes =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                ( specId + 1
                , case maybeNode of
                    Just (Mono.MonoCtor home shape _) ->
                        if List.isEmpty shape.fieldTypes && CtorTag.embedsAsNullCons home shape.name then
                            Dict.insert specId shape.tag acc

                        else
                            acc

                    Just (Mono.MonoEnum _ _ tag _) ->
                        Dict.insert specId tag acc

                    _ ->
                        acc
                )
            )
            ( 0, Dict.empty )
            nodes
        )
