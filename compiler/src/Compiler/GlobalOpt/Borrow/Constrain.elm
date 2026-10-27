module Compiler.GlobalOpt.Borrow.Constrain exposing
    ( Env, emptyEnv
    , constrainDef, constrainClosureForSig, DefAnalysis, Constraints, Gen, emptyGen
    , Get, Occ, Reason
    )

{-| Borrow inference decides, for each heap value a function handles, whether
the function must own it or may borrow it. This module turns the body of one
definition into the constraints that decision is solved from;
`Compiler.GlobalOpt.Borrow.Solve` solves them.

**Resources.** The walk gives every value it meets a resource skeleton, as
`Compiler.GlobalOpt.Borrow.Rty` describes: one fresh resource for each heap
position of the value's type. Resources are numbered from the counter in `Gen`,
so after a walk `next` is the number of resources the definition used. A use of
a local variable gets its own copy of the binding's skeleton, so the binding and
each use can be given different access modes.

**Constraints.** The walk records how resources relate:

  - a _flow_ pairs a resource with the resource of a value that takes it over:
    a binding with a use of it, or a `case` or `if` arm with the result, in
    both directions, or an argument with a call result that its callee's
    signature says may alias it;
  - a _storage equality_ says two resources share storage, such as an element
    of a list, tuple or record literal and the literal itself;
  - a _get_ is a read out of a container;
  - a _seed_ says a resource is live at least until a point, and a _scope_ is
    the point a binding stays in scope until;
  - a resource is _forced owned_, with a `Reason`, where ownership is required
    whatever the uses are.

**Points.** A point in the body is a `Compiler.GlobalOpt.Borrow.Lifetime`
`Path`. Each expression that sequences or chooses between subexpressions takes a
fresh node id `n` from `Gen`, and a child's path is `Seq n i` or `Arm n i`
consed onto the expression's own path. The head of a path built here is
therefore its innermost step, not the step leaving the root. The empty path is
the end of the whole body.

**Calls.** At a call the walk uses what is known about the callee. A saturated
direct call to a global applies the callee's `BorrowSig` from `Env.sigs`. A
kernel call applies the kernel's entry in `KernelSigs`. Any other callee is
looked up with `LssFacts.query` when `Env.lssFacts` is present, and a `Routed`
answer is applied like a direct signature. Where none of these gives a
signature, and for every call to a global that is not a saturated direct call,
the arguments are _poisoned_: each of their resources is forced owned and
marked as escaping, because the callee may keep them. A call's result takes its
modes from an applied `BorrowSig`; in every other case, including a kernel call
with a `KernelSigs` entry, the result is owned.

**Census data.** `Gen` also carries data that `Solve` never reads, for a driver
to read off the final `Gen`: counts of each kind of poisoning and of signature
hits and misses, and inputs to an escape analysis. Those inputs are escape
seeds (resources that escape, for example because they are consumed by a
callee, captured, or held by a global value), escape edges (alias links used
by that analysis alone), the resources of tail-call arguments, the head
resources of strings, and _fresh sites_ (allocation sites in the definition,
each with a class name and a weight).


# Environment

@docs Env, emptyEnv


# Generation

@docs constrainDef, constrainClosureForSig, DefAnalysis, Constraints, Gen, emptyGen


# Constraint records

@docs Get, Occ, Reason

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.Borrow.Lifetime exposing (Path, Step(..))
import Compiler.GlobalOpt.Borrow.LssFacts as LssFacts
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..))
import Compiler.GlobalOpt.Borrow.Rty as Rty exposing (RTy, ResVar)
import Compiler.GlobalOpt.Borrow.Sig as Sig exposing (BorrowSig)
import Dict exposing (Dict)
import Set exposing (Set)



-- CONSTRAINTS


{-| The constraints generated for one definition.

`Solve` reads every field except `occs` and `escEdges`. `scopes` is keyed by a
binding's head resource; a binding whose value has no head resource is entered
under -1. `paramSeeds` tags every resource of a parameter with the parameter's
index, counting the parameters of the definition and also those of every
closure and local tail-recursive function inside it from 0.

-}
type alias Constraints =
    { flows : List ( ResVar, ResVar )
    , gets : List Get
    , storageEq : List ( ResVar, ResVar )
    , scopes : Dict ResVar Path
    , seeds : List ( ResVar, Path )
    , forcedOwned : List ( ResVar, Reason )
    , occs : List Occ
    , paramSeeds : List ( ResVar, Int )
    , escEdges : List ( ResVar, ResVar ) -- record-update stores and destructure reads, for escape analysis only
    }


{-| A read out of a container: the container's head resource, the pairs of a
resource on the container side and the resource of the value read out, and the
point of the read.

A get built here has at most one pair, the container's head and the head of
the value read out; it has none when the value read out has no head resource.
`container` is -1 when the container expression has no head resource.

-}
type alias Get =
    { container : ResVar, out : List ( ResVar, ResVar ), path : Path }


{-| One use of a local variable: the fresh resources of the value at that use,
head first.
-}
type alias Occ =
    { res : List ResVar }


{-| Why a resource is forced owned.

`RConstruct` covers ownership the walk imposes itself: the head of a list,
tuple or record literal, a record update or closure value, a referenced global
value, a call result that is owned by default or by its signature, an argument
at an `Owned` position of a signature or a `POwned` kernel parameter, an
argument beyond the parameters a signature or kernel signature lists, and an
argument of a saturated direct call whose callee has no signature.

`RKernel` marks an argument of a kernel call that has no `KernelSigs` entry.

`RClosureBoundary` marks an argument of a call to a global that is not a
saturated direct call, an argument of any other non-kernel call that is not
routed to a signature, and a kernel or accessor function used as a value.

`RErased` marks the resource of an erased value, whose contents the analysis
cannot see. Every such resource in a skeleton built from a type is forced
owned.

`RCapture` marks a value captured by a closure.

-}
type Reason
    = RConstruct
    | RKernel
    | RClosureBoundary
    | RErased
    | RCapture


{-| A set of constraints with nothing in it.
-}
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
    , escEdges = []
    }



-- GEN


{-| The state of constraint generation for one definition: the next fresh
resource, the constraints so far, the next node id for path steps, and census
counters and lists. `immortalLiterals` counts string literals,
`updateCopiedHeapFields` the heap fields a record update copies from its base
without naming them, and `nonVarOwnedFresh` and `nonVarBorrowedProducer` the
heap call arguments that are not variables, as `countNonVarOperands` splits
them.
-}
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
    , stringRes : List ResVar -- string head resources
    , sigMissReads : Int -- saturated direct calls whose callee has no signature
    , kernelSigHits : Int -- kernel calls with a KernelSigs entry
    , kernelDefaultedHeapCalls : Int -- kernel calls with no entry and at least one heap argument
    , kernelDefaultedNames : Dict ( Name, Name ) Int -- those calls, counted per (home, name)
    , poisoningCallSites : Int -- heap arguments with an Owned position in an applied BorrowSig
    , tailArgRes : List ResVar -- resources of tail-call arguments
    , closureRouted : Int -- calls routed to a signature by the LSS facts
    , escSeeds : List ResVar
    , freshSites : List ( ResVar, String, Int ) -- (head resource, class, weight) per allocation site
    }


{-| Generation state with no resources, no constraints and every counter at zero.
-}
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
    , escSeeds = []
    , freshSites = []
    }


{-| Returns a fresh resource.
-}
fresh : Gen -> ( ResVar, Gen )
fresh g =
    ( g.next, { g | next = g.next + 1 } )


{-| Builds a fresh resource skeleton for a type.

Every string head in it is recorded in `stringRes`, and every erased resource in
it is forced owned with `RErased` and counted in `poisonedByErased`.

-}
freshR : Mono.MonoType -> Gen -> ( RTy, Gen )
freshR t g =
    let
        ( rty, n ) =
            Rty.freshRTy t g.next
    in
    ( rty, harvestFresh rty { g | next = n } )


{-| Records the string heads of a freshly built skeleton in `stringRes`, and
forces each of its erased resources owned with `RErased`, counting each in
`poisonedByErased`.
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


{-| Returns a fresh node id for path steps.
-}
freshNode : Gen -> ( Int, Gen )
freshNode g =
    ( g.nodeCounter, { g | nodeCounter = g.nodeCounter + 1 } )



-- CONSTRAINT EMITTERS


{-| Applies an update to the constraints held in the state.
-}
emit : (Constraints -> Constraints) -> Gen -> Gen
emit f g =
    { g | cs = f g.cs }


{-| Adds flows, each from the first resource of a pair to the second.
-}
addFlows : List ( ResVar, ResVar ) -> Gen -> Gen
addFlows ps =
    emit (\c -> { c | flows = ps ++ c.flows })


{-| Adds a flow in each direction for every pair.
-}
addFlowsBidir : List ( ResVar, ResVar ) -> Gen -> Gen
addFlowsBidir ps =
    emit (\c -> { c | flows = List.foldl (\( a, b ) acc -> ( a, b ) :: ( b, a ) :: acc) c.flows ps })


{-| Adds storage equalities.
-}
addStorageEqs : List ( ResVar, ResVar ) -> Gen -> Gen
addStorageEqs ps =
    emit (\c -> { c | storageEq = ps ++ c.storageEq })


{-| Seeds every resource in the list as live until `path`.
-}
addSeeds : List ResVar -> Path -> Gen -> Gen
addSeeds rs path =
    emit (\c -> { c | seeds = List.map (\r -> ( r, path )) rs ++ c.seeds })


{-| Conses every resource of a skeleton, paired with `tag`, onto `acc`.
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


{-| Seeds every resource of a skeleton as live until `path`.
-}
addSeedsOfRTy : RTy -> Path -> Gen -> Gen
addSeedsOfRTy rty path =
    emit (\c -> { c | seeds = resPairsInto path rty c.seeds })


{-| Records that the binding with head resource `r` is in scope until `path`,
replacing any earlier scope for `r`.
-}
addScope : ResVar -> Path -> Gen -> Gen
addScope r path =
    emit (\c -> { c | scopes = Dict.insert r path c.scopes })


{-| Forces a resource owned, for the given reason.
-}
addForced : ResVar -> Reason -> Gen -> Gen
addForced r reason =
    emit (\c -> { c | forcedOwned = ( r, reason ) :: c.forcedOwned })


{-| Adds a container read.
-}
addGet : Get -> Gen -> Gen
addGet get =
    emit (\c -> { c | gets = get :: c.gets })


{-| Records one use of a local variable with the given resources.
-}
addOcc : List ResVar -> Gen -> Gen
addOcc res g =
    emit
        (\c ->
            { c | occs = { res = res } :: c.occs }
        )
        g


{-| Adds escape edges.
-}
addEscEdges : List ( ResVar, ResVar ) -> Gen -> Gen
addEscEdges ps =
    emit (\c -> { c | escEdges = ps ++ c.escEdges })


{-| Conses every resource of a skeleton onto `acc`.
-}
resInto : RTy -> List ResVar -> List ResVar
resInto rty acc =
    case rty of
        Rty.RScalar ->
            acc

        Rty.RString r ->
            r :: acc

        Rty.ROpaque r ->
            r :: acc

        Rty.RClosure r ->
            r :: acc

        Rty.RList r elem ->
            resInto elem (r :: acc)

        Rty.RTuple r elems ->
            List.foldl resInto (r :: acc) elems

        Rty.RRecord r fields ->
            List.foldl (\( _, t ) a -> resInto t a) (r :: acc) fields

        Rty.RCustom r args ->
            List.foldl resInto (r :: acc) args


{-| Marks every resource of a skeleton as an escape seed.
-}
escSeedAll : RTy -> Gen -> Gen
escSeedAll rty g =
    { g | escSeeds = resInto rty g.escSeeds }


{-| Records an allocation site whose value has the skeleton `rty`, with class
`prefix` followed by the skeleton's shape class, and weight `w`.

Nothing is recorded for a skeleton with no head resource or a weight of zero or
less, such as an empty list literal.

-}
addFreshSite : String -> Int -> RTy -> Gen -> Gen
addFreshSite prefix w rty g =
    case Rty.topRes rty of
        Just top ->
            if w <= 0 then
                g

            else
                { g | freshSites = ( top, prefix ++ shapeClass rty, w ) :: g.freshSites }

        Nothing ->
            g


{-| Returns a short name for the outermost shape of a skeleton, with a tuple's
arity appended.
-}
shapeClass : RTy -> String
shapeClass rty =
    case rty of
        Rty.RScalar ->
            "scalar"

        Rty.RString _ ->
            "str"

        Rty.ROpaque _ ->
            "opq"

        Rty.RClosure _ ->
            "clo"

        Rty.RList _ _ ->
            "cons"

        Rty.RTuple _ elems ->
            "tup" ++ String.fromInt (List.length elems)

        Rty.RRecord _ _ ->
            "rec"

        Rty.RCustom _ _ ->
            "custom"



-- ENV


{-| The environment of the walk: the skeleton of each variable in scope, the
borrow signature of each specialization, and the LSS facts used to route closure
calls.

`sigs` gives `Nothing` for a specialization with no known signature, and a
saturated call to it is then poisoned. With `lssFacts` at `Nothing`, every call
to a callee that is not a global or a kernel is poisoned.

-}
type alias Env =
    { vars : Dict Name RTy
    , sigs :
        Mono.SpecId
        -> Maybe BorrowSig
    , lssFacts : Maybe LssFacts.Facts
    }


{-| An environment with no variables, no known signatures and no LSS facts.
-}
emptyEnv : Env
emptyEnv =
    { vars = Dict.empty, sigs = \_ -> Nothing, lssFacts = Nothing }


{-| Binds a variable to its skeleton.
-}
bindVar : Name -> RTy -> Env -> Env
bindVar name rty env =
    { env | vars = Dict.insert name rty env.vars }



-- NODE ENTRY


{-| What the walk of one definition produced: the types and skeletons of its
parameters and result, and the final generation state.

For a node that is neither a tail-recursive function nor a define, both
parameter lists are empty and `resultRty` is `RScalar`, whatever the node's
type.

-}
type alias DefAnalysis =
    { paramTys : List Mono.MonoType
    , paramRtys : List RTy
    , resultTy : Mono.MonoType
    , resultRty : RTy
    , gen : Gen
    }


{-| Generates the constraints of one definition, starting from the given state.

A tail-recursive function, and a define whose body is a closure, are analysed
as functions: their parameters are bound to fresh skeletons with parameter
seeds, and the body is walked. Only the parameters and body of such a closure
are walked, not its captures. Any other define is walked as a value with no
parameters. Other nodes, such as constructors, externs and ports, are not
walked, and the state is returned unchanged.

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
            { paramTys = [], paramRtys = [], resultTy = Mono.nodeType node, resultRty = Rty.RScalar, gen = g }


{-| Generates the constraints of a closure's parameters and body as if the
closure were a definition, so that a signature can be read back for it. Its
captures are not walked.
-}
constrainClosureForSig : Env -> Mono.ClosureInfo -> Mono.MonoExpr -> Gen -> DefAnalysis
constrainClosureForSig env info body g =
    analyzeFn env info.params body g


{-| Generates the constraints of a function with the given parameters and body.

The result is not forced owned: it is owned where it is built fresh, and a
result that flows from a parameter is coupled to that parameter through the
parameter seeds.

-}
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
    , gen = g2
    }


{-| Binds each parameter to a fresh skeleton, tags every resource of the
parameter at index `i` with `i` in `paramSeeds`, and returns the skeletons in
parameter order.
-}
bindParamsRtys : List ( Name, Mono.MonoType ) -> Env -> Gen -> ( Env, List RTy, Gen )
bindParamsRtys params env g =
    let
        ( env1, revRtys, ( g1, _ ) ) =
            List.foldl
                (\( name, t ) ( accEnv, accRtys, ( accG, i ) ) ->
                    let
                        ( rty, accG1 ) =
                            freshR t accG

                        accG2 =
                            emit (\c -> { c | paramSeeds = resPairsInto i rty c.paramSeeds }) accG1
                    in
                    ( bindVar name rty accEnv, rty :: accRtys, ( accG2, i + 1 ) )
                )
                ( env, [], ( g, 0 ) )
                params
    in
    ( env1, List.reverse revRtys, g1 )


{-| Binds parameters as `bindParamsRtys` does, dropping the skeletons.
-}
bindParams : List ( Name, Mono.MonoType ) -> Env -> Gen -> ( Env, Gen )
bindParams params env g =
    let
        ( env1, _, g1 ) =
            bindParamsRtys params env g
    in
    ( env1, g1 )



-- EXPRESSION WALKER


{-| Generates the constraints of an expression evaluated at `path`, and returns
the skeleton of its value.

An unbound local variable gives `RScalar`. A local tail-recursive function's
name is bound to a fresh skeleton of the `let` expression's type, and its body is
walked with its parameters bound but its result skeleton discarded. An `if`'s
conditions are all walked at `Seq n 0` of its node and its branches at
`Arm n i` of the same node, so a resource used in a condition and in a branch
has its lifetimes joined across a sequence step and an alternatives step, which
`Compiler.GlobalOpt.Borrow.Lifetime` resolves conservatively.

-}
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
                    -- A string literal is never freed, so it is an escape seed.
                    ( rty, escSeedAll rty { g1 | immortalLiterals = g1.immortalLiterals + 1 } )

                _ ->
                    ( Rty.RScalar, g )

        Mono.MonoUnit ->
            ( Rty.RScalar, g )

        Mono.MonoVarLocal x _ ->
            case Dict.get x env.vars of
                Nothing ->
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
                            addOcc (List.map Tuple.second pairs) g3
                    in
                    ( useRty, g4 )

        Mono.MonoVarGlobal _ _ t ->
            -- A global value lives outside the function, so it is owned and escapes.
            let
                ( rty, g1 ) =
                    freshR t g
            in
            ( rty, ownEverything rty (escSeedAll rty g1) )

        Mono.MonoVarKernel _ _ _ _ t ->
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

        Mono.MonoRecordAccess e _ t ->
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

                ( fieldRtys, g3 ) =
                    constrainFields env n path 1 fes g2

                ( resultRty, g4 ) =
                    freshR t g3

                g5 =
                    ownEverything resultRty g4

                mentioned =
                    List.map Tuple.first fes

                copiedHeap =
                    countCopiedHeapFields baseRty mentioned

                -- The result stores the new field values and the base's copied
                -- fields; escape edges link them to it.
                g5b =
                    case Rty.topRes resultRty of
                        Just resTop ->
                            addEscEdges
                                (List.foldl
                                    (\fr acc ->
                                        case Rty.topRes fr of
                                            Just ft ->
                                                ( resTop, ft ) :: acc

                                            Nothing ->
                                                acc
                                    )
                                    (List.map (\ft -> ( resTop, ft )) (copiedHeapFieldTops baseRty mentioned))
                                    fieldRtys
                                )
                                (addFreshSite "lit:" 1 resultRty g5)

                        Nothing ->
                            g5

                g6 =
                    { g5b | updateCopiedHeapFields = g5b.updateCopiedHeapFields + copiedHeap }
            in
            ( resultRty, g6 )

        Mono.MonoDestruct (Mono.MonoDestructor x dpath _) body _ ->
            let
                ( n, g0 ) =
                    freshNode g

                rootRes =
                    rootResFor dpath env

                g1 =
                    addSeeds rootRes (Seq n 0 :: path) g0

                ( xRty, g2 ) =
                    freshR (Mono.getMonoPathType dpath) g1

                -- `x` is read out of the root value; an escape edge links them.
                g2b =
                    case ( rootTopFor dpath env, Rty.topRes xRty ) of
                        ( Just rootTop, Just xTop ) ->
                            addEscEdges [ ( rootTop, xTop ) ] g2

                        _ ->
                            g2

                env1 =
                    bindVar x xRty env

                g3 =
                    addScope (Maybe.withDefault -1 (Rty.topRes xRty)) (Seq n 1 :: path) g2b
            in
            constrainExpr env1 (Seq n 1 :: path) body g3

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
            in
            freshR t g1

        Mono.MonoClosure info body t ->
            let
                ( n, g0 ) =
                    freshNode g

                g1 =
                    List.foldl
                        (\( _, capE, _ ) acc ->
                            let
                                ( capRty, acc1 ) =
                                    constrainExpr env (Seq n 0 :: path) capE acc
                            in
                            poison capRty RCapture bumpCaptures acc1
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
            ( rty, ownEverything rty (addFreshSite "lit:" 1 rty g4) )

        Mono.MonoAccessorValue _ _ t ->
            let
                ( rty, g1 ) =
                    freshR t g
            in
            ( rty, poison rty RClosureBoundary bumpClosure g1 )



-- CALL DISPATCH


{-| Generates the constraints of a call of `f` on `args`, with result type `t`,
and returns the skeleton of the result.

The arguments are walked first, the result is recorded as a fresh site whose
class starts with `call:`, and the callee is then handled as the module
documentation's section on calls describes. A global or kernel callee is not
itself walked; any other callee is.

-}
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
            countNonVarOperands args argRtys (addFreshSite "call:" 1 resultRty g2)

        poisoned gg =
            ownEverything resultRty gg
    in
    case f of
        Mono.MonoVarGlobal _ specId _ ->
            if isDirectSaturated callInfo then
                case env.sigs specId of
                    Just sig ->
                        ( resultRty, applyDirectSig sig path argRtys resultRty gNV )

                    Nothing ->
                        ( resultRty, poisoned (ownArgsEsc argRtys { gNV | sigMissReads = gNV.sigMissReads + 1 }) )

            else
                -- Not a single-stage saturated call with a direct call kind.
                ( resultRty, poisoned (poisonArgs argRtys RClosureBoundary bumpClosure gNV) )

        Mono.MonoVarKernel _ prefix home name _ ->
            case KernelSigs.lookup ( prefix, home, name ) of
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


{-| Tells whether a call passes exactly the callee's first stage of arguments
with a direct call kind.
-}
isDirectSaturated : Mono.CallInfo -> Bool
isDirectSaturated ci =
    ci.isSingleStageSaturated && isDirectKind ci.callKind


{-| Tells whether a call kind is a direct call.
-}
isDirectKind : Mono.CallKind -> Bool
isDirectKind k =
    case k of
        Mono.CallDirectFlat ->
            True

        Mono.CallDirectKnownSegmentation ->
            True

        _ ->
            False


{-| Applies a callee's borrow signature at a call.

An argument resource at an `Owned` position is forced owned and marked as an
escape seed; one at any other position is seeded as live until the call. Result
resources at an `Owned` position are forced owned. For each result position that
`resultLts` says may alias a parameter, a flow is added from the head of that
argument to the result resource, so the argument's ownership follows how the
result is used. Positions are matched by index, and a list that is too short for
its type is not reported: the extra resources are left alone.

-}
applyDirectSig : BorrowSig -> Path -> List RTy -> RTy -> Gen -> Gen
applyDirectSig sig path argRtys resultRty g =
    applyParamList path argRtys sig.params g
        |> applyResultModes resultRty sig.result
        |> applyResultLts sig.resultLts argRtys resultRty


{-| Forces owned each resource of the result at an `Owned` position of the
signature's result modes. Resources beyond the last mode are left alone.
-}
applyResultModes : RTy -> Sig.SigTy -> Gen -> Gen
applyResultModes resultRty sigTy g =
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


{-| Adds a flow from the head of each argument a result position may alias to
that result resource. Positions and argument indices out of range are skipped.
-}
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


{-| Returns the element at index `k`, counting from 0.
-}
nthOf : Int -> List a -> Maybe a
nthOf k list =
    List.head (List.drop k list)


{-| Applies parameter modes to arguments in order. An argument beyond the
signature's parameters is forced owned and marked as an escape seed; parameters
beyond the arguments are ignored.
-}
applyParamList : Path -> List RTy -> List Sig.SigTy -> Gen -> Gen
applyParamList path argRtys sigTys g =
    case ( argRtys, sigTys ) of
        ( argRty :: restA, sigTy :: restS ) ->
            applyParamList path restA restS (applyParamModes argRty sigTy path g)

        ( argRty :: restA, [] ) ->
            applyParamList path restA [] (ownEverything argRty (escSeedAll argRty g))

        ( [], _ ) ->
            g


{-| Applies one parameter's modes to one argument, as `applyDirectSig`
describes, and counts the argument in `poisoningCallSites` when it is a heap
value with at least one resource forced owned.
-}
applyParamModes : RTy -> Sig.SigTy -> Path -> Gen -> Gen
applyParamModes argRty sigTy path g =
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
                                go (idx + 1) rest (addForced r RConstruct { acc | escSeeds = r :: acc.escSeeds }) True

                            _ ->
                                go (idx + 1) rest (addSeeds [ r ] path acc) anyOwned

        ( g1, forcedOwned ) =
            go 0 (Rty.allRes argRty) g False
    in
    if isHeapRty argRty && forcedOwned then
        { g1 | poisoningCallSites = g1.poisoningCallSites + 1 }

    else
        g1


{-| Applies a kernel's signature at a call.

A `PBorrowed` argument is seeded as live until the call, and a `POwned` one is
forced owned and marked as an escape seed. The result is owned. For each index
in `resultAliases`, a get from that argument's head to the result's head is
added, so the result is treated as read out of that argument.

-}
applyKernelSig : KernelSigs.KernelSig -> Path -> List RTy -> RTy -> Gen -> Gen
applyKernelSig ksig path argRtys resultRty g =
    let
        g1 =
            ownEverything resultRty (applyKernelParams path argRtys ksig.params g)
    in
    List.foldl
        (\k acc ->
            case ( nthTop k argRtys, Rty.topRes resultRty ) of
                ( Just src, Just dst ) ->
                    addGet { container = src, out = [ ( src, dst ) ], path = path } acc

                _ ->
                    acc
        )
        g1
        ksig.resultAliases


{-| Applies kernel parameter modes to arguments in order. An argument beyond the
listed modes is treated as `POwned`.
-}
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
                            ownEverything argRty (escSeedAll argRty g)
            in
            applyKernelParams path restA restP g1

        ( argRty :: restA, [] ) ->
            applyKernelParams path restA [] (ownEverything argRty (escSeedAll argRty g))

        ( [], _ ) ->
            g


{-| Returns the head resource of the skeleton at index `k`, if there is one.
-}
nthTop : Int -> List RTy -> Maybe ResVar
nthTop k rtys =
    case List.head (List.drop k rtys) of
        Just rty ->
            Rty.topRes rty

        Nothing ->
            Nothing



-- WALKER HELPERS


{-| Walks a list of expressions as children `i`, `i + 1`, ... of sequence node
`n`, and returns their skeletons.
-}
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


{-| Walks the conditions of an `if`, all at child 0 of sequence node `n`.
-}
constrainConds : Env -> Int -> Path -> List Mono.MonoExpr -> Gen -> Gen
constrainConds env n path conds g =
    List.foldl (\c acc -> Tuple.second (constrainExpr env (Seq n 0 :: path) c acc)) g conds


{-| Walks the arguments of a tail call as children of sequence node `n`, seeds
every resource of each as live until the empty path, the end of the whole body,
and records the resources in `tailArgRes`.
-}
constrainTailArgs : Env -> Int -> Path -> List Mono.MonoExpr -> Gen -> Gen
constrainTailArgs env n path args g =
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


{-| Walks the field values of a record update as children `i`, `i + 1`, ...
of sequence node `n`, and returns their skeletons.
-}
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


{-| Generates the constraints of a list, tuple or record literal with elements
`es` and type `t`, and returns its skeleton.

The literal's head is forced owned with `RConstruct`, and the head of each
element is storage-equal to it. The literal is a fresh site of class `lit:`,
weighted by its number of elements for a list and 1 otherwise.

-}
constrainContainer : Env -> Path -> List Mono.MonoExpr -> Mono.MonoType -> Gen -> ( RTy, Gen )
constrainContainer env path es t g =
    let
        ( n, g0 ) =
            freshNode g

        ( elemRtys, g1 ) =
            constrainArgs env n path 0 es g0

        ( resultRty, g2a ) =
            freshR t g1

        -- A list literal of k elements allocates k cons cells.
        g2 =
            addFreshSite "lit:"
                (case resultRty of
                    Rty.RList _ _ ->
                        List.length es

                    _ ->
                        1
                )
                resultRty
                g2a

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


{-| Walks each arm at `Arm n i` and adds flows in both directions between each
arm's skeleton and the shared result skeleton.
-}
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


{-| Returns a copy of a skeleton with fresh resources, recording string heads in
`stringRes`. Nothing in this module calls it.
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


{-| Returns a copy of a skeleton with fresh resources, together with the pairs of
each original resource and its copy, head first in pre-order. String heads of
the copy are recorded in `stringRes`; erased resources are not forced owned.
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


{-| Copies a list of skeletons as `cloneRTyF` does, concatenating the pairs.
-}
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


{-| Copies the field skeletons of a record as `cloneRTyF` does, concatenating
the pairs.
-}
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


{-| Copies a list of skeletons as `cloneRTy` does. Only `cloneRTy` calls it.
-}
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


{-| Copies the field skeletons of a record as `cloneRTy` does. Only `cloneRTy`
calls it.
-}
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


{-| Pairs the head of the container with the head of the value read out, or
returns no pair when either has no head.
-}
zipTop : RTy -> RTy -> List ( ResVar, ResVar )
zipTop container out =
    case ( Rty.topRes container, Rty.topRes out ) of
        ( Just c, Just o ) ->
            [ ( c, o ) ]

        _ ->
            []


{-| Returns every resource of the variable a destructuring path starts from, or
none when the variable is unbound.
-}
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


{-| Returns the head resource of the variable a destructuring path starts from.
-}
rootTopFor : Mono.MonoPath -> Env -> Maybe ResVar
rootTopFor dpath env =
    rootName dpath
        |> Maybe.andThen (\name -> Dict.get name env.vars)
        |> Maybe.andThen Rty.topRes


{-| Returns the variable a destructuring path starts from.
-}
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


{-| Returns the arm bodies held inline in a decision tree, leaving out jumps to
shared branches.
-}
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


{-| Returns the head resources of the fields of a record skeleton that a record
update does not name, and so copies from the base. A base that is not a record
skeleton gives none.
-}
copiedHeapFieldTops : RTy -> List Name -> List ResVar
copiedHeapFieldTops baseRty mentioned =
    case baseRty of
        Rty.RRecord _ fields ->
            List.filterMap
                (\( name, fieldRty ) ->
                    if List.member name mentioned then
                        Nothing

                    else
                        Rty.topRes fieldRty
                )
                fields

        _ ->
            []


{-| Counts the heap fields of a record skeleton that a record update does not
name.
-}
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


{-| Counts the heap arguments of a call that are not variables, as
`nonVarOwnedFresh` when `isOwnedProducer` counts it as producing a new value
and as `nonVarBorrowedProducer` otherwise.
-}
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


{-| Tells whether an expression is a local or global variable.
-}
isVar : Mono.MonoExpr -> Bool
isVar e =
    case e of
        Mono.MonoVarLocal _ _ ->
            True

        Mono.MonoVarGlobal _ _ _ ->
            True

        _ ->
            False


{-| Tells whether the census counts an expression as producing a new value: a
literal, a list, tuple or record literal, a record update, or any call.
-}
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


{-| Tells whether a skeleton has any resource.
-}
isHeapRty : RTy -> Bool
isHeapRty rty =
    case rty of
        Rty.RScalar ->
            False

        _ ->
            True



-- OWN / POISON HELPERS


{-| Forces every resource of a skeleton owned with `RConstruct`.
-}
ownEverything : RTy -> Gen -> Gen
ownEverything =
    forceAllOf RConstruct


{-| Forces every resource of a skeleton owned with `reason`.
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


{-| Forces every resource of each argument owned with `RConstruct` and marks it
as an escape seed.
-}
ownArgsEsc : List RTy -> Gen -> Gen
ownArgsEsc rtys g =
    List.foldl (\rty acc -> ownEverything rty (escSeedAll rty acc)) g rtys


{-| Poisons a heap value: forces every resource owned with `reason`, marks each
as an escape seed, and applies `bump` to count it. A skeleton with no resource is
left alone and not counted.
-}
poison : RTy -> Reason -> (Gen -> Gen) -> Gen -> Gen
poison rty reason bump g =
    if isHeapRty rty then
        bump (forceAllOf reason rty (escSeedAll rty g))

    else
        g


{-| Poisons each argument as `poison` does, counting each heap argument once.
-}
poisonArgs : List RTy -> Reason -> (Gen -> Gen) -> Gen -> Gen
poisonArgs rtys reason bump g =
    List.foldl (\rty acc -> poison rty reason bump acc) g rtys


{-| Counts one value poisoned at a closure boundary.
-}
bumpClosure : Gen -> Gen
bumpClosure g =
    { g | poisonedByClosure = g.poisonedByClosure + 1 }


{-| Counts one value poisoned at a kernel call with no signature.
-}
bumpKernel : Gen -> Gen
bumpKernel g =
    { g | poisonedByKernel = g.poisonedByKernel + 1 }


{-| Counts one captured value forced owned.
-}
bumpCaptures : Gen -> Gen
bumpCaptures g =
    { g | capturesForcedOwned = g.capturesForcedOwned + 1 }
