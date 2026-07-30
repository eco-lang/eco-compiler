module Compiler.GlobalOpt.Borrow.Constrain exposing
    ( Constraints, Get, Occ, Reason(..)
    , Gen, emptyGen
    , Env, emptyEnv
    , constrainNode
    , DefAnalysis, constrainDef, constrainClosureForSig
    )

{-| Borrow-inference constraint generation (design §7.5, §8). A Design-B
direct-recursion walker over `MonoExpr` produces a `Constraints` accumulator
(flows / gets / storageEq / scopes / seeds / forcedOwned / occs) that the
Stage-A–D solver (`Solve`) consumes.

Phase 2 keeps every call boundary all-owned: `Env.sigs` yields `Nothing` and
kernels are all-owned unconditionally (`()` placeholders — Phase 3 swaps them
for the real `Sig`/`KernelSigs` types at the same sites).

Walk-time census counters live on `Gen` (flat `Int` fields, well under the
32-slot record cap); the driver reads them off the final `Gen` per def.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Path, Step(..))
import Compiler.GlobalOpt.Borrow.LssFacts as LssFacts
import Compiler.GlobalOpt.Borrow.Mode as Mode exposing (Mode(..))
import Compiler.GlobalOpt.Borrow.Rty as Rty exposing (RTy, ResVar)
import Compiler.GlobalOpt.Borrow.Sig as Sig exposing (BorrowSig)
import Dict exposing (Dict)
import Set exposing (Set)



-- CONSTRAINTS (design §7.5)


type alias Constraints =
    { flows : List ( ResVar, ResVar ) -- bind → use (lateral; I-Use)
    , gets : List Get -- container reads (I-Get)
    , storageEq : List ( ResVar, ResVar ) -- nested/heap-storage equalities (§3.3)
    , scopes : Dict ResVar Path -- binding resource → scope path (I-Let)
    , seeds : List ( ResVar, Path ) -- ltA/ltP ≥ p (reads, borrowed args)
    , forcedOwned : List ( ResVar, Reason )
    , occs : List Occ -- reification records
    , paramSeeds : List ( ResVar, Int ) -- α-seeds: param resource → param position (LParams {i})
    }


type alias Get =
    { container : ResVar, out : List ( ResVar, ResVar ), path : Path }


type alias Occ =
    { res : List ResVar }


type Reason
    = RConstruct
    | RKernel
    | RClosureBoundary
    | RErased
    | RPort
    | RTailArg
    | RCapture


emptyConstraints : Constraints
emptyConstraints =
    { flows = []
    , gets = []
    , storageEq = []
    , scopes = Dict.empty
    , seeds = []
    , forcedOwned = []
    , occs = []
    , paramSeeds = []
    }



-- GEN (per-def analysis state + walk-time census counters)


type alias Gen =
    { next : ResVar
    , cs : Constraints
    , nodeCounter : Int
    , immortalLiterals : Int
    , capturesForcedOwned : Int
    , poisonedByClosure : Int
    , poisonedByKernel : Int
    , poisonedByErased : Int
    , updateCopiedHeapFields : Int
    , nonVarOwnedFresh : Int
    , nonVarBorrowedProducer : Int
    , stringRes : List ResVar -- RString heads (rcManaged v1 target; for wouldFree)
    , sigMissReads : Int -- B3: direct call whose callee sig is Nothing
    , kernelSigHits : Int -- B3: kernel call matched an allowlisted sig
    , kernelDefaultedHeapCalls : Int -- B3: kernel call defaulted all-owned with heap args
    , kernelDefaultedNames : Dict ( Name, Name ) Int -- audit histogram: per-kernel heap-defaulting call count
    , poisoningCallSites : Int -- B3: direct/kernel sites that forced ≥1 heap arg owned
    , tailArgRes : List ResVar -- BORROW_005: resources of MonoTailCall args (escape-seeded)
    , closureRouted : Int -- B3.5: closure calls routed to a real lambda sig (recovered)
    }


emptyGen : Gen
emptyGen =
    { next = 0
    , cs = emptyConstraints
    , nodeCounter = 0
    , immortalLiterals = 0
    , capturesForcedOwned = 0
    , poisonedByClosure = 0
    , poisonedByKernel = 0
    , poisonedByErased = 0
    , updateCopiedHeapFields = 0
    , nonVarOwnedFresh = 0
    , nonVarBorrowedProducer = 0
    , stringRes = []
    , sigMissReads = 0
    , kernelSigHits = 0
    , kernelDefaultedHeapCalls = 0
    , kernelDefaultedNames = Dict.empty
    , poisoningCallSites = 0
    , tailArgRes = []
    , closureRouted = 0
    }


fresh : Gen -> ( ResVar, Gen )
fresh g =
    ( g.next, { g | next = g.next + 1 } )


freshR : Mono.MonoType -> Gen -> ( RTy, Gen )
freshR t g =
    let
        ( rty, n ) =
            Rty.freshRTy t g.next
    in
    ( rty, harvestFresh rty { g | next = n } )


{-| item 19: one walk over a fresh RTy doing BOTH jobs that used to be separate
passes over it — (a) collect `RString` head resvars into `stringRes` (rcManaged v1
target), consed directly (no `collectStringRes ++` intermediate/`concatMap`), and
(b) boundary-poison each erased `ROpaque` resource Owned (RErased) + bump the
census (§7.3). `stringRes` is only ever membership-tested, so its order is
irrelevant; `forcedOwned` folds into the order-independent DSU — so this is
behavior-preserving.
-}
harvestFresh : RTy -> Gen -> Gen
harvestFresh rty g =
    case rty of
        Rty.RScalar ->
            g

        Rty.RString r ->
            { g | stringRes = r :: g.stringRes }

        Rty.ROpaque r ->
            { g | poisonedByErased = g.poisonedByErased + 1 } |> addForced r RErased

        Rty.RClosure _ ->
            g

        Rty.RList _ elem ->
            harvestFresh elem g

        Rty.RTuple _ elems ->
            List.foldl harvestFresh g elems

        Rty.RRecord _ fields ->
            List.foldl (\( _, t ) acc -> harvestFresh t acc) g fields

        Rty.RCustom _ args ->
            List.foldl harvestFresh g args


freshNode : Gen -> ( Int, Gen )
freshNode g =
    ( g.nodeCounter, { g | nodeCounter = g.nodeCounter + 1 } )



-- CONSTRAINT EMITTERS


emit : (Constraints -> Constraints) -> Gen -> Gen
emit f g =
    { g | cs = f g.cs }


addFlows : List ( ResVar, ResVar ) -> Gen -> Gen
addFlows ps =
    emit (\c -> { c | flows = ps ++ c.flows })


{-| Add each pair in BOTH directions (item 26: `unifyArms` needs bidirectional
flow between arm results). Conses both directions straight onto `c.flows` in one
fold, avoiding the `pairs ++ List.map reverse pairs` intermediate list + concat.
Flow order does not affect the (confluent) fixpoints or the DSU partition.
-}
addFlowsBidir : List ( ResVar, ResVar ) -> Gen -> Gen
addFlowsBidir ps =
    emit (\c -> { c | flows = List.foldl (\( a, b ) acc -> ( a, b ) :: ( b, a ) :: acc) c.flows ps })


addStorageEqs : List ( ResVar, ResVar ) -> Gen -> Gen
addStorageEqs ps =
    emit (\c -> { c | storageEq = ps ++ c.storageEq })


addSeeds : List ResVar -> Path -> Gen -> Gen
addSeeds rs path =
    emit (\c -> { c | seeds = List.map (\r -> ( r, path )) rs ++ c.seeds })


{-| item 19c: cons `(r, tag)` for every resvar in an RTy directly onto an
accumulator in one walk — replaces `List.map (\r -> (r, tag)) (Rty.allRes rty)`
(an `allRes` concatMap list + a map list). Order within the RTy is irrelevant to
`seeds`/`paramSeeds` (both fold into resvar-keyed commutative joins).
-}
resPairsInto : b -> RTy -> List ( ResVar, b ) -> List ( ResVar, b )
resPairsInto tag rty acc =
    case rty of
        Rty.RScalar ->
            acc

        Rty.RString r ->
            ( r, tag ) :: acc

        Rty.ROpaque r ->
            ( r, tag ) :: acc

        Rty.RClosure r ->
            ( r, tag ) :: acc

        Rty.RList r elem ->
            resPairsInto tag elem (( r, tag ) :: acc)

        Rty.RTuple r elems ->
            List.foldl (\e a -> resPairsInto tag e a) (( r, tag ) :: acc) elems

        Rty.RRecord r fields ->
            List.foldl (\( _, t ) a -> resPairsInto tag t a) (( r, tag ) :: acc) fields

        Rty.RCustom r args ->
            List.foldl (\e a -> resPairsInto tag e a) (( r, tag ) :: acc) args


addSeedsOfRTy : RTy -> Path -> Gen -> Gen
addSeedsOfRTy rty path =
    emit (\c -> { c | seeds = resPairsInto path rty c.seeds })


addScope : ResVar -> Path -> Gen -> Gen
addScope r path =
    emit (\c -> { c | scopes = Dict.insert r path c.scopes })


addForced : ResVar -> Reason -> Gen -> Gen
addForced r reason =
    emit (\c -> { c | forcedOwned = ( r, reason ) :: c.forcedOwned })


addForcedAll : List ResVar -> Reason -> Gen -> Gen
addForcedAll rs reason g =
    List.foldl (\r acc -> addForced r reason acc) g rs


addGet : Get -> Gen -> Gen
addGet get =
    emit (\c -> { c | gets = get :: c.gets })


addOcc : List ResVar -> Gen -> Gen
addOcc res g =
    emit
        (\c ->
            { c | occs = { res = res } :: c.occs }
        )
        g



-- ENV


type alias Env =
    { vars : Dict Name RTy
    , sigs : Mono.SpecId -> Maybe BorrowSig -- B3: interprocedural signatures (Nothing = unsolved/poison)
    , lssFacts : Maybe LssFacts.Facts -- B3.5: LSS singleton-set routing (Nothing = no routing)
    }


emptyEnv : Env
emptyEnv =
    { vars = Dict.empty, sigs = \_ -> Nothing, lssFacts = Nothing }


bindVar : Name -> RTy -> Env -> Env
bindVar name rty env =
    { env | vars = Dict.insert name rty env.vars }



-- NODE ENTRY


{-| Result of analyzing one def node — carries the param/result shapes AND
their RTys so the driver can read back an interprocedural `BorrowSig`.
-}
type alias DefAnalysis =
    { paramTys : List Mono.MonoType
    , paramRtys : List RTy
    , resultTy : Mono.MonoType
    , resultRty : RTy
    , gen : Gen
    }


{-| Analyze one node into the constraint accumulator (census-only entry).
-}
constrainNode : Env -> Mono.MonoNode -> Gen -> Gen
constrainNode env node g =
    (constrainDef env node g).gen


{-| Analyze a def node, returning its param/result shapes+RTys + the final Gen.
Post-P1 every top-level callable is closure-wrapped, so a `MonoDefine` whose
body is a `MonoClosure` is a function whose params live on the closure.
-}
constrainDef : Env -> Mono.MonoNode -> Gen -> DefAnalysis
constrainDef env node g =
    case node of
        Mono.MonoTailFunc params body _ ->
            analyzeFn env params body g

        Mono.MonoDefine (Mono.MonoClosure info inner _) _ ->
            analyzeFn env info.params inner g

        Mono.MonoDefine body _ ->
            let
                ( rty, g1 ) =
                    constrainExpr env [] body g
            in
            { paramTys = [], paramRtys = [], resultTy = Mono.typeOf body, resultRty = rty, gen = g1 }

        _ ->
            -- ctor/enum/extern/manager/port: no walk (construct-only / RPort poison).
            { paramTys = [], paramRtys = [], resultTy = Mono.nodeType node, resultRty = Rty.RScalar, gen = g }


{-| Analyze a closure (its params + body) as a def, for its lambda signature
(B3.5). Mirrors `constrainDef`'s function path.
-}
constrainClosureForSig : Env -> Mono.ClosureInfo -> Mono.MonoExpr -> Gen -> DefAnalysis
constrainClosureForSig env info body g =
    analyzeFn env info.params body g


analyzeFn : Env -> List ( Name, Mono.MonoType ) -> Mono.MonoExpr -> Gen -> DefAnalysis
analyzeFn env params body g =
    let
        ( env1, paramRtys, g1 ) =
            bindParamsRtys params env g

        ( rty, g2 ) =
            constrainExpr env1 [] body g1
    in
    { paramTys = List.map Tuple.second params
    , paramRtys = paramRtys
    , resultTy = Mono.typeOf body
    , resultRty = rty

    -- Result ownership comes from the construct rule (fresh values owned) +
    -- α-coupling (pass-through params borrow through) — NOT force-owned.
    , gen = g2
    }


bindParamsRtys : List ( Name, Mono.MonoType ) -> Env -> Gen -> ( Env, List RTy, Gen )
bindParamsRtys params env g =
    let
        ( env1, revRtys, ( g1, _ ) ) =
            List.foldl
                (\( name, t ) ( accEnv, accRtys, ( accG, i ) ) ->
                    let
                        ( rty, accG1 ) =
                            freshR t accG

                        -- α-seed: every resource of param position i carries LParams {i}
                        -- so a result resource that flows from it reads back its coupling.
                        accG2 =
                            emit (\c -> { c | paramSeeds = resPairsInto i rty c.paramSeeds }) accG1
                    in
                    ( bindVar name rty accEnv, rty :: accRtys, ( accG2, i + 1 ) )
                )
                ( env, [], ( g, 0 ) )
                params
    in
    ( env1, List.reverse revRtys, g1 )


bindParams : List ( Name, Mono.MonoType ) -> Env -> Gen -> ( Env, Gen )
bindParams params env g =
    let
        ( env1, _, g1 ) =
            bindParamsRtys params env g
    in
    ( env1, g1 )



-- EXPRESSION WALKER (total; all 18 constructors)


constrainExpr : Env -> Path -> Mono.MonoExpr -> Gen -> ( RTy, Gen )
constrainExpr env path expr g =
    case expr of
        Mono.MonoLiteral lit t ->
            case lit of
                Mono.LStr _ ->
                    let
                        ( rty, g1 ) =
                            freshR t g
                    in
                    ( rty, { g1 | immortalLiterals = g1.immortalLiterals + 1 } )

                _ ->
                    ( Rty.RScalar, g )

        Mono.MonoUnit ->
            ( Rty.RScalar, g )

        Mono.MonoVarLocal x _ ->
            case Dict.get x env.vars of
                Nothing ->
                    -- Unbound (shouldn't happen for well-formed graphs); treat as fresh scalar.
                    ( Rty.RScalar, g )

                Just bindRty ->
                    let
                        ( useRty, pairs, g1 ) =
                            cloneRTyF bindRty g

                        g2 =
                            addFlows pairs g1

                        g3 =
                            addStorageEqs (List.drop 1 pairs) g2

                        g4 =
                            -- allRes useRty ≡ the new-resvar (second) components of
                            -- the pre-order pairs — reuse them, no extra RTy walk.
                            addOcc (List.map Tuple.second pairs) g3
                    in
                    ( useRty, g4 )

        Mono.MonoVarGlobal _ _ t ->
            -- value reference; Phase 2: sigs = Nothing ⇒ all-owned fresh.
            let
                ( rty, g1 ) =
                    freshR t g
            in
            ( rty, ownEverything rty g1 )

        Mono.MonoVarKernel _ _ _ _ t ->
            -- kernel value (not a call): boundary-poisoned closure.
            let
                ( rty, g1 ) =
                    freshR t g
            in
            ( rty, poison rty RClosureBoundary bumpClosure g1 )

        Mono.MonoList _ es t ->
            constrainContainer env path es t g

        Mono.MonoTupleCreate _ es t ->
            constrainContainer env path es t g

        Mono.MonoRecordCreate fes t ->
            constrainContainer env path (List.map Tuple.second fes) t g

        Mono.MonoRecordAccess e f t ->
            let
                ( n, g0 ) =
                    freshNode g

                ( eRty, g1 ) =
                    constrainExpr env (Seq n 0 :: path) e g0

                ( outRty, g2 ) =
                    freshR t g1

                container =
                    Maybe.withDefault -1 (Rty.topRes eRty)

                g3 =
                    addGet { container = container, out = zipTop eRty outRty, path = path } g2

                g4 =
                    addSeedsOfRTy eRty path g3
            in
            ( outRty, g4 )

        Mono.MonoRecordUpdate base fes t ->
            let
                ( n, g0 ) =
                    freshNode g

                ( baseRty, g1 ) =
                    constrainExpr env (Seq n 0 :: path) base g0

                g2 =
                    addSeedsOfRTy baseRty path g1

                ( _, g3 ) =
                    constrainFields env n path 1 fes g2

                ( resultRty, g4 ) =
                    freshR t g3

                g5 =
                    ownEverything resultRty g4

                -- copied-over heap fields: no occurrence to attach a dup to.
                copiedHeap =
                    countCopiedHeapFields baseRty (List.map Tuple.first fes)

                g6 =
                    { g5 | updateCopiedHeapFields = g5.updateCopiedHeapFields + copiedHeap }
            in
            ( resultRty, g6 )

        Mono.MonoDestruct (Mono.MonoDestructor x dpath _) body t ->
            let
                ( n, g0 ) =
                    freshNode g

                rootRes =
                    rootResFor dpath env

                g1 =
                    addSeeds rootRes (Seq n 0 :: path) g0

                ( xRty, g2 ) =
                    freshR (Mono.getMonoPathType dpath) g1

                env1 =
                    bindVar x xRty env

                g3 =
                    addScope (Maybe.withDefault -1 (Rty.topRes xRty)) (Seq n 1 :: path) g2

                ( bodyRty, g4 ) =
                    constrainExpr env1 (Seq n 1 :: path) body g3
            in
            ( bodyRty, g4 )

        Mono.MonoCase _ scrutinee decider jumps t ->
            let
                ( n, g0 ) =
                    freshNode g

                scrutRes =
                    case Dict.get scrutinee env.vars of
                        Just rty ->
                            Rty.allRes rty

                        Nothing ->
                            []

                g1 =
                    addSeeds scrutRes path g0

                arms =
                    collectInlines decider ++ List.map Tuple.second jumps

                ( resultRty, g2 ) =
                    freshR t g1
            in
            ( resultRty, unifyArms env n path arms resultRty g2 )

        Mono.MonoIf pairs elseE t ->
            let
                ( n, g0 ) =
                    freshNode g

                conds =
                    List.map Tuple.first pairs

                branches =
                    List.map Tuple.second pairs ++ [ elseE ]

                g1 =
                    constrainConds env n path conds g0

                ( resultRty, g2 ) =
                    freshR t g1
            in
            ( resultRty, unifyArms env n path branches resultRty g2 )

        Mono.MonoLet def body t ->
            case def of
                Mono.MonoDef x rhs ->
                    let
                        ( n, g0 ) =
                            freshNode g

                        ( rhsRty, g1 ) =
                            constrainExpr env (Seq n 0 :: path) rhs g0

                        env1 =
                            bindVar x rhsRty env

                        g2 =
                            addScope (Maybe.withDefault -1 (Rty.topRes rhsRty)) (Seq n 1 :: path) g1
                    in
                    constrainExpr env1 (Seq n 1 :: path) body g2

                Mono.MonoTailDef x params rhs ->
                    let
                        ( n, g0 ) =
                            freshNode g

                        ( envInner, g1 ) =
                            bindParams params env g0

                        ( _, g2 ) =
                            constrainExpr envInner (Seq n 0 :: path) rhs g1

                        ( xRty, g3 ) =
                            freshR t g2

                        env1 =
                            bindVar x xRty env
                    in
                    constrainExpr env1 (Seq n 1 :: path) body g3

        Mono.MonoCall _ f args t callInfo ->
            constrainCall env path f args t callInfo g

        Mono.MonoTailCall _ args t ->
            let
                ( n, g0 ) =
                    freshNode g

                g1 =
                    constrainTailArgs env n path (List.map Tuple.second args) g0

                ( rty, g2 ) =
                    freshR t g1
            in
            ( rty, g2 )

        Mono.MonoClosure info body t ->
            let
                ( n, g0 ) =
                    freshNode g

                -- captured heap resources are boundary-poisoned (§8.4).
                g1 =
                    List.foldl
                        (\( _, capE, _ ) acc ->
                            let
                                ( capRty, acc1 ) =
                                    constrainExpr env (Seq n 0 :: path) capE acc

                                acc2 =
                                    poison capRty RCapture bumpCaptures acc1
                            in
                            acc2
                        )
                        g0
                        info.captures

                ( envInner, g2 ) =
                    bindParams info.params env g1

                ( _, g3 ) =
                    constrainExpr envInner (Seq n 1 :: path) body g2

                ( rty, g4 ) =
                    freshR t g3
            in
            ( rty, ownEverything rty g4 )

        Mono.MonoAccessorValue _ _ t ->
            let
                ( rty, g1 ) =
                    freshR t g
            in
            ( rty, poison rty RClosureBoundary bumpClosure g1 )



-- CALL DISPATCH (§8.3; Phase 2 coarse — every branch lands all-owned)


constrainCall : Env -> Path -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> Gen -> ( RTy, Gen )
constrainCall env path f args t callInfo g =
    let
        ( n, g0 ) =
            freshNode g

        ( argRtys, g1 ) =
            constrainArgs env n path 0 args g0

        ( resultRty, g2 ) =
            freshR t g1

        gNV =
            countNonVarOperands args argRtys g2

        -- A poisoned (unknown-callee) call result is conservatively owned; a
        -- routed/sig'd call gets its result ownership from the callee sig.
        poisoned gg =
            ownEverything resultRty gg
    in
    case f of
        Mono.MonoVarGlobal _ specId _ ->
            if isDirectSaturated callInfo then
                -- §8.3 direct call: consult the callee signature.
                case env.sigs specId of
                    Just sig ->
                        ( resultRty, applyDirectSig sig path argRtys resultRty gNV )

                    Nothing ->
                        ( resultRty, poisoned (ownArgs argRtys { gNV | sigMissReads = gNV.sigMissReads + 1 }) )

            else
                -- under/over-application (PAP): boundary-poisoned.
                ( resultRty, poisoned (poisonArgs argRtys RClosureBoundary bumpClosure gNV) )

        Mono.MonoVarKernel _ _ home name _ ->
            case KernelSigs.lookup ( home, name ) of
                Just ksig ->
                    ( resultRty
                    , applyKernelSig ksig path argRtys resultRty { gNV | kernelSigHits = gNV.kernelSigHits + 1 }
                    )

                Nothing ->
                    let
                        g4 =
                            poisonArgs argRtys RKernel bumpKernel gNV

                        g5 =
                            if List.any isHeapRty argRtys then
                                { g4
                                    | kernelDefaultedHeapCalls = g4.kernelDefaultedHeapCalls + 1
                                    , kernelDefaultedNames =
                                        Dict.update ( home, name )
                                            (\m -> Just (1 + Maybe.withDefault 0 m))
                                            g4.kernelDefaultedNames
                                }

                            else
                                g4
                    in
                    ( resultRty, poisoned g5 )

        _ ->
            -- closure / generic / PAP / non-var callee. B3.5: if LSS knows a
            -- singleton lambda set, route through the member's real signature;
            -- else boundary-poison (Phase-2 behavior).
            let
                ( _, gf ) =
                    constrainExpr env (Seq n 0 :: path) f gNV
            in
            case env.lssFacts of
                Just facts ->
                    case LssFacts.query facts (Mono.typeOf f) of
                        LssFacts.Routed sig ->
                            ( resultRty, applyDirectSig sig path argRtys resultRty { gf | closureRouted = gf.closureRouted + 1 } )

                        LssFacts.Poison _ ->
                            ( resultRty, poisoned (poisonArgs argRtys RClosureBoundary bumpClosure gf) )

                Nothing ->
                    ( resultRty, poisoned (poisonArgs argRtys RClosureBoundary bumpClosure gf) )


isDirectSaturated : Mono.CallInfo -> Bool
isDirectSaturated ci =
    ci.isSingleStageSaturated && isDirectKind ci.callKind


isDirectKind : Mono.CallKind -> Bool
isDirectKind k =
    case k of
        Mono.CallDirectFlat ->
            True

        Mono.CallDirectKnownSegmentation ->
            True

        _ ->
            False


{-| Apply a callee `BorrowSig`: per param ResPos, Owned forces the arg resource
owned / Borrowed seeds only liveness; the result's modes are applied to the
call result; and `resultLts` couples each result resource to its source args
(paper §5.1 — so a returned arg's ownership tracks how the caller uses the
result).
-}
applyDirectSig : BorrowSig -> Path -> List RTy -> RTy -> Gen -> Gen
applyDirectSig sig path argRtys resultRty g =
    applyParamList path argRtys sig.params g
        |> applyResultModes resultRty sig.result
        |> applyResultLts sig.resultLts argRtys resultRty


applyResultModes : RTy -> Sig.SigTy -> Gen -> Gen
applyResultModes resultRty sigTy g =
    -- item 12: index `sigTy.modes` positionally instead of allocating
    -- `Array.toList modes` + a `map2` pair list. The `idx >= modesLen` stop
    -- reproduces `List.map2`'s truncation to the shorter of the two.
    let
        modesLen =
            Array.length sigTy.modes

        go idx rs acc =
            case rs of
                [] ->
                    acc

                r :: rest ->
                    if idx >= modesLen then
                        acc

                    else
                        case Array.get idx sigTy.modes of
                            Just Owned ->
                                go (idx + 1) rest (addForced r RConstruct acc)

                            _ ->
                                go (idx + 1) rest acc
    in
    go 0 (Rty.allRes resultRty) g


applyResultLts : List ( Int, Set Int ) -> List RTy -> RTy -> Gen -> Gen
applyResultLts resultLts argRtys resultRty g =
    let
        resultRes =
            Rty.allRes resultRty
    in
    List.foldl
        (\( pos, s ) acc ->
            case nthOf pos resultRes of
                Just rres ->
                    Set.foldl
                        (\i acc2 ->
                            case nthTop i argRtys of
                                Just argTop ->
                                    addFlows [ ( argTop, rres ) ] acc2

                                Nothing ->
                                    acc2
                        )
                        acc
                        s

                Nothing ->
                    acc
        )
        g
        resultLts


nthOf : Int -> List a -> Maybe a
nthOf k list =
    List.head (List.drop k list)


applyParamList : Path -> List RTy -> List Sig.SigTy -> Gen -> Gen
applyParamList path argRtys sigTys g =
    case ( argRtys, sigTys ) of
        ( argRty :: restA, sigTy :: restS ) ->
            applyParamList path restA restS (applyParamModes argRty sigTy path g)

        ( argRty :: restA, [] ) ->
            -- extra arg beyond the sig (arity mismatch): default owned.
            applyParamList path restA [] (ownEverything argRty g)

        ( [], _ ) ->
            g


applyParamModes : RTy -> Sig.SigTy -> Path -> Gen -> Gen
applyParamModes argRty sigTy path g =
    -- item 12: one indexed pass over allRes reading `sigTy.modes` via `Array.get`
    -- — computes both the fold (`g1`) and `anyOwned` (for `forcedHeapOwned`) in a
    -- single traversal, no `Array.toList` + `map2` pair list. The `idx >= modesLen`
    -- stop reproduces `List.map2`'s truncation to the shorter list.
    let
        modesLen =
            Array.length sigTy.modes

        go idx rs acc anyOwned =
            case rs of
                [] ->
                    ( acc, anyOwned )

                r :: rest ->
                    if idx >= modesLen then
                        ( acc, anyOwned )

                    else
                        case Array.get idx sigTy.modes of
                            Just Owned ->
                                go (idx + 1) rest (addForced r RConstruct acc) True

                            _ ->
                                go (idx + 1) rest (addSeeds [ r ] path acc) anyOwned

        ( g1, forcedOwned ) =
            go 0 (Rty.allRes argRty) g False
    in
    if isHeapRty argRty && forcedOwned then
        { g1 | poisoningCallSites = g1.poisoningCallSites + 1 }

    else
        g1


applyKernelSig : KernelSigs.KernelSig -> Path -> List RTy -> RTy -> Gen -> Gen
applyKernelSig ksig path argRtys resultRty g =
    let
        -- kernels produce owned results (fresh value or aliased element).
        g1 =
            ownEverything resultRty (applyKernelParams path argRtys ksig.params g)
    in
    case ksig.resultAliases of
        Just k ->
            case ( nthTop k argRtys, Rty.topRes resultRty ) of
                ( Just src, Just dst ) ->
                    addGet { container = src, out = [ ( src, dst ) ], path = path } g1

                _ ->
                    g1

        Nothing ->
            g1


applyKernelParams : Path -> List RTy -> List KernelSigs.ParamMode -> Gen -> Gen
applyKernelParams path argRtys pmodes g =
    case ( argRtys, pmodes ) of
        ( argRty :: restA, pm :: restP ) ->
            let
                g1 =
                    case pm of
                        KernelSigs.PBorrowed ->
                            addSeedsOfRTy argRty path g

                        KernelSigs.POwned ->
                            ownEverything argRty g
            in
            applyKernelParams path restA restP g1

        ( argRty :: restA, [] ) ->
            -- missing tail: default POwned (defensive).
            applyKernelParams path restA [] (ownEverything argRty g)

        ( [], _ ) ->
            g


nthTop : Int -> List RTy -> Maybe ResVar
nthTop k rtys =
    case List.head (List.drop k rtys) of
        Just rty ->
            Rty.topRes rty

        Nothing ->
            Nothing



-- WALKER HELPERS


constrainArgs : Env -> Int -> Path -> Int -> List Mono.MonoExpr -> Gen -> ( List RTy, Gen )
constrainArgs env n path i args g =
    case args of
        [] ->
            ( [], g )

        a :: rest ->
            let
                ( aRty, g1 ) =
                    constrainExpr env (Seq n i :: path) a g

                ( rtys, g2 ) =
                    constrainArgs env n path (i + 1) rest g1
            in
            ( aRty :: rtys, g2 )


constrainConds : Env -> Int -> Path -> List Mono.MonoExpr -> Gen -> Gen
constrainConds env n path conds g =
    List.foldl (\c acc -> Tuple.second (constrainExpr env (Seq n 0 :: path) c acc)) g conds


constrainTailArgs : Env -> Int -> Path -> List Mono.MonoExpr -> Gen -> Gen
constrainTailArgs env n path args g =
    -- Each arg seeds ESCAPE (a path ordered after the whole body — RTailArg)
    -- so reification never drops after the tail call (BORROW_005).
    Tuple.second
        (List.foldl
            (\a ( i, acc ) ->
                let
                    ( aRty, acc1 ) =
                        constrainExpr env (Seq n i :: path) a acc

                    rs =
                        Rty.allRes aRty

                    acc2 =
                        addSeeds rs [] acc1
                in
                ( i + 1, { acc2 | tailArgRes = rs ++ acc2.tailArgRes } )
            )
            ( 0, g )
            args
        )


constrainFields : Env -> Int -> Path -> Int -> List ( Name, Mono.MonoExpr ) -> Gen -> ( List RTy, Gen )
constrainFields env n path i fes g =
    case fes of
        [] ->
            ( [], g )

        ( _, e ) :: rest ->
            let
                ( rty, g1 ) =
                    constrainExpr env (Seq n i :: path) e g

                ( rtys, g2 ) =
                    constrainFields env n path (i + 1) rest g1
            in
            ( rty :: rtys, g2 )


constrainContainer : Env -> Path -> List Mono.MonoExpr -> Mono.MonoType -> Gen -> ( RTy, Gen )
constrainContainer env path es t g =
    let
        ( n, g0 ) =
            freshNode g

        ( elemRtys, g1 ) =
            constrainArgs env n path 0 es g0

        ( resultRty, g2 ) =
            freshR t g1

        -- container top forced owned (RConstruct); each element storageEq with a
        -- container slot resource (heap-store position).
        g3 =
            case Rty.topRes resultRty of
                Just top ->
                    addForced top RConstruct g2

                Nothing ->
                    g2

        g4 =
            List.foldl
                (\elemRty acc ->
                    case Rty.topRes elemRty of
                        Just er ->
                            case Rty.topRes resultRty of
                                Just cr ->
                                    addStorageEqs [ ( er, cr ) ] acc

                                Nothing ->
                                    acc

                        Nothing ->
                            acc
                )
                g3
                elemRtys
    in
    ( resultRty, g4 )


unifyArms : Env -> Int -> Path -> List Mono.MonoExpr -> RTy -> Gen -> Gen
unifyArms env n path arms resultRty g =
    Tuple.second
        (List.foldl
            (\arm ( i, acc ) ->
                let
                    ( armRty, acc1 ) =
                        constrainExpr env (Arm n i :: path) arm acc

                    pairs =
                        Rty.zipRTy armRty resultRty

                    acc2 =
                        addFlowsBidir pairs acc1
                in
                ( i + 1, acc2 )
            )
            ( 0, g )
            arms
        )


{-| Clone an RTy's shape with fresh ResVars (a use instance of a binding).
-}
cloneRTy : RTy -> Gen -> ( RTy, Gen )
cloneRTy rty g =
    case rty of
        Rty.RScalar ->
            ( Rty.RScalar, g )

        Rty.RString _ ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.RString r, { g1 | stringRes = r :: g1.stringRes } )

        Rty.ROpaque _ ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.ROpaque r, g1 )

        Rty.RClosure _ ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.RClosure r, g1 )

        Rty.RList _ elem ->
            let
                ( r, g1 ) =
                    fresh g

                ( elem2, g2 ) =
                    cloneRTy elem g1
            in
            ( Rty.RList r elem2, g2 )

        Rty.RTuple _ elems ->
            let
                ( r, g1 ) =
                    fresh g

                ( elems2, g2 ) =
                    cloneList elems g1
            in
            ( Rty.RTuple r elems2, g2 )

        Rty.RRecord _ fields ->
            let
                ( r, g1 ) =
                    fresh g

                ( fields2, g2 ) =
                    cloneFields fields g1
            in
            ( Rty.RRecord r fields2, g2 )

        Rty.RCustom _ args ->
            let
                ( r, g1 ) =
                    fresh g

                ( args2, g2 ) =
                    cloneList args g1
            in
            ( Rty.RCustom r args2, g2 )


{-| item 11: like `cloneRTy` but also returns the pre-order `(oldRes, newRes)`
pairs — i.e. `zipRTy bindRty useRty` — computed during the single clone walk, so
the `MonoVarLocal` hot path drops the separate `zipRTy` and `allRes` traversals
(and the `++`/`concatMap` intermediates those build). Pairs are root-first
pre-order, matching `zipRTy`, so `List.drop 1 pairs` still drops the root pair.
-}
cloneRTyF : RTy -> Gen -> ( RTy, List ( ResVar, ResVar ), Gen )
cloneRTyF rty g =
    case rty of
        Rty.RScalar ->
            ( Rty.RScalar, [], g )

        Rty.RString old ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.RString r, [ ( old, r ) ], { g1 | stringRes = r :: g1.stringRes } )

        Rty.ROpaque old ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.ROpaque r, [ ( old, r ) ], g1 )

        Rty.RClosure old ->
            let
                ( r, g1 ) =
                    fresh g
            in
            ( Rty.RClosure r, [ ( old, r ) ], g1 )

        Rty.RList old elem ->
            let
                ( r, g1 ) =
                    fresh g

                ( elem2, elemPairs, g2 ) =
                    cloneRTyF elem g1
            in
            ( Rty.RList r elem2, ( old, r ) :: elemPairs, g2 )

        Rty.RTuple old elems ->
            let
                ( r, g1 ) =
                    fresh g

                ( elems2, elemPairs, g2 ) =
                    cloneListF elems g1
            in
            ( Rty.RTuple r elems2, ( old, r ) :: elemPairs, g2 )

        Rty.RRecord old fields ->
            let
                ( r, g1 ) =
                    fresh g

                ( fields2, fieldPairs, g2 ) =
                    cloneFieldsF fields g1
            in
            ( Rty.RRecord r fields2, ( old, r ) :: fieldPairs, g2 )

        Rty.RCustom old args ->
            let
                ( r, g1 ) =
                    fresh g

                ( args2, argPairs, g2 ) =
                    cloneListF args g1
            in
            ( Rty.RCustom r args2, ( old, r ) :: argPairs, g2 )


cloneListF : List RTy -> Gen -> ( List RTy, List ( ResVar, ResVar ), Gen )
cloneListF rtys g =
    case rtys of
        [] ->
            ( [], [], g )

        x :: rest ->
            let
                ( x2, xp, g1 ) =
                    cloneRTyF x g

                ( rest2, rp, g2 ) =
                    cloneListF rest g1
            in
            ( x2 :: rest2, xp ++ rp, g2 )


cloneFieldsF : List ( Name, RTy ) -> Gen -> ( List ( Name, RTy ), List ( ResVar, ResVar ), Gen )
cloneFieldsF fields g =
    case fields of
        [] ->
            ( [], [], g )

        ( name, x ) :: rest ->
            let
                ( x2, xp, g1 ) =
                    cloneRTyF x g

                ( rest2, rp, g2 ) =
                    cloneFieldsF rest g1
            in
            ( ( name, x2 ) :: rest2, xp ++ rp, g2 )


cloneList : List RTy -> Gen -> ( List RTy, Gen )
cloneList rtys g =
    case rtys of
        [] ->
            ( [], g )

        x :: rest ->
            let
                ( x2, g1 ) =
                    cloneRTy x g

                ( rest2, g2 ) =
                    cloneList rest g1
            in
            ( x2 :: rest2, g2 )


cloneFields : List ( Name, RTy ) -> Gen -> ( List ( Name, RTy ), Gen )
cloneFields fields g =
    case fields of
        [] ->
            ( [], g )

        ( name, x ) :: rest ->
            let
                ( x2, g1 ) =
                    cloneRTy x g

                ( rest2, g2 ) =
                    cloneFields rest g1
            in
            ( ( name, x2 ) :: rest2, g2 )


zipTop : RTy -> RTy -> List ( ResVar, ResVar )
zipTop container out =
    case ( Rty.topRes container, Rty.topRes out ) of
        ( Just c, Just o ) ->
            [ ( c, o ) ]

        _ ->
            []


rootResFor : Mono.MonoPath -> Env -> List ResVar
rootResFor dpath env =
    case rootName dpath of
        Just name ->
            case Dict.get name env.vars of
                Just rty ->
                    Rty.allRes rty

                Nothing ->
                    []

        Nothing ->
            []


rootName : Mono.MonoPath -> Maybe Name
rootName dpath =
    case dpath of
        Mono.MonoRoot name _ ->
            Just name

        Mono.MonoIndex _ _ _ sub ->
            rootName sub

        Mono.MonoField _ _ sub ->
            rootName sub

        Mono.MonoUnbox _ sub ->
            rootName sub


collectInlines : Mono.Decider Mono.MonoChoice -> List Mono.MonoExpr
collectInlines decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ s f ->
            collectInlines s ++ collectInlines f

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectInlines d) edges ++ collectInlines fallback


countCopiedHeapFields : RTy -> List Name -> Int
countCopiedHeapFields baseRty mentioned =
    case baseRty of
        Rty.RRecord _ fields ->
            List.length
                (List.filter
                    (\( name, fieldRty ) ->
                        not (List.member name mentioned) && isHeapRty fieldRty
                    )
                    fields
                )

        _ ->
            0


countNonVarOperands : List Mono.MonoExpr -> List RTy -> Gen -> Gen
countNonVarOperands args argRtys g =
    List.foldl
        (\( argE, argRty ) acc ->
            if isHeapRty argRty && not (isVar argE) then
                if isOwnedProducer argE then
                    { acc | nonVarOwnedFresh = acc.nonVarOwnedFresh + 1 }

                else
                    { acc | nonVarBorrowedProducer = acc.nonVarBorrowedProducer + 1 }

            else
                acc
        )
        g
        (List.map2 Tuple.pair args argRtys)


isVar : Mono.MonoExpr -> Bool
isVar e =
    case e of
        Mono.MonoVarLocal _ _ ->
            True

        Mono.MonoVarGlobal _ _ _ ->
            True

        _ ->
            False


isOwnedProducer : Mono.MonoExpr -> Bool
isOwnedProducer e =
    case e of
        Mono.MonoList _ _ _ ->
            True

        Mono.MonoTupleCreate _ _ _ ->
            True

        Mono.MonoRecordCreate _ _ ->
            True

        Mono.MonoRecordUpdate _ _ _ ->
            True

        Mono.MonoCall _ _ _ _ _ ->
            True

        Mono.MonoLiteral _ _ ->
            True

        _ ->
            False


isHeapRty : RTy -> Bool
isHeapRty rty =
    case rty of
        Rty.RScalar ->
            False

        _ ->
            True



-- OWN / POISON HELPERS


ownEverything : RTy -> Gen -> Gen
ownEverything =
    forceAllOf RConstruct


{-| item 19 (extension): force every resvar in an RTy to Owned with `reason`, by
walking the RTy directly instead of `addForcedAll (Rty.allRes rty)` which
materialises an `allRes` list (concatMap). Used on the ~8 `ownEverything` sites
plus `ownArgs`/`poison`. `forcedOwned` is order-independent.
-}
forceAllOf : Reason -> RTy -> Gen -> Gen
forceAllOf reason rty g =
    case rty of
        Rty.RScalar ->
            g

        Rty.RString r ->
            addForced r reason g

        Rty.ROpaque r ->
            addForced r reason g

        Rty.RClosure r ->
            addForced r reason g

        Rty.RList r elem ->
            forceAllOf reason elem (addForced r reason g)

        Rty.RTuple r elems ->
            List.foldl (forceAllOf reason) (addForced r reason g) elems

        Rty.RRecord r fields ->
            List.foldl (\( _, t ) acc -> forceAllOf reason t acc) (addForced r reason g) fields

        Rty.RCustom r args ->
            List.foldl (forceAllOf reason) (addForced r reason g) args


ownArgs : List RTy -> Gen -> Gen
ownArgs rtys g =
    List.foldl ownEverything g rtys


poison : RTy -> Reason -> (Gen -> Gen) -> Gen -> Gen
poison rty reason bump g =
    if isHeapRty rty then
        bump (forceAllOf reason rty g)

    else
        g


poisonArgs : List RTy -> Reason -> (Gen -> Gen) -> Gen -> Gen
poisonArgs rtys reason bump g =
    List.foldl (\rty acc -> poison rty reason bump acc) g rtys


bumpClosure : Gen -> Gen
bumpClosure g =
    { g | poisonedByClosure = g.poisonedByClosure + 1 }


bumpKernel : Gen -> Gen
bumpKernel g =
    { g | poisonedByKernel = g.poisonedByKernel + 1 }


bumpCaptures : Gen -> Gen
bumpCaptures g =
    { g | capturesForcedOwned = g.capturesForcedOwned + 1 }
