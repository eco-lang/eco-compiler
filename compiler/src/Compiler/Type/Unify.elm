module Compiler.Type.Unify exposing
    ( unify, Answer(..)
    , unifyBoolS, unifyS
    )

{-| Type inference turns a program into equations between type variables, and
this module solves one equation at a time: it decides whether two variables can
stand for the same type and, if they can, makes them one.

A variable is a point of the store, as `Compiler.AST.TypeVars` describes, and
points known to be equal form a class with one shared descriptor, as
`Compiler.Type.UnionFind` describes. To _unify_ two points is to compare the
contents of their two classes and, when they agree, join the classes under a
descriptor whose content is the agreed type. The join takes the lower of the two
ranks, resets the mark to `Type.noMark` and clears the copy. Where the two
contents are structures, their parts are unified first, recursively.

Agreement follows a few rules.

A flexible variable agrees with anything and takes the other side's content;
of two flexible variables, a named one's content survives. A rigid variable
agrees only with a flexible variable, with `Error`, or, for a rigid super type,
with a flexible super type it subsumes: equal ones, a rigid `number` with a
flexible `comparable`, and a rigid `compappend` with a flexible `comparable` or
`appendable`.

A _super type_ is one of Elm's constrained variables. A flexible `number` is
`Int` or `Float` from `Basics`. A flexible `comparable` is a number, `String`,
`Char`, a `List` of comparables, or a tuple of comparables, every element of
which is checked. A flexible `appendable` is `String` or any `List`; a
`compappend` is `String` or a `List` of comparables, never a tuple. Two flexible
super types join to the narrower: `number` with `comparable` gives `number`,
`comparable` with `appendable` gives `compappend`, and `number` mismatches
`appendable` and `compappend`. Before a `List` or tuple is accepted as
comparable, an occurs check rejects a structure that contains its own variable.

An alias is unified through its expansion. Against a flexible variable the
alias content is kept; against an alias of the same module and name only the
arguments are unified; against anything else but `Error` only the alias's
expansion point is unified, so the alias's own point stays a class of its own.
The one asymmetry is a rigid variable: with the rigid variable first the pair
mismatches, and with the alias first the alias's expansion is unified with the
rigid variable.

`Error` content agrees with everything and the joined class holds `Error`, so
that one type error does not cause a cascade of further reports.

Lambda sets, the contents of the set slot of a `FunL` arrow, are joined rather
than matched, and the join never fails. Top absorbs any other set; of two tops
the one with the lower provenance code is kept. Two member lists give their
union, and when one already contains the other its content is kept unchanged.
An `LsFrom` set's sources are kept through the join: two source lists are
concatenated, keeping the first occurrence of each point. No cap on the size of
a set is applied here. A `Fun1` arrow agrees with a `FunL` arrow whose argument
and result agree, and the join keeps the `FunL`.

Records are unified field by field, through extension chains: each side's
fields are gathered by following `Record1` extensions and aliases. Fields both
sides have are unified; fields only one side has are pushed into the other
side's extension as a fresh record, sharing a fresh extension variable when
both sides have fields of their own.

The fresh variables made along the way, by records and by comparable element
checks, are collected and returned with the answer, on failure as well as on
success, so that the caller can give them a rank. Where a failure in one part
would otherwise skip the rest, the arguments of a type application and of an
alias are all unified before the failure is reported, and so are the shared
fields of a record once its extensions agree; a mismatch between the extensions
skips the shared fields, and the parts of an arrow or a tuple stop at the first
failure.

A failed unification is not undone. Classes the attempt joined before it met
the mismatch stay joined. `unify` and `unifyS` then render both types and join
the two classes under `Error`; `unifyBoolS` does neither and leaves the store
as the attempt left it.


# Unification

@docs unify, Answer
@docs unifyBoolS, unifyS

-}

import Compiler.AST.TypeVars as Vars
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Type.Error as Error
import Compiler.Type.Occurs as Occurs
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



-- ====== UNIFY ======


{-| The outcome of unifying two variables, with the fresh variables the attempt
made.

`AnswerOk` means the two variables are now one class.

`AnswerErr` carries the two types as rendered after the failed attempt, so they
include whatever partial joins the attempt made before the mismatch. By the
time it is returned, both classes have been joined under `Error`.

-}
type Answer
    = AnswerOk (List Vars.Variable)
    | AnswerErr (List Vars.Variable) Error.Type Error.Type


{-| Unifies two variables as an `IO` action. It is `unifyS` with the state
first in the result.
-}
unify : Vars.Variable -> Vars.Variable -> IO Answer
unify v1 v2 s0 =
    let
        ( answer, s1 ) =
            unifyS v1 v2 s0
    in
    ( s1, answer )


{-| Unifies two variables in the given state and returns the answer with the
new state.

On a mismatch both types are rendered with `Type.toErrorType` before the two
classes are joined under `Error`, so the rendered types show the partial joins
the failed attempt made. Rendering writes names into the store, as
`Compiler.Type.Type` describes.

-}
unifyS : Vars.Variable -> Vars.Variable -> IO.State -> ( Answer, IO.State )
unifyS v1 v2 s0 =
    case guardedUnifyS v1 v2 [] s0 of
        ( s1, Ok (UnifyOk vars ()) ) ->
            ( answerOk vars, s1 )

        ( s1, Err (UnifyErr vars ()) ) ->
            let
                ( s2, t1 ) =
                    Type.toErrorType v1 s1

                ( s3, t2 ) =
                    Type.toErrorType v2 s2
            in
            ( AnswerErr vars t1 t2, UF.unionS v1 v2 errorDescriptor s3 )


{-| Unifies two variables and reports only whether it worked: `True` with the
unified state, or `False` with the state as the failed attempt left it,
partial joins included.

It renders no error types, joins nothing under `Error`, and does not return the
fresh variables. A caller that wants to discard a failed attempt goes back to
the state it held before the call, which the immutable store leaves intact.

-}
unifyBoolS : Vars.Variable -> Vars.Variable -> IO.State -> ( Bool, IO.State )
unifyBoolS v1 v2 s0 =
    case guardedUnifyS v1 v2 [] s0 of
        ( s1, Ok _ ) ->
            ( True, s1 )

        ( s1, Err _ ) ->
            ( False, s1 )


{-| Returns `AnswerOk vars`, using one shared value when `vars` is empty, which
is the common case because only records and comparable checks make variables.
-}
answerOk : List Vars.Variable -> Answer
answerOk vars =
    case vars of
        [] ->
            answerOkEmpty

        _ ->
            AnswerOk vars


{-| The shared successful answer with no fresh variables.
-}
answerOkEmpty : Answer
answerOkEmpty =
    AnswerOk []


{-| The descriptor both classes of a failed unification are joined under:
`Error` content with rank `Type.noRank` and mark `Type.noMark`.
-}
errorDescriptor : Vars.Descriptor
errorDescriptor =
    IO.makeDescriptor Vars.Error Type.noRank Type.noMark Nothing



-- ====== CPS UNIFIER ======


{-| A step of unification that may mismatch, producing an `a` when it does not.

It is run with the list of fresh variables made so far, and passes that list on
whether the step succeeds or mismatches, so the variables made before a
mismatch are not lost.

-}
type Unify a
    = Unify (List Vars.Variable -> IO (Result UnifyErr (UnifyOk a)))


{-| A successful step's result together with the fresh variables made so far.
-}
type UnifyOk a
    = UnifyOk (List Vars.Variable) a


{-| A mismatch, together with the fresh variables made before it.
-}
type UnifyErr
    = UnifyErr (List Vars.Variable) ()


{-| Applies `func` to a step's result.
-}
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


{-| Returns a step that succeeds with `a` and changes nothing.
-}
pure : a -> Unify a
pure a =
    Unify (\vars -> IO.pure (Ok (UnifyOk vars a)))


{-| Returns a step that runs the given one and, unless it mismatched, the step
`callback` makes from its result.
-}
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


{-| Returns a step that runs `mkVar` and adds the variable it makes to the
fresh variables.
-}
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


{-| A step that fails, leaving the store unchanged.
-}
mismatch : Unify a
mismatch =
    Unify (\vars -> IO.pure (Err (UnifyErr vars ())))


{-| Returns a step that runs `f` on each element of `xs` in order, stopping at
the first mismatch.
-}
forEach_ : List a -> (a -> Unify ()) -> Unify ()
forEach_ xs f =
    List.foldl (\x acc -> acc |> andThen (\_ -> f x)) (pure ()) xs


{-| Returns a step that runs `f` on the pairs of `xs` and `ys` in order,
stopping at the first mismatch. Lists of different lengths mismatch once the
shorter runs out.
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


{-| Returns a step that never mismatches: it runs the given step and gives
`True` if it succeeded and `False` if it mismatched, keeping the fresh variables
either way. The store keeps whatever the step changed before a mismatch.
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


{-| Returns a step that runs `f` on every pair of `xs` and `ys`, carrying on
after a mismatch so that every fresh variable is collected, and then mismatches
if any pair did or the lengths differ.
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


{-| The two variables being unified, with the descriptors of their classes as
read when the attempt began.
-}
type alias Context =
    { var1 : Vars.Variable
    , desc1 : Vars.Descriptor
    , var2 : Vars.Variable
    , desc2 : Vars.Descriptor
    }


{-| Builds a `Context` from its four fields in order.
-}
makeContext : Vars.Variable -> Vars.Descriptor -> Vars.Variable -> Vars.Descriptor -> Context
makeContext var1 desc1 var2 desc2 =
    { var1 = var1, desc1 = desc1, var2 = var2, desc2 = desc2 }


{-| Returns the context with the two sides swapped.
-}
reorient : Context -> Context
reorient props =
    makeContext props.var2 props.desc2 props.var1 props.desc1



-- ====== MERGE ======


{-| Returns a step that joins the two classes of the context under `content`,
with the lower of their two ranks, no mark and no copy.
-}
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


{-| Returns a step that makes a new variable holding `content`, at the lower of
the context's two ranks, and adds it to the fresh variables.
-}
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


{-| Returns a step that unifies two variables, doing nothing when they are
already one class.
-}
guardedUnify : Vars.Variable -> Vars.Variable -> Unify ()
guardedUnify left right =
    -- An explicit closure, not a partial application of `guardedUnifyS`, so
    -- that running the step is a saturated call.
    Unify (\vars s0 -> guardedUnifyS left right vars s0)


{-| Unifies two variables in the given state, given the fresh variables made
so far, doing nothing when they are already one class.

Unlike `unifyS`, the state comes first in the result, as in an `IO` action.

-}
guardedUnifyS : Vars.Variable -> Vars.Variable -> List Vars.Variable -> IO.State -> ( IO.State, Result UnifyErr (UnifyOk ()) )
guardedUnifyS left right vars s0 =
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


{-| Returns a step that unifies two parts of the structures being unified.
-}
subUnify : Vars.Variable -> Vars.Variable -> Unify ()
subUnify var1 var2 =
    guardedUnify var1 var2


{-| Returns a step that unifies the remaining elements of two tuples pairwise,
stopping at the first mismatch, and then joins the context under
`otherContent`.
-}
subUnifyTuple : List Vars.Variable -> List Vars.Variable -> Context -> Vars.Content -> Unify ()
subUnifyTuple cs zs context otherContent =
    zipWithM_ subUnify cs zs
        |> andThen (\_ -> merge context otherContent)


{-| Returns a step that unifies the two sides of a context whose variables are
in different classes, choosing the rule by the first side's content.
-}
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
            merge ctx Vars.Error



-- ====== UNIFY FLEXIBLE VARIABLES ======


{-| Returns a step that unifies a flexible variable, whose content is
`content`, with `otherContent`. The other side's content is kept, except that an
unnamed flexible variable on the other side keeps this one's.
-}
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


{-| Returns a step that unifies a rigid variable, with its super type if it has
one, with `otherContent`. It succeeds against a flexible variable, against
`Error`, and against a flexible super type that `combineRigidSupers` accepts,
keeping the rigid content in the last case.
-}
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


{-| Returns a step that unifies a flexible variable with super type `super` with
`otherContent`, following the super-type rules in the module docstring.
-}
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


{-| Tells whether a rigid variable with super type `rigid` can absorb a
flexible variable with super type `flex`.
-}
combineRigidSupers : Vars.SuperType -> Vars.SuperType -> Bool
combineRigidSupers rigid flex =
    rigid
        == flex
        || (rigid == Vars.Number && flex == Vars.Comparable)
        || (rigid == Vars.CompAppend && (flex == Vars.Comparable || flex == Vars.Appendable))


{-| Tells whether the type named `home`.`name`, applied to no arguments, belongs
to super type `super`.
-}
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


{-| Tells whether `home`.`name` is `Basics.Int` or `Basics.Float`.
-}
isNumber : ModuleName.Canonical -> Name.Name -> Bool
isNumber home name =
    (home == ModuleName.basics)
        && (name == Name.int || name == Name.float)


{-| Returns a step that unifies the first side of the context, a flexible
variable with super type `super`, with the structure `flatType` on the second
side, keeping the structure.
-}
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


{-| Returns a step that mismatches when the context's second variable occurs
inside its own structure.
-}
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


{-| Returns a step that unifies `var` with a fresh flexible `comparable` at
`var`'s rank, adding that variable to the fresh variables.
-}
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


{-| Returns a step that unifies an alias of `home`.`name` with arguments `args`
and expansion `realVar` with `otherContent`, following the alias rules in the
module docstring.
-}
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


{-| Returns a step that unifies the structure `flatType` with `otherContent`.
Two structures agree only when they are built the same way and their parts
agree, apart from the arrow, lambda-set and record rules in the module
docstring.
-}
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

                -- A plain arrow is a `FunL` whose slot is unconstrained.
                ( Vars.Fun1 arg1 res1, Vars.FunL arg2 res2 _ ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx otherContent)

                ( Vars.FunL arg1 res1 _, Vars.Fun1 arg2 res2 ) ->
                    subUnify arg1 arg2
                        |> andThen (\_ -> subUnify res1 res2)
                        |> andThen (\_ -> merge ctx content)

                ( Vars.LambdaSet1 ls1, Vars.LambdaSet1 ls2 ) ->
                    case ( ls1, ls2 ) of
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
                                    merge ctx content

                                Vars.SortedSub ->
                                    merge ctx otherContent

                                Vars.SortedMixed ->
                                    merge ctx (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers (IO.unionSortedAsc m1 m2))))

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



-- ====== UNIFY RECORDS ======


{-| Returns a step that unifies two gathered records, pushing each side's own
fields into the other side's extension as described in the module docstring,
and then joins the context under a record of the shared fields, together with
each side's own fields only when both sides have some.
-}
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


{-| Returns a step that unifies every pair in `sharedFields`, carrying on after
a mismatch, and then either mismatches or joins the context under a record of
the shared fields and `otherFields` with extension `ext`.
-}
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


{-| Returns a step that runs `func` on every entry in key order and gives the
dictionary of its results, or `Nothing` if `func` gave `Nothing` for any entry.
Every entry is run either way.
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


{-| Returns a step that unifies a shared field's two variables, giving the
first one on success and `Nothing` on a mismatch, without mismatching itself.
-}
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


{-| A record's fields gathered from its whole extension chain, with the
variable that ends the chain, which is not a `Record1` or an alias.
-}
type RecordStructure
    = RecordStructure (Dict Name.Name Vars.Variable) Vars.Variable


{-| Returns `sources` without repeated points, keeping the first occurrence of
each. Points are compared by store index, so two points of one class are both
kept.
-}
dedupeSources : List Vars.Variable -> List Vars.Variable
dedupeSources sources =
    dedupeSourcesGo sources []


{-| Returns `sources` without the points whose index is in `seen` and without
repeats, keeping first occurrences.
-}
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


{-| Gathers the fields of a record whose own fields are `fields` and whose
extension is `variable`, following `Record1` extensions and aliases. Where a
field name appears more than once, the outermost occurrence wins.
-}
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
