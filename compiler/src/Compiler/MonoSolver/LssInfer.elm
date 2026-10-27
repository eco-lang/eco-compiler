module Compiler.MonoSolver.LssInfer exposing
    ( signatureFor, instantiateWithSignature
    , injectLambdaMemberQualified, injectLambdaMemberQualifiedId, injectSpineMemberId
    , injectPapSuccessors, injectPapSuccessorsFrom, papMemberKey
    , flowArrowSetsPlain, noteApplied, declaredArityOf, kernelAliasOf
    , canTypeArrowDepth, canTypeMentionsArrow
    )

{-| Infers each definition's lambda-set signature, so that a call site can learn
which functions the callee's body puts into the arrows of its type without
walking that body.

A _lambda set_ is the set of function values that can flow through one arrow of
a type. The solver's store gives each arrow a _set slot_, and a slot holds
_members_: integer ids, each naming one function value, interned from string
keys by `Compiler.MonoSolver.Engine`. The key's prefix says what kind of value
it names: `l|` a source lambda, `g|` a global, `c|` an enum or box
constructor, `k|` a kernel, `a|` a record accessor, and `p|<global>|<d>` a
partial application of a global with `d` arguments supplied. A slot can
instead be ⊤, the set that may hold anything, which is always sound and only
loses precision. What a slot can hold and how writes combine is
`Compiler.MonoSolver.Store`'s to say.

A slot that is not ⊤ claims to list every function that can reach its arrow,
and a later stage may turn a call through a one-member set into a direct call.
Much of this module is therefore deciding, where a set might be incomplete,
whether to publish it or make it ⊤.

A definition's signature is an `Engine.LssSignature`, one `Engine.ArrowFact`
per arrow of its _signature source type_. That type is the definition's stored
annotation when it has one, and its own type otherwise (`sigSourceTypeFor`).
A fact's index is the arrow's _ordinal_: the position of its slot in the array
`Store.loadTypeWithArrows` returns for that type. `instantiateWithSignature`
applies the facts to a fresh instantiation loaded with
`Store.loadTypeIsolatedWithArrows`, pairing facts with slots by ordinal, so the
type it is given must be sourced the same way. When a non-trivial signature
and the instantiation differ in length nothing can be paired, and every slot of
the instantiation is made ⊤.

The unit of inference is one `TOpt.Cycle` node, all of its members together,
or one other definition. A unit is inferred the first time any of its members
is asked for, and every member's signature is memoized in `lssSignatures`.
The signatures of the globals a unit references are computed first, so that
the unit itself is inferred inside one scratch store (`Engine.withScratchStore`)
with no other inference nested in it. Every member's signature source type is
loaded through that store's shared memo, so a recursive or sibling reference
unifies with the member's own slots. Asking for the signature of a unit that is
still being inferred crashes.

Most of the file is the body walk, `walkExpr`. It is a fold over the typed
expression that loads types and writes set facts; it translates nothing and
creates no specializations. Lambda literals and references to named functions
write their own member ids into their type's slots, a call applies its callee's
signature, an `if` or `case` joins its branches into one result, and a `let`
joins its right-hand side into the name's type. Each walked expression hands
its parent a `WalkPoint`, which says whether the sets it carries are known to be
complete.

After the walk, each member's slots are read back into facts. Where a slot's
contents arrive over a deferred inclusion edge from another of the same
signature's slots, the fact records that ordinal in `sources`, and the caller
installs the edge in its own store; members from any other inflow are copied
into the fact. An empty fact means only that the body added nothing visible to
that arrow, not that no function reaches it.

The module also exposes the helpers that write member ids along a type's
arrows, the arity queries, and the directed set flow `flowArrowSetsPlain`.


# Signatures

@docs signatureFor, instantiateWithSignature


# Member injection

@docs injectLambdaMemberQualified, injectLambdaMemberQualifiedId, injectSpineMemberId
@docs injectPapSuccessors, injectPapSuccessorsFrom, papMemberKey


# Flow and queries

@docs flowArrowSetsPlain, noteApplied, declaredArityOf, kernelAliasOf
@docs canTypeArrowDepth, canTypeMentionsArrow

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..))
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.Store as Store
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Dict as CoreDict exposing (Dict)
import System.TypeCheck.IO as IO



-- ====== PUBLIC API ======


{-| Returns the lambda-set signature of `global`, inferring and memoizing its
whole unit on first demand.

A `Link` node is followed first, and the member's own memoized signature is
preferred over the target's. A global that is a cycle group's handle rather
than a member gets a trivial placeholder. With LSS disabled the result is
`Engine.trivialSignature 0` and nothing is memoized. Asking for a member of a
unit still being inferred aborts with an `EngineBug`.

-}
signatureFor : TOpt.Global -> Engine.S -> ( Engine.LssSignature, Engine.S )
signatureFor global s0 =
    let
        gkey =
            TOpt.toComparableGlobal global
    in
    case HashMap.get TOpt.globalHash (==) global s0.lssSignatures of
        Just sig ->
            ( sig, s0 )

        Nothing ->
            if not s0.env.lss.enabled then
                ( Engine.trivialSignature 0, s0 )

            else if HashMap.member TOpt.globalHash (==) global s0.lssInProgress then
                Engine.crashFailure (EngineBug ("LssInfer.signatureFor re-entry on in-flight unit member: " ++ gkey))

            else
                case HashMap.get TOpt.globalHash (==) global s0.env.toptNodes of
                    Just (TOpt.Link target) ->
                        -- A cycle member links to its group's handle, and
                        -- inferring the group memoizes every member's own
                        -- signature, which is preferred over the handle's.
                        case signatureFor target s0 of
                            ( sigTarget, s1 ) ->
                                case HashMap.get TOpt.globalHash (==) global s1.lssSignatures of
                                    Just own ->
                                        ( own, s1 )

                                    Nothing ->
                                        ( sigTarget, { s1 | lssSignatures = HashMap.insert TOpt.globalHash (==) global sigTarget s1.lssSignatures } )

                    _ ->
                        inferUnit global s0


{-| Loads `funcCanType` as a fresh instantiation and applies the signature of
`global` to its arrow slots, returning the instantiation's root.

`funcCanType` must be `global`'s stored annotation when it has one, since that
is the type the signature's ordinals count; otherwise the facts may pair with
the wrong arrows, or, for a non-trivial signature whose arrow count differs,
every slot is made ⊤.

-}
instantiateWithSignature : TOpt.Global -> Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiateWithSignature global funcCanType s0 =
    case signatureFor global s0 of
        ( sig, s1 ) ->
            instantiateWithSig global sig funcCanType s1


{-| Does what `instantiateWithSignature` does with the signature `sig` already
in hand. A trivial signature has no facts to apply, so its type is loaded
without collecting the arrow slots.
-}
instantiateWithSig : TOpt.Global -> Engine.LssSignature -> Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiateWithSig global sig funcCanType s1 =
    if sig.trivial then
        Store.loadTypeIsolated funcCanType s1

    else
        case Store.loadTypeIsolatedWithArrows funcCanType s1 of
            ( ( funcVar, slots ), s2 ) ->
                case applyFacts global sig slots funcVar s2 of
                    s3 ->
                        ( funcVar, s3 )


{-| Writes a source lambda's raw member id into the first `arity` arrows of
`funcVar`'s result spine, as `injectSpineMemberId` describes. `arity` is the
lambda's parameter count. A lambda with no source id writes nothing.
-}
injectLambdaMember : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Engine.S -> Engine.S
injectLambdaMember arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            s0

        Just lamId ->
            injectSpineMemberId arity (Engine.srcLambdaKey lamId) funcVar s0


{-| Does what `injectLambdaMemberQualifiedId` does, without returning the id.
-}
injectLambdaMemberQualified : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Engine.S -> Engine.S
injectLambdaMemberQualified arity srcLam funcVar s0 =
    case injectLambdaMemberQualifiedId arity srcLam funcVar s0 of
        ( _, s1 ) ->
            s1


{-| Mints a source lambda's member id with `Engine.lambdaInstanceMemberId`,
writes it along `funcVar`'s result spine, and returns it. A lambda with no
source id writes nothing and returns `Nothing`.

The id is written into the first `arity` arrows, `arity` being the lambda's
parameter count, except for a lambda that is the root of its definition and so
was given its global's `g|` id. That id names the unapplied global, so it is
written on the head arrow only, and the deeper arrows, which hold partial
applications of the global, get its `p|` ids (`injectFoldedSuccessors`).

-}
injectLambdaMemberQualifiedId : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Engine.S -> ( Maybe Int, Engine.S )
injectLambdaMemberQualifiedId arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            ( Nothing, s0 )

        Just lamId ->
            case Engine.lambdaInstanceMemberId lamId s0 of
                ( mid, s1 ) ->
                    case CoreDict.get (Engine.srcLambdaKey lamId) s1.lssMemberTable.rootLamOf of
                        Just g ->
                            case injectSpineMemberId 1 mid funcVar s1 of
                                s2 ->
                                    case injectFoldedSuccessors g arity funcVar s2 of
                                        s3 ->
                                            ( Just mid, s3 )

                        Nothing ->
                            case injectSpineMemberId arity mid funcVar s1 of
                                s2 ->
                                    ( Just mid, s2 )



-- ====== SIGNATURE SOURCE ======


{-| Returns the type whose arrows `global`'s signature ordinals count: its
stored annotation if it has one, else `fallbackType`. Inference and every call
site go through this, so that both count the same arrows.
-}
sigSourceTypeFor : TOpt.Global -> Can.Type TypeIds.MVarId -> Engine.S -> Can.Type TypeIds.MVarId
sigSourceTypeFor global fallbackType s =
    case DMap.get TOpt.toComparableGlobal global s.env.annotations of
        Just (Can.Forall _ annoType) ->
            annoType

        Nothing ->
            fallbackType


{-| Applies `sig`'s facts to `slots`, the arrow slots of a fresh instantiation
rooted at `funcVar`, pairing them by ordinal.

A trivial signature writes nothing, whatever the slot count. Otherwise, when the
signature and the instantiation have different numbers of arrows, every arrow
set under `funcVar` is made ⊤, and the mismatch is counted under `lss.report`.

-}
applyFacts : TOpt.Global -> Engine.LssSignature -> Array Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
applyFacts global sig slots funcVar s0 =
    if sig.trivial then
        s0

    else if Array.length sig.arrows /= Array.length slots then
        Store.poisonArrowSets funcVar (censusLenGuard global (Array.length sig.arrows) (Array.length slots) s0)

    else
        applyFactsGo sig.arrows slots 0 s0


{-| Counts, under `lss.report`, an instantiation of `global` made ⊤ because its
`slotsN` arrows did not match the signature's `sigN`: once in total, once per
global, and once per pair of counts.
-}
censusLenGuard : TOpt.Global -> Int -> Int -> Engine.S -> Engine.S
censusLenGuard global sigN slotsN s =
    if not s.env.lss.report then
        s

    else
        s
            |> Engine.bumpArgFlowCensus "poison|lenGuard|all"
            |> Engine.bumpArgFlowCensus ("poison|lenGuard|" ++ TOpt.toComparableGlobal global)
            |> Engine.bumpArgFlowCensus ("poison|lenGuardShape|" ++ String.fromInt sigN ++ "->" ++ String.fromInt slotsN)


{-| Applies the facts from ordinal `i` onwards to their slots. For each fact, the
slot is unified with the slot of its `rep` ordinal, then made ⊤ (keeping the
fact's ⊤ kind) or given the fact's members, and then given a deferred inclusion
edge from the slot of each ordinal in `sources`.
-}
applyFactsGo : Array Engine.ArrowFact -> Array Vars.Variable -> Int -> Engine.S -> Engine.S
applyFactsGo facts slots i s0 =
    case ( Array.get i facts, Array.get i slots ) of
        ( Just fact, Just slot ) ->
            let
                afterRep =
                    if fact.rep /= i then
                        case Array.get fact.rep slots of
                            Just repSlot ->
                                Store.unifyStrictS (\() -> "") repSlot slot s0

                            Nothing ->
                                s0

                    else
                        s0
            in
            case afterRep of
                s1 ->
                    let
                        afterSet =
                            if fact.top then
                                Store.unifySlotWithSet (Just fact.topKind) [] slot s1

                            else if not (List.isEmpty fact.members) then
                                Store.unifySlotWithSet Nothing fact.members slot s1

                            else
                                s1
                    in
                    case afterSet of
                        s2 ->
                            -- The edges are followed when the slot is read,
                            -- so members the source slots gain later, from the
                            -- call's arguments, still arrive.
                            case installSources fact.sources slots slot s2 of
                                s3 ->
                                    applyFactsGo facts slots (i + 1) s3

        _ ->
            s0


{-| Adds to `dst` a deferred inclusion edge from the slot of each ordinal in
`ordinals`, skipping an ordinal with no slot.
-}
installSources : List Int -> Array Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
installSources ordinals slots dst s0 =
    case ordinals of
        [] ->
            s0

        j :: rest ->
            case Array.get j slots of
                Nothing ->
                    installSources rest slots dst s0

                Just srcSlot ->
                    case Store.addSlotSource srcSlot dst s0 of
                        s1 ->
                            installSources rest slots dst s1



-- ====== UNIT INFERENCE ======


{-| One definition of an inference unit: the global, the type its signature is
read from, and the body to walk, which is `Nothing` for a node with no
expression to walk (a constructor, enum, box, manager or kernel node, or an
unknown global).

`tailArgs` is non-empty only for a tail-recursive member of a cycle. Its body
is typed at the function's result while `sigType` is the whole function type,
so the walk first binds these names to the first arrows of the loaded type.

-}
type alias UnitMember =
    { g : TOpt.Global
    , gkey : String
    , sigType : Can.Type TypeIds.MVarId
    , body : Maybe (TOpt.Expr TypeIds.MVarId)
    , tailArgs : List Name
    }


{-| Infers the signatures of the whole unit `global` belongs to, memoizes each
member's, and returns `global`'s.

The unit's members are marked as in progress for the duration. A `global` that
is not itself one of the members, a cycle group's handle, is given a trivial
placeholder.

-}
inferUnit : TOpt.Global -> Engine.S -> ( Engine.LssSignature, Engine.S )
inferUnit global s0 =
    case resolveUnit global s0 of
        ( members, s1 ) ->
            let
                s2 =
                    { s1 | lssInProgress = HashMap.insert TOpt.globalHash (==) global () (List.foldl (\m acc -> HashMap.insert TOpt.globalHash (==) m.g () acc) s1.lssInProgress members) }
            in
            -- Callee signatures are computed before entering the scratch
            -- store, so that no inference runs inside it.
            case preResolveCallees members s2 of
                s3 ->
                    case Engine.withScratchStore (inferUnitInScratch members) s3 of
                        ( sigs, s4 ) ->
                            let
                                s5 =
                                    { s4
                                        | lssSignatures = List.foldl (\( k, sg ) acc -> HashMap.insert TOpt.globalHash (==) k sg acc) s4.lssSignatures sigs
                                        , lssInProgress = HashMap.remove TOpt.globalHash (==) global (List.foldl (\m acc -> HashMap.remove TOpt.globalHash (==) m.g acc) s4.lssInProgress members)
                                    }
                            in
                            case List.filter (\( k, _ ) -> k == global) sigs of
                                ( _, sig ) :: _ ->
                                    ( sig, s5 )

                                [] ->
                                    let
                                        placeholder =
                                            Engine.trivialSignature 0
                                    in
                                    ( placeholder, { s5 | lssSignatures = HashMap.insert TOpt.globalHash (==) global placeholder s5.lssSignatures } )


{-| Returns the members of the inference unit `global` belongs to, following
`Link` nodes: every value and function definition of a `TOpt.Cycle`, or the one
definition otherwise.

A constructor, enum, box, manager, kernel or unknown global becomes a member
with no body, which contributes nothing to its signature.

-}
resolveUnit : TOpt.Global -> Engine.S -> ( List UnitMember, Engine.S )
resolveUnit ((TOpt.Global home _) as global) s0 =
    case HashMap.get TOpt.globalHash (==) global s0.env.toptNodes of
        Nothing ->
            ( [ memberOf global Can.TUnit Nothing s0 ], s0 )

        Just node ->
            case node of
                TOpt.Define expr _ meta ->
                    ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.TrackedDefine _ expr _ meta ->
                    ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.Cycle _ valueDefs funcDefs _ ->
                    let
                        valueMembers =
                            List.map
                                (\( name, expr ) -> memberOf (TOpt.Global home name) (TOpt.typeOf expr) (Just expr) s0)
                                valueDefs

                        funcMembers =
                            List.map
                                (\def ->
                                    case def of
                                        TOpt.Def _ name bodyExpr defType ->
                                            memberOf (TOpt.Global home name) defType (Just bodyExpr) s0

                                        TOpt.TailDef _ name args bodyExpr defType _ ->
                                            let
                                                m =
                                                    memberOf (TOpt.Global home name) defType (Just bodyExpr) s0
                                            in
                                            { m | tailArgs = List.map (\( locName, _ ) -> A.toValue locName) args }
                                )
                                funcDefs
                    in
                    ( valueMembers ++ funcMembers, s0 )

                TOpt.PortIncoming expr _ meta ->
                    ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.PortOutgoing expr _ meta ->
                    ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.Ctor _ _ canType ->
                    ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Enum _ canType ->
                    ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Box canType ->
                    ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Link target ->
                    resolveUnit target s0

                TOpt.Manager _ ->
                    ( [ memberOf global Can.TUnit Nothing s0 ], s0 )

                TOpt.Kernel _ _ ->
                    ( [ memberOf global Can.TUnit Nothing s0 ], s0 )


{-| Builds a unit member for `g` with no tail arguments, its signature type chosen
by `sigSourceTypeFor`.
-}
memberOf : TOpt.Global -> Can.Type TypeIds.MVarId -> Maybe (TOpt.Expr TypeIds.MVarId) -> Engine.S -> UnitMember
memberOf g fallbackType body s =
    { g = g
    , gkey = TOpt.toComparableGlobal g
    , sigType = sigSourceTypeFor g fallbackType s
    , body = body
    , tailArgs = []
    }


{-| Computes the signature of every global the unit's bodies reference, except
the unit's own members and globals already memoized.
-}
preResolveCallees : List UnitMember -> Engine.S -> Engine.S
preResolveCallees members s0 =
    let
        unitKeys =
            List.foldl (\m acc -> CoreDict.insert m.gkey () acc) CoreDict.empty members

        referenced =
            List.foldl
                (\m acc ->
                    case m.body of
                        Just body ->
                            collectReferencedGlobals body acc

                        Nothing ->
                            acc
                )
                CoreDict.empty
                members
    in
    preResolveGo unitKeys (CoreDict.values referenced) s0


{-| Computes the signature of each of `globals` that is neither in `unitKeys` nor
already memoized.
-}
preResolveGo : Dict String () -> List TOpt.Global -> Engine.S -> Engine.S
preResolveGo unitKeys globals s0 =
    case globals of
        [] ->
            s0

        g :: rest ->
            let
                k =
                    TOpt.toComparableGlobal g
            in
            if CoreDict.member k unitKeys || HashMap.member TOpt.globalHash (==) g s0.lssSignatures then
                preResolveGo unitKeys rest s0

            else
                case signatureFor g s0 of
                    ( _, s1 ) ->
                        preResolveGo unitKeys rest s1


{-| Adds to `acc` every global, enum, box and cycle member that `expr` references,
keyed by its comparable name.
-}
collectReferencedGlobals : TOpt.Expr TypeIds.MVarId -> Dict String TOpt.Global -> Dict String TOpt.Global
collectReferencedGlobals expr acc =
    case expr of
        TOpt.VarGlobal _ g _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarEnum _ g _ _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarBox _ g _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarCycle _ home name _ ->
            CoreDict.insert (TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name) acc

        _ ->
            List.foldl collectReferencedGlobals acc (directChildren expr)



-- ====== THE SCRATCH-STORE UNIT PASS ======


{-| Infers the signatures of `members` inside the current scratch store: loads
each member's signature type through the shared memo, walks the bodies, and
reads the slots back into signatures, in member order.

Under `lss.qCensus`, the unit's recorded constraints are then compared with the
store's answer and counted, and the constraint log is cleared, so that the same
constraints are not counted again when the scratch store is dropped.

-}
inferUnitInScratch : List UnitMember -> Engine.S -> ( List ( TOpt.Global, Engine.LssSignature ), Engine.S )
inferUnitInScratch members s0 =
    case loadMemberSlots members [] s0 of
        ( loaded, s1 ) ->
            -- `loaded` has one entry per member, in member order.
            case walkMembers (List.map2 Tuple.pair members loaded) s1 of
                s2 ->
                    case
                        zonkSignatures
                            (List.map2
                                (\m ( gkey, _, slots ) -> ( gkey, selfIdOf m, slots ))
                                members
                                loaded
                            )
                            []
                            s2
                    of
                        ( sigs, s3 ) ->
                            -- Counted here, while the scratch store still
                            -- holds the unit's complete constraints.
                            let
                                s4 =
                                    Store.qInferenceCensus
                                        (List.map (\( _, root, _ ) -> root) loaded)
                                        s3

                                aux4 =
                                    s4.itemAux
                            in
                            ( sigs, { s4 | itemAux = { aux4 | qLog = [] } } )


{-| Loads each member's signature type through the shared memo, returning, in
member order, the member's global, the type's root and its arrow slots.
-}
loadMemberSlots : List UnitMember -> List ( TOpt.Global, Vars.Variable, Array Vars.Variable ) -> Engine.S -> ( List ( TOpt.Global, Vars.Variable, Array Vars.Variable ), Engine.S )
loadMemberSlots members acc s0 =
    case members of
        [] ->
            ( List.reverse acc, s0 )

        m :: rest ->
            case Store.loadTypeWithArrows m.sigType s0 of
                ( ( root, slots ), s1 ) ->
                    loadMemberSlots rest (( m.g, root, slots ) :: acc) s1


{-| Returns the raw member id of the lambda that is the member's whole body, if
it is one.

This id is removed from the member's facts when they are read back. A
reference to the definition already names it with its `g|` member, and keeping
the raw id would make the signature of every definition with a parameter
non-trivial. Ids of lambdas inside the body are kept.

-}
selfIdOf : UnitMember -> Maybe Int
selfIdOf m =
    case m.body of
        Just (TOpt.Function (Just lamId) _ _ _) ->
            Just (Engine.srcLambdaKey lamId)

        Just (TOpt.TrackedFunction (Just lamId) _ _ _) ->
            Just (Engine.srcLambdaKey lamId)

        _ ->
            Nothing


{-| Walks each member's body and joins the value it hands back into the member's
loaded signature type, binding a tail-recursive member's arguments to that
type's first arrows and joining at the arrow after them. A member with no body
is only counted, under `lss.report`.
-}
walkMembers : List ( UnitMember, ( TOpt.Global, Vars.Variable, Array Vars.Variable ) ) -> Engine.S -> Engine.S
walkMembers pairs s0 =
    case pairs of
        [] ->
            s0

        ( m, ( _, root, _ ) ) :: rest ->
            case m.body of
                Nothing ->
                    walkMembers rest (Engine.bumpArgFlowCensus "sig|bodyless" s0)

                Just body ->
                    let
                        ( env0, maybeTarget, s1 ) =
                            bindParamsFromSpine m.tailArgs root CoreDict.empty CoreDict.empty s0
                    in
                    case walkExpr env0 body s1 of
                        ( wp, s2 ) ->
                            case ( maybeTarget, wpPoint wp ) of
                                ( Just target, Just p ) ->
                                    case joinArrowSetsSig target p s2 of
                                        s3 ->
                                            walkMembers rest s3

                                _ ->
                                    walkMembers rest s2


{-| Reads back each pending member's slots into its signature, returning them in
member order. Each entry carries the member's global, its own body lambda's
raw id to leave out (`selfIdOf`), and its arrow slots.
-}
zonkSignatures : List ( TOpt.Global, Maybe Int, Array Vars.Variable ) -> List ( TOpt.Global, Engine.LssSignature ) -> Engine.S -> ( List ( TOpt.Global, Engine.LssSignature ), Engine.S )
zonkSignatures pending acc s0 =
    case pending of
        [] ->
            ( List.reverse acc, s0 )

        ( gkey, selfId, slots ) :: rest ->
            case zonkOneSignature selfId slots s0 of
                ( sig, s1 ) ->
                    zonkSignatures rest (( gkey, sig ) :: acc) (censusSigFacts gkey sig s1)


{-| Counts, under `lss.report`, every fact of `g`'s non-trivial signature that is
not the default, one key per ordinal, naming its member count and class, its
source count, whether it is ⊤ and its `rep`.
-}
censusSigFacts : TOpt.Global -> Engine.LssSignature -> Engine.S -> Engine.S
censusSigFacts g sig s =
    if not s.env.lss.report || sig.trivial then
        s

    else
        let
            gkey =
                TOpt.toComparableGlobal g
        in
        List.foldl
            (\( i, f ) acc ->
                if f.rep == i && not f.top && List.isEmpty f.members && List.isEmpty f.sources then
                    acc

                else
                    Engine.bumpArgFlowCensus
                        ("sigfacts|"
                            ++ gkey
                            ++ "|"
                            ++ String.fromInt i
                            ++ "|m="
                            ++ String.fromInt (List.length f.members)
                            ++ ","
                            ++ Engine.membersClass f.members s.lssMemberTable
                            ++ "|s="
                            ++ String.fromInt (List.length f.sources)
                            ++ "|t="
                            ++ (if f.top then
                                    "1"

                                else
                                    "0"
                               )
                            ++ "|r="
                            ++ (if f.rep == i then
                                    "-"

                                else
                                    String.fromInt f.rep
                               )
                        )
                        acc
            )
            s
            (List.indexedMap Tuple.pair (Array.toList sig.arrows))


{-| Reads back one member's arrow slots into its signature, leaving `selfId` out
of every fact.
-}
zonkOneSignature : Maybe Int -> Array Vars.Variable -> Engine.S -> ( Engine.LssSignature, Engine.S )
zonkOneSignature selfId slots s0 =
    zonkSigGo selfId slots (Array.length slots) 0 [] s0


{-| Reads back the slots from ordinal `i` onwards, then builds the signature.

Each fact's `rep` is the smallest ordinal whose slot is unified with this one.
A ⊤ slot gives a ⊤ fact of the same kind with no members. A slot with members
gives them, unless there are more than `lss.maxSetSize` (when that is above 0),
which gives ⊤. A slot with deferred edges is resolved by `sigResolveEdges`. An
unwritten slot gives the default fact. The signature is trivial when every fact
is the default, and its `residual` pairs the `rep` of each fact that carries
members with those members.

-}
zonkSigGo : Maybe Int -> Array Vars.Variable -> Int -> Int -> List Engine.ArrowFact -> Engine.S -> ( Engine.LssSignature, Engine.S )
zonkSigGo selfId slots n i factsRev s0 =
    if i >= n then
        let
            facts =
                List.reverse factsRev

            trivial =
                List.all identity
                    (List.indexedMap
                        (\j f -> f.rep == j && not f.top && List.isEmpty f.members && List.isEmpty f.sources)
                        facts
                    )
        in
        let
            -- Keyed by `rep`: unified slots are one set, so their members
            -- belong to one key.
            residual =
                List.foldr
                    (\( j, f ) acc ->
                        if List.isEmpty f.members then
                            acc

                        else
                            let
                                key =
                                    if f.rep == j then
                                        j

                                    else
                                        f.rep
                            in
                            ( key, f.members ) :: acc
                    )
                    []
                    (List.indexedMap Tuple.pair facts)
        in
        ( { arrows = Array.fromList facts, trivial = trivial, residual = residual }
        , censusSignature n facts trivial s0
        )

    else
        case Array.get i slots of
            Nothing ->
                Engine.crashFailure (EngineBug "zonkOneSignature: slot index out of range")

            Just slot ->
                case repOrdinal slots slot i 0 s0 of
                    ( rep, s1 ) ->
                        let
                            ( store1, desc ) =
                                UF.get slot s1.store

                            s2 =
                                { s1 | store = store1 }

                            ( fact, s3 ) =
                                case desc.content of
                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsTop tpK)) ->
                                        ( Ok { rep = rep, members = [], top = True, topKind = tpK, sources = [] }, s2 )

                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms0)) ->
                                        let
                                            -- Filtering keeps the ascending
                                            -- order set writes require.
                                            ms =
                                                case selfId of
                                                    Just sid ->
                                                        List.filter (\mid -> mid /= sid) ms0

                                                    Nothing ->
                                                        ms0
                                        in
                                        -- A `maxSetSize` of 0 means no cap.
                                        if s2.env.lss.maxSetSize > 0 && List.length ms > s2.env.lss.maxSetSize then
                                            ( Ok { rep = rep, members = [], top = True, topKind = Mono.tkWiden, sources = [] }
                                            , Engine.bumpWidenedBySigSize s2
                                            )

                                        else
                                            ( Ok { rep = rep, members = ms, top = False, topKind = Mono.tkLegacy, sources = [] }, s2 )

                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms0 srcs)) ->
                                        ( Err ( ms0, srcs ), s2 )

                                    _ ->
                                        -- Unwritten: the body contributed nothing.
                                        ( Ok { rep = rep, members = [], top = False, topKind = Mono.tkLegacy, sources = [] }, s2 )
                        in
                        case fact of
                            Ok done ->
                                zonkSigGo selfId slots n (i + 1) (done :: factsRev) s3

                            Err ( ms0, srcs ) ->
                                case sigResolveEdges selfId slots i ms0 srcs s3 of
                                    ( resolved, s4 ) ->
                                        let
                                            ( done, s5 ) =
                                                finishSigFact rep resolved s4
                                        in
                                        zonkSigGo selfId slots n (i + 1) (done :: factsRev) s5


{-| Counts, under `lss.report`, a finished signature of `n` arrows by its number
of arrows and by class: `arrowfree` for no arrows, `allflex` for a trivial
signature, `hasTop` for one with a ⊤ fact, and `carrying` for the rest.
-}
censusSignature : Int -> List Engine.ArrowFact -> Bool -> Engine.S -> Engine.S
censusSignature n facts trivial s =
    if not s.env.lss.report then
        s

    else
        let
            klass =
                if n == 0 then
                    "arrowfree"

                else if trivial then
                    "allflex"

                else if List.any .top facts then
                    "hasTop"

                else
                    "carrying"
        in
        s
            |> Engine.bumpArgFlowCensus ("sig|" ++ klass)
            |> Engine.bumpArgFlowCensus ("sig|arrows=" ++ String.fromInt n)


{-| Resolves the slot at ordinal `i`, holding members `ms0` and deferred edges
from `srcs`, into the members and source ordinals of its fact.

The edges are followed transitively. A slot unified with the slot of another
ordinal is _promoted_: the ordinal goes into `sources` and the slot is not
followed further, because the caller installs that edge itself. Any other slot
is _internalized_: its members are collected and its own edges followed.
Reaching a ⊤ slot, or a slot that is not a lambda set, makes the fact ⊤.

Reaching an unwritten slot makes the fact ⊤ too when it would otherwise carry
any members or source ordinals: values can arrive through that slot that
neither the members nor the caller's edges account for, so a non-empty fact
would claim a completeness it does not have. A fact that would be empty stays
empty. `selfId` is removed from the collected members.

-}
sigResolveEdges : Maybe Int -> Array Vars.Variable -> Int -> List Int -> List Vars.Variable -> Engine.S -> ( { top : Bool, members : List Int, sources : List Int }, Engine.S )
sigResolveEdges selfId slots i ms0 srcs s0 =
    case sigEdgesGo slots i srcs [] ms0 [] False s0 of
        ( ( Nothing, _ ), s1 ) ->
            ( { top = True, members = [], sources = [] }, s1 )

        ( ( Just ( members, ordinals ), sawFlex ), s1 ) ->
            let
                filtered =
                    case selfId of
                        Just sid ->
                            List.filter (\mid -> mid /= sid) members

                        Nothing ->
                            members
            in
            if sawFlex && not (List.isEmpty filtered && List.isEmpty ordinals) then
                ( { top = True, members = [], sources = [] }
                , censusMixedSig filtered (Engine.bumpTopMixedFlexSig s1)
                )

            else
                ( { top = False, members = filtered, sources = List.sort ordinals }, s1 )


{-| Counts, under `lss.report`, a fact made ⊤ because it crossed an unwritten
slot, once in total and once by `Engine.membersClass` of the `members` it
would have carried.
-}
censusMixedSig : List Int -> Engine.S -> Engine.S
censusMixedSig members s =
    if not s.env.lss.report then
        s

    else
        s
            |> Engine.bumpArgFlowCensus "mixed|sig"
            |> Engine.bumpArgFlowCensus ("mixed|sig|" ++ Engine.membersClass members s.lssMemberTable)


{-| Follows the deferred edges in `pending`, skipping visited slots, and returns
the members and promoted ordinals collected so far (or `Nothing` once a ⊤ or
non-set slot is reached), with whether an unwritten slot was crossed.
-}
sigEdgesGo : Array Vars.Variable -> Int -> List Vars.Variable -> List Int -> List Int -> List Int -> Bool -> Engine.S -> ( ( Maybe ( List Int, List Int ), Bool ), Engine.S )
sigEdgesGo slots i pending visited accMembers accOrdinals sawFlex s0 =
    case pending of
        [] ->
            ( ( Just ( accMembers, accOrdinals ), sawFlex ), s0 )

        src :: rest ->
            let
                key =
                    Engine.pointKey src
            in
            if List.member key visited then
                sigEdgesGo slots i rest visited accMembers accOrdinals sawFlex s0

            else
                case ordinalOf slots i src s0 of
                    ( Just j, s1 ) ->
                        sigEdgesGo slots
                            i
                            rest
                            (key :: visited)
                            accMembers
                            (if List.member j accOrdinals then
                                accOrdinals

                             else
                                j :: accOrdinals
                            )
                            sawFlex
                            s1

                    ( Nothing, s1 ) ->
                        let
                            ( store1, desc ) =
                                UF.get src s1.store

                            s2 =
                                { s1 | store = store1 }

                            visited1 =
                                key :: visited
                        in
                        case desc.content of
                            Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
                                ( ( Nothing, sawFlex ), s2 )

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
                                sigEdgesGo slots i rest visited1 (IO.unionSortedAsc accMembers ms) accOrdinals sawFlex s2

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms ss)) ->
                                sigEdgesGo slots i (ss ++ rest) visited1 (IO.unionSortedAsc accMembers ms) accOrdinals sawFlex s2

                            Vars.FlexVar _ ->
                                -- Unwritten: no members, but the crossing
                                -- is recorded for `sigResolveEdges`.
                                sigEdgesGo slots i rest visited1 accMembers accOrdinals True s2

                            _ ->
                                -- Not a lambda set: fail toward ⊤.
                                ( ( Nothing, sawFlex ), s2 )


{-| Returns the first ordinal other than `i` whose slot is unified with `node`,
looking at every ordinal, unlike `repOrdinal`, which looks only below `i`.
-}
ordinalOf : Array Vars.Variable -> Int -> Vars.Variable -> Engine.S -> ( Maybe Int, Engine.S )
ordinalOf slots i node s0 =
    ordinalOfGo slots i node 0 s0


{-| Looks for `node` among the slots from ordinal `j` onwards, skipping `i`.
-}
ordinalOfGo : Array Vars.Variable -> Int -> Vars.Variable -> Int -> Engine.S -> ( Maybe Int, Engine.S )
ordinalOfGo slots i node j s0 =
    if j >= Array.length slots then
        ( Nothing, s0 )

    else if j == i then
        ordinalOfGo slots i node (j + 1) s0

    else
        case Array.get j slots of
            Nothing ->
                ( Nothing, s0 )

            Just other ->
                let
                    ( store1, eq ) =
                        UF.equivalent node other s0.store

                    s1 =
                        { s0 | store = store1 }
                in
                if eq then
                    ( Just j, s1 )

                else
                    ordinalOfGo slots i node (j + 1) s1


{-| Builds the fact for a slot resolved by `sigResolveEdges`. A resolved ⊤
becomes a ⊤ fact of the edge kind. More than `lss.maxSetSize` members (when
that is above 0) becomes a ⊤ fact of the widening kind, with its sources
dropped. Otherwise the fact carries the members and source ordinals.
-}
finishSigFact : Int -> { top : Bool, members : List Int, sources : List Int } -> Engine.S -> ( Engine.ArrowFact, Engine.S )
finishSigFact rep resolved s0 =
    if resolved.top then
        -- The ⊤ slot's own kind is not carried back by the edge walk.
        ( { rep = rep, members = [], top = True, topKind = Mono.tkEdge, sources = [] }, s0 )

    else if s0.env.lss.maxSetSize > 0 && List.length resolved.members > s0.env.lss.maxSetSize then
        ( { rep = rep, members = [], top = True, topKind = Mono.tkWiden, sources = [] }
        , Engine.bumpWidenedBySigSize s0
        )

    else
        ( { rep = rep, members = resolved.members, top = False, topKind = Mono.tkLegacy, sources = resolved.sources }, s0 )


{-| Returns the smallest ordinal from `j` up to `i` whose slot is unified with
`slot`, which is `i` itself when none below it is.
-}
repOrdinal : Array Vars.Variable -> Vars.Variable -> Int -> Int -> Engine.S -> ( Int, Engine.S )
repOrdinal slots slot i j s0 =
    if j >= i then
        ( i, s0 )

    else
        case Array.get j slots of
            Nothing ->
                ( i, s0 )

            Just other ->
                let
                    ( store1, eq ) =
                        UF.equivalent other slot s0.store
                in
                if eq then
                    ( j, { s0 | store = store1 } )

                else
                    repOrdinal slots slot i (j + 1) { s0 | store = store1 }



-- ====== THE WALK ======


{-| The names in scope during the walk that have a loaded type: let-bound names,
and the parameters of lambdas and tail-recursive definitions, each mapped to
the Point its type was loaded at. A use of the name joins its own type's set
slots with that Point's.
-}
type alias LetEnv =
    Dict Name Vars.Variable


{-| What the walk of one expression hands its parent: the Point at which it
loaded the expression's type, if any, and whether the sets in that type's slots
can be trusted to list every function the value can hold.

The distinction matters where several values meet in one result, an `if` or
`case` _hub_. Joining a branch whose sets may be incomplete with a branch that
has members would publish a set that looks complete and is not, so the hub
joins its branches only when every branch is honest or a self call, and
otherwise makes its arrows ⊤.

`WpHonest` carries a Point whose sets are complete or ⊤: a lambda literal, a
reference to a named function, a hub, a literal whose arrow-bearing parts are
all honest, or a kernel boundary whose result was made ⊤. A use of a name in
the `LetEnv` is also classed `WpHonest`, whatever its right-hand side was, so
its sets may be incomplete.

`WpOpaque` carries a Point whose sets may be missing members: the result of a
call, whose callee's signature can leave an arrow empty, or a literal with a
part that is not honest. Joining it alone into a slot is still sound, because
an empty set slot is not read as complete.

`WpSelf` is a tail call of the enclosing tail-recursive definition. Its value
is one of the values the other branches produce, so a hub skips it.

`WpNone` has no Point: the value's type has no arrow where one is looked for,
or it is a form the walk does not track, such as a record field access, a
pattern-bound name, an enum or box constructor call, or a literal with LSS
disabled. A hub with such a branch is made ⊤.

-}
type WalkPoint
    = WpNone
    | WpSelf
    | WpHonest Vars.Variable
    | WpOpaque Vars.Variable


{-| Returns the Point a walk point carries, if any.
-}
wpPoint : WalkPoint -> Maybe Vars.Variable
wpPoint wp =
    case wp of
        WpHonest p ->
            Just p

        WpOpaque p ->
            Just p

        WpNone ->
            Nothing

        WpSelf ->
            Nothing


{-| Walks `expr`, writing the set facts it implies into the store, and returns what
it hands its parent.

A lambda literal writes its own member along its type. A reference to a
global, constructor, kernel or accessor writes its member on its type's head
arrow, and for a global or constructor the members of its partial applications
go on the arrows below, up to its declared arity. A call applies its
callee (`walkCall`) and then walks the callee and arguments as values. A `let`
joins the right-hand side's flow into the name's loaded type and walks the body
with the name in scope. An `if` or `case` joins its branches (`joinCfHub`), and
a record, tuple, list or update joins its parts (`walkLiteral`). Anything else
only has its children walked.

-}
walkExpr : LetEnv -> TOpt.Expr TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
walkExpr letEnv expr s0 =
    case expr of
        TOpt.Function srcLam params body meta ->
            walkFunction (List.map Tuple.first params) srcLam body meta letEnv s0

        TOpt.TrackedFunction srcLam params body meta ->
            walkFunction (List.map (\( locName, _ ) -> A.toValue locName) params) srcLam body meta letEnv s0

        TOpt.Call _ func args meta ->
            case walkCall letEnv func args meta s0 of
                ( wp, s1 ) ->
                    case walkChildren letEnv (func :: args) s1 of
                        s2 ->
                            ( wp, s2 )

        TOpt.VarGlobal _ g meta ->
            case kernelAliasOf g s0 of
                Just ( kernelPrefix, home, name ) ->
                    -- A kernel alias is the kernel value, so it gets the
                    -- kernel's `k|` member rather than a `g|` of its own; one
                    -- value with two ids would never read as a singleton.
                    -- The `p|` members below the head are keyed by the alias.
                    withPapSuccessors g
                        (standaloneMemberWith (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta)
                        s0

                Nothing ->
                    case
                        withPapSuccessors g
                            (standaloneMemberWith (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) meta)
                            s0
                    of
                        ( wp, sW ) ->
                            ( wp, sW )

        TOpt.VarEnum _ g _ meta ->
            withPapSuccessors g
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta)
                s0

        TOpt.VarBox _ g meta ->
            withPapSuccessors g
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta)
                s0

        TOpt.VarCycle _ home name meta ->
            -- The `g|` member goes on the head arrow only; the arrows below
            -- hold partial applications, which have `p|` members.
            withPapSuccessors (TOpt.Global home name)
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name)) meta)
                s0

        TOpt.VarKernel _ kernelPrefix home name meta ->
            standaloneMemberWith (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta s0

        TOpt.Accessor _ field meta ->
            standaloneMember ("a|" ++ field) meta s0

        TOpt.VarLocal name meta ->
            joinLetUse letEnv name meta s0

        TOpt.TrackedVarLocal _ name meta ->
            joinLetUse letEnv name meta s0

        TOpt.Let def body _ ->
            case def of
                TOpt.Def _ name rhs defType ->
                    case walkExpr letEnv rhs s0 of
                        ( rhsWp, s1 ) ->
                            case Store.loadTypeS defType s1 of
                                ( rhsVar, s2 ) ->
                                    case sigFlowJoinInto rhsVar (wpPoint rhsWp) s2 of
                                        s3 ->
                                            walkExpr (CoreDict.insert name rhsVar letEnv) body s3

                TOpt.TailDef _ name args rhs defType _ ->
                    -- The rhs is typed at the result while `defType` is the
                    -- whole function type, so the arguments are bound to the
                    -- first arrows and the rhs is joined at the arrow after.
                    case Store.loadTypeS defType s0 of
                        ( rhsVar, s1 ) ->
                            let
                                ( env1, maybeRes, s2 ) =
                                    bindParamsFromSpine
                                        (List.map (\( locName, _ ) -> A.toValue locName) args)
                                        rhsVar
                                        CoreDict.empty
                                        letEnv
                                        s1
                            in
                            case walkExpr env1 rhs s2 of
                                ( rhsWp, s3 ) ->
                                    case ( maybeRes, wpPoint rhsWp ) of
                                        ( Just resVar, Just p ) ->
                                            case joinArrowSetsSig resVar p s3 of
                                                s4 ->
                                                    walkExpr (CoreDict.insert name rhsVar letEnv) body s4

                                        _ ->
                                            walkExpr (CoreDict.insert name rhsVar letEnv) body s3

        TOpt.Destruct _ body _ ->
            walkExpr letEnv body s0

        TOpt.If branches finally meta ->
            case walkIfPairs letEnv branches [] s0 of
                ( branchWps, s1 ) ->
                    case walkExpr letEnv finally s1 of
                        ( finalWp, s2 ) ->
                            joinCfHub (finalWp :: branchWps) meta s2

        TOpt.Case _ _ decider jumps meta ->
            case walkCollect letEnv (deciderExprs decider ++ List.map Tuple.second jumps) [] s0 of
                ( wps, s1 ) ->
                    joinCfHub wps meta s1

        TOpt.TailCall _ tcArgs _ ->
            case walkChildren letEnv (List.map Tuple.second tcArgs) s0 of
                s1 ->
                    ( WpSelf, s1 )

        TOpt.Record fields meta ->
            walkLiteral letEnv "record" (CoreDict.toList fields) Nothing meta expr s0

        TOpt.TrackedRecord _ fields meta ->
            walkLiteral letEnv "record" (List.map (\( ln, e ) -> ( A.toValue ln, e )) (DMap.toList fields)) Nothing meta expr s0

        TOpt.Tuple _ a b rest meta ->
            walkLiteral letEnv "tuple" (List.indexedMap (\i e -> ( String.fromInt i, e )) (a :: b :: rest)) Nothing meta expr s0

        TOpt.List _ items meta ->
            walkLiteral letEnv "list" (List.map (\e -> ( "l", e )) items) Nothing meta expr s0

        TOpt.Update _ record fields meta ->
            walkLiteral letEnv "update" (List.map (\( ln, e ) -> ( A.toValue ln, e )) (DMap.toList fields)) (Just record) meta expr s0

        _ ->
            -- Types inside one definition already share their Points
            -- through the memo, so these forms add no set facts.
            case walkChildren letEnv (directChildren expr) s0 of
                s1 ->
                    ( WpNone, s1 )


{-| Walks a lambda literal: loads its type, writes its raw member id along the
first arrows of that type (one per parameter), binds the parameters to those
arrows' argument types, walks the body, and joins the body's value into the
arrow after the last parameter. The lambda is `WpHonest`.
-}
walkFunction : List Name -> Maybe TypeIds.SrcLambdaId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> LetEnv -> Engine.S -> ( WalkPoint, Engine.S )
walkFunction paramNames srcLam body meta letEnv s0 =
    case Store.loadTypeS meta.tipe s0 of
        ( funcVar, s1 ) ->
            case injectLambdaMember (List.length paramNames) srcLam funcVar s1 of
                s2 ->
                    let
                        ( letEnv1, maybeRes, s3 ) =
                            bindParamsFromSpine paramNames funcVar CoreDict.empty letEnv s2
                    in
                    case walkExpr letEnv1 body s3 of
                        ( wp, s4 ) ->
                            case ( maybeRes, wpPoint wp ) of
                                ( Just resVar, Just bodyPt ) ->
                                    case joinArrowSetsSig resVar bodyPt s4 of
                                        s5 ->
                                            ( WpHonest funcVar, s5 )

                                _ ->
                                    ( WpHonest funcVar, s4 )


{-| Walks a record, tuple, list or record update (`form` names which), whose
parts are `elems`, keyed by field name or position, plus the updated record
`maybeBase`.

With LSS enabled, the literal's type is loaded and each part's value is joined
into the part of that type it fills (`joinLiteralElems`), the updated record
into the whole. The result is `WpHonest` when the base, if any, is honest and
every part whose type mentions an arrow is honest, and `WpOpaque` otherwise.
With LSS disabled only the children are walked, and the result is `WpNone`.

-}
walkLiteral : LetEnv -> String -> List ( String, TOpt.Expr TypeIds.MVarId ) -> Maybe (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
walkLiteral letEnv form elems maybeBase meta expr s0 =
    if not s0.env.lss.enabled then
        case walkChildren letEnv (directChildren expr) s0 of
            s1 ->
                ( WpNone, s1 )

    else
        case walkMaybe letEnv maybeBase s0 of
            ( baseWp, s1 ) ->
                case walkKeyed letEnv elems [] s1 of
                    ( wps, s2 ) ->
                        case Store.loadTypeS meta.tipe s2 of
                            ( litVar, s3 ) ->
                                case joinLiteralBase litVar baseWp s3 of
                                    s4 ->
                                        case joinLiteralElems form litVar wps s4 of
                                            s5 ->
                                                let
                                                    elemHonest ( ( _, e ), wp ) =
                                                        not (canTypeMentionsArrow (TOpt.typeOf e)) || isHonest wp

                                                    baseHonest =
                                                        case ( maybeBase, baseWp ) of
                                                            ( Just _, Just wp ) ->
                                                                isHonest wp

                                                            ( Just _, Nothing ) ->
                                                                False

                                                            ( Nothing, _ ) ->
                                                                True

                                                    honest =
                                                        baseHonest && List.all elemHonest (List.map2 (\e ( _, wp ) -> ( e, wp )) elems wps)
                                                in
                                                ( if honest then
                                                    WpHonest litVar

                                                  else
                                                    WpOpaque litVar
                                                , censusLitFacts form honest s5
                                                )


{-| Tells whether a walk point is `WpHonest`.
-}
isHonest : WalkPoint -> Bool
isHonest wp =
    case wp of
        WpHonest _ ->
            True

        _ ->
            False


{-| Walks the expression, if there is one.
-}
walkMaybe : LetEnv -> Maybe (TOpt.Expr TypeIds.MVarId) -> Engine.S -> ( Maybe WalkPoint, Engine.S )
walkMaybe letEnv maybeExpr s0 =
    case maybeExpr of
        Nothing ->
            ( Nothing, s0 )

        Just e ->
            case walkExpr letEnv e s0 of
                ( wp, s1 ) ->
                    ( Just wp, s1 )


{-| Walks each keyed expression in order, pairing each key with what its walk
returns.
-}
walkKeyed : LetEnv -> List ( String, TOpt.Expr TypeIds.MVarId ) -> List ( String, WalkPoint ) -> Engine.S -> ( List ( String, WalkPoint ), Engine.S )
walkKeyed letEnv elems acc s0 =
    case elems of
        [] ->
            ( List.reverse acc, s0 )

        ( k, e ) :: rest ->
            case walkExpr letEnv e s0 of
                ( wp, s1 ) ->
                    walkKeyed letEnv rest (( k, wp ) :: acc) s1


{-| Joins the updated record's value, when its walk carried a Point, into the
literal's type.
-}
joinLiteralBase : Vars.Variable -> Maybe WalkPoint -> Engine.S -> Engine.S
joinLiteralBase litVar baseWp s0 =
    case Maybe.andThen wpPoint baseWp of
        Just p ->
            joinArrowSetsSig litVar p s0

        Nothing ->
            s0


{-| Joins each part's Point into the part of the literal's loaded type it fills:
a record field by name, a tuple element by position, and every list element
into the list's element type. Aliases are followed. A type of any other shape
is left alone and, under `lss.report`, counted.
-}
joinLiteralElems : String -> Vars.Variable -> List ( String, WalkPoint ) -> Engine.S -> Engine.S
joinLiteralElems form litVar wps s0 =
    case Engine.liftIO (UF.get litVar) s0 of
        ( desc, s1 ) ->
            case desc.content of
                Vars.Alias _ _ _ real ->
                    joinLiteralElems form real wps s1

                Vars.Structure (Vars.Record1 fields _) ->
                    joinKeyedSlots (List.map (\( k, wp ) -> ( CoreDict.get k fields, wp )) wps) s1

                Vars.Structure (Vars.Tuple1 a b rest) ->
                    joinKeyedSlots (List.map2 (\slot ( _, wp ) -> ( Just slot, wp )) (a :: b :: rest) wps) s1

                Vars.Structure (Vars.App1 _ "List" [ elem ]) ->
                    joinKeyedSlots (List.map (\( _, wp ) -> ( Just elem, wp )) wps) s1

                _ ->
                    censusLitShapeMiss form s1


{-| Counts, under `lss.report`, one walked literal of kind `form`, as honest or
opaque.
-}
censusLitFacts : String -> Bool -> Engine.S -> Engine.S
censusLitFacts form honest s =
    if not s.env.lss.report then
        s

    else
        Engine.bumpArgFlowCensus
            ("litFacts|"
                ++ form
                ++ (if honest then
                        "|honest"

                    else
                        "|opaque"
                   )
            )
            s


{-| Counts, under `lss.report`, a literal of kind `form` whose type had no shape
its parts could be joined into.
-}
censusLitShapeMiss : String -> Engine.S -> Engine.S
censusLitShapeMiss form s =
    if not s.env.lss.report then
        s

    else
        Engine.bumpArgFlowCensus ("litFacts|shapeMiss|" ++ form) s


{-| Joins each walk point's Point into its paired slot, skipping pairs where
either is missing.
-}
joinKeyedSlots : List ( Maybe Vars.Variable, WalkPoint ) -> Engine.S -> Engine.S
joinKeyedSlots pairs s0 =
    case pairs of
        [] ->
            s0

        ( maybeSlot, wp ) :: rest ->
            case ( maybeSlot, wpPoint wp ) of
                ( Just slot, Just p ) ->
                    case joinArrowSetsSig slot p s0 of
                        s1 ->
                            joinKeyedSlots rest s1

                _ ->
                    joinKeyedSlots rest s0


{-| Applies the callee of a call to its arguments, returning what the call
hands its parent. The callee and arguments themselves are walked by the caller.

A global or cycle member is applied through its signature (`applyCalleeAt`), a
kernel through what `KernelSetFacts` records about it (`kernelCallBoundary`),
and a let-bound or parameter name through its loaded type (`localCalleeJoin`).
A `Debug` function makes the arrows of every argument and of the result ⊤. An
enum or box constructor, or any other callee not listed, gives `WpNone`.

-}
walkCall : LetEnv -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
walkCall letEnv func args meta s0 =
    case func of
        TOpt.VarGlobal _ g funcMeta ->
            applyCalleeAt g funcMeta.tipe args meta s0

        TOpt.VarCycle _ home name funcMeta ->
            applyCalleeAt (TOpt.Global home name) funcMeta.tipe args meta s0

        TOpt.VarKernel _ kernelPrefix home name funcMeta ->
            kernelCallBoundary kernelPrefix home name funcMeta args meta s0

        TOpt.VarDebug _ _ _ _ _ ->
            poisonCallBoundary args meta s0

        TOpt.VarLocal name _ ->
            localCalleeJoin letEnv name args meta s0

        TOpt.TrackedVarLocal _ name _ ->
            localCalleeJoin letEnv name args meta s0

        TOpt.VarEnum _ _ _ _ ->
            ( WpNone, s0 )

        TOpt.VarBox _ _ _ ->
            -- The payload's members reach the constructed value through
            -- the arguments' walk, not through the callee.
            ( WpNone, s0 )

        _ ->
            ( WpNone, s0 )


{-| Applies the global `g` to `args` at a call of type `meta.tipe`, joining the
callee's parameters with the arguments and its remaining type with the call's,
and writes the `p|` members of a partial application (`injectPapMemberInfer`).
The result is `WpOpaque`, or `WpNone` when the callee is inert
(`calleeInert`).

A member of the unit being inferred is loaded through the shared memo, so the
call unifies with that member's own signature slots. Any other global is
loaded as a fresh instantiation with its signature applied.

-}
applyCalleeAt : TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
applyCalleeAt g funcFallbackType args meta s0 =
    let
        srcType =
            sigSourceTypeFor g funcFallbackType s0
    in
    if HashMap.member TOpt.globalHash (==) g s0.lssInProgress then
        case Store.loadTypeS srcType s0 of
            ( funcVar, s1 ) ->
                case unifyCallShape funcVar args meta s1 of
                    ( callVar, s2 ) ->
                        injectPapMemberInfer g (List.length args) callVar s2

    else
        case signatureFor g s0 of
            ( sig, s1 ) ->
                if calleeInert sig args meta then
                    ( WpNone, Engine.bumpArgFlowCensus "callee|inert" s1 )

                else
                    case instantiateWithSig g sig srcType (Engine.bumpArgFlowCensus "callee|instantiated" s1) of
                        ( funcVar, s2 ) ->
                            case unifyCallShape funcVar args meta s2 of
                                ( callVar, s3 ) ->
                                    injectPapMemberInfer g (List.length args) callVar s3


{-| Tells whether applying a callee could not touch any set slot: its signature
is trivial, so no fact is written, and neither the call's type nor any
argument's type mentions an arrow, so unifying them connects no slot.
-}
calleeInert : Engine.LssSignature -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Bool
calleeInert sig args meta =
    sig.trivial
        && not (canTypeMentionsArrow meta.tipe)
        && List.all (\a -> not (canTypeMentionsArrow (TOpt.typeOf a))) args


{-| Writes the members of a partial application into `callVar`, the loaded type
of a call that supplies `argCount` arguments to `g`, and returns `WpOpaque
callVar`.

When `g`'s declared arity is above `argCount`, the call's value is a partial
application: its head arrow gets the `p|<g>|<argCount>` member, and each arrow
below gets the member of the partial application with one more argument, up to
the declared arity. The `g|` member of `g` itself is never written here, since
it names the unapplied global. Nothing is written with LSS disabled or for a
saturated call.

-}
injectPapMemberInfer : TOpt.Global -> Int -> Vars.Variable -> Engine.S -> ( WalkPoint, Engine.S )
injectPapMemberInfer g argCount callVar s0 =
    if not s0.env.lss.enabled then
        ( WpOpaque callVar, s0 )

    else if declaredArityOf g 8 s0 <= argCount then
        ( WpOpaque callVar, s0 )

    else
        let
            ( mid, sMid ) =
                Engine.papMemberIdFor g argCount s0
        in
        case injectSpineMemberId 1 mid callVar sMid of
            s1 ->
                case injectPapSuccessorsFrom g (argCount + 1) callVar s1 of
                    s2 ->
                        ( WpOpaque callVar, s2 )


{-| Unifies the parameters of the callee type `funcVar` with the arguments'
types, and the rest of the callee type with the call's own type, returning the
call's loaded type. The unifications are best effort, so a mismatch is
discarded.

The callee type is unified whole, so when `funcVar` is a Point shared with
other uses, those uses' types are merged. `applyCalleeAt` relies on this for a
member of the unit being inferred, whose Point comes from the shared memo.

-}
unifyCallShape : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
unifyCallShape funcVar args meta s0 =
    case unifyParamsBestEffort funcVar args s0 of
        ( restVar, s1 ) ->
            case Store.loadTypeS meta.tipe s1 of
                ( callVar, s2 ) ->
                    case Store.unifyBestEffortStoreS restVar callVar s2 of
                        s3 ->
                            ( callVar, s3 )


{-| Counts an application of the arrow whose content is `content`, when
`lss.arrowCensus` is on: every call counts an attempt, then the arrow is
counted as having no set slot, as having a slot with no known `ArrowId`, or as
a hit, which also records its `ArrowId` as applied. The counters themselves are
written only under `lss.report`.

The `ArrowId` is looked up by the slot's union-find representative, not the
slot itself, since the slot recorded at load may since have been unified with
others.

-}
noteApplied : Vars.Content -> Engine.S -> Engine.S
noteApplied content s =
    if not s.env.lss.arrowCensus then
        s

    else
        let
            sA =
                Engine.bumpArgFlowCensus "apply|attempt" s
        in
        case Store.arrowSetSlot content of
            Nothing ->
                Engine.bumpArgFlowCensus "apply|noSlot" sA

            Just pSet ->
                let
                    ( store1, reprVar ) =
                        UF.repr pSet sA.store

                    s1 =
                        { sA | store = store1 }
                in
                case CoreDict.get (Engine.pointKey reprVar) s1.itemAux.arrowOfSlot of
                    Nothing ->
                        Engine.bumpArgFlowCensus "apply|noArrowId" s1

                    Just aid ->
                        Engine.bumpArgFlowCensus "apply|hit" (Engine.bumpAppliedArrow aid s1)


{-| Unifies each argument's type with the parameter of the next arrow of
`funcVar`, best effort, and returns what is left of the callee type after the
last argument, or where it stops being an arrow.

Each argument's type is loaded again from the argument expression's type, not
taken from the argument's walk, so members that walk wrote need not reach the
parameter; a signature can then be empty at a position an argument did feed.

-}
unifyParamsBestEffort : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> ( Vars.Variable, Engine.S )
unifyParamsBestEffort funcVar args s0 =
    case args of
        [] ->
            ( funcVar, s0 )

        arg :: rest ->
            let
                ( store1, desc ) =
                    UF.get funcVar s0.store

                s1 =
                    { s0 | store = store1 }
            in
            case Store.arrowParts desc.content of
                Just ( pParam, pRest ) ->
                    case Store.loadTypeS (TOpt.typeOf arg) (noteApplied desc.content s1) of
                        ( argVar, s2 ) ->
                            case Store.unifyBestEffortStoreS pParam argVar s2 of
                                s3 ->
                                    unifyParamsBestEffort pRest rest s3

                Nothing ->
                    ( funcVar, s1 )


{-| Applies a let-bound or parameter name to `args`: each argument's value flows
into the matching parameter of the name's loaded type (`joinCallArgs`), and,
when the call's type mentions an arrow, the rest of that type flows into the
call's loaded type, which is returned as `WpOpaque`.

The name's Point is shared by all its uses, so only set slots are connected;
the types themselves are never unified. A name not in scope,
a type that runs out of arrows, or an arrow-free call gives `WpNone`.

-}
localCalleeJoin : LetEnv -> Name -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
localCalleeJoin letEnv name args meta s0 =
    case CoreDict.get name letEnv of
        Nothing ->
            ( WpNone, s0 )

        Just fVar ->
            case joinCallArgs fVar args CoreDict.empty s0 of
                ( maybeRest, s1 ) ->
                    case maybeRest of
                        Nothing ->
                            ( WpNone, s1 )

                        Just restVar ->
                            if canTypeMentionsArrow meta.tipe then
                                case Store.loadTypeS meta.tipe s1 of
                                    ( callVar, s2 ) ->
                                        case flowArrowSetsSig restVar callVar s2 of
                                            s3 ->
                                                ( WpOpaque callVar, s3 )

                            else
                                ( WpNone, s1 )


{-| Walks `v`'s arrows one per argument, adding directed set flow from each
argument's loaded type into the parameter, for arguments whose type mentions an
arrow. Returns the rest of the type after the last argument, or `Nothing` when
the type runs out of arrows or an alias leads back to a Point already passed.
-}
joinCallArgs : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Dict Int () -> Engine.S -> ( Maybe Vars.Variable, Engine.S )
joinCallArgs v args seen s0 =
    case args of
        [] ->
            ( Just v, s0 )

        arg :: rest ->
            let
                key =
                    Engine.pointKey v

                ( store1, desc ) =
                    UF.get v s0.store

                s1 =
                    { s0 | store = store1 }
            in
            if CoreDict.member key seen then
                ( Nothing, s1 )

            else
                case desc.content of
                    Vars.Alias _ _ _ real ->
                        joinCallArgs real args (CoreDict.insert key () seen) s1

                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                if canTypeMentionsArrow (TOpt.typeOf arg) then
                                    case Store.loadTypeS (TOpt.typeOf arg) s1 of
                                        ( argVar, s2 ) ->
                                            case flowArrowSetsSig argVar pParam s2 of
                                                s3 ->
                                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s3

                                else
                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s1

                            Nothing ->
                                ( Nothing, s1 )


{-| Applies a kernel to `args` according to what `KernelSetFacts.factFor` records
about it. `funcMeta.tipe` is the kernel's type at this use and `meta.tipe` the
call's.

A kernel with no row, or with a license that `KernelSetFacts.licenseApplies`
rejects at this use's type, is treated as `poisonCallBoundary` treats it. An
`Inert` license gives `WpNone` and touches nothing, since nothing such a kernel
takes or finally returns has an arrow. Any other license loads the kernel's
type as a fresh instantiation and applies it as an ordinary callee with no
signature (`unifyCallShape`), giving `WpOpaque`; this holds for partial and
over-application alike.

A `Positional` row applies only when the call supplies exactly as many
arguments as the row has parameters; otherwise the call is poisoned as for no
row. Each `PSFOpaque` parameter has its argument's arrows made ⊤, and a
`PSFApplies` parameter is left alone. A `PSFOpaque` result has the call's
arrows made ⊤ and gives `WpHonest`; any other result is left unconstrained and
gives `WpNone`.

The `widenedByKernel` counter is bumped once when anything was made ⊤.

-}
kernelCallBoundary : Name -> Name -> Name -> TOpt.Meta TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
kernelCallBoundary prefix home name funcMeta args meta s0 =
    case KernelSetFacts.factFor prefix home name of
        Nothing ->
            poisonCallBoundary args meta s0

        Just (KernelSetFacts.TypeFaithful license) ->
            if not (KernelSetFacts.licenseApplies (Engine.isScalarVar s0) license funcMeta.tipe) then
                -- Used at a type the license does not cover: treated as
                -- having no row.
                poisonCallBoundary args meta s0

            else
                case license.scope of
                    KernelSetFacts.Inert ->
                        -- For a saturated call the result type has no arrow
                        -- either, so a hub this call is a branch of is not
                        -- poisoned by the `WpNone`.
                        ( WpNone, Engine.bumpKernelLicensed s0 )

                    _ ->
                        case Store.loadTypeIsolated funcMeta.tipe s0 of
                            ( funcVar, s1 ) ->
                                case unifyCallShape funcVar args meta s1 of
                                    ( callVar, s2 ) ->
                                        ( WpOpaque callVar, Engine.bumpKernelLicensed s2 )

        Just (KernelSetFacts.Positional plan) ->
            if List.length plan.params /= List.length args then
                poisonCallBoundary args meta s0

            else
                case kernelArgsGo plan.params args False [] s0 of
                    ( ( argPoisoned, tunnelsRev ), s1 ) ->
                        case Store.loadTypeS meta.tipe s1 of
                            ( resVar, s2 ) ->
                                let
                                    resultStep =
                                        case plan.result of
                                            KernelSetFacts.PSFOpaque ->
                                                case Store.poisonArrowSets resVar s2 of
                                                    s3 ->
                                                        ( True, s3 )

                                            _ ->
                                                ( False, s2 )
                                in
                                case resultStep of
                                    ( resPoisoned, s3 ) ->
                                        case joinTunnels resVar (List.reverse tunnelsRev) s3 of
                                            s4 ->
                                                let
                                                    s5 =
                                                        Engine.bumpKernelFactHit
                                                            (if argPoisoned || resPoisoned then
                                                                Engine.bumpWidenedByKernel s4

                                                             else
                                                                s4
                                                            )
                                                in
                                                if resPoisoned then
                                                    ( WpHonest resVar, s5 )

                                                else
                                                    ( WpNone, s5 )


{-| Applies a `Positional` row's parameter flows to the arguments in order, making
the arrows of each `PSFOpaque` argument's loaded type ⊤. Returns whether any
argument was made ⊤, and `tunnelsRev` unchanged, since no flow adds to it.
-}
kernelArgsGo : List KernelSetFacts.ParamSetFlow -> List (TOpt.Expr TypeIds.MVarId) -> Bool -> List Vars.Variable -> Engine.S -> ( ( Bool, List Vars.Variable ), Engine.S )
kernelArgsGo flows args poisoned tunnelsRev s0 =
    case ( flows, args ) of
        ( flow :: fRest, arg :: aRest ) ->
            case flow of
                KernelSetFacts.PSFOpaque ->
                    case Store.loadTypeS (TOpt.typeOf arg) s0 of
                        ( argVar, s1 ) ->
                            case Store.poisonArrowSets argVar s1 of
                                s2 ->
                                    kernelArgsGo fRest aRest True tunnelsRev s2

                KernelSetFacts.PSFApplies ->
                    kernelArgsGo fRest aRest poisoned tunnelsRev s0

        _ ->
            ( ( poisoned, tunnelsRev ), s0 )


{-| Adds directed set flow from each of `vars` into the kernel call's result type
`resVar`.
-}
joinTunnels : Vars.Variable -> List Vars.Variable -> Engine.S -> Engine.S
joinTunnels resVar vars s0 =
    case vars of
        [] ->
            s0

        v :: rest ->
            case flowArrowSetsPlain v resVar s0 of
                s1 ->
                    joinTunnels resVar rest s1


{-| Makes every arrow in each argument's loaded type and in the call's loaded type
⊤, counts the boundary in `widenedByKernel`, and returns the call's type as
`WpHonest`, since ⊤ is complete.
-}
poisonCallBoundary : List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
poisonCallBoundary args meta s0 =
    case poisonArgList args s0 of
        s1 ->
            case Store.loadTypeS meta.tipe s1 of
                ( resVar, s2 ) ->
                    case Store.poisonArrowSets resVar s2 of
                        s3 ->
                            ( WpHonest resVar, Engine.bumpWidenedByKernel s3 )


{-| Makes every arrow in each argument's loaded type ⊤.
-}
poisonArgList : List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
poisonArgList args s0 =
    case args of
        [] ->
            s0

        arg :: rest ->
            case Store.loadTypeS (TOpt.typeOf arg) s0 of
                ( argVar, s1 ) ->
                    case Store.poisonArrowSets argVar s1 of
                        s2 ->
                            poisonArgList rest s2


{-| Writes the member interned for `key` on the head arrow of the referenced
value's type, as `standaloneMemberWith` does. Used for record accessors.
-}
standaloneMember : String -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
standaloneMember key =
    standaloneMemberWith (Engine.memberIdFor key)


{-| Returns the number of parameters `g` is declared with, following at most
`fuel` `Link` nodes.

A constructor gives its arity, which may be 0, and a box gives 1. A definition
whose body is a lambda gives the lambda's parameter count, and a member of a
cycle the count of its own definition. A kernel alias gives the length of the
outer arrow spine of the kernel's type. Every other case, including a
definition with no parameters, an unknown global and running out of fuel,
gives 1.

-}
declaredArityOf : TOpt.Global -> Int -> Engine.S -> Int
declaredArityOf ((TOpt.Global _ name) as g) fuel s =
    declaredArityGo name g fuel s


{-| Does what `declaredArityOf` describes, with `sought` the name first asked
for. A cycle member is a `Link` to its group's node, so the member's own
definition is found in the group by `sought`, which is kept unchanged however
many links are followed.
-}
declaredArityGo : Name -> TOpt.Global -> Int -> Engine.S -> Int
declaredArityGo sought g fuel s =
    if fuel <= 0 then
        1

    else
        case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
            Just (TOpt.Ctor _ arity _) ->
                arity

            Just (TOpt.Box _) ->
                1

            Just (TOpt.Link target) ->
                declaredArityGo sought target (fuel - 1) s

            Just (TOpt.Define (TOpt.Function _ params _ _) _ _) ->
                List.length params

            Just (TOpt.TrackedDefine _ (TOpt.Function _ params _ _) _ _) ->
                List.length params

            Just (TOpt.Define (TOpt.TrackedFunction _ params _ _) _ _) ->
                List.length params

            Just (TOpt.TrackedDefine _ (TOpt.TrackedFunction _ params _ _) _ _) ->
                List.length params

            Just (TOpt.Cycle _ _ funcDefs _) ->
                cycleDefArity sought funcDefs

            -- A kernel alias has no lambda to count, so its arity is the
            -- kernel type's outer arrow spine. For a definition that spine
            -- would also count the arrows of a returned function.
            Just (TOpt.Define (TOpt.VarKernel _ _ _ _ kernelMeta) _ _) ->
                canTypeArrowSpine kernelMeta.tipe

            Just (TOpt.TrackedDefine _ (TOpt.VarKernel _ _ _ _ kernelMeta) _ _) ->
                canTypeArrowSpine kernelMeta.tipe

            _ ->
                1


{-| Returns the number of arrows along a canonical type's outer spine, following
aliases: 2 for `a -> b -> c`, and 3 for `(a -> b) -> List a -> List b -> c`.
-}
canTypeArrowSpine : Can.Type TypeIds.MVarId -> Int
canTypeArrowSpine t =
    case t of
        Can.TLambda _ _ to ->
            1 + canTypeArrowSpine to

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeArrowSpine real

        Can.TAlias _ _ _ (Can.Holey real) ->
            canTypeArrowSpine real

        _ ->
            0


{-| Returns the parameter count of the function definition named `sought` in a
cycle: the lambda's parameter count for a definition whose body is a lambda,
and the argument count for a tail-recursive one. A definition whose body is not
a lambda, or a name not among `funcDefs`, gives 1.
-}
cycleDefArity : Name -> List (TOpt.Def TypeIds.MVarId) -> Int
cycleDefArity sought funcDefs =
    let
        fromFunc =
            List.foldl
                (\def acc ->
                    case acc of
                        Just _ ->
                            acc

                        Nothing ->
                            case def of
                                TOpt.Def _ n body _ ->
                                    if n == sought then
                                        case body of
                                            TOpt.Function _ params _ _ ->
                                                Just (List.length params)

                                            TOpt.TrackedFunction _ params _ _ ->
                                                Just (List.length params)

                                            _ ->
                                                Just 1

                                    else
                                        Nothing

                                TOpt.TailDef _ n args _ _ _ ->
                                    if n == sought then
                                        Just (List.length args)

                                    else
                                        Nothing
                )
                Nothing
                funcDefs
    in
    case fromFunc of
        Just arity ->
            arity

        Nothing ->
            1


{-| Returns the kernel's prefix, home and name when `g`, after following `Link`
nodes, is a _kernel alias_: a definition whose body is exactly a reference to a
kernel, such as `cons = Elm.Kernel.List.cons`. A reference to such a global is
a reference to the kernel value.
-}
kernelAliasOf : TOpt.Global -> Engine.S -> Maybe ( Name, Name, Name )
kernelAliasOf g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Define (TOpt.VarKernel _ kernelPrefix home name _) _ _) ->
            Just ( kernelPrefix, home, name )

        Just (TOpt.TrackedDefine _ (TOpt.VarKernel _ kernelPrefix home name _) _ _) ->
            Just ( kernelPrefix, home, name )

        Just (TOpt.Link target) ->
            kernelAliasOf target s

        _ ->
            Nothing


{-| Walks a reference to a named function value whose type is `meta.tipe`: when
that type is an arrow, mints its member with `mint`, writes it on the head
arrow of the loaded type, and returns that type as `WpHonest`. Otherwise
nothing is minted and the result is `WpNone`.

Only the head arrow is written. A name, unlike a lambda literal, has no
parameter count at hand, and the arrows below the head hold partial
applications or a returned function, which are other values.

-}
standaloneMemberWith : (Engine.S -> ( Int, Engine.S )) -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
standaloneMemberWith mint meta s0 =
    if canTypeIsArrow meta.tipe then
        case mint s0 of
            ( mid, s1 ) ->
                case Store.loadTypeS meta.tipe s1 of
                    ( funcVar, s2 ) ->
                        case injectSpineMemberId 1 mid funcVar s2 of
                            s3 ->
                                ( WpHonest funcVar, s3 )

    else
        ( WpNone, s0 )


{-| Runs `step`, a reference's walk, and when it returns a `WpHonest` type writes
`g`'s partial-application members below that type's head arrow
(`injectPapSuccessors`).
-}
withPapSuccessors : TOpt.Global -> (Engine.S -> ( WalkPoint, Engine.S )) -> Engine.S -> ( WalkPoint, Engine.S )
withPapSuccessors g step s0 =
    case step s0 of
        ( wp, s1 ) ->
            case wp of
                WpHonest funcVar ->
                    case injectPapSuccessors g funcVar s1 of
                        s2 ->
                            ( wp, s2 )

                _ ->
                    ( wp, s1 )


{-| Returns the member key `p|<global>|<supplied>` of a partial application of
a global, as `Engine.papMemberKey` builds it. Each number of supplied arguments
is a different value, and none is the global itself.
-}
papMemberKey : TOpt.Global -> Int -> String
papMemberKey =
    Engine.papMemberKey


{-| Writes, below the head arrow of `v0`, the members of the partial
applications of `g` with `startDepth`, `startDepth + 1`, ... arguments
supplied, one per arrow, up to `g`'s declared arity less one.

`v0` is the type of a partial application of `g` with `startDepth - 1`
arguments, whose own member is on its head arrow; each arrow below holds the
value one more argument further in. Nothing is written with LSS disabled or
when `startDepth` reaches the declared arity.

-}
injectPapSuccessorsFrom : TOpt.Global -> Int -> Vars.Variable -> Engine.S -> Engine.S
injectPapSuccessorsFrom g startDepth v0 s0 =
    if not s0.env.lss.enabled then
        s0

    else
        let
            arity =
                declaredArityOf g 8 s0
        in
        if startDepth >= arity then
            s0

        else
            case mintPapSuccessorIds g startDepth arity [] s0 of
                ( midsRev, s1 ) ->
                    Store.foldSetWrites
                        (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                        (Engine.bumpArgFlowCensus "papInject|deepDone" s1)


{-| Writes, below the head arrow of `v0`, the type of a reference to `g`, the
member `p|<g>|<d>` on the arrow at depth `d`, for `d` from 1 to `g`'s declared
arity less one. The arrow at depth `d` holds `g` with `d` arguments supplied,
which is a partial application; the arrows past the declared arity hold what
`g`'s body returns, and are not written.

Nothing is written with LSS disabled or for a declared arity of 1 or less.

-}
injectPapSuccessors : TOpt.Global -> Vars.Variable -> Engine.S -> Engine.S
injectPapSuccessors g v0 s0 =
    if not s0.env.lss.enabled then
        s0

    else
        let
            arity =
                declaredArityOf g 8 s0
        in
        if arity <= 1 then
            Engine.bumpArgFlowCensus "refspine|arity1" s0

        else
            case mintPapSuccessorIds g 1 arity [] s0 of
                ( midsRev, s1 ) ->
                    Store.foldSetWrites
                        (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                        (Engine.bumpArgFlowCensus "refspine|inject" s1)


{-| Writes the same members `injectPapSuccessors` writes, bounded by `arity`,
the parameter count of `g`'s root lambda, instead of by `g`'s declared arity.
Nothing is written for an arity of 1 or less.
-}
injectFoldedSuccessors : TOpt.Global -> Int -> Vars.Variable -> Engine.S -> Engine.S
injectFoldedSuccessors g arity v0 s0 =
    if arity <= 1 then
        Engine.bumpArgFlowCensus "rootFold|spineHeadOnly" s0

    else
        case mintPapSuccessorIds g 1 arity [] s0 of
            ( midsRev, s1 ) ->
                Store.foldSetWrites
                    (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                    (Engine.bumpArgFlowCensus "rootFold|spineDepth" s1)


{-| Mints the partial-application member ids of `g` for `d` up to `arity` less
one, prepending each to `acc`, so the result is deepest first.
-}
mintPapSuccessorIds : TOpt.Global -> Int -> Int -> List Int -> Engine.S -> ( List Int, Engine.S )
mintPapSuccessorIds g d arity acc s0 =
    if d >= arity then
        ( acc, s0 )

    else
        case Engine.papMemberIdFor g d s0 of
            ( mid, s1 ) ->
                mintPapSuccessorIds g (d + 1) arity (mid :: acc) s1


{-| Writes `mids`, shallowest first, down the result chain of `v`: the first
goes on the arrow that is `v`'s result, the next on that arrow's result, and so
on. Aliases are followed without using a member. The walk stops at a result
that is not an arrow with a set slot, or at a Point it has already passed.
-}
papSuccGoC : List Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
papSuccGoC mids seen v c0 =
    case mids of
        [] ->
            c0

        mid :: rest ->
            let
                key =
                    Engine.pointKey v
            in
            if CoreDict.member key seen then
                c0

            else
                let
                    ( store1, desc ) =
                        UF.get v c0.store

                    c1 =
                        { c0 | store = store1 }

                    seen1 =
                        CoreDict.insert key () seen
                in
                case desc.content of
                    Vars.Structure (Vars.FunL _ res _) ->
                        papSuccWrite mid rest seen1 res c1

                    Vars.Alias _ _ _ real ->
                        papSuccGoC mids seen1 real c1

                    _ ->
                        c1


{-| Writes `mid` on `res` when it is an arrow with a set slot, following aliases,
and continues `papSuccGoC` from it with the rest of the members.
-}
papSuccWrite : Int -> List Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
papSuccWrite mid rest seen res c0 =
    let
        key =
            Engine.pointKey res
    in
    if CoreDict.member key seen then
        c0

    else
        let
            ( store1, desc ) =
                UF.get res c0.store

            c1 =
                { c0 | store = store1 }

            seen1 =
                CoreDict.insert key () seen
        in
        case desc.content of
            Vars.Structure (Vars.FunL _ _ slot) ->
                -- `seen`, not `seen1`: `papSuccGoC` adds `res` itself when
                -- it enters, and would stop at once if `res` were already in.
                papSuccGoC rest seen res (Store.unifySlotWithSetC Nothing [ mid ] slot c1)

            Vars.Alias _ _ _ real ->
                papSuccWrite mid rest seen1 real c1

            _ ->
                c1


{-| Writes the member `mid` into the set slots of the first `arity` arrows along
`v0`'s result chain: `v0` itself, its result, that arrow's result, and so on.
Aliases are followed without counting an arrow, and the walk stops early at a
result that is not an arrow with a set slot, or at a Point already passed.

A value applied to fewer arguments than its parameter count is, for this
purpose, the same value, so `mid` names those arrows too. The bound matters
because a type cannot tell parameters from a returned function:
`f : Int -> (Int -> Int)` with one parameter returns some other function at its
second arrow, which `mid` must not name. Argument arrows are never written;
they hold the caller's values.

Writes merge with what the slot holds, as `Store.unifySlotWithSet` describes.

-}
injectSpineMemberId : Int -> Int -> Vars.Variable -> Engine.S -> Engine.S
injectSpineMemberId arity mid v0 s0 =
    spineGo mid arity CoreDict.empty v0 s0


{-| Does what `injectSpineMemberId` describes, with `remaining` arrows still to
write and the Points in `seen` already passed.
-}
spineGo : Int -> Int -> Dict Int () -> Vars.Variable -> Engine.S -> Engine.S
spineGo mid remaining seen v s0 =
    Store.foldSetWrites (spineGoC mid remaining seen v (Store.setWriteCtx (Store.qOnFor s0) s0.store)) s0


{-| Does what `spineGo` does on a set-write context, so that the whole walk is
written back to the state once.
-}
spineGoC : Int -> Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
spineGoC mid remaining seen v c0 =
    if remaining <= 0 then
        c0

    else
        let
            key =
                Engine.pointKey v
        in
        if CoreDict.member key seen then
            c0

        else
            let
                ( store1, desc ) =
                    UF.get v c0.store

                c1 =
                    { c0 | store = store1 }
            in
            case desc.content of
                Vars.Structure (Vars.FunL _ res slot) ->
                    spineGoC mid (remaining - 1) (CoreDict.insert key () seen) res (Store.unifySlotWithSetC Nothing [ mid ] slot c1)

                Vars.Alias _ _ _ real ->
                    spineGoC mid remaining (CoreDict.insert key () seen) real c1

                _ ->
                    c1


{-| Walks a use of the name `name`: when it is in the `LetEnv` and its type
mentions an arrow, loads the use's type, joins it with the name's bound Point,
and returns it as `WpHonest`. Otherwise the result is `WpNone`.
-}
joinLetUse : LetEnv -> Name -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
joinLetUse letEnv name meta s0 =
    case CoreDict.get name letEnv of
        Nothing ->
            ( WpNone, s0 )

        Just rhsVar ->
            if not (canTypeMentionsArrow meta.tipe) then
                -- An arrow-free join would write no slot.
                ( WpNone, s0 )

            else
                case Store.loadTypeS meta.tipe s0 of
                    ( useVar, s1 ) ->
                        case joinArrowSets identity rhsVar useVar s1 of
                            s2 ->
                                ( WpHonest useVar, s2 )


{-| Walks the types `a` and `b` side by side and unifies the set slots of the
arrows found at matching positions, without unifying the types themselves.

Where the two sides stop matching, because one is a type variable, they are
arrows of different kinds, or they have different shapes, every arrow set under
both is made ⊤ and `onPoison` is applied, and that branch is not walked
further. An empty record against any other structure, or unit against unit,
matches with nothing to join.
Aliases are followed. Records join only the fields they share, then their
extensions.

-}
joinArrowSets : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
joinArrowSets onPoison a b s0 =
    let
        ( store1, descA ) =
            UF.get a s0.store

        ( store2, descB ) =
            UF.get b store1

        s1 =
            { s0 | store = store2 }
    in
    case ( descA.content, descB.content ) of
        ( Vars.Structure flatA, Vars.Structure flatB ) ->
            case ( flatA, flatB ) of
                ( Vars.FunL argA resA slotA, Vars.FunL argB resB slotB ) ->
                    case Store.unifyBestEffortStoreS slotA slotB s1 of
                        s2 ->
                            case joinArrowSets onPoison argA argB s2 of
                                s3 ->
                                    joinArrowSets onPoison resA resB s3

                ( Vars.Fun1 argA resA, Vars.Fun1 argB resB ) ->
                    case joinArrowSets onPoison argA argB s1 of
                        s2 ->
                            joinArrowSets onPoison resA resB s2

                ( Vars.App1 _ _ argsA, Vars.App1 _ _ argsB ) ->
                    joinArrowSetsList onPoison argsA argsB s1

                ( Vars.Tuple1 a1 b1 restA, Vars.Tuple1 a2 b2 restB ) ->
                    joinArrowSetsList onPoison (a1 :: b1 :: restA) (a2 :: b2 :: restB) s1

                ( Vars.Record1 fieldsA extA, Vars.Record1 fieldsB extB ) ->
                    let
                        shared =
                            CoreDict.merge
                                (\_ _ acc -> acc)
                                (\_ va vb acc -> ( va, vb ) :: acc)
                                (\_ _ acc -> acc)
                                fieldsA
                                fieldsB
                                []
                    in
                    case joinArrowSetsPairs onPoison shared s1 of
                        s2 ->
                            joinArrowSets onPoison extA extB s2

                ( Vars.EmptyRecord1, _ ) ->
                    s1

                ( _, Vars.EmptyRecord1 ) ->
                    s1

                ( Vars.Unit1, Vars.Unit1 ) ->
                    s1

                _ ->
                    poisonBoth onPoison a b s1

        ( Vars.Alias _ _ _ realA, _ ) ->
            joinArrowSets onPoison realA b s1

        ( _, Vars.Alias _ _ _ realB ) ->
            joinArrowSets onPoison a realB s1

        _ ->
            poisonBoth onPoison a b s1


{-| Does what `joinArrowSets` does, counting each place it makes sets ⊤ in
`widenedByCf` under `lss.report`.
-}
joinArrowSetsSig : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
joinArrowSetsSig =
    joinArrowSets Engine.bumpWidenedByCf


{-| Makes the functions held by the type `src` flow into the type `dst`: walks
both side by side and, at each pair of matching arrows, adds a deferred
inclusion edge from `src`'s set slot to `dst`'s (`Store.addSlotSource`), so
`dst`'s set includes `src`'s without the two being made equal.

Results are walked in the same direction and arguments in the opposite one,
since the functions a caller of `dst` passes in reach `src`'s parameters. At a
custom type, tuple or record the variance of the parts is not known, so the
whole of that part is joined symmetrically by `joinArrowSets` instead. A
mismatch, an alias, an empty record or unit is handled as `joinArrowSets`
handles it.

-}
flowArrowSets : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
flowArrowSets onPoison src dst s0 =
    let
        ( store1, descS ) =
            UF.get src s0.store

        ( store2, descD ) =
            UF.get dst store1

        s1 =
            { s0 | store = store2 }
    in
    case ( descS.content, descD.content ) of
        ( Vars.Structure flatS, Vars.Structure flatD ) ->
            case ( flatS, flatD ) of
                ( Vars.FunL argS resS slotS, Vars.FunL argD resD slotD ) ->
                    case Store.addSlotSource slotS slotD s1 of
                        s2 ->
                            case flowArrowSets onPoison resS resD s2 of
                                s3 ->
                                    flowArrowSets onPoison argD argS s3

                ( Vars.Fun1 argS resS, Vars.Fun1 argD resD ) ->
                    case flowArrowSets onPoison resS resD s1 of
                        s2 ->
                            flowArrowSets onPoison argD argS s2

                ( Vars.App1 _ _ _, Vars.App1 _ _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.Tuple1 _ _ _, Vars.Tuple1 _ _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.Record1 _ _, Vars.Record1 _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.EmptyRecord1, _ ) ->
                    s1

                ( _, Vars.EmptyRecord1 ) ->
                    s1

                ( Vars.Unit1, Vars.Unit1 ) ->
                    s1

                _ ->
                    poisonBoth onPoison src dst s1

        ( Vars.Alias _ _ _ realS, _ ) ->
            flowArrowSets onPoison realS dst s1

        ( _, Vars.Alias _ _ _ realD ) ->
            flowArrowSets onPoison src realD s1

        _ ->
            poisonBoth onPoison src dst s1


{-| Joins `src` and `dst` symmetrically with `joinArrowSets`, counting the join
in `flowDegraded` under `lss.report` when `src` mentions an arrow.
-}
degradeToSymmetric : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
degradeToSymmetric onPoison src dst s0 =
    case storeMentionsArrow src s0 of
        ( carries, s1 ) ->
            joinArrowSets onPoison
                src
                dst
                (if carries then
                    Engine.bumpFlowDegraded s1

                 else
                    s1
                )


{-| Tells whether the type in the store under `root` contains an arrow, with or
without a set slot, looking through type arguments, tuples, records and
aliases, and visiting each Point once.
-}
storeMentionsArrow : Vars.Variable -> Engine.S -> ( Bool, Engine.S )
storeMentionsArrow root s0 =
    storeMentionsArrowGo [ root ] [] s0


{-| Does what `storeMentionsArrow` does for the Points in `pending`, skipping those
in `visited`.
-}
storeMentionsArrowGo : List Vars.Variable -> List Int -> Engine.S -> ( Bool, Engine.S )
storeMentionsArrowGo pending visited s0 =
    case pending of
        [] ->
            ( False, s0 )

        v :: rest ->
            let
                key =
                    Engine.pointKey v
            in
            if List.member key visited then
                storeMentionsArrowGo rest visited s0

            else
                let
                    ( store1, desc ) =
                        UF.get v s0.store

                    s1 =
                        { s0 | store = store1 }

                    visited1 =
                        key :: visited
                in
                case desc.content of
                    Vars.Structure (Vars.FunL _ _ _) ->
                        ( True, s1 )

                    Vars.Structure (Vars.Fun1 _ _) ->
                        ( True, s1 )

                    Vars.Structure (Vars.App1 _ _ args) ->
                        storeMentionsArrowGo (args ++ rest) visited1 s1

                    Vars.Structure (Vars.Tuple1 a b more) ->
                        storeMentionsArrowGo (a :: b :: more ++ rest) visited1 s1

                    Vars.Structure (Vars.Record1 fields ext) ->
                        storeMentionsArrowGo (CoreDict.values fields ++ (ext :: rest)) visited1 s1

                    Vars.Alias _ _ _ real ->
                        storeMentionsArrowGo (real :: rest) visited1 s1

                    _ ->
                        storeMentionsArrowGo rest visited1 s1


{-| Does what `flowArrowSets` does, counting each place it makes sets ⊤ in
`widenedByCf` under `lss.report`.
-}
flowArrowSetsSig : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
flowArrowSetsSig =
    flowArrowSets Engine.bumpWidenedByCf


{-| Makes the functions held by the type `src` flow into the type `dst`, as a
directed inclusion: at each pair of matching arrows, `dst`'s set comes to
include `src`'s. Results flow in the same direction and arguments in the
opposite one. Inside a custom type, tuple or record the parts are joined
symmetrically, and where the two types stop matching every arrow set under both
is made ⊤.
-}
flowArrowSetsPlain : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
flowArrowSetsPlain =
    flowArrowSets identity


{-| Joins `maybePoint`, when there is one, into `target`, with
`joinArrowSetsSig`.
-}
sigFlowJoinInto : Vars.Variable -> Maybe Vars.Variable -> Engine.S -> Engine.S
sigFlowJoinInto target maybePoint s0 =
    case maybePoint of
        Just p ->
            joinArrowSetsSig target p s0

        Nothing ->
            s0


{-| Joins the two lists' Points pairwise, ignoring the longer list's extra
Points.
-}
joinArrowSetsList : (Engine.S -> Engine.S) -> List Vars.Variable -> List Vars.Variable -> Engine.S -> Engine.S
joinArrowSetsList onPoison xs ys s0 =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            case joinArrowSets onPoison x y s0 of
                s1 ->
                    joinArrowSetsList onPoison xr yr s1

        _ ->
            s0


{-| Joins each pair of Points.
-}
joinArrowSetsPairs : (Engine.S -> Engine.S) -> List ( Vars.Variable, Vars.Variable ) -> Engine.S -> Engine.S
joinArrowSetsPairs onPoison pairs s0 =
    case pairs of
        [] ->
            s0

        ( x, y ) :: rest ->
            case joinArrowSets onPoison x y s0 of
                s1 ->
                    joinArrowSetsPairs onPoison rest s1


{-| Makes every arrow set under `a` and under `b` ⊤, then applies `onPoison`
once.
-}
poisonBoth : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
poisonBoth onPoison a b s0 =
    case Store.poisonArrowSets a s0 of
        s1 ->
            case Store.poisonArrowSets b s1 of
                s2 ->
                    onPoison s2


{-| Returns the number of arrows along a canonical type's outer spine: 2 for
`a -> (Int -> b)`. Aliases are followed only when they are `Filled`; a `Holey`
alias counts as no arrow.
-}
canTypeArrowDepth : Can.Type TypeIds.MVarId -> Int
canTypeArrowDepth t =
    case t of
        Can.TLambda _ _ res ->
            1 + canTypeArrowDepth res

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeArrowDepth real

        _ ->
            0


{-| Tells whether a canonical type is an arrow, following `Filled` aliases only.
-}
canTypeIsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeIsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeIsArrow real

        _ ->
            False


{-| Tells whether a canonical type contains an arrow anywhere, looking through
type arguments, records, tuples, and both the body and the arguments of an
alias. A type variable counts as no arrow, though it may stand for a function.
-}
canTypeMentionsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeMentionsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.any canTypeMentionsArrow typeArgs

        Can.TRecord fields _ ->
            CoreDict.foldl (\_ (Can.FieldType _ ft) acc -> acc || canTypeMentionsArrow ft) False fields

        Can.TUnit ->
            False

        Can.TTuple a b rest ->
            canTypeMentionsArrow a || canTypeMentionsArrow b || List.any canTypeMentionsArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeMentionsArrow real || List.any (\( _, at ) -> canTypeMentionsArrow at) aliasArgs

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeMentionsArrow real || List.any (\( _, at ) -> canTypeMentionsArrow at) aliasArgs


{-| Binds each of `names` in `letEnv` to the argument type of the next arrow along
`v`'s spine, following aliases. Returns the extended environment and the rest
of the type after the last name, or `Nothing` with only the names bound so far
when the spine runs out of arrows or an alias leads back to a Point already
passed. The store is read, not written.
-}
bindParamsFromSpine : List Name -> Vars.Variable -> Dict Int () -> LetEnv -> Engine.S -> ( LetEnv, Maybe Vars.Variable, Engine.S )
bindParamsFromSpine names v seen letEnv s0 =
    case names of
        [] ->
            ( letEnv, Just v, s0 )

        n :: rest ->
            let
                key =
                    Engine.pointKey v

                ( store1, desc ) =
                    UF.get v s0.store

                s1 =
                    { s0 | store = store1 }
            in
            if CoreDict.member key seen then
                ( letEnv, Nothing, s1 )

            else
                case desc.content of
                    Vars.Alias _ _ _ real ->
                        bindParamsFromSpine names real (CoreDict.insert key () seen) letEnv s1

                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                bindParamsFromSpine rest
                                    pRest
                                    (CoreDict.insert key () seen)
                                    (CoreDict.insert n pParam letEnv)
                                    s1

                            Nothing ->
                                ( letEnv, Nothing, s1 )


{-| Joins the branches of an `if` or `case` whose result type is `meta.tipe`
into one loaded result type, the hub, and returns it as `WpHonest`.

When every branch is `WpHonest` or `WpSelf`, each honest branch's functions
flow into the hub (`flowArrowSets`), so the hub's sets are the union of the
branches'. Otherwise the hub's arrows are made ⊤ and counted in `widenedByCf`
under `lss.report`, since a branch that may be incomplete would make that union
look complete when it is not. A result type with no arrow gives `WpNone` and
loads nothing.

-}
joinCfHub : List WalkPoint -> TOpt.Meta TypeIds.MVarId -> Engine.S -> ( WalkPoint, Engine.S )
joinCfHub wps meta s0 =
    if not (canTypeMentionsArrow meta.tipe) then
        ( WpNone, s0 )

    else
        case Store.loadTypeS meta.tipe s0 of
            ( hub, s1 ) ->
                if List.all hubHonest wps then
                    -- Directed at the arrows of the result's spine; inside
                    -- a container the join is symmetric.
                    case flowAllSig hub (List.filterMap wpPoint wps) s1 of
                        s2 ->
                            ( WpHonest hub, s2 )

                else
                    case Store.poisonArrowSets hub s1 of
                        s2 ->
                            ( WpHonest hub, Engine.bumpWidenedByCf s2 )


{-| Tells whether a branch can be joined into a hub: an honest branch or a self
call.
-}
hubHonest : WalkPoint -> Bool
hubHonest wp =
    case wp of
        WpHonest _ ->
            True

        WpSelf ->
            True

        WpOpaque _ ->
            False

        WpNone ->
            False


{-| Makes each of `pts` flow into `hub` with `flowArrowSetsSig`.
-}
flowAllSig : Vars.Variable -> List Vars.Variable -> Engine.S -> Engine.S
flowAllSig hub pts s0 =
    case pts of
        [] ->
            s0

        p :: rest ->
            case flowArrowSetsSig p hub s0 of
                s1 ->
                    flowAllSig hub rest s1


{-| Walks each condition and branch of an `if` in order, prepending each branch's
walk point to `acc`.
-}
walkIfPairs : LetEnv -> List ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> List WalkPoint -> Engine.S -> ( List WalkPoint, Engine.S )
walkIfPairs letEnv pairs acc s0 =
    case pairs of
        [] ->
            ( acc, s0 )

        ( cond, branch ) :: rest ->
            case walkExpr letEnv cond s0 of
                ( _, s1 ) ->
                    case walkExpr letEnv branch s1 of
                        ( wp, s2 ) ->
                            walkIfPairs letEnv rest (wp :: acc) s2


{-| Walks each expression in order, prepending its walk point to `acc`.
-}
walkCollect : LetEnv -> List (TOpt.Expr TypeIds.MVarId) -> List WalkPoint -> Engine.S -> ( List WalkPoint, Engine.S )
walkCollect letEnv exprs acc s0 =
    case exprs of
        [] ->
            ( acc, s0 )

        e :: rest ->
            case walkExpr letEnv e s0 of
                ( wp, s1 ) ->
                    walkCollect letEnv rest (wp :: acc) s1



-- ====== STRUCTURAL CHILD FOLDS ======


{-| Walks each expression in order, discarding what the walks return.
-}
walkChildren : LetEnv -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
walkChildren letEnv exprs s0 =
    case exprs of
        [] ->
            s0

        e :: rest ->
            case walkExpr letEnv e s0 of
                ( _, s1 ) ->
                    walkChildren letEnv rest s1


{-| Returns the immediate subexpressions of `expr`. For a `case` these are the
expressions inlined in its decision tree's leaves and the bodies of its
shared branches.
-}
directChildren : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
directChildren expr =
    case expr of
        TOpt.Bool _ _ _ ->
            []

        TOpt.Chr _ _ _ ->
            []

        TOpt.Str _ _ _ ->
            []

        TOpt.Int _ _ _ ->
            []

        TOpt.Float _ _ _ ->
            []

        TOpt.VarLocal _ _ ->
            []

        TOpt.TrackedVarLocal _ _ _ ->
            []

        TOpt.VarGlobal _ _ _ ->
            []

        TOpt.VarEnum _ _ _ _ ->
            []

        TOpt.VarBox _ _ _ ->
            []

        TOpt.VarCycle _ _ _ _ ->
            []

        TOpt.VarDebug _ _ _ _ _ ->
            []

        TOpt.VarKernel _ _ _ _ _ ->
            []

        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ func args _ ->
            func :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches finally _ ->
            List.concatMap (\( c, b ) -> [ c, b ]) branches ++ [ finally ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ rhs _ ->
                    [ rhs ]

                TOpt.TailDef _ _ _ rhs _ _ ->
                    [ rhs ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderExprs decider ++ List.map Tuple.second jumps

        TOpt.Accessor _ _ _ ->
            []

        TOpt.Access record _ _ _ ->
            [ record ]

        TOpt.Update _ record fields _ ->
            record :: DMap.values fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            DMap.values fields

        TOpt.Unit _ ->
            []

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        TOpt.Shader _ _ _ _ ->
            []


{-| Returns the expressions inlined in a decision tree's leaves; a leaf that jumps
to a shared branch contributes none.
-}
deciderExprs : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderExprs decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline e ->
                    [ e ]

                TOpt.Jump _ ->
                    []

        TOpt.Chain _ success failure ->
            deciderExprs success ++ deciderExprs failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> deciderExprs d) edges ++ deciderExprs fallback
