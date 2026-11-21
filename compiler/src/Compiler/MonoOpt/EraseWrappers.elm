module Compiler.MonoOpt.EraseWrappers exposing
    ( EraseStats, emptyStats, erase, eraseKeeping, check, renderStats
    , Plan, plan, noPlan, Rewritten, rewriteNodes, finish
    , Erasable, erasableFromList, erasableSize, erasableIsEmpty, isErasable, eraseType, translateKv, consistentWith
    )

{-| Erases wrapper types (plans/constructor-representation-levels.md §6, units E1a
and E1b): a value of a custom type with exactly one constructor of exactly one
field, `type W a = C payload`, is represented as its field. This is Elm's own
`Unbox` optimization (`Can.Unbox`), which the JS back end already applies.

The pass runs on the monomorphized graph, before inlining. It

  - chooses the wrapper type constructors it may erase (`choose`): those whose
    every instantiation the graph reaches has one constructor of one field,
    that are not kernel-visible (`Compiler.MonoOpt.KernelVisible`), none of
    whose instantiations is ever viewed through a type variable (an erased view
    reads a value untyped, so `Debug.toString` used as a function value would
    print the bare field), that are not on a cycle of wrappers (erasing `type T = T (List T)` would make the
    type infinite), and, unless `allowUnboxed`, whose field is boxed in every
    instantiation (an `Int`, `Float` or `Char` field would make the erased
    value an unboxed one, which an erased view of it could not read);
  - records the printed type of every `Debug.log` and `Debug.toString` call
    whose argument mentions an erased type in the call's `printType`, so that
    the type table can still print the constructor (MONO_031);
  - replaces each saturated call of an erased constructor by its argument,
    drops each `MonoUnbox`/`DtUnbox` step out of an erased type, and turns each
    erased constructor's node into the identity function at the same SpecId,
    so that every reference to it stays valid and first-class uses such as
    `List.map W` call the identity, which inlining then removes;
  - rewrites every type in the graph with `eraseType`, rebuilds `ctorShapes`
    without the erased types, and keeps the old shapes and the erased types
    in the graph's `repr` for the type table.

With `allowUnboxed` (E1b) a wrapper whose field is unboxed in some
instantiation is erased per instantiation instead: `meetsOk` is given the
tentative set of erased instantiations and returns the subset whose every
view agrees on its slot kind after erasure (`RepresentationMeets`).

@docs EraseStats, emptyStats, erase, eraseKeeping, check, renderStats
@docs Plan, plan, noPlan, Rewritten, rewriteNodes, finish
@docs Erasable, erasableFromList, erasableSize, erasableIsEmpty, isErasable, eraseType, translateKv, consistentWith

-}

import Array exposing (Array)
import Compiler.Core.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Kernel.Visibility as Visibility
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Data.HashMap as HashMap
import Data.NonEmptyList as NE
import Dict exposing (Dict)
import Set exposing (Set)


{-| What one run of the pass did.
-}
type alias EraseStats =
    { erasedCtors : Int
    , erasedKeys : Int
    , excludedKv : Int
    , excludedMeetsVar : Int
    , skippedMoveOnly : Int
    , excludedCycle : Int
    , excludedUnboxed : Int
    , ctorCallsRemoved : Int
    , unboxStepsRemoved : Int
    }


{-| The statistics of a run that erased nothing.
-}
emptyStats : EraseStats
emptyStats =
    { erasedCtors = 0, erasedKeys = 0, excludedKv = 0, excludedMeetsVar = 0, skippedMoveOnly = 0, excludedCycle = 0, excludedUnboxed = 0, ctorCallsRemoved = 0, unboxStepsRemoved = 0 }


{-| The statistics as one line for the inline report.
-}
renderStats : EraseStats -> String
renderStats s =
    "erase-wrappers: erased "
        ++ String.fromInt s.erasedCtors
        ++ " type constructors ("
        ++ String.fromInt s.erasedKeys
        ++ " instantiations); excluded kernel-visible "
        ++ String.fromInt s.excludedKv
        ++ ", viewed through a type variable "
        ++ String.fromInt s.excludedMeetsVar
        ++ " (move-only meets skipped "
        ++ String.fromInt s.skippedMoveOnly
        ++ "), cyclic "
        ++ String.fromInt s.excludedCycle
        ++ ", unboxed "
        ++ String.fromInt s.excludedUnboxed
        ++ "; removed "
        ++ String.fromInt s.ctorCallsRemoved
        ++ " constructor calls and "
        ++ String.fromInt s.unboxStepsRemoved
        ++ " unbox steps"


{-| The custom types being erased, under the layout key (`Mono.LayoutMap`),
each with the type itself as the graph's `ctorShapes` lists it and its field
type before erasure. Every instantiation `ctorShapes` holds is listed. A lookup
reads the layout hash the type carries and compares `Int`s; a pre-filter on the
type constructor's name (a `Set String`) was tried and cost more than it saved
(plans/constructor-representation-levels.md §13.6).

The key ignores lambda sets and type-variable ids, so the listed type and the
type being erased may differ in those; `eraseType` substitutes the erased
type's own arguments into the field type.
-}
type alias Erasable =
    { types : Mono.LayoutMap ( Mono.MonoType, Mono.MonoType )
    }


{-| The erasure of nothing.
-}
emptyErasable : Erasable
emptyErasable =
    { types = Mono.layoutMapEmpty }


{-| Returns `e` with the custom type `t` erased to `payload`.
-}
erasableInsert : Mono.MonoType -> Mono.MonoType -> Erasable -> Erasable
erasableInsert t payload e =
    case t of
        Mono.MCustom _ _ _ _ ->
            { types = Mono.layoutMapInsert t ( t, payload ) e.types }

        _ ->
            e


{-| The erasure of each custom type of the list to the payload paired with it.
-}
erasableFromList : List ( Mono.MonoType, Mono.MonoType ) -> Erasable
erasableFromList pairs =
    List.foldl (\( t, payload ) acc -> erasableInsert t payload acc) emptyErasable pairs


{-| The listed type and payload `t` is erased by, if it is erased.
-}
erasableGet : Erasable -> Mono.MonoType -> Maybe ( Mono.MonoType, Mono.MonoType )
erasableGet e t =
    case t of
        Mono.MCustom _ _ _ _ ->
            Mono.layoutMapGet t e.types

        _ ->
            Nothing


{-| Returns whether the custom type `t` itself is erased.
-}
isErasable : Erasable -> Mono.MonoType -> Bool
isErasable e t =
    case t of
        Mono.MCustom _ _ _ _ ->
            Mono.layoutMapMember t e.types

        _ ->
            False


{-| The number of erased instantiations.
-}
erasableSize : Erasable -> Int
erasableSize e =
    Mono.layoutMapSize e.types


{-| Returns whether nothing is erased.
-}
erasableIsEmpty : Erasable -> Bool
erasableIsEmpty e =
    Mono.layoutMapIsEmpty e.types


{-| The erasures of `e` whose type satisfies `keep`, in their order.
-}
erasableFilter : (Mono.MonoType -> Bool) -> Erasable -> Erasable
erasableFilter keep e =
    Mono.layoutMapFoldl
        (\t ( _, payload ) acc ->
            if keep t then
                erasableInsert t payload acc

            else
                acc
        )
        emptyErasable
        e.types


type alias CtorKey =
    ( String, String )


ctorKeyOf : Mono.MonoType -> Maybe CtorKey
ctorKeyOf t =
    case t of
        Mono.MCustom _ home name _ ->
            Just ( ModuleName.toComparableCanonical home, name )

        _ ->
            Nothing


{-| Returns whether some type inside `t` (or `t` itself) is erasable.
-}
mentions : Erasable -> Mono.MonoType -> Bool
mentions e t =
    case t of
        Mono.MCustom _ _ _ args ->
            isErasable e t || List.any (mentions e) args

        Mono.MList _ inner ->
            mentions e inner

        Mono.MTuple _ shape ->
            List.any (mentions e) (Mono.tupleToList shape)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc || mentions e ft) False fields

        Mono.MFunction _ _ params result ->
            mentions e result || List.any (mentions e) params

        _ ->
            False


{-| Returns `t` with every erasable custom type inside it replaced by its
erased field type. A type that mentions nothing erasable is returned as it is.
-}
eraseType : Erasable -> Mono.MonoType -> Mono.MonoType
eraseType e t =
    if erasableIsEmpty e then
        t

    else
        Maybe.withDefault t (eraseTypeMaybe e t)


{-| The kernel-visibility set of the erased graph, carried over the erasure
instead of computed again (plans/constructor-representation-levels.md §13 R2.1):
the type constructors unchanged, each instance type erased. `choose` never
erases a type in the set, so no erased type leaves it; a recomputation can only
find fewer instances (`Compiler.Pipeline.Steps.representation` checks that
under validation).
-}
translateKv : Erasable -> KernelVisible.KvSet -> KernelVisible.KvSet
translateKv e kv =
    KernelVisible.mapInstances (eraseType e) kv


{-| `eraseType`, or `Nothing` when `t` mentions nothing erasable. One descent:
only the spine above an erased type is rebuilt, and a type is looked up once,
where it stands. Nothing is allocated on a type it leaves alone.
-}
eraseTypeMaybe : Erasable -> Mono.MonoType -> Maybe Mono.MonoType
eraseTypeMaybe e t =
    case t of
        Mono.MCustom _ home name args ->
            case erasableGet e t of
                Just ( listed, payload ) ->
                    Just (eraseType e (instantiateLike listed t payload))

                Nothing ->
                    Maybe.map (Mono.mCustom home name) (eraseList e args)

        Mono.MList _ inner ->
            Maybe.map Mono.mList (eraseTypeMaybe e inner)

        Mono.MTuple _ shape ->
            case shape of
                Mono.T2 a b ->
                    case ( eraseTypeMaybe e a, eraseTypeMaybe e b ) of
                        ( Nothing, Nothing ) ->
                            Nothing

                        ( ma, mb ) ->
                            Just (Mono.mTuple (Mono.T2 (Maybe.withDefault a ma) (Maybe.withDefault b mb)))

                Mono.T3 a b c ->
                    case ( eraseTypeMaybe e a, eraseTypeMaybe e b, eraseTypeMaybe e c ) of
                        ( Nothing, Nothing, Nothing ) ->
                            Nothing

                        ( ma, mb, mc ) ->
                            Just (Mono.mTuple (Mono.T3 (Maybe.withDefault a ma) (Maybe.withDefault b mb) (Maybe.withDefault c mc)))

        Mono.MRecord _ fields ->
            -- Only a field that changes is written back; an unchanged record allocates nothing.
            let
                ( changed, fields1 ) =
                    Dict.foldl
                        (\name ft ( ch, acc ) ->
                            case eraseTypeMaybe e ft of
                                Just ft1 ->
                                    ( True, Dict.insert name ft1 acc )

                                Nothing ->
                                    ( ch, acc )
                        )
                        ( False, fields )
                        fields
            in
            if changed then
                Just (Mono.mRecord fields1)

            else
                Nothing

        Mono.MFunction _ anno params result ->
            case ( eraseList e params, eraseTypeMaybe e result ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( ps, res ) ->
                    Just (Mono.mFunction anno (Maybe.withDefault params ps) (Maybe.withDefault result res))

        _ ->
            Nothing


{-| The types `eraseTypeMemo` has erased, keyed by spec hash and confirmed with
`==`: the result keeps the input's lambda sets and type-variable ids, which the
keys do not tell apart, so only an equal type may share it.
-}
type alias EraseMemo =
    HashMap.HashMap Mono.MonoType (Maybe Mono.MonoType)


{-| `eraseTypeMaybe`, remembered for each composite type: the graph's types
repeat (every use of a variable carries its type), so most lookups hit, and
`==` confirms a hit at once when the two are the same value. A leaf or type
variable is never erased and is not remembered.
-}
eraseTypeMemo : Erasable -> Mono.MonoType -> EraseMemo -> ( Maybe Mono.MonoType, EraseMemo )
eraseTypeMemo e t memo =
    case t of
        Mono.MList _ _ ->
            eraseTypeRemember e t memo

        Mono.MTuple _ _ ->
            eraseTypeRemember e t memo

        Mono.MRecord _ _ ->
            eraseTypeRemember e t memo

        Mono.MCustom _ _ _ _ ->
            eraseTypeRemember e t memo

        Mono.MFunction _ _ _ _ ->
            eraseTypeRemember e t memo

        _ ->
            ( Nothing, memo )


eraseTypeRemember : Erasable -> Mono.MonoType -> EraseMemo -> ( Maybe Mono.MonoType, EraseMemo )
eraseTypeRemember e t memo =
    case HashMap.get Mono.specHashOf (==) t memo of
        Just r ->
            ( r, memo )

        Nothing ->
            let
                r =
                    eraseTypeMaybe e t
            in
            ( r, HashMap.insert Mono.specHashOf (==) t r memo )


eraseList : Erasable -> List Mono.MonoType -> Maybe (List Mono.MonoType)
eraseList e ts =
    case ts of
        [] ->
            Nothing

        t :: rest ->
            case ( eraseTypeMaybe e t, eraseList e rest ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mt, mr ) ->
                    Just (Maybe.withDefault t mt :: Maybe.withDefault rest mr)



{-| `payload`, the field type of the instantiation `listed`, with each type
variable of `listed`'s arguments replaced by what stands at the same position
in `actual`'s arguments. `listed` and `actual` have one layout key, so they
differ at most in type-variable ids and lambda sets.
-}
instantiateLike : Mono.MonoType -> Mono.MonoType -> Mono.MonoType -> Mono.MonoType
instantiateLike listed actual payload =
    let
        bind a b acc =
            case ( a, b ) of
                ( Mono.MVar id _, _ ) ->
                    Dict.insert (Id.toComparable id) b acc

                ( Mono.MCustom _ _ _ xs, Mono.MCustom _ _ _ ys ) ->
                    List.foldl (\( x, y ) d -> bind x y d) acc (List.map2 Tuple.pair xs ys)

                ( Mono.MList _ x, Mono.MList _ y ) ->
                    bind x y acc

                ( Mono.MTuple _ xs, Mono.MTuple _ ys ) ->
                    List.foldl (\( x, y ) d -> bind x y d) acc (List.map2 Tuple.pair (Mono.tupleToList xs) (Mono.tupleToList ys))

                ( Mono.MRecord _ xs, Mono.MRecord _ ys ) ->
                    Dict.foldl
                        (\n x d ->
                            case Dict.get n ys of
                                Just y ->
                                    bind x y d

                                Nothing ->
                                    d
                        )
                        acc
                        xs

                ( Mono.MFunction _ _ ps r, Mono.MFunction _ _ qs u ) ->
                    List.foldl (\( x, y ) d -> bind x y d) (bind r u acc) (List.map2 Tuple.pair ps qs)

                _ ->
                    acc

        subst =
            bind listed actual Dict.empty

        apply t =
            case t of
                Mono.MVar id _ ->
                    Dict.get (Id.toComparable id) subst |> Maybe.withDefault t

                Mono.MCustom _ home name args ->
                    Mono.mCustom home name (List.map apply args)

                Mono.MList _ x ->
                    Mono.mList (apply x)

                Mono.MTuple _ shape ->
                    Mono.mTuple (Mono.tupleMap apply shape)

                Mono.MRecord _ fields ->
                    Mono.mRecord (Dict.map (\_ ft -> apply ft) fields)

                Mono.MFunction _ anno ps r ->
                    Mono.mFunction anno (List.map apply ps) (apply r)

                _ ->
                    t
    in
    if Dict.isEmpty subst || listed == actual then
        payload

    else
        apply payload


-- ====== CONSISTENCY WITH THE MEETS (E1b) ======


{-| Returns the subset of the tentative erasure `tentative` under which every
meet of `meets` (taken on the graph before erasure) stays consistent, by
un-erasing instantiations until none conflicts. A meet conflicts when

  - one side is an instantiation that is erased and the other an
    instantiation of the same wrapper that is not: one view would read a heap
    value where the other has the bare field; or
  - it is an interior meet and the two sides would have different slot kinds
    after erasure (a `Quantity Float` erased to `f64` inside a `List a` whose
    elements another view reads boxed). Call-boundary boxing (CGEN_001)
    repairs a root difference, so a root meet never conflicts this way.

Each round only removes erasures, so the loop ends.

-}
consistentWith : List RepresentationMeets.Meet -> Erasable -> Erasable
consistentWith meets tentative =
    let
        candidates =
            tentative

        round e =
            let
                isCandidate t =
                    isErasable candidates t

                isErased t =
                    isErasable e t

                sameCtor a b =
                    case ( a, b ) of
                        ( Mono.MCustom _ h1 n1 _, Mono.MCustom _ h2 n2 _ ) ->
                            h1 == h2 && n1 == n2

                        _ ->
                            False

                kindAfter t =
                    RepresentationMeets.slotKindOf (eraseType e t)

                drops m =
                    let
                        mixed =
                            isCandidate m.a
                                && isCandidate m.b
                                && sameCtor m.a m.b
                                && (isErased m.a /= isErased m.b)

                        -- Only a clash the erasure makes: some meets differ in slot kind before any
                        -- pass (MONO_021 views of values never read), and those stay as they are.
                        kindClash =
                            not m.root
                                && kindAfter m.a /= kindAfter m.b
                                && RepresentationMeets.slotKindOf m.a == RepresentationMeets.slotKindOf m.b
                    in
                    if mixed then
                        List.filter isErased [ m.a, m.b ]

                    else if kindClash then
                        -- Un-erase whichever erased type the clash runs through; a side that is not an
                        -- erased type itself may hold one inside, which is erased with it.
                        List.filter (\t -> mentions e t) [ m.a, m.b ]
                            |> List.concatMap (erasedWithin e)

                    else
                        []

                toDrop =
                    List.concatMap drops meets |> Mono.layoutSetFromList
            in
            if Mono.layoutSetSize toDrop == 0 then
                e

            else
                round (erasableFilter (\t -> not (Mono.layoutSetMember t toDrop)) e)
    in
    round tentative


{-| The erased instantiations that occur in `t`, `t` among them.
-}
erasedWithin : Erasable -> Mono.MonoType -> List Mono.MonoType
erasedWithin e t =
    let
        here =
            case t of
                Mono.MCustom _ _ _ _ ->
                    if isErasable e t then
                        [ t ]

                    else
                        []

                _ ->
                    []

        inner =
            case t of
                Mono.MCustom _ _ _ args ->
                    List.concatMap (erasedWithin e) args

                Mono.MList _ x ->
                    erasedWithin e x

                Mono.MTuple _ shape ->
                    List.concatMap (erasedWithin e) (Mono.tupleToList shape)

                Mono.MRecord _ fields ->
                    List.concatMap (erasedWithin e) (Dict.values fields)

                Mono.MFunction _ _ ps r ->
                    List.concatMap (erasedWithin e) (r :: ps)

                _ ->
                    []
    in
    here ++ inner



-- ====== CHOOSING ======


{-| The custom types occurring in `t`, `t` among them.
-}
customsWithin : Mono.MonoType -> List Mono.MonoType
customsWithin t =
    case t of
        Mono.MCustom _ _ _ args ->
            t :: List.concatMap customsWithin args

        Mono.MList _ x ->
            customsWithin x

        Mono.MTuple _ shape ->
            List.concatMap customsWithin (Mono.tupleToList shape)

        Mono.MRecord _ fields ->
            List.concatMap customsWithin (Dict.values fields)

        Mono.MFunction _ _ ps r ->
            List.concatMap customsWithin (r :: ps)

        _ ->
            []


type alias Choice =
    { erasable : Erasable
    , ctors : Set CtorKey
    , excludedKv : Int
    , excludedMeetsVar : Int
    , excludedCycle : Int
    , excludedUnboxed : Int
    }


isPrimitive : Mono.MonoType -> Bool
isPrimitive t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MChar ->
            True

        _ ->
            False


{-| The custom types of `ctorShapes` that are wrappers, grouped by type
constructor, each with its field type; a type constructor with any
instantiation that is not a wrapper is left out.
-}
wrapperGroups : Mono.LayoutMap (List Mono.CtorShape) -> Dict CtorKey (List ( Mono.MonoType, Mono.MonoType ))
wrapperGroups ctorShapes =
    let
        ( groups, notWrappers ) =
            Mono.layoutMapFoldl
                (\key shapes ( acc, bad ) ->
                    case ctorKeyOf key of
                        Just ck ->
                            case shapes of
                                [ { fieldTypes } ] ->
                                    case fieldTypes of
                                        [ payload ] ->
                                            ( Dict.update ck (\m -> Just (( key, payload ) :: Maybe.withDefault [] m)) acc, bad )

                                        _ ->
                                            ( acc, Set.insert ck bad )

                                _ ->
                                    ( acc, Set.insert ck bad )

                        Nothing ->
                            ( acc, bad )
                )
                ( Dict.empty, Set.empty )
                ctorShapes
    in
    Dict.filter (\ck _ -> not (Set.member ck notWrappers)) groups


{-| The type constructors of `groups` with an instantiation on a cycle: an
instantiation whose field type contains, at any depth, an instantiation that
leads back to it (`type T = T (List T)`, or two wrappers holding each other).
Erasing a cycle would make the type infinite. The cycle is between
instantiations, not type constructors: `Box (Box String)` holds `Box String`,
which is no cycle.
-}
cyclic : Dict CtorKey (List ( Mono.MonoType, Mono.MonoType )) -> Set CtorKey
cyclic groups =
    let
        -- Instantiation -> ( its type constructor, its field type ).
        insts : Mono.LayoutMap ( CtorKey, Mono.MonoType )
        insts =
            Dict.foldl
                (\ck pairs acc -> List.foldl (\( key, payload ) a -> Mono.layoutMapInsert key ( ck, payload ) a) acc pairs)
                Mono.layoutMapEmpty
                groups

        collect t acc =
            case t of
                Mono.MCustom _ _ _ args ->
                    List.foldl collect
                        (if Mono.layoutMapMember t insts then
                            Mono.layoutSetInsert t acc

                         else
                            acc
                        )
                        args

                Mono.MList _ inner ->
                    collect inner acc

                Mono.MTuple _ shape ->
                    List.foldl collect acc (Mono.tupleToList shape)

                Mono.MRecord _ fields ->
                    List.foldl collect acc (Dict.values fields)

                Mono.MFunction _ _ params result ->
                    List.foldl collect (collect result acc) params

                _ ->
                    acc

        succ : Mono.LayoutMap (List Mono.MonoType)
        succ =
            Mono.layoutMapMap (\_ ( _, payload ) -> Mono.layoutMapFoldl (\t () acc -> t :: acc) [] (collect payload Mono.layoutSetEmpty)) insts

        successors t =
            Mono.layoutMapGet t succ |> Maybe.withDefault []

        -- Depth-first reachability; the graphs here hold wrapper instantiations only.
        reaches : Mono.MonoType -> Bool
        reaches target =
            let
                go stack seen =
                    case stack of
                        [] ->
                            False

                        k :: rest ->
                            if Mono.eqKeyLayout k target then
                                True

                            else if Mono.layoutSetMember k seen then
                                go rest seen

                            else
                                go (successors k ++ rest) (Mono.layoutSetInsert k seen)
            in
            go (successors target) Mono.layoutSetEmpty
    in
    Mono.layoutMapFoldl
        (\k ( ck, _ ) acc ->
            if reaches k then
                Set.insert ck acc

            else
                acc
        )
        Set.empty
        insts


toErasable : Dict CtorKey (List ( Mono.MonoType, Mono.MonoType )) -> Erasable
toErasable groups =
    Dict.foldl
        (\_ insts acc -> List.foldl (\( key, payload ) a -> erasableInsert key payload a) acc insts)
        emptyErasable
        groups


{-| Chooses the erasable wrappers of `ctorShapes`; see the module docs.
`meetsOk` is used only when `allowUnboxed` is set.
-}
choose :
    { allowUnboxed : Bool, meetsOk : Erasable -> Erasable, meets : List RepresentationMeets.Meet }
    -> KernelVisible.KvSet
    -> Mono.LayoutMap (List Mono.CtorShape)
    -> Choice
choose opts kv ctorShapes =
    let
        groups0 =
            wrapperGroups ctorShapes

        -- A wrapper some value of which is also viewed through a type variable stays a heap value:
        -- an erased view reads it untyped, as `Debug.toString` used as a function value does, and
        -- would print the bare field without the constructor.
        meetsVar : Mono.LayoutSet
        meetsVar =
            List.foldl
                (\m acc ->
                    case ( m.a, m.b ) of
                        ( Mono.MVar _ _, other ) ->
                            List.foldl Mono.layoutSetInsert acc (customsWithin other)

                        ( other, Mono.MVar _ _ ) ->
                            List.foldl Mono.layoutSetInsert acc (customsWithin other)

                        _ ->
                            acc
                )
                Mono.layoutSetEmpty
                opts.meets

        notKvOnly =
            Dict.filter
                (\( home, name ) insts ->
                    not (Visibility.isKernelOwned home name)
                        && not (List.any (\( key, _ ) -> KernelVisible.isVisible kv key) insts)
                )
                groups0

        notKv =
            Dict.filter
                (\_ insts -> not (List.any (\( key, _ ) -> Mono.layoutSetMember key meetsVar) insts))
                notKvOnly

        cyc =
            cyclic notKv

        acyclic =
            Dict.filter (\ck _ -> not (Set.member ck cyc)) notKv

        -- A type constructor is kept while none of its instantiations erases to a primitive under
        -- the current choice. Dropping one can change what another's field erases to, so iterate.
        dropUnboxed groups =
            let
                e =
                    toErasable groups

                kept =
                    Dict.filter (\_ insts -> List.all (\( _, payload ) -> not (isPrimitive (eraseType e payload))) insts) groups
            in
            if Dict.size kept == Dict.size groups then
                groups

            else
                dropUnboxed kept

        boxedOnly =
            dropUnboxed acyclic

        erasable =
            if opts.allowUnboxed then
                opts.meetsOk (toErasable acyclic)

            else
                toErasable boxedOnly

        erasedCtors =
            Dict.keys acyclic
                |> List.filter
                    (\ck ->
                        Dict.get ck acyclic
                            |> Maybe.withDefault []
                            |> List.any (\( key, _ ) -> isErasable erasable key)
                    )
                |> Set.fromList
    in
    { erasable = erasable
    , ctors = erasedCtors
    , excludedKv = Dict.size groups0 - Dict.size notKvOnly
    , excludedMeetsVar = Dict.size notKvOnly - Dict.size notKv
    , excludedCycle = Set.size cyc
    , excludedUnboxed = Dict.size acyclic - Set.size erasedCtors
    }



-- ====== THE PASS ======


{-| Erases the wrappers of `graph` the options and `kv` allow, and returns the
graph with what it did.
-}
erase :
    { allowUnboxed : Bool, meetsOk : Erasable -> Erasable, meets : List RepresentationMeets.Meet }
    -> KernelVisible.KvSet
    -> Mono.MonoGraph
    -> ( Mono.MonoGraph, EraseStats )
erase opts kv graph =
    let
        ( g1, stats, _ ) =
            eraseKeeping opts kv graph
    in
    ( g1, stats )


{-| `erase`, also returning the erasure it applied, so that a later pass can
carry what it knew of the graph over to the erased one (`eraseType`).
-}
eraseKeeping :
    { allowUnboxed : Bool, meetsOk : Erasable -> Erasable, meets : List RepresentationMeets.Meet }
    -> KernelVisible.KvSet
    -> Mono.MonoGraph
    -> ( Mono.MonoGraph, EraseStats, Erasable )
eraseKeeping opts kv graph =
    let
        p =
            plan opts kv graph
    in
    if erasableIsEmpty p.erasable then
        ( graph, choiceStats p.choice, p.erasable )

    else
        let
            ( g1, stats ) =
                finish p (rewriteNodes p (\_ -> False) (\x _ -> ( Nothing, x )) () graph) graph
        in
        ( g1, stats, p.erasable )


{-| What the pass will do to a graph, decided before any node is touched: the
erasure, the choice it came from, the SpecIds of the erased constructors' nodes
(each with its home, shape and the type it builds), and the graph's constructor
table after the erasure.
-}
type alias Plan =
    { erasable : Erasable
    , choice : Choice
    , ctorSpecs : Dict Int ( ModuleName.Canonical, Mono.CtorShape, Mono.MonoType )
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape)
    }


{-| Decides what the pass does to `graph` under the options and `kv`; see
`erase`.
-}
plan :
    { allowUnboxed : Bool, meetsOk : Erasable -> Erasable, meets : List RepresentationMeets.Meet }
    -> KernelVisible.KvSet
    -> Mono.MonoGraph
    -> Plan
plan opts kv (Mono.MonoGraph g) =
    let
        choice =
            choose opts kv g.ctorShapes

        e =
            choice.erasable
    in
    if erasableIsEmpty e then
        { erasable = e, choice = choice, ctorSpecs = Dict.empty, ctorShapes = g.ctorShapes }

    else
        { erasable = e
        , choice = choice
        , ctorSpecs =
            Array.foldl
                (\maybeNode ( acc, i ) ->
                    case maybeNode of
                        Just (Mono.MonoCtor home shape t) ->
                            if isErasable e t then
                                ( Dict.insert i ( home, shape, t ) acc, i + 1 )

                            else
                                ( acc, i + 1 )

                        _ ->
                            ( acc, i + 1 )
                )
                ( Dict.empty, 0 )
                g.nodes
                |> Tuple.first
        , ctorShapes =
            Mono.layoutMapFoldl
                (\key shapes acc ->
                    if isErasable e key then
                        acc

                    else
                        let
                            key1 =
                                eraseType e key
                        in
                        if Mono.layoutMapMember key1 acc then
                            acc

                        else
                            Mono.layoutMapInsert key1
                                (List.map (\s -> { s | fieldTypes = List.map (eraseType e) s.fieldTypes }) shapes)
                                acc
                )
                Mono.layoutMapEmpty
                g.ctorShapes
        }


{-| The plan that erases nothing, for a graph the pass is not run on.
-}
noPlan : Mono.MonoGraph -> Plan
noPlan (Mono.MonoGraph g) =
    { erasable = emptyErasable
    , choice = { erasable = emptyErasable, ctors = Set.empty, excludedKv = 0, excludedMeetsVar = 0, excludedCycle = 0, excludedUnboxed = 0 }
    , ctorSpecs = Dict.empty
    , ctorShapes = g.ctorShapes
    }


choiceStats : Choice -> EraseStats
choiceStats choice =
    { emptyStats | excludedKv = choice.excludedKv, excludedMeetsVar = choice.excludedMeetsVar, excludedCycle = choice.excludedCycle, excludedUnboxed = choice.excludedUnboxed }


{-| The nodes of a graph after `rewriteNodes`: the erased constructors' nodes
replaced by identity functions (numbered from the graph's `nextLambdaIndex` on),
the counts of what the erasure removed, and the context of the extra step.
-}
type alias Rewritten ctx =
    { nodes : Array (Maybe Mono.MonoNode)
    , nextLambda : Int
    , counts : Counts
    , extra : ctx
    , visited : Set Int
    }


{-| Rewrites the nodes of the graph by the plan, in one loop: an erased
constructor's node becomes the identity function on its field; any other node
has its expressions rewritten in one bottom-up traversal, in which `extra` runs
on each expression after the erasure's own step (so that another pass's
rewrite shares the traversal), and then its types erased. `extra` sees the
node's types before erasure; a pass that looks types up applies `eraseType`
first (`NullableMaybe.rewriteStep`).

Only a node one of whose types mentions an erased type (a read-only scan,
`Traverse.anyNodeType`), or that `extraTouches` says `extra` can rewrite, is
visited; every other node is kept as the same value. `extraTouches` is asked
only about a node that mentions no erased type, and such a node gets the
traversal alone, not the erasure's `Debug` pre-walk or type rewrite. The type
rewrite remembers what it erased across the nodes (`eraseTypeMemo`). `visited`
holds the SpecIds of the visited and replaced nodes.
-}
rewriteNodes : Plan -> (Mono.MonoNode -> Bool) -> (ctx -> Mono.MonoExpr -> ( Maybe Mono.MonoExpr, ctx )) -> ctx -> Mono.MonoGraph -> Rewritten ctx
rewriteNodes p extraTouches extra ctx0 (Mono.MonoGraph g) =
    let
        e =
            p.erasable

        erasing =
            not (erasableIsEmpty e)

        eraseTypes node memo =
            if erasing then
                Tuple.mapFirst (Maybe.withDefault node) (Traverse.mapNodeTypesMaybe (eraseTypeMemo e) memo node)

            else
                ( node, memo )

        mentionsErased node =
            erasing && Traverse.anyNodeType (mentions e) node

        ( nodes, ( _, lam, ( counts, ctx, ( visited, _ ) ) ) ) =
            Array.foldl
                (\maybeNode ( acc, ( i, l, ( cnt, x, ( vis, memo ) ) ) ) ->
                    let
                        st =
                            ( cnt, x )
                    in
                    case ( maybeNode, Dict.get i p.ctorSpecs ) of
                        ( Just _, Just ( home, shape, _ ) ) ->
                            let
                                -- The parameter type of the constructor's registry entry, so that the
                                -- identity function's type is the one its SpecId is keyed by (MONO_025); the
                                -- node's shape can carry other ids for type variables nothing fixes.
                                payload =
                                    case Array.get i g.registry.reverseMapping |> Maybe.andThen identity of
                                        Just ( _, Mono.MFunction _ _ [ par ] _ ) ->
                                            par

                                        _ ->
                                            List.head shape.fieldTypes |> Maybe.withDefault Mono.MUnit
                            in
                            let
                                ( node1, memo1 ) =
                                    eraseTypes (identityNode home payload l) memo
                            in
                            ( Array.push (Just node1) acc, ( i + 1, l + 1, ( cnt, x, ( Set.insert i vis, memo1 ) ) ) )

                        ( Just node, Nothing ) ->
                            if mentionsErased node then
                                let
                                    ( node1, ( cnt1, x1 ) ) =
                                        rewriteNodeExprs True e p.ctorSpecs extra node st

                                    ( node2, memo1 ) =
                                        eraseTypes node1 memo
                                in
                                ( Array.push (Just node2) acc, ( i + 1, l, ( cnt1, x1, ( Set.insert i vis, memo1 ) ) ) )

                            else if extraTouches node then
                                let
                                    ( node1, ( cnt1, x1 ) ) =
                                        rewriteNodeExprs False e p.ctorSpecs extra node st
                                in
                                ( Array.push (Just node1) acc, ( i + 1, l, ( cnt1, x1, ( Set.insert i vis, memo ) ) ) )

                            else
                                ( Array.push maybeNode acc, ( i + 1, l, ( cnt, x, ( vis, memo ) ) ) )

                        ( Nothing, _ ) ->
                            ( Array.push Nothing acc, ( i + 1, l, ( cnt, x, ( vis, memo ) ) ) )
                )
                ( Array.empty, ( 0, g.nextLambdaIndex, ( { calls = 0, steps = 0, lastRemoved = Nothing }, ctx0, ( Set.empty, HashMap.empty ) ) ) )
                g.nodes
    in
    { nodes = nodes, nextLambda = lam, counts = counts, extra = ctx, visited = visited }


{-| The graph with the rewritten nodes, and with every table that names an
erased type or constructor updated by the plan; and what the pass did.
-}
finish : Plan -> Rewritten ctx -> Mono.MonoGraph -> ( Mono.MonoGraph, EraseStats )
finish p rewritten (Mono.MonoGraph g) =
    let
        e =
            p.erasable
    in
    if erasableIsEmpty e then
        ( Mono.MonoGraph { g | nodes = rewritten.nodes }, choiceStats p.choice )

    else
        let
            erasedKeys =
                Mono.layoutMapFoldl
                    (\key _ acc ->
                        if isErasable e key then
                            Mono.layoutMapInsert key () acc

                        else
                            acc
                    )
                    g.repr.erasedKeys
                    g.ctorShapes

            erasedCtorNames : Set ( String, String )
            erasedCtorNames =
                Dict.values p.ctorSpecs
                    |> List.map (\( home, shape, _ ) -> ( ModuleName.toComparableCanonical home, shape.name ))
                    |> Set.fromList

            registry =
                g.registry

            repr =
                g.repr

            stats =
                choiceStats p.choice
        in
        ( Mono.MonoGraph
            { g
                | nodes = rewritten.nodes
                , nextLambdaIndex = rewritten.nextLambda
                , ctorShapes = p.ctorShapes
                -- Only a visited node's calls can have changed (an erased constructor's call removed).
                , callEdges =
                    Array.indexedMap
                        (\i edges ->
                            if Set.member i rewritten.visited then
                                Array.get i rewritten.nodes |> Maybe.andThen identity |> Maybe.map Traverse.specEdgesOfNode

                            else
                                edges
                        )
                        g.callEdges
                , registry =
                    { registry
                        | reverseMapping =
                            Array.map
                                (\entry ->
                                    case entry of
                                        Just ( gl, t ) ->
                                            case eraseTypeMaybe e t of
                                                Just t1 ->
                                                    Just ( gl, t1 )

                                                Nothing ->
                                                    entry

                                        Nothing ->
                                            entry
                                )
                                registry.reverseMapping
                    }
                , lssMemberOrigins =
                    Dict.map
                        (\_ origin ->
                            case origin of
                                Mono.OriginCtor home name ->
                                    if Set.member ( ModuleName.toComparableCanonical home, name ) erasedCtorNames then
                                        Mono.OriginGlobal home name

                                    else
                                        origin

                                _ ->
                                    origin
                        )
                        g.lssMemberOrigins
                , repr =
                    { repr
                        | printShapes =
                            if Mono.layoutMapValues repr.printShapes |> List.isEmpty then
                                g.ctorShapes

                            else
                                repr.printShapes
                        , erasedKeys = erasedKeys
                    }
            }
        , { stats
            | erasedCtors = Set.size p.choice.ctors
            , erasedKeys = erasableSize e
            , ctorCallsRemoved = rewritten.counts.calls
            , unboxStepsRemoved = rewritten.counts.steps
          }
        )


{-| The identity function on `payload` that replaces an erased constructor's
node.
-}
identityNode : ModuleName.Canonical -> Mono.MonoType -> Int -> Mono.MonoNode
identityNode home payload lambdaIndex =
    let
        fnType =
            Mono.mFunction Mono.topSynth [ payload ] payload

        param =
            "erased_wrapper_value"
    in
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home lambdaIndex
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( param, payload ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (Mono.MonoVarLocal param payload)
            fnType
        )
        fnType


{-| What the erasure removed, and in `lastRemoved` the expression the step just
produced by removing an erased constructor call, with that call's type (see
`rewriteNodeExprs`).
-}
type alias Counts =
    { calls : Int, steps : Int, lastRemoved : Maybe ( Mono.MonoExpr, Mono.MonoType ) }


rewriteNodeExprs :
    Bool
    -> Erasable
    -> Dict Int a
    -> (ctx -> Mono.MonoExpr -> ( Maybe Mono.MonoExpr, ctx ))
    -> Mono.MonoNode
    -> ( Counts, ctx )
    -> ( Mono.MonoNode, ( Counts, ctx ) )
rewriteNodeExprs erasing e ctorSpecs extra node st =
    let
        -- The erasure's step is `setPrintType` then `rewriteExpr`, composed. `setPrintType` needs the
        -- printed argument's type before erasure; types are erased only after the traversal, so every
        -- argument still has it, except one that was itself an erased constructor call: that is its
        -- field by now. The step on that argument records the removal in `lastRemoved`, and since a
        -- call's arguments are the last children the traversal visits before the call, the record at
        -- a `Debug` call is the printed argument's, when it has one. Every other node clears it. A
        -- node that mentions no erased type gets only `extra`.
        step ( cnt, x ) ex =
            let
                ( m1, cnt1 ) =
                    if erasing then
                        let
                            m0 =
                                setPrintType e cnt.lastRemoved ex

                            ( mr, c1 ) =
                                rewriteExpr e ctorSpecs { cnt | lastRemoved = Nothing } (Maybe.withDefault ex m0)
                        in
                        ( case mr of
                            Just _ ->
                                mr

                            Nothing ->
                                m0
                        , c1
                        )

                    else
                        ( Nothing, cnt )

                ( m2, x1 ) =
                    extra x (Maybe.withDefault ex m1)
            in
            ( case m2 of
                Just _ ->
                    m2

                Nothing ->
                    m1
            , ( cnt1, x1 )
            )

        go expr c =
            Traverse.traverseExpr step c expr
    in
    case node of
        Mono.MonoDefine expr t ->
            let
                ( expr1, c1 ) =
                    go expr st
            in
            ( Mono.MonoDefine expr1 t, c1 )

        Mono.MonoTailFunc params expr t ->
            let
                ( expr1, c1 ) =
                    go expr st
            in
            ( Mono.MonoTailFunc params expr1 t, c1 )

        Mono.MonoPortIncoming expr t ->
            let
                ( expr1, c1 ) =
                    go expr st
            in
            ( Mono.MonoPortIncoming expr1 t, c1 )

        Mono.MonoPortOutgoing expr t ->
            let
                ( expr1, c1 ) =
                    go expr st
            in
            ( Mono.MonoPortOutgoing expr1 t, c1 )

        _ ->
            ( node, st )


{-| Records the printed argument's original type on a `Debug.log` or
`Debug.toString` call whose argument mentions an erased type.
-}
setPrintType : Erasable -> Maybe ( Mono.MonoExpr, Mono.MonoType ) -> Mono.MonoExpr -> Maybe Mono.MonoExpr
setPrintType e lastRemoved expr =
    case expr of
        Mono.MonoCall region ((Mono.MonoVarKernel _ _ "Debug" name _) as fn) args t ci ->
            let
                printed =
                    case ( name, args ) of
                        ( "log", [ _, value ] ) ->
                            Just value

                        ( "toString", [ value ] ) ->
                            Just value

                        _ ->
                            Nothing
            in
            case printed of
                Just value ->
                    let
                        -- The argument's type before erasure: the removed constructor call's type when
                        -- the argument is what that removal produced, else its own.
                        vt =
                            case lastRemoved of
                                Just ( produced, originalType ) ->
                                    if produced == value then
                                        originalType

                                    else
                                        Mono.typeOf value

                                Nothing ->
                                    Mono.typeOf value
                    in
                    if ci.printType == Nothing && mentions e vt then
                        Just (Mono.MonoCall region fn args t { ci | printType = Just vt })

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


rewriteExpr : Erasable -> Dict Int a -> Counts -> Mono.MonoExpr -> ( Maybe Mono.MonoExpr, Counts )
rewriteExpr e ctorSpecs cnt expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ arg ] callType _ ->
            if Dict.member specId ctorSpecs then
                ( Just arg, { cnt | calls = cnt.calls + 1, lastRemoved = Just ( arg, callType ) } )

            else
                ( Nothing, cnt )

        Mono.MonoDestruct (Mono.MonoDestructor name path ty) inner t ->
            let
                ( path1, n ) =
                    erasePath e path 0
            in
            if n > 0 then
                ( Just (Mono.MonoDestruct (Mono.MonoDestructor name path1 ty) inner t), { cnt | steps = cnt.steps + n } )

            else
                ( Nothing, cnt )

        Mono.MonoCase label scrut decider jumps t ->
            let
                ( decider1, n ) =
                    eraseDecider e decider 0
            in
            if n > 0 then
                ( Just (Mono.MonoCase label scrut decider1 jumps t), { cnt | steps = cnt.steps + n } )

            else
                ( Nothing, cnt )

        _ ->
            ( Nothing, cnt )


erasePath : Erasable -> Mono.MonoPath -> Int -> ( Mono.MonoPath, Int )
erasePath e path n =
    case path of
        Mono.MonoIndex i kind ty inner ->
            let
                ( inner1, n1 ) =
                    erasePath e inner n
            in
            ( Mono.MonoIndex i kind ty inner1, n1 )

        Mono.MonoField name ty inner ->
            let
                ( inner1, n1 ) =
                    erasePath e inner n
            in
            ( Mono.MonoField name ty inner1, n1 )

        Mono.MonoUnbox ty inner ->
            let
                ( inner1, n1 ) =
                    erasePath e inner n
            in
            if isErasable e (Mono.getMonoPathType inner) then
                ( inner1, n1 + 1 )

            else
                ( Mono.MonoUnbox ty inner1, n1 )

        Mono.MonoRoot _ _ ->
            ( path, n )


eraseDtPath : Erasable -> Mono.MonoDtPath -> Int -> ( Mono.MonoDtPath, Int )
eraseDtPath e path n =
    case path of
        Mono.DtIndex i kind ty inner ->
            let
                ( inner1, n1 ) =
                    eraseDtPath e inner n
            in
            ( Mono.DtIndex i kind ty inner1, n1 )

        Mono.DtUnbox ty inner ->
            let
                ( inner1, n1 ) =
                    eraseDtPath e inner n
            in
            if isErasable e (Mono.dtPathType inner) then
                ( inner1, n1 + 1 )

            else
                ( Mono.DtUnbox ty inner1, n1 )

        Mono.DtRoot _ _ ->
            ( path, n )


eraseDecider : Erasable -> Mono.Decider a -> Int -> ( Mono.Decider a, Int )
eraseDecider e decider n =
    case decider of
        Mono.Leaf _ ->
            ( decider, n )

        Mono.Chain tests success failure ->
            let
                ( tests1, n1 ) =
                    NE.foldr
                        (\( p, test ) ( acc, k ) ->
                            let
                                ( p1, k1 ) =
                                    eraseDtPath e p k
                            in
                            ( ( p1, test ) :: acc, k1 )
                        )
                        ( [], n )
                        tests

                ( success1, n2 ) =
                    eraseDecider e success n1

                ( failure1, n3 ) =
                    eraseDecider e failure n2
            in
            case tests1 of
                first :: rest ->
                    ( Mono.Chain (NE.Nonempty first rest) success1 failure1, n3 )

                [] ->
                    ( decider, n )

        Mono.FanOut path edges fallback ->
            let
                ( path1, n1 ) =
                    eraseDtPath e path n

                ( edges1, n2 ) =
                    NE.foldr
                        (\( test, d ) ( acc, k ) ->
                            let
                                ( d1, k1 ) =
                                    eraseDecider e d k
                            in
                            ( ( test, d1 ) :: acc, k1 )
                        )
                        ( [], n1 )
                        edges

                ( fallback1, n3 ) =
                    eraseDecider e fallback n2
            in
            case edges1 of
                first :: rest ->
                    ( Mono.FanOut path1 (NE.Nonempty first rest) fallback1, n3 )

                [] ->
                    ( decider, n )



-- ====== CHECK (MONO_031) ======


{-| Checks MONO_031 on a graph after the pass: no node, expression or path type
mentions an erased type, and no decision tree tests one. Returns one message
per violation.
-}
check : Mono.MonoGraph -> List String
check (Mono.MonoGraph g) =
    let
        e : Erasable
        e =
            Mono.layoutMapFoldl (\key _ acc -> erasableInsert key Mono.MUnit acc) emptyErasable g.repr.erasedKeys
    in
    if erasableIsEmpty e then
        []

    else
        Array.foldl
            (\maybeNode ( acc, i ) ->
                case maybeNode of
                    Just node ->
                        if Traverse.anyNodeType (mentions e) node then
                            ( ("MONO_031 violation (spec " ++ String.fromInt i ++ "): a type still mentions an erased wrapper") :: acc, i + 1 )

                        else
                            ( acc, i + 1 )

                    Nothing ->
                        ( acc, i + 1 )
            )
            ( [], 0 )
            g.nodes
            |> Tuple.first
            |> List.reverse
