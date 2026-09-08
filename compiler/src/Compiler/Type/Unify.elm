module Compiler.Type.Unify exposing (unify, Answer(..))

{-| Type unification for Hindley-Milner type inference.

Unification finds a substitution that makes two types equal, or reports
that no such substitution exists. This module implements unification using
union-find data structures for efficient variable binding.


# Unification

@docs unify, Answer

-}

import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Type.Error as Error
import Compiler.Type.Occurs as Occurs
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



-- ====== UNIFY ======


{-| Result of attempting to unify two type variables.

AnswerOk indicates successful unification and includes all newly created
variables. AnswerErr indicates a type mismatch and includes the conflicting
types for error reporting.

-}
type Answer
    = AnswerOk (List Vars.Variable)
    | AnswerErr (List Vars.Variable) Error.Type Error.Type


{-| Attempts to unify two type variables.

Finds a substitution that makes both variables represent the same type, or
returns an error with the conflicting types. Uses union-find to efficiently
merge equivalent variables and handles all type constructors including
functions, records, tuples, and type aliases.

-}
unify : Vars.Variable -> Vars.Variable -> IO Answer
unify v1 v2 =
    case guardedUnify v1 v2 of
        Unify k ->
            k []
                |> IO.andThen
                    (\result ->
                        case result of
                            Ok (UnifyOk vars ()) ->
                                onSuccess vars ()

                            Err (UnifyErr vars ()) ->
                                Type.toErrorType v1
                                    |> IO.andThen
                                        (\t1 ->
                                            Type.toErrorType v2
                                                |> IO.andThen
                                                    (\t2 ->
                                                        UF.union v1 v2 errorDescriptor
                                                            |> IO.map (\_ -> AnswerErr vars t1 t2)
                                                    )
                                        )
                    )


onSuccess : List Vars.Variable -> () -> IO Answer
onSuccess vars () =
    IO.pure (AnswerOk vars)


errorDescriptor : Vars.Descriptor
errorDescriptor =
    IO.makeDescriptor Vars.Error Type.noRank Type.noMark Nothing



-- ====== CPS UNIFIER ======


type Unify a
    = Unify (List Vars.Variable -> IO (Result UnifyErr (UnifyOk a)))


type UnifyOk a
    = UnifyOk (List Vars.Variable) a


type UnifyErr
    = UnifyErr (List Vars.Variable) ()


map : (a -> b) -> Unify a -> Unify b
map func (Unify kv) =
    Unify <|
        \vars ->
            IO.map
                (Result.map
                    (\(UnifyOk vars1 value) ->
                        UnifyOk vars1 (func value)
                    )
                )
                (kv vars)


pure : a -> Unify a
pure a =
    Unify (\vars -> IO.pure (Ok (UnifyOk vars a)))


andThen : (a -> Unify b) -> Unify a -> Unify b
andThen callback (Unify ka) =
    Unify <|
        \vars ->
            ka vars
                |> IO.andThen
                    (\result ->
                        case result of
                            Ok (UnifyOk vars1 a) ->
                                case callback a of
                                    Unify kb ->
                                        kb vars1

                            Err err ->
                                IO.pure (Err err)
                    )


register : IO Vars.Variable -> Unify Vars.Variable
register mkVar =
    Unify
        (\vars ->
            IO.map
                (\var ->
                    Ok (UnifyOk (var :: vars) var)
                )
                mkVar
        )


mismatch : Unify a
mismatch =
    Unify (\vars -> IO.pure (Err (UnifyErr vars ())))


{-| Run each element through `f` in order, short-circuiting on the first
mismatch. Threads the fresh-var accumulator through the whole traversal, so an
element-wise unification can't accidentally drop a step (which is what the old
hand-written `List.foldl` in the comparable-tuple case did).
-}
forEach_ : List a -> (a -> Unify ()) -> Unify ()
forEach_ xs f =
    List.foldl (\x acc -> acc |> andThen (\_ -> f x)) (pure ()) xs


{-| Unify two lists pairwise, short-circuiting on the first mismatch; `mismatch`
if the lengths differ.
-}
zipWithM_ : (a -> b -> Unify ()) -> List a -> List b -> Unify ()
zipWithM_ f xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            pure ()

        ( x :: xr, y :: yr ) ->
            f x y |> andThen (\_ -> zipWithM_ f xr yr)

        _ ->
            mismatch


{-| Run a unification, recovering a mismatch to `False` while keeping any fresh
vars it allocated (never short-circuits). `True` on success. This is the single
place the `Ok`/`Err` conversion lives for the run-all discipline below.
-}
try : Unify () -> Unify Bool
try (Unify u) =
    Unify
        (\vars ->
            u vars
                |> IO.map
                    (\result ->
                        case result of
                            Ok (UnifyOk vs ()) ->
                                Ok (UnifyOk vs True)

                            Err (UnifyErr vs ()) ->
                                Ok (UnifyOk vs False)
                    )
        )


{-| "Run-all-then-report": unify every pair (so all fresh vars are collected)
even after a mismatch, then report a mismatch if any pair failed or the lengths
differ. Preserves the discipline of the old `unifyArgs`/`unifyAliasArgs`, which
kept unifying remaining args after a failure so `Solve` still sees every fresh
var on the error path.
-}
zipAllWithM_ : (a -> b -> Unify ()) -> List a -> List b -> Unify ()
zipAllWithM_ f xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            pure ()

        ( x :: xr, y :: yr ) ->
            try (f x y)
                |> andThen
                    (\ok ->
                        zipAllWithM_ f xr yr
                            |> andThen
                                (\_ ->
                                    if ok then
                                        pure ()

                                    else
                                        mismatch
                                )
                    )

        _ ->
            mismatch



-- ====== UNIFICATION HELPERS ======


type alias Context =
    { var1 : Vars.Variable
    , desc1 : Vars.Descriptor
    , var2 : Vars.Variable
    , desc2 : Vars.Descriptor
    }


{-| Helper to construct Context with positional args
-}
makeContext : Vars.Variable -> Vars.Descriptor -> Vars.Variable -> Vars.Descriptor -> Context
makeContext var1 desc1 var2 desc2 =
    { var1 = var1, desc1 = desc1, var2 = var2, desc2 = desc2 }


reorient : Context -> Context
reorient props =
    makeContext props.var2 props.desc2 props.var1 props.desc1



-- ====== MERGE ======
-- merge : Context -> UF.Content -> Unify ( UF.Point UF.Descriptor, UF.Point UF.Descriptor )


merge : Context -> Vars.Content -> Unify ()
merge props content =
    let
        desc1Props =
            props.desc1

        desc2Props =
            props.desc2
    in
    Unify
        (\vars s0 ->
            ( UF.unionS props.var1 props.var2 (IO.makeDescriptor content (min desc1Props.rank desc2Props.rank) Type.noMark Nothing) s0
            , Ok (UnifyOk vars ())
            )
        )


fresh : Context -> Vars.Content -> Unify Vars.Variable
fresh props content =
    let
        desc1Props =
            props.desc1

        desc2Props =
            props.desc2
    in
    IO.makeDescriptor content (min desc1Props.rank desc2Props.rank) Type.noMark Nothing |> UF.fresh |> register



-- ====== ACTUALLY UNIFY THINGS ======


guardedUnify : Vars.Variable -> Vars.Variable -> Unify ()
guardedUnify left right =
    -- THE hot path of unification. Threads the union-find state directly
    -- (plans/io-monad-dispatch-reduction.md P3): `UF.equivalent left right` and
    -- the two `UF.get`s were each a PARTIAL application, so each built a PAP
    -- that `andThen` then had to dispatch through — 141 M dispatches to the
    -- `UnionFind` IO wrappers across the self-compile, `UF.get` alone 80.8 M.
    -- Saturated `equivalentS`/`getS` calls are direct, and the three `andThen`s
    -- disappear with them. `Unify` wraps `List Variable -> IO a`, and
    -- `IO a = State -> ( State, a )`, so taking `s0` here is just eta-expansion.
    Unify
        (\vars s0 ->
            let
                ( equivalent, s1 ) =
                    UF.equivalentS s0 left right
            in
            if equivalent then
                ( s1, Ok (UnifyOk vars ()) )

            else
                let
                    ( leftDesc, s2 ) =
                        UF.getS s1 left

                    ( rightDesc, s3 ) =
                        UF.getS s2 right
                in
                case actuallyUnify (makeContext left leftDesc right rightDesc) of
                    Unify k ->
                        k vars s3
        )


subUnify : Vars.Variable -> Vars.Variable -> Unify ()
subUnify var1 var2 =
    guardedUnify var1 var2


subUnifyTuple : List Vars.Variable -> List Vars.Variable -> Context -> Vars.Content -> Unify ()
subUnifyTuple cs zs context otherContent =
    zipWithM_ subUnify cs zs
        |> andThen (\_ -> merge context otherContent)


actuallyUnify : Context -> Unify ()
actuallyUnify ctx =
    let
        desc1Props =
            ctx.desc1

        desc2Props =
            ctx.desc2

        firstContent =
            desc1Props.content

        secondContent =
            desc2Props.content
    in
    case firstContent of
        Vars.FlexVar _ ->
            unifyFlex ctx firstContent secondContent

        Vars.FlexSuper super _ ->
            unifyFlexSuper ctx super firstContent secondContent

        Vars.RigidVar _ ->
            unifyRigid ctx Nothing firstContent secondContent

        Vars.RigidSuper super _ ->
            unifyRigid ctx (Just super) firstContent secondContent

        Vars.Alias home name args realVar ->
            unifyAlias ctx home name args realVar secondContent

        Vars.Structure flatType ->
            unifyStructure ctx flatType firstContent secondContent

        Vars.Error ->
            -- If there was an error, just pretend it is okay. This lets us avoid
            -- "cascading" errors where one problem manifests as multiple message.
            merge ctx Vars.Error



-- ====== UNIFY FLEXIBLE VARIABLES ======


unifyFlex : Context -> Vars.Content -> Vars.Content -> Unify ()
unifyFlex context content otherContent =
    case otherContent of
        Vars.Error ->
            merge context Vars.Error

        Vars.FlexVar maybeName ->
            merge context <|
                case maybeName of
                    Nothing ->
                        content

                    Just _ ->
                        otherContent

        Vars.FlexSuper _ _ ->
            merge context otherContent

        Vars.RigidVar _ ->
            merge context otherContent

        Vars.RigidSuper _ _ ->
            merge context otherContent

        Vars.Alias _ _ _ _ ->
            merge context otherContent

        Vars.Structure _ ->
            merge context otherContent



-- ====== UNIFY RIGID VARIABLES ======


unifyRigid : Context -> Maybe Vars.SuperType -> Vars.Content -> Vars.Content -> Unify ()
unifyRigid context maybeSuper content otherContent =
    case otherContent of
        Vars.FlexVar _ ->
            merge context content

        Vars.FlexSuper otherSuper _ ->
            case maybeSuper of
                Just super ->
                    if combineRigidSupers super otherSuper then
                        merge context content

                    else
                        mismatch

                Nothing ->
                    mismatch

        Vars.RigidVar _ ->
            mismatch

        Vars.RigidSuper _ _ ->
            mismatch

        Vars.Alias _ _ _ _ ->
            mismatch

        Vars.Structure _ ->
            mismatch

        Vars.Error ->
            merge context Vars.Error



-- ====== UNIFY SUPER VARIABLES ======


unifyFlexSuper : Context -> Vars.SuperType -> Vars.Content -> Vars.Content -> Unify ()
unifyFlexSuper ctx super content otherContent =
    let
        first =
            ctx.var1
    in
    case otherContent of
        Vars.Structure flatType ->
            unifyFlexSuperStructure ctx super flatType

        Vars.RigidVar _ ->
            mismatch

        Vars.RigidSuper otherSuper _ ->
            if combineRigidSupers otherSuper super then
                merge ctx otherContent

            else
                mismatch

        Vars.FlexVar _ ->
            merge ctx content

        Vars.FlexSuper otherSuper _ ->
            case super of
                Vars.Number ->
                    case otherSuper of
                        Vars.Number ->
                            merge ctx content

                        Vars.Comparable ->
                            merge ctx content

                        Vars.Appendable ->
                            mismatch

                        Vars.CompAppend ->
                            mismatch

                Vars.Comparable ->
                    case otherSuper of
                        Vars.Comparable ->
                            merge ctx otherContent

                        Vars.Number ->
                            merge ctx otherContent

                        Vars.Appendable ->
                            Type.unnamedFlexSuper Vars.CompAppend |> merge ctx

                        Vars.CompAppend ->
                            merge ctx otherContent

                Vars.Appendable ->
                    case otherSuper of
                        Vars.Appendable ->
                            merge ctx otherContent

                        Vars.Comparable ->
                            Type.unnamedFlexSuper Vars.CompAppend |> merge ctx

                        Vars.CompAppend ->
                            merge ctx otherContent

                        Vars.Number ->
                            mismatch

                Vars.CompAppend ->
                    case otherSuper of
                        Vars.Comparable ->
                            merge ctx content

                        Vars.Appendable ->
                            merge ctx content

                        Vars.CompAppend ->
                            merge ctx content

                        Vars.Number ->
                            mismatch

        Vars.Alias _ _ _ realVar ->
            subUnify first realVar

        Vars.Error ->
            merge ctx Vars.Error


combineRigidSupers : Vars.SuperType -> Vars.SuperType -> Bool
combineRigidSupers rigid flex =
    rigid
        == flex
        || (rigid == Vars.Number && flex == Vars.Comparable)
        || (rigid == Vars.CompAppend && (flex == Vars.Comparable || flex == Vars.Appendable))


atomMatchesSuper : Vars.SuperType -> ModuleName.Canonical -> Name.Name -> Bool
atomMatchesSuper super home name =
    case super of
        Vars.Number ->
            isNumber home name

        Vars.Comparable ->
            isNumber home name || Error.isString home name || Error.isChar home name

        Vars.Appendable ->
            Error.isString home name

        Vars.CompAppend ->
            Error.isString home name


isNumber : ModuleName.Canonical -> Name.Name -> Bool
isNumber home name =
    (home == ModuleName.basics)
        && (name == Name.int || name == Name.float)


unifyFlexSuperStructure : Context -> Vars.SuperType -> Vars.FlatType -> Unify ()
unifyFlexSuperStructure context super flatType =
    case flatType of
        Vars.App1 home name [] ->
            if atomMatchesSuper super home name then
                merge context (Vars.Structure flatType)

            else
                mismatch

        Vars.App1 home name [ variable ] ->
            if home == ModuleName.list && name == Name.list then
                case super of
                    Vars.Number ->
                        mismatch

                    Vars.Appendable ->
                        merge context (Vars.Structure flatType)

                    Vars.Comparable ->
                        comparableOccursCheck context
                            |> andThen (\_ -> unifyComparableRecursive variable)
                            |> andThen (\_ -> merge context (Vars.Structure flatType))

                    Vars.CompAppend ->
                        comparableOccursCheck context
                            |> andThen (\_ -> unifyComparableRecursive variable)
                            |> andThen (\_ -> merge context (Vars.Structure flatType))

            else
                mismatch

        Vars.Tuple1 a b cs ->
            case super of
                Vars.Number ->
                    mismatch

                Vars.Appendable ->
                    mismatch

                Vars.Comparable ->
                    comparableOccursCheck context
                        |> andThen (\_ -> forEach_ (a :: b :: cs) unifyComparableRecursive)
                        |> andThen (\_ -> merge context (Vars.Structure flatType))

                Vars.CompAppend ->
                    mismatch

        _ ->
            mismatch



-- TODO: is there some way to avoid doing this?
-- Do type classes require occurs checks?


comparableOccursCheck : Context -> Unify ()
comparableOccursCheck props =
    Unify
        (\vars ->
            Occurs.occurs props.var2
                |> IO.map
                    (\hasOccurred ->
                        if hasOccurred then
                            Err (UnifyErr vars ())

                        else
                            Ok (UnifyOk vars ())
                    )
        )


unifyComparableRecursive : Vars.Variable -> Unify ()
unifyComparableRecursive var =
    register
        (UF.get var
            |> IO.andThen
                (\descProps ->
                    UF.fresh (IO.makeDescriptor (Type.unnamedFlexSuper Vars.Comparable) descProps.rank Type.noMark Nothing)
                )
        )
        |> andThen (\compVar -> guardedUnify compVar var)



-- ====== UNIFY ALIASES ======


unifyAlias : Context -> ModuleName.Canonical -> Name.Name -> List ( Name.Name, Vars.Variable ) -> Vars.Variable -> Vars.Content -> Unify ()
unifyAlias ctx home name args realVar otherContent =
    let
        second =
            ctx.var2
    in
    case otherContent of
        Vars.FlexVar _ ->
            merge ctx (Vars.Alias home name args realVar)

        Vars.FlexSuper _ _ ->
            subUnify realVar second

        Vars.RigidVar _ ->
            subUnify realVar second

        Vars.RigidSuper _ _ ->
            subUnify realVar second

        Vars.Alias otherHome otherName otherArgs otherRealVar ->
            if name == otherName && home == otherHome then
                zipAllWithM_ subUnify (List.map Tuple.second args) (List.map Tuple.second otherArgs)
                    |> andThen (\_ -> merge ctx otherContent)

            else
                subUnify realVar otherRealVar

        Vars.Structure _ ->
            subUnify realVar second

        Vars.Error ->
            merge ctx Vars.Error



-- ====== UNIFY STRUCTURES ======


unifyStructure : Context -> Vars.FlatType -> Vars.Content -> Vars.Content -> Unify ()
unifyStructure ctx flatType content otherContent =
    let
        first =
            ctx.var1

        second =
            ctx.var2
    in
    case otherContent of
        Vars.FlexVar _ ->
            merge ctx content

        Vars.FlexSuper super _ ->
            unifyFlexSuperStructure (reorient ctx) super flatType

        Vars.RigidVar _ ->
            mismatch

        Vars.RigidSuper _ _ ->
            mismatch

        Vars.Alias _ _ _ realVar ->
            subUnify first realVar

        Vars.Structure otherFlatType ->
            case ( flatType, otherFlatType ) of
                ( Vars.App1 home name args, Vars.App1 otherHome otherName otherArgs ) ->
                    if home == otherHome && name == otherName then
                        zipAllWithM_ subUnify args otherArgs
                            |> andThen (\_ -> merge ctx otherContent)

                    else
                        mismatch

                ( Vars.Fun1 arg1 res1, Vars.Fun1 arg2 res2 ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx otherContent)

                ( Vars.FunL arg1 res1 set1, Vars.FunL arg2 res2 set2 ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> subUnify set1 set2)
                        |> andThen (\_ -> merge ctx otherContent)

                -- Mixed arrows: unify the type structure, keep the slotted
                -- side. Legal only transiently (a demand encoded before lss
                -- gating); semantically Fun1 ≡ FunL with an unconstrained slot.
                ( Vars.Fun1 arg1 res1, Vars.FunL arg2 res2 _ ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx otherContent)

                ( Vars.FunL arg1 res1 _, Vars.Fun1 arg2 res2 ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx content)

                ( Vars.LambdaSet1 ls1, Vars.LambdaSet1 ls2 ) ->
                    -- Join-semilattice union (LSS): TOTAL — set unification
                    -- never mismatches. Members are ground ids; ⊤ absorbs and
                    -- carries none (members-under-⊤ are dead at every reader).
                    -- One O(n+m) merge-scan classifies the pair; subsumption
                    -- reuses the covering side's content AS-IS, and a real
                    -- union allocates only the merged spine with suffix
                    -- sharing. NOTE the ≤8 `maxSetSize` cap is READBACK-only
                    -- (zonkSetSlot): in-store sets can transiently exceed it
                    -- (Run B measured a 81-97-member tail), which the linear
                    -- scan tolerates.
                    case ( ls1, ls2 ) of
                        -- §4.9 provenance: (⊤,⊤) takes the higher-priority
                        -- kind (min code) via the shared per-kind CAFs —
                        -- still allocation-free; absorption keeps the
                        -- surviving ⊤'s birth kind.
                        ( Vars.LsTop p1, Vars.LsTop p2 ) ->
                            if p1 <= p2 then
                                merge ctx content

                            else
                                merge ctx otherContent

                        ( Vars.LsTop _, _ ) ->
                            merge ctx content

                        ( _, Vars.LsTop _ ) ->
                            merge ctx otherContent

                        ( Vars.LsMembers m1, Vars.LsMembers m2 ) ->
                            case IO.classifySorted m1 m2 of
                                Vars.SortedEqual ->
                                    merge ctx content

                                Vars.SortedSuper ->
                                    -- m2 ⊆ m1: side 1's content as-is.
                                    merge ctx content

                                Vars.SortedSub ->
                                    -- m1 ⊆ m2: side 2's content as-is.
                                    merge ctx otherContent

                                Vars.SortedMixed ->
                                    merge ctx (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers (IO.unionSortedAsc m1 m2))))

                        -- LSS_023 (`plans/lss-directed-set-flow.md`): class
                        -- merges MERGE the deferred edge lists — the union-hook
                        -- problem is solved by representation, not by hooks.
                        -- Dedupe uses IO.pointKey (Unify cannot import Engine).
                        -- The join stays TOTAL.
                        ( Vars.LsFrom m1 s1, Vars.LsFrom m2 s2 ) ->
                            merge ctx
                                (Vars.Structure
                                    (Vars.LambdaSet1
                                        (Vars.LsFrom (IO.unionSortedAsc m1 m2)
                                            (dedupeSources (s1 ++ s2))
                                        )
                                    )
                                )

                        ( Vars.LsFrom m1 s1, Vars.LsMembers m2 ) ->
                            merge ctx (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom (IO.unionSortedAsc m1 m2) s1)))

                        ( Vars.LsMembers m1, Vars.LsFrom m2 s2 ) ->
                            merge ctx (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom (IO.unionSortedAsc m1 m2) s2)))

                ( Vars.EmptyRecord1, Vars.EmptyRecord1 ) ->
                    merge ctx otherContent

                ( Vars.Record1 fields ext, Vars.EmptyRecord1 ) ->
                    if Dict.isEmpty fields then
                        subUnify ext second

                    else
                        mismatch

                ( Vars.EmptyRecord1, Vars.Record1 fields ext ) ->
                    if Dict.isEmpty fields then
                        subUnify first ext

                    else
                        mismatch

                ( Vars.Record1 fields1 ext1, Vars.Record1 fields2 ext2 ) ->
                    Unify
                        (\vars ->
                            gatherFields fields1 ext1
                                |> IO.andThen
                                    (\structure1 ->
                                        gatherFields fields2 ext2
                                            |> IO.andThen
                                                (\structure2 ->
                                                    case unifyRecord ctx structure1 structure2 of
                                                        Unify k ->
                                                            k vars
                                                )
                                    )
                        )

                ( Vars.Tuple1 a b cs, Vars.Tuple1 x y zs ) ->
                    subUnify a x
                        |> andThen (\_ -> subUnify b y)
                        |> andThen (\_ -> subUnifyTuple cs zs ctx otherContent)

                ( Vars.Unit1, Vars.Unit1 ) ->
                    merge ctx otherContent

                _ ->
                    mismatch

        Vars.Error ->
            merge ctx Vars.Error



-- ====== UNIFY ARGS ======
-- ====== UNIFY RECORDS ======


unifyRecord : Context -> RecordStructure -> RecordStructure -> Unify ()
unifyRecord context (RecordStructure fields1 ext1) (RecordStructure fields2 ext2) =
    let
        sharedFields : Dict Name.Name ( Vars.Variable, Vars.Variable )
        sharedFields =
            Dict.merge
                (\_ _ acc -> acc)
                (\k a b acc -> Dict.insert k ( a, b ) acc)
                (\_ _ acc -> acc)
                fields1
                fields2
                Dict.empty

        uniqueFields1 : Dict Name.Name Vars.Variable
        uniqueFields1 =
            Dict.diff fields1 fields2

        uniqueFields2 : Dict Name.Name Vars.Variable
        uniqueFields2 =
            Dict.diff fields2 fields1
    in
    if Dict.isEmpty uniqueFields1 then
        if Dict.isEmpty uniqueFields2 then
            subUnify ext1 ext2
                |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty ext1)

        else
            fresh context (Vars.Structure (Vars.Record1 uniqueFields2 ext2))
                |> andThen
                    (\subRecord ->
                        subUnify ext1 subRecord
                            |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty subRecord)
                    )

    else if Dict.isEmpty uniqueFields2 then
        fresh context (Vars.Structure (Vars.Record1 uniqueFields1 ext1))
            |> andThen
                (\subRecord ->
                    subUnify subRecord ext2
                        |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty subRecord)
                )

    else
        let
            otherFields : Dict Name.Name Vars.Variable
            otherFields =
                Dict.union uniqueFields1 uniqueFields2
        in
        fresh context Type.unnamedFlexVar
            |> andThen
                (\ext ->
                    fresh context (Vars.Structure (Vars.Record1 uniqueFields1 ext))
                        |> andThen
                            (\sub1 ->
                                fresh context (Vars.Structure (Vars.Record1 uniqueFields2 ext))
                                    |> andThen
                                        (\sub2 ->
                                            subUnify ext1 sub2
                                                |> andThen (\_ -> subUnify sub1 ext2)
                                                |> andThen (\_ -> unifySharedFields context sharedFields otherFields ext)
                                        )
                            )
                )


unifySharedFields : Context -> Dict Name.Name ( Vars.Variable, Vars.Variable ) -> Dict Name.Name Vars.Variable -> Vars.Variable -> Unify ()
unifySharedFields context sharedFields otherFields ext =
    traverseAll unifyField sharedFields
        |> andThen
            (\result ->
                case result of
                    Just matchingFields ->
                        merge context (Vars.Structure (Vars.Record1 (Dict.union matchingFields otherFields) ext))

                    Nothing ->
                        mismatch
            )


{-| Traverse every entry, failing as a whole if `func` declines any of them.

The caller used to reconstruct that verdict by comparing `Dict.size` of the
input against `Dict.size` of the output — two full tree walks to recover one bit
that the traversal already knew.

-}
traverseAll : (comparable -> b -> Unify (Maybe c)) -> Dict comparable b -> Unify (Maybe (Dict comparable c))
traverseAll func =
    Dict.foldl
        (\a b ->
            andThen
                (\acc ->
                    map
                        (\maybeC ->
                            Maybe.map2 (\c dict -> Dict.insert a c dict) maybeC acc
                        )
                        (func a b)
                )
        )
        (pure (Just Dict.empty))


unifyField : Name.Name -> ( Vars.Variable, Vars.Variable ) -> Unify (Maybe Vars.Variable)
unifyField _ ( actual, expected ) =
    try (subUnify actual expected)
        |> map
            (\ok ->
                if ok then
                    Just actual

                else
                    Nothing
            )



-- ====== GATHER RECORD STRUCTURE ======


type RecordStructure
    = RecordStructure (Dict Name.Name Vars.Variable) Vars.Variable


{-| Dedupe an `LsFrom` source list by raw Point index, preserving first
occurrence. Small lists (edge fan-in per slot); quadratic is fine and
allocation-light.
-}
dedupeSources : List Vars.Variable -> List Vars.Variable
dedupeSources sources =
    dedupeSourcesGo sources []


dedupeSourcesGo : List Vars.Variable -> List Int -> List Vars.Variable
dedupeSourcesGo sources seen =
    case sources of
        [] ->
            []

        v :: rest ->
            let
                k =
                    IO.pointKey v
            in
            if List.member k seen then
                dedupeSourcesGo rest seen

            else
                v :: dedupeSourcesGo rest (k :: seen)


gatherFields : Dict Name.Name Vars.Variable -> Vars.Variable -> IO RecordStructure
gatherFields fields variable =
    UF.get variable
        |> IO.andThen
            (\descProps ->
                case descProps.content of
                    Vars.Structure (Vars.Record1 subFields subExt) ->
                        gatherFields (Dict.union fields subFields) subExt

                    Vars.Alias _ _ _ var ->
                        -- TODO may be dropping useful alias info here
                        gatherFields fields var

                    _ ->
                        IO.pure (RecordStructure fields variable)
            )
