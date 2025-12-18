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
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- UNIFY


{-| Result of attempting to unify two type variables.

AnswerOk indicates successful unification and includes all newly created
variables. AnswerErr indicates a type mismatch and includes the conflicting
types for error reporting.

-}
type Answer
    = AnswerOk (List IO.Variable)
    | AnswerErr (List IO.Variable) Error.Type Error.Type


{-| Attempts to unify two type variables.

Finds a substitution that makes both variables represent the same type, or
returns an error with the conflicting types. Uses union-find to efficiently
merge equivalent variables and handles all type constructors including
functions, records, tuples, and type aliases.

-}
unify : IO.Variable -> IO.Variable -> IO Answer
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


onSuccess : List IO.Variable -> () -> IO Answer
onSuccess vars () =
    IO.pure (AnswerOk vars)


errorDescriptor : IO.Descriptor
errorDescriptor =
    IO.makeDescriptor IO.Error Type.noRank Type.noMark Nothing



-- CPS UNIFIER


type Unify a
    = Unify (List IO.Variable -> IO (Result UnifyErr (UnifyOk a)))


type UnifyOk a
    = UnifyOk (List IO.Variable) a


type UnifyErr
    = UnifyErr (List IO.Variable) ()


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


register : IO IO.Variable -> Unify IO.Variable
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



-- UNIFICATION HELPERS


type Context
    = Context ContextProps


type alias ContextProps =
    { var1 : IO.Variable
    , desc1 : IO.Descriptor
    , var2 : IO.Variable
    , desc2 : IO.Descriptor
    }


{-| Helper to construct Context with positional args
-}
makeContext : IO.Variable -> IO.Descriptor -> IO.Variable -> IO.Descriptor -> Context
makeContext var1 desc1 var2 desc2 =
    Context { var1 = var1, desc1 = desc1, var2 = var2, desc2 = desc2 }


reorient : Context -> Context
reorient (Context props) =
    makeContext props.var2 props.desc2 props.var1 props.desc1



-- MERGE
-- merge : Context -> UF.Content -> Unify ( UF.Point UF.Descriptor, UF.Point UF.Descriptor )


merge : Context -> IO.Content -> Unify ()
merge (Context props) content =
    let
        (IO.Descriptor desc1Props) =
            props.desc1

        (IO.Descriptor desc2Props) =
            props.desc2
    in
    Unify
        (\vars ->
            UF.union props.var1 props.var2 (IO.makeDescriptor content (min desc1Props.rank desc2Props.rank) Type.noMark Nothing)
                |> IO.map (Ok << UnifyOk vars)
        )


fresh : Context -> IO.Content -> Unify IO.Variable
fresh (Context props) content =
    let
        (IO.Descriptor desc1Props) =
            props.desc1

        (IO.Descriptor desc2Props) =
            props.desc2
    in
    IO.makeDescriptor content (min desc1Props.rank desc2Props.rank) Type.noMark Nothing |> UF.fresh |> register



-- ACTUALLY UNIFY THINGS


guardedUnify : IO.Variable -> IO.Variable -> Unify ()
guardedUnify left right =
    Unify
        (\vars ->
            UF.equivalent left right
                |> IO.andThen
                    (\equivalent ->
                        if equivalent then
                            IO.pure (Ok (UnifyOk vars ()))

                        else
                            UF.get left
                                |> IO.andThen
                                    (\leftDesc ->
                                        UF.get right
                                            |> IO.andThen
                                                (\rightDesc ->
                                                    case actuallyUnify (makeContext left leftDesc right rightDesc) of
                                                        Unify k ->
                                                            k vars
                                                )
                                    )
                    )
        )


subUnify : IO.Variable -> IO.Variable -> Unify ()
subUnify var1 var2 =
    guardedUnify var1 var2


subUnifyTuple : List IO.Variable -> List IO.Variable -> Context -> IO.Content -> Unify ()
subUnifyTuple cs zs context otherContent =
    case ( cs, zs ) of
        ( [], [] ) ->
            merge context otherContent

        ( c :: restCs, z :: restZs ) ->
            subUnify c z
                |> andThen (\_ -> subUnifyTuple restCs restZs context otherContent)

        _ ->
            mismatch


actuallyUnify : Context -> Unify ()
actuallyUnify ((Context props) as ctx) =
    let
        (IO.Descriptor desc1Props) =
            props.desc1

        (IO.Descriptor desc2Props) =
            props.desc2

        firstContent =
            desc1Props.content

        secondContent =
            desc2Props.content
    in
    case firstContent of
        IO.FlexVar _ ->
            unifyFlex ctx firstContent secondContent

        IO.FlexSuper super _ ->
            unifyFlexSuper ctx super firstContent secondContent

        IO.RigidVar _ ->
            unifyRigid ctx Nothing firstContent secondContent

        IO.RigidSuper super _ ->
            unifyRigid ctx (Just super) firstContent secondContent

        IO.Alias home name args realVar ->
            unifyAlias ctx home name args realVar secondContent

        IO.Structure flatType ->
            unifyStructure ctx flatType firstContent secondContent

        IO.Error ->
            -- If there was an error, just pretend it is okay. This lets us avoid
            -- "cascading" errors where one problem manifests as multiple message.
            merge ctx IO.Error



-- UNIFY FLEXIBLE VARIABLES


unifyFlex : Context -> IO.Content -> IO.Content -> Unify ()
unifyFlex context content otherContent =
    case otherContent of
        IO.Error ->
            merge context IO.Error

        IO.FlexVar maybeName ->
            merge context <|
                case maybeName of
                    Nothing ->
                        content

                    Just _ ->
                        otherContent

        IO.FlexSuper _ _ ->
            merge context otherContent

        IO.RigidVar _ ->
            merge context otherContent

        IO.RigidSuper _ _ ->
            merge context otherContent

        IO.Alias _ _ _ _ ->
            merge context otherContent

        IO.Structure _ ->
            merge context otherContent



-- UNIFY RIGID VARIABLES


unifyRigid : Context -> Maybe IO.SuperType -> IO.Content -> IO.Content -> Unify ()
unifyRigid context maybeSuper content otherContent =
    case otherContent of
        IO.FlexVar _ ->
            merge context content

        IO.FlexSuper otherSuper _ ->
            case maybeSuper of
                Just super ->
                    if combineRigidSupers super otherSuper then
                        merge context content

                    else
                        mismatch

                Nothing ->
                    mismatch

        IO.RigidVar _ ->
            mismatch

        IO.RigidSuper _ _ ->
            mismatch

        IO.Alias _ _ _ _ ->
            mismatch

        IO.Structure _ ->
            mismatch

        IO.Error ->
            merge context IO.Error



-- UNIFY SUPER VARIABLES


unifyFlexSuper : Context -> IO.SuperType -> IO.Content -> IO.Content -> Unify ()
unifyFlexSuper ((Context props) as ctx) super content otherContent =
    let
        first =
            props.var1
    in
    case otherContent of
        IO.Structure flatType ->
            unifyFlexSuperStructure ctx super flatType

        IO.RigidVar _ ->
            mismatch

        IO.RigidSuper otherSuper _ ->
            if combineRigidSupers otherSuper super then
                merge ctx otherContent

            else
                mismatch

        IO.FlexVar _ ->
            merge ctx content

        IO.FlexSuper otherSuper _ ->
            case super of
                IO.Number ->
                    case otherSuper of
                        IO.Number ->
                            merge ctx content

                        IO.Comparable ->
                            merge ctx content

                        IO.Appendable ->
                            mismatch

                        IO.CompAppend ->
                            mismatch

                IO.Comparable ->
                    case otherSuper of
                        IO.Comparable ->
                            merge ctx otherContent

                        IO.Number ->
                            merge ctx otherContent

                        IO.Appendable ->
                            Type.unnamedFlexSuper IO.CompAppend |> merge ctx

                        IO.CompAppend ->
                            merge ctx otherContent

                IO.Appendable ->
                    case otherSuper of
                        IO.Appendable ->
                            merge ctx otherContent

                        IO.Comparable ->
                            Type.unnamedFlexSuper IO.CompAppend |> merge ctx

                        IO.CompAppend ->
                            merge ctx otherContent

                        IO.Number ->
                            mismatch

                IO.CompAppend ->
                    case otherSuper of
                        IO.Comparable ->
                            merge ctx content

                        IO.Appendable ->
                            merge ctx content

                        IO.CompAppend ->
                            merge ctx content

                        IO.Number ->
                            mismatch

        IO.Alias _ _ _ realVar ->
            subUnify first realVar

        IO.Error ->
            merge ctx IO.Error


combineRigidSupers : IO.SuperType -> IO.SuperType -> Bool
combineRigidSupers rigid flex =
    rigid
        == flex
        || (rigid == IO.Number && flex == IO.Comparable)
        || (rigid == IO.CompAppend && (flex == IO.Comparable || flex == IO.Appendable))


atomMatchesSuper : IO.SuperType -> IO.Canonical -> Name.Name -> Bool
atomMatchesSuper super home name =
    case super of
        IO.Number ->
            isNumber home name

        IO.Comparable ->
            isNumber home name || Error.isString home name || Error.isChar home name

        IO.Appendable ->
            Error.isString home name

        IO.CompAppend ->
            Error.isString home name


isNumber : IO.Canonical -> Name.Name -> Bool
isNumber home name =
    (home == ModuleName.basics)
        && (name == Name.int || name == Name.float)


unifyFlexSuperStructure : Context -> IO.SuperType -> IO.FlatType -> Unify ()
unifyFlexSuperStructure context super flatType =
    case flatType of
        IO.App1 home name [] ->
            if atomMatchesSuper super home name then
                merge context (IO.Structure flatType)

            else
                mismatch

        IO.App1 home name [ variable ] ->
            if home == ModuleName.list && name == Name.list then
                case super of
                    IO.Number ->
                        mismatch

                    IO.Appendable ->
                        merge context (IO.Structure flatType)

                    IO.Comparable ->
                        comparableOccursCheck context
                            |> andThen (\_ -> unifyComparableRecursive variable)
                            |> andThen (\_ -> merge context (IO.Structure flatType))

                    IO.CompAppend ->
                        comparableOccursCheck context
                            |> andThen (\_ -> unifyComparableRecursive variable)
                            |> andThen (\_ -> merge context (IO.Structure flatType))

            else
                mismatch

        IO.Tuple1 a b cs ->
            case super of
                IO.Number ->
                    mismatch

                IO.Appendable ->
                    mismatch

                IO.Comparable ->
                    List.foldl (\var _ -> unifyComparableRecursive var) (comparableOccursCheck context) (a :: b :: cs)
                        |> andThen (\_ -> merge context (IO.Structure flatType))

                IO.CompAppend ->
                    mismatch

        _ ->
            mismatch



-- TODO: is there some way to avoid doing this?
-- Do type classes require occurs checks?


comparableOccursCheck : Context -> Unify ()
comparableOccursCheck (Context props) =
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


unifyComparableRecursive : IO.Variable -> Unify ()
unifyComparableRecursive var =
    register
        (UF.get var
            |> IO.andThen
                (\(IO.Descriptor descProps) ->
                    UF.fresh (IO.makeDescriptor (Type.unnamedFlexSuper IO.Comparable) descProps.rank Type.noMark Nothing)
                )
        )
        |> andThen (\compVar -> guardedUnify compVar var)



-- UNIFY ALIASES


unifyAlias : Context -> IO.Canonical -> Name.Name -> List ( Name.Name, IO.Variable ) -> IO.Variable -> IO.Content -> Unify ()
unifyAlias ((Context props) as ctx) home name args realVar otherContent =
    let
        second =
            props.var2
    in
    case otherContent of
        IO.FlexVar _ ->
            merge ctx (IO.Alias home name args realVar)

        IO.FlexSuper _ _ ->
            subUnify realVar second

        IO.RigidVar _ ->
            subUnify realVar second

        IO.RigidSuper _ _ ->
            subUnify realVar second

        IO.Alias otherHome otherName otherArgs otherRealVar ->
            if name == otherName && home == otherHome then
                Unify
                    (\vars ->
                        unifyAliasArgs vars args otherArgs
                            |> IO.andThen
                                (\res ->
                                    case res of
                                        Ok (UnifyOk vars1 ()) ->
                                            case merge ctx otherContent of
                                                Unify k ->
                                                    k vars1

                                        Err err ->
                                            IO.pure (Err err)
                                )
                    )

            else
                subUnify realVar otherRealVar

        IO.Structure _ ->
            subUnify realVar second

        IO.Error ->
            merge ctx IO.Error


unifyAliasArgs : List IO.Variable -> List ( Name.Name, IO.Variable ) -> List ( Name.Name, IO.Variable ) -> IO (Result UnifyErr (UnifyOk ()))
unifyAliasArgs vars args1 args2 =
    case args1 of
        ( _, arg1 ) :: others1 ->
            case args2 of
                ( _, arg2 ) :: others2 ->
                    case subUnify arg1 arg2 of
                        Unify k ->
                            k vars
                                |> IO.andThen
                                    (\res1 ->
                                        case res1 of
                                            Ok (UnifyOk vs ()) ->
                                                unifyAliasArgs vs others1 others2

                                            Err (UnifyErr vs ()) ->
                                                unifyAliasArgs vs others1 others2
                                                    |> IO.map
                                                        (\res2 ->
                                                            case res2 of
                                                                Ok (UnifyOk vs_ ()) ->
                                                                    Err (UnifyErr vs_ ())

                                                                Err err ->
                                                                    Err err
                                                        )
                                    )

                _ ->
                    IO.pure (Err (UnifyErr vars ()))

        [] ->
            case args2 of
                [] ->
                    IO.pure (Ok (UnifyOk vars ()))

                _ ->
                    IO.pure (Err (UnifyErr vars ()))



-- UNIFY STRUCTURES


unifyStructure : Context -> IO.FlatType -> IO.Content -> IO.Content -> Unify ()
unifyStructure ((Context props) as ctx) flatType content otherContent =
    let
        first =
            props.var1

        second =
            props.var2
    in
    case otherContent of
        IO.FlexVar _ ->
            merge ctx content

        IO.FlexSuper super _ ->
            unifyFlexSuperStructure (reorient ctx) super flatType

        IO.RigidVar _ ->
            mismatch

        IO.RigidSuper _ _ ->
            mismatch

        IO.Alias _ _ _ realVar ->
            subUnify first realVar

        IO.Structure otherFlatType ->
            case ( flatType, otherFlatType ) of
                ( IO.App1 home name args, IO.App1 otherHome otherName otherArgs ) ->
                    if home == otherHome && name == otherName then
                        Unify
                            (\vars ->
                                unifyArgs vars args otherArgs
                                    |> IO.andThen
                                        (\unifiedArgs ->
                                            case unifiedArgs of
                                                Ok (UnifyOk vars1 ()) ->
                                                    case merge ctx otherContent of
                                                        Unify k ->
                                                            k vars1

                                                Err err ->
                                                    IO.pure (Err err)
                                        )
                            )

                    else
                        mismatch

                ( IO.Fun1 arg1 res1, IO.Fun1 arg2 res2 ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx otherContent)

                ( IO.EmptyRecord1, IO.EmptyRecord1 ) ->
                    merge ctx otherContent

                ( IO.Record1 fields ext, IO.EmptyRecord1 ) ->
                    if Dict.isEmpty fields then
                        subUnify ext second

                    else
                        mismatch

                ( IO.EmptyRecord1, IO.Record1 fields ext ) ->
                    if Dict.isEmpty fields then
                        subUnify first ext

                    else
                        mismatch

                ( IO.Record1 fields1 ext1, IO.Record1 fields2 ext2 ) ->
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

                ( IO.Tuple1 a b cs, IO.Tuple1 x y zs ) ->
                    subUnify a x
                        |> andThen (\_ -> subUnify b y)
                        |> andThen (\_ -> subUnifyTuple cs zs ctx otherContent)

                ( IO.Unit1, IO.Unit1 ) ->
                    merge ctx otherContent

                _ ->
                    mismatch

        IO.Error ->
            merge ctx IO.Error



-- UNIFY ARGS


unifyArgs : List IO.Variable -> List IO.Variable -> List IO.Variable -> IO (Result UnifyErr (UnifyOk ()))
unifyArgs vars args1 args2 =
    case args1 of
        arg1 :: others1 ->
            case args2 of
                arg2 :: others2 ->
                    case subUnify arg1 arg2 of
                        Unify k ->
                            k vars
                                |> IO.andThen
                                    (\result ->
                                        case result of
                                            Ok (UnifyOk vs ()) ->
                                                unifyArgs vs others1 others2

                                            Err (UnifyErr vs ()) ->
                                                unifyArgs vs others1 others2
                                                    |> IO.map
                                                        (Result.andThen
                                                            (\(UnifyOk vs_ ()) ->
                                                                Err (UnifyErr vs_ ())
                                                            )
                                                        )
                                    )

                _ ->
                    IO.pure (Err (UnifyErr vars ()))

        [] ->
            case args2 of
                [] ->
                    IO.pure (Ok (UnifyOk vars ()))

                _ ->
                    IO.pure (Err (UnifyErr vars ()))



-- UNIFY RECORDS


unifyRecord : Context -> RecordStructure -> RecordStructure -> Unify ()
unifyRecord context (RecordStructure fields1 ext1) (RecordStructure fields2 ext2) =
    let
        sharedFields : Dict String Name.Name ( IO.Variable, IO.Variable )
        sharedFields =
            Utils.mapIntersectionWith identity compare Tuple.pair fields1 fields2

        uniqueFields1 : Dict String Name.Name IO.Variable
        uniqueFields1 =
            Dict.diff fields1 fields2

        uniqueFields2 : Dict String Name.Name IO.Variable
        uniqueFields2 =
            Dict.diff fields2 fields1
    in
    if Dict.isEmpty uniqueFields1 then
        if Dict.isEmpty uniqueFields2 then
            subUnify ext1 ext2
                |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty ext1)

        else
            fresh context (IO.Structure (IO.Record1 uniqueFields2 ext2))
                |> andThen
                    (\subRecord ->
                        subUnify ext1 subRecord
                            |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty subRecord)
                    )

    else if Dict.isEmpty uniqueFields2 then
        fresh context (IO.Structure (IO.Record1 uniqueFields1 ext1))
            |> andThen
                (\subRecord ->
                    subUnify subRecord ext2
                        |> andThen (\_ -> unifySharedFields context sharedFields Dict.empty subRecord)
                )

    else
        let
            otherFields : Dict String Name.Name IO.Variable
            otherFields =
                Dict.union uniqueFields1 uniqueFields2
        in
        fresh context Type.unnamedFlexVar
            |> andThen
                (\ext ->
                    fresh context (IO.Structure (IO.Record1 uniqueFields1 ext))
                        |> andThen
                            (\sub1 ->
                                fresh context (IO.Structure (IO.Record1 uniqueFields2 ext))
                                    |> andThen
                                        (\sub2 ->
                                            subUnify ext1 sub2
                                                |> andThen (\_ -> subUnify sub1 ext2)
                                                |> andThen (\_ -> unifySharedFields context sharedFields otherFields ext)
                                        )
                            )
                )


unifySharedFields : Context -> Dict String Name.Name ( IO.Variable, IO.Variable ) -> Dict String Name.Name IO.Variable -> IO.Variable -> Unify ()
unifySharedFields context sharedFields otherFields ext =
    traverseMaybe identity compare unifyField sharedFields
        |> andThen
            (\matchingFields ->
                if Dict.size sharedFields == Dict.size matchingFields then
                    merge context (IO.Structure (IO.Record1 (Dict.union matchingFields otherFields) ext))

                else
                    mismatch
            )


traverseMaybe : (a -> comparable) -> (a -> a -> Order) -> (a -> b -> Unify (Maybe c)) -> Dict comparable a b -> Unify (Dict comparable a c)
traverseMaybe toComparable keyComparison func =
    Dict.foldl keyComparison
        (\a b ->
            andThen
                (\acc ->
                    map
                        (\maybeC ->
                            maybeC
                                |> Maybe.map (\c -> Dict.insert toComparable a c acc)
                                |> Maybe.withDefault acc
                        )
                        (func a b)
                )
        )
        (pure Dict.empty)


unifyField : Name.Name -> ( IO.Variable, IO.Variable ) -> Unify (Maybe IO.Variable)
unifyField _ ( actual, expected ) =
    Unify
        (\vars ->
            case subUnify actual expected of
                Unify k ->
                    k vars
                        |> IO.map
                            (\result ->
                                case result of
                                    Ok (UnifyOk vs ()) ->
                                        Ok (UnifyOk vs (Just actual))

                                    Err (UnifyErr vs ()) ->
                                        Ok (UnifyOk vs Nothing)
                            )
        )



-- GATHER RECORD STRUCTURE


type RecordStructure
    = RecordStructure (Dict String Name.Name IO.Variable) IO.Variable


gatherFields : Dict String Name.Name IO.Variable -> IO.Variable -> IO RecordStructure
gatherFields fields variable =
    UF.get variable
        |> IO.andThen
            (\(IO.Descriptor descProps) ->
                case descProps.content of
                    IO.Structure (IO.Record1 subFields subExt) ->
                        gatherFields (Dict.union fields subFields) subExt

                    IO.Alias _ _ _ var ->
                        -- TODO may be dropping useful alias info here
                        gatherFields fields var

                    _ ->
                        IO.pure (RecordStructure fields variable)
            )
