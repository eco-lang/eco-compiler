module Compiler.Type.Error exposing
    ( Type(..), Super(..), Extension(..), Direction(..), Problem(..)
    , isInt, isFloat, isString, isChar, isList
    , iteratedDealias, toDoc, toComparison
    , typeEncoder, typeDecoder
    )

{-| A type mismatch is reported long after the solver that found it has moved
on, so the two types involved are captured as plain values, and this module is
those values and the comparison that explains a mismatch to the user.

An _error type_ is a `Type` from this module: a snapshot of a solver type that
holds no solver variables and can be printed, compared and stored on its own.
`Compiler.Type.Type.toErrorType` makes one from a solver variable. Type
variables are identified by name alone, and a type alias keeps both its
name and the type it stands for, so a message can show the name the user wrote.

The rest of the module is the comparison. `toComparison` walks an actual and an
expected type side by side and returns a printed document for each, with the
parts that differ coloured, together with a list of _problems_. A problem is a
recognised kind of mistake, such as giving an `Int` where a `Float` is needed or
misspelling a record field, which the caller can turn into a hint. Two types
can differ without any problem being recognised.

Most of the file is that walk. It is written in the style of an applicative
functor over `Diff`, a pair of documents built in step together with a record
of whether they differ, so that the two sides of every compound type are printed
by the same traversal.


# Types

@docs Type, Super, Extension, Direction, Problem


# Type Predicates

@docs isInt, isFloat, isString, isChar, isList


# Utilities

@docs iteratedDealias, toDoc, toComparison


# Serialization

@docs typeEncoder, typeDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Bag as Bag
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Dict exposing (Dict)
import Prelude
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== ERROR TYPES ======


{-| A type as it is shown in an error message, independent of the solver it
came from.

`Lambda` is a whole function type, flattened: its payloads are every part of
the type in order, arguments first and the result last, so `a -> b -> c` is
`Lambda a b [ c ]`.

`Infinite` stands for a type that contains itself and prints as `∞`. `Error`
stands for a type the solver had already marked as erroneous after an earlier
mismatch, and prints as `?`.

`FlexVar` and `FlexSuper` are type variables the solver was free to bind, and
`RigidVar` and `RigidSuper` are variables fixed by a type annotation. The
`Super` variants carry the constraint their name implies.

`Type` is a named type applied to its arguments, identified by its home module
and name.

`Record` maps each field name to its type, with an `Extension` saying whether
the record is open to more fields.

`Tuple` holds its first two elements and then the rest.

`Alias` carries the alias's home module and name, each parameter name paired
with its argument, and last the type the alias stands for. It is printed by its
name.

-}
type Type
    = Lambda Type Type (List Type)
    | Infinite
    | Error
    | FlexVar Name
    | FlexSuper Super Name
    | RigidVar Name
    | RigidSuper Super Name
    | Type ModuleName.Canonical Name (List Type)
    | Record (Dict Name Type) Extension
    | Unit
    | Tuple Type Type (List Type)
    | Alias ModuleName.Canonical Name (List ( Name, Type )) Type


{-| The constraint on a constrained type variable, one for each of Elm's
`number`, `comparable`, `appendable` and `compappend` variables. `CompAppend`
is a type that is both comparable and appendable.
-}
type Super
    = Number
    | Comparable
    | Appendable
    | CompAppend


{-| Whether a record type can have fields beyond the ones it lists.

A `Closed` record has exactly its listed fields. `FlexOpen` and `RigidOpen`
records are extensible, `{ r | ... }`, and carry the name of the variable `r`;
as with type variables, a flexible one could still be bound to more fields and
a rigid one comes from an annotation.

-}
type Extension
    = Closed
    | FlexOpen Name
    | RigidOpen Name


{-| Returns the type that `tipe` stands for once every alias at its top level
has been replaced by its definition. Aliases nested inside the result, such as
in its arguments or fields, are left in place.
-}
iteratedDealias : Type -> Type
iteratedDealias tipe =
    case tipe of
        Alias _ _ _ real ->
            iteratedDealias real

        _ ->
            tipe



-- ====== TO DOC ======


{-| Prints `tipe` as a document, adding parentheses where position `ctx`
needs them, with type names shortened as `localizer` allows.

An alias is printed by its name and arguments, never as the type it stands
for. `Infinite` prints as `∞` and `Error` as `?`. Record fields come out in
alphabetical order. Nothing is coloured.

-}
toDoc : L.Localizer -> RT.Context -> Type -> D.Doc
toDoc localizer ctx tipe =
    case tipe of
        Lambda a b cs ->
            RT.lambda ctx
                (toDoc localizer RT.Func a)
                (toDoc localizer RT.Func b)
                (List.map (toDoc localizer RT.Func) cs)

        Infinite ->
            D.fromChars "∞"

        Error ->
            D.fromChars "?"

        FlexVar name ->
            D.fromName name

        FlexSuper _ name ->
            D.fromName name

        RigidVar name ->
            D.fromName name

        RigidSuper _ name ->
            D.fromName name

        Type home name args ->
            RT.apply ctx
                (L.toDoc localizer home name)
                (List.map (toDoc localizer RT.App) args)

        Record fields ext ->
            RT.record (fieldsToDocs localizer fields) (extToDoc ext)

        Unit ->
            D.fromChars "()"

        Tuple a b cs ->
            RT.tuple
                (toDoc localizer RT.None a)
                (toDoc localizer RT.None b)
                (List.map (toDoc localizer RT.None) cs)

        Alias home name args _ ->
            aliasToDoc localizer ctx home name args


{-| Prints an alias by its name applied to its arguments, in position `ctx`.
-}
aliasToDoc : L.Localizer -> RT.Context -> ModuleName.Canonical -> Name -> List ( Name, Type ) -> D.Doc
aliasToDoc localizer ctx home name args =
    RT.apply ctx
        (L.toDoc localizer home name)
        (List.map (toDoc localizer RT.App << Tuple.second) args)


{-| Prints each field of a record as a name and a type, in alphabetical order
of field name.
-}
fieldsToDocs : L.Localizer -> Dict Name Type -> List ( D.Doc, D.Doc )
fieldsToDocs localizer fields =
    Dict.foldr (addField localizer) [] fields


{-| Prepends the printed `fieldName` and `fieldType` to `docs`.
-}
addField : L.Localizer -> Name -> Type -> List ( D.Doc, D.Doc ) -> List ( D.Doc, D.Doc )
addField localizer fieldName fieldType docs =
    let
        f : D.Doc
        f =
            D.fromName fieldName

        t : D.Doc
        t =
            toDoc localizer RT.None fieldType
    in
    ( f, t ) :: docs


{-| Returns the printed name of a record's extension variable, or `Nothing`
for a closed record.
-}
extToDoc : Extension -> Maybe D.Doc
extToDoc ext =
    case ext of
        Closed ->
            Nothing

        FlexOpen x ->
            Just (D.fromName x)

        RigidOpen x ->
            Just (D.fromName x)



-- ====== DIFF ======


{-| The two sides of a comparison printed in step: the actual side, then the
expected side, then whether they differ.

The comparison builds a `Diff` for each part of the two types and combines
them with `mapDiff`, `applyDiff` and `liftA2`, which join the statuses so that
a compound type differs when any of its parts does.

-}
type Diff a
    = Diff a a Status


{-| Whether the two sides of a comparison differ. A `Different` status
carries the problems recognised so far, and that collection may be empty: two
types can differ in a way that no `Problem` describes.
-}
type Status
    = Similar
    | Different (Bag.Bag Problem)


{-| A recognised kind of mistake behind a type mismatch, found by
`toComparison` so that the error message can offer a hint about it. In what
follows, the actual type is the first one given to `toComparison` and the
expected type the second.

`IntFloat` is an `Int` where a `Float` is expected, or the reverse.

`StringFromInt` and `StringFromFloat` are an `Int` or a `Float` where a
`String` is expected. `StringToInt` and `StringToFloat` are a `String` where an
`Int` or a `Float` is expected.

`AnythingToBool` is some other type without arguments where a `Bool` is
expected.

`AnythingFromMaybe` is a `Maybe t` where something matching `t` is expected.
It is not found when the expected type is itself a named type, such as `Int`.

`ArityMismatch` occurs between two function types with different numbers of
parts. Its two numbers count every part, arguments and result, of the actual
and then the expected type.

`BadFlexSuper` is a constrained type variable the solver was free to bind, met
by a type that does not satisfy its constraint. The `Direction` says which side
the variable was on, and the `Type` is the other side.

`BadRigidVar` and `BadRigidSuper` are a type variable from an annotation met by
a different type, carrying the variable's name and the other type. Two records
extending differently named rigid variables also give a `BadRigidVar`.

`FieldTypo` is a field that one record has and the other lacks, where the other
record cannot gain fields; it carries the alphabetically first such field and
every field name of the other record, from which a likely intended name can be
picked. `FieldsMissing` lists the fields the expected record has and the actual
record lacks, when neither can gain fields and the actual record has nothing
extra.

-}
type Problem
    = IntFloat
    | StringFromInt
    | StringFromFloat
    | StringToInt
    | StringToFloat
    | AnythingToBool
    | AnythingFromMaybe
    | ArityMismatch Int Int
    | BadFlexSuper Direction Super Type
    | BadRigidVar Name Type
    | BadRigidSuper Super Name Type
    | FieldTypo Name (List Name)
    | FieldsMissing (List Name)


{-| Which side of a comparison something is on: `Have` is the actual type and
`Need` the expected one.
-}
type Direction
    = Have
    | Need


{-| Applies `func` to both sides of a `Diff`, keeping its status.
-}
mapDiff : (a -> b) -> Diff a -> Diff b
mapDiff func (Diff a b status) =
    Diff (func a) (func b) status


{-| Returns a `Diff` with `a` on both sides and nothing different.
-}
pureDiff : a -> Diff a
pureDiff a =
    Diff a a Similar


{-| Applies each side of the function `Diff` to the same side of the argument
`Diff`, and joins their statuses with the function's problems first. The
argument comes first so that it reads in a pipeline.
-}
applyDiff : Diff a -> Diff (a -> b) -> Diff b
applyDiff (Diff aArg bArg status2) (Diff aFunc bFunc status1) =
    Diff (aFunc aArg) (bFunc bArg) (merge status1 status2)


{-| Combines `x` and `y` side by side with `f`; the result differs if either
does, with the problems of `x` before those of `y`.
-}
liftA2 : (a -> b -> c) -> Diff a -> Diff b -> Diff c
liftA2 f x y =
    applyDiff y (mapDiff f x)


{-| Joins two statuses: `Similar` only when both are, otherwise `Different`
with the problems of `status1` before those of `status2`.
-}
merge : Status -> Status -> Status
merge status1 status2 =
    case status1 of
        Similar ->
            status2

        Different problems1 ->
            case status2 of
                Similar ->
                    status1

                Different problems2 ->
                    Different (Bag.append problems1 problems2)



-- ====== COMPARISON ======


{-| Compares the actual type `tipe1` with the expected type `tipe2`, and
returns the printed actual type, the printed expected type, and the problems
recognised between them.

Parts that differ are highlighted in yellow in both documents. An unconstrained
flexible variable matches any type except a flexible variable of another name,
and a constrained one matches any type that satisfies its constraint, looking
through aliases. When two different named types would print with the same name,
both are printed with their module name and no problem is reported. An empty
problem list does not mean the types match.

-}
toComparison : L.Localizer -> Type -> Type -> ( D.Doc, D.Doc, List Problem )
toComparison localizer tipe1 tipe2 =
    case toDiff localizer RT.None tipe1 tipe2 of
        Diff doc1 doc2 Similar ->
            ( doc1, doc2, [] )

        Diff doc1 doc2 (Different problems) ->
            ( doc1, doc2, Bag.toList problems )


{-| Compares `tipe1` (actual) with `tipe2` (expected), printed in position
`ctx`, and returns both documents with the status of the comparison.

The branches are tried in order and none falls through to a later one: a
branch whose condition fails goes straight to `toDiffOtherwise`. So a pair of
named types is settled by the named-type branch, a pair of aliases by the alias
branch, and a one-argument named type on the actual side by the `Maybe` branch,
before the later `List` and alias branches are reached. In particular
`AnythingFromMaybe` is found only when the expected type is not a `Type`,
and two differently named flexible variables are reported as different.

-}
toDiff : L.Localizer -> RT.Context -> Type -> Type -> Diff D.Doc
toDiff localizer ctx tipe1 tipe2 =
    case ( tipe1, tipe2 ) of
        ( Unit, Unit ) ->
            same localizer ctx tipe1

        ( Error, Error ) ->
            same localizer ctx tipe1

        ( Infinite, Infinite ) ->
            same localizer ctx tipe1

        ( FlexVar x, FlexVar y ) ->
            if x == y then
                same localizer ctx tipe1

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( FlexSuper _ x, FlexSuper _ y ) ->
            if x == y then
                same localizer ctx tipe1

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( RigidVar x, RigidVar y ) ->
            if x == y then
                same localizer ctx tipe1

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( RigidSuper _ x, RigidSuper _ y ) ->
            if x == y then
                same localizer ctx tipe1

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( FlexVar _, _ ) ->
            similar localizer ctx tipe1 tipe2

        ( _, FlexVar _ ) ->
            similar localizer ctx tipe1 tipe2

        ( FlexSuper s _, t ) ->
            if isSuper s t then
                similar localizer ctx tipe1 tipe2

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( t, FlexSuper s _ ) ->
            if isSuper s t then
                similar localizer ctx tipe1 tipe2

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( Lambda a b cs, Lambda x y zs ) ->
            if List.length cs == List.length zs then
                toDiff localizer RT.Func a x
                    |> mapDiff (RT.lambda ctx)
                    |> applyDiff (toDiff localizer RT.Func b y)
                    |> applyDiff
                        (List.map2 (toDiff localizer RT.Func) cs zs
                            |> List.foldr (liftA2 (::)) (pureDiff [])
                        )

            else
                let
                    f : Type -> D.Doc
                    f =
                        toDoc localizer RT.Func
                in
                different
                    (D.dullyellow (RT.lambda ctx (f a) (f b) (List.map f cs)))
                    (D.dullyellow (RT.lambda ctx (f x) (f y) (List.map f zs)))
                    (Bag.one (ArityMismatch (2 + List.length cs) (2 + List.length zs)))

        ( Tuple a b cs, Tuple x y zs ) as pair ->
            toDiffTuple localizer ctx pair ( a, b, cs ) ( x, y, zs ) (pureDiff [])

        ( Record fields1 ext1, Record fields2 ext2 ) ->
            diffRecord localizer fields1 ext1 fields2 ext2

        ( Type home1 name1 args1, Type home2 name2 args2 ) ->
            if home1 == home2 && name1 == name2 then
                List.map2 (toDiff localizer RT.App) args1 args2
                    |> List.foldr (liftA2 (::)) (pureDiff [])
                    |> mapDiff (RT.apply ctx (L.toDoc localizer home1 name1))

            else if L.toChars localizer home1 name1 == L.toChars localizer home2 name2 then
                different
                    (nameClashToDoc ctx localizer home1 name1 args1)
                    (nameClashToDoc ctx localizer home2 name2 args2)
                    Bag.empty

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( Alias home1 name1 args1 _, Alias home2 name2 args2 _ ) ->
            if home1 == home2 && name1 == name2 then
                List.map2 (toDiff localizer RT.App) (List.map Tuple.second args1) (List.map Tuple.second args2)
                    |> List.foldr (liftA2 (::)) (pureDiff [])
                    |> mapDiff (RT.apply ctx (L.toDoc localizer home1 name1))

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( Type home name [ t1 ], t2 ) ->
            if isMaybe home name && isSimilar (toDiff localizer ctx t1 t2) then
                different
                    (RT.apply ctx (D.dullyellow (L.toDoc localizer home name)) [ toDoc localizer RT.App t1 ])
                    (toDoc localizer ctx t2)
                    (Bag.one AnythingFromMaybe)

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( t1, Type home name [ t2 ] ) ->
            if isList home name && isSimilar (toDiff localizer ctx t1 t2) then
                different
                    (toDoc localizer ctx t1)
                    (RT.apply ctx (D.dullyellow (L.toDoc localizer home name)) [ toDoc localizer RT.App t2 ])
                    Bag.empty

            else
                toDiffOtherwise localizer ctx ( tipe1, tipe2 )

        ( Alias home1 name1 args1 t1, t2 ) ->
            case diffAliasedRecord localizer t1 t2 of
                Just (Diff _ doc2 status) ->
                    Diff (D.dullyellow (aliasToDoc localizer ctx home1 name1 args1)) doc2 status

                Nothing ->
                    case tipe2 of
                        Type home2 name2 args2 ->
                            if L.toChars localizer home1 name1 == L.toChars localizer home2 name2 then
                                different
                                    (nameClashToDoc ctx localizer home1 name1 (List.map Tuple.second args1))
                                    (nameClashToDoc ctx localizer home2 name2 args2)
                                    Bag.empty

                            else
                                different
                                    (D.dullyellow (toDoc localizer ctx tipe1))
                                    (D.dullyellow (toDoc localizer ctx tipe2))
                                    Bag.empty

                        _ ->
                            different
                                (D.dullyellow (toDoc localizer ctx tipe1))
                                (D.dullyellow (toDoc localizer ctx tipe2))
                                Bag.empty

        ( _, Alias home2 name2 args2 _ ) ->
            case diffAliasedRecord localizer tipe1 tipe2 of
                Just (Diff doc1 _ status) ->
                    Diff doc1 (D.dullyellow (aliasToDoc localizer ctx home2 name2 args2)) status

                Nothing ->
                    case tipe1 of
                        Type home1 name1 args1 ->
                            if L.toChars localizer home1 name1 == L.toChars localizer home2 name2 then
                                different
                                    (nameClashToDoc ctx localizer home1 name1 args1)
                                    (nameClashToDoc ctx localizer home2 name2 (List.map Tuple.second args2))
                                    Bag.empty

                            else
                                different
                                    (D.dullyellow (toDoc localizer ctx tipe1))
                                    (D.dullyellow (toDoc localizer ctx tipe2))
                                    Bag.empty

                        _ ->
                            different
                                (D.dullyellow (toDoc localizer ctx tipe1))
                                (D.dullyellow (toDoc localizer ctx tipe2))
                                Bag.empty

        pair ->
            toDiffOtherwise localizer ctx pair


{-| Compares two tuples element by element, given their first two elements and
the rest, with `diffCs` holding the comparisons of the extra elements done so
far. Tuples of different sizes go to `toDiffOtherwise` as `pair`.

Each extra element's comparison is put in front of those before it, so with
more than one extra element they come out in reverse order. Elm tuples have at
most three elements, which leaves one extra element at most.

-}
toDiffTuple : L.Localizer -> RT.Context -> ( Type, Type ) -> ( Type, Type, List Type ) -> ( Type, Type, List Type ) -> Diff (List D.Doc) -> Diff D.Doc
toDiffTuple localizer ctx pair ( a, b, cs ) ( x, y, zs ) diffCs =
    case ( cs, zs ) of
        ( [], [] ) ->
            toDiff localizer RT.None a x
                |> mapDiff RT.tuple
                |> applyDiff (toDiff localizer RT.None b y)
                |> applyDiff diffCs

        ( c :: restCs, z :: restZs ) ->
            mapDiff (::) (toDiff localizer RT.None c z)
                |> applyDiff diffCs
                |> toDiffTuple localizer ctx pair ( a, b, restCs ) ( x, y, restZs )

        _ ->
            toDiffOtherwise localizer ctx pair


{-| Returns both types of `pair` highlighted as different, with the problem
their combination suggests, if any.

A variable from an annotation, or a constrained variable, on either side gives
the matching `BadRigidVar`, `BadRigidSuper` or `BadFlexSuper`, the actual side
checked first. Otherwise only two named types without arguments are examined,
for the `Int`, `Float`, `String` and `Bool` problems.

-}
toDiffOtherwise : L.Localizer -> RT.Context -> ( Type, Type ) -> Diff D.Doc
toDiffOtherwise localizer ctx (( tipe1, tipe2 ) as pair) =
    let
        doc1 : D.Doc
        doc1 =
            D.dullyellow (toDoc localizer ctx tipe1)

        doc2 : D.Doc
        doc2 =
            D.dullyellow (toDoc localizer ctx tipe2)
    in
    different doc1 doc2 <|
        case pair of
            ( RigidVar x, other ) ->
                BadRigidVar x other |> Bag.one

            ( FlexSuper s _, other ) ->
                BadFlexSuper Have s other |> Bag.one

            ( RigidSuper s x, other ) ->
                BadRigidSuper s x other |> Bag.one

            ( other, RigidVar x ) ->
                BadRigidVar x other |> Bag.one

            ( other, FlexSuper s _ ) ->
                BadFlexSuper Need s other |> Bag.one

            ( other, RigidSuper s x ) ->
                BadRigidSuper s x other |> Bag.one

            ( Type home1 name1 [], Type home2 name2 [] ) ->
                if isInt home1 name1 && isFloat home2 name2 then
                    IntFloat |> Bag.one

                else if isFloat home1 name1 && isInt home2 name2 then
                    IntFloat |> Bag.one

                else if isInt home1 name1 && isString home2 name2 then
                    StringFromInt |> Bag.one

                else if isFloat home1 name1 && isString home2 name2 then
                    StringFromFloat |> Bag.one

                else if isString home1 name1 && isInt home2 name2 then
                    StringToInt |> Bag.one

                else if isString home1 name1 && isFloat home2 name2 then
                    StringToFloat |> Bag.one

                else if isBool home2 name2 then
                    AnythingToBool |> Bag.one

                else
                    Bag.empty

            _ ->
                Bag.empty



-- ====== DIFF HELPERS ======


{-| Returns `tipe` printed on both sides, with nothing different.
-}
same : L.Localizer -> RT.Context -> Type -> Diff D.Doc
same localizer ctx tipe =
    let
        doc : D.Doc
        doc =
            toDoc localizer ctx tipe
    in
    Diff doc doc Similar


{-| Returns `t1` and `t2` printed without highlighting, as a match.
-}
similar : L.Localizer -> RT.Context -> Type -> Type -> Diff D.Doc
similar localizer ctx t1 t2 =
    Diff (toDoc localizer ctx t1) (toDoc localizer ctx t2) Similar


{-| Returns `a` and `b` as sides that differ, with `problems`.
-}
different : a -> a -> Bag.Bag Problem -> Diff a
different a b problems =
    Diff a b (Different problems)


{-| Tells whether the comparison found the two sides to match.
-}
isSimilar : Diff a -> Bool
isSimilar (Diff _ _ status) =
    case status of
        Similar ->
            True

        Different _ ->
            False



-- ====== IS TYPE ======


{-| Tells whether `home` and `name` identify `Bool` from `Basics` in `elm/core`.
-}
isBool : ModuleName.Canonical -> Name -> Bool
isBool home name =
    home == ModuleName.basics && name == Name.bool


{-| Tells whether `home` and `name` identify `Int` from `Basics` in `elm/core`.
-}
isInt : ModuleName.Canonical -> Name -> Bool
isInt home name =
    home == ModuleName.basics && name == Name.int


{-| Tells whether `home` and `name` identify `Float` from `Basics` in `elm/core`.
-}
isFloat : ModuleName.Canonical -> Name -> Bool
isFloat home name =
    home == ModuleName.basics && name == Name.float


{-| Tells whether `home` and `name` identify `String` from `String` in `elm/core`.
-}
isString : ModuleName.Canonical -> Name -> Bool
isString home name =
    home == ModuleName.string && name == Name.string


{-| Tells whether `home` and `name` identify `Char` from `Char` in `elm/core`.
-}
isChar : ModuleName.Canonical -> Name -> Bool
isChar home name =
    home == ModuleName.char && name == Name.char


{-| Tells whether `home` and `name` identify `Maybe` from `Maybe` in `elm/core`.
-}
isMaybe : ModuleName.Canonical -> Name -> Bool
isMaybe home name =
    home == ModuleName.maybe && name == Name.maybe


{-| Tells whether `home` and `name` identify `List` from `List` in `elm/core`.
-}
isList : ModuleName.Canonical -> Name -> Bool
isList home name =
    home == ModuleName.list && name == Name.list



-- ====== IS SUPER ======


{-| Tells whether `tipe`, looking through aliases at its top, satisfies the
constraint `super`.

`number` accepts `Int` and `Float`. `comparable` accepts those, `String`,
`Char`, a `List` of comparable elements and a tuple whose elements are all
comparable. `appendable` accepts `String` and any `List`. `compappend` accepts
`String` and a `List` of comparable elements. Nothing else satisfies any
constraint, type variables included.

-}
isSuper : Super -> Type -> Bool
isSuper super tipe =
    case iteratedDealias tipe of
        Type h n args ->
            case super of
                Number ->
                    isInt h n || isFloat h n

                Comparable ->
                    isInt h n || isFloat h n || isString h n || isChar h n || isList h n && isSuper super (Prelude.head args)

                Appendable ->
                    isString h n || isList h n

                CompAppend ->
                    isString h n || isList h n && isSuper Comparable (Prelude.head args)

        Tuple a b cs ->
            case super of
                Number ->
                    False

                Comparable ->
                    List.all (isSuper super) (a :: b :: cs)

                Appendable ->
                    False

                CompAppend ->
                    False

        _ ->
            False



-- ====== NAME CLASH ======


{-| Prints a named type applied to `args`, in position `ctx`, with its name
qualified by its module name in place of the localized form, for when two
different types would otherwise print alike. The package is not shown.
-}
nameClashToDoc : RT.Context -> L.Localizer -> ModuleName.Canonical -> Name -> List Type -> D.Doc
nameClashToDoc ctx localizer (ModuleName.Canonical _ home) name args =
    RT.apply ctx
        (D.yellow (D.fromName home) |> D.a (D.dullyellow (D.fromChars "." |> D.a (D.fromName name))))
        (List.map (toDoc localizer RT.App) args)



-- ====== DIFF ALIASED RECORD ======


{-| Compares `t1` and `t2` as records when both are records once the aliases
at their top are looked through, and returns `Nothing` otherwise.
-}
diffAliasedRecord : L.Localizer -> Type -> Type -> Maybe (Diff D.Doc)
diffAliasedRecord localizer t1 t2 =
    case ( iteratedDealias t1, iteratedDealias t2 ) of
        ( Record fields1 ext1, Record fields2 ext2 ) ->
            Just (diffRecord localizer fields1 ext1 fields2 ext2)

        _ ->
            Nothing



-- ====== RECORD DIFFS ======


{-| Compares the actual record, `fields1` extended by `ext1`, with the expected
record, `fields2` extended by `ext2`.

Fields on both sides are compared by type. A field on one side only is printed
with its name highlighted and makes the records differ, even when both are
open. The extensions are compared by `extToDiff`. The problem reported depends
on which records can gain fields, as `hasFixedFields` decides: when both
cannot, the alphabetically first field only the actual record has is a
`FieldTypo` against the expected record's fields, or failing that the fields
only the expected record has are `FieldsMissing`; when only the expected record
cannot, a field only the actual record has is a `FieldTypo`; when only the
actual record cannot, a field only the expected record has is a `FieldTypo`
against the actual record's fields.

-}
diffRecord : L.Localizer -> Dict Name Type -> Extension -> Dict Name Type -> Extension -> Diff D.Doc
diffRecord localizer fields1 ext1 fields2 ext2 =
    let
        toUnknownDocs : Name -> Type -> ( D.Doc, D.Doc )
        toUnknownDocs field tipe =
            ( D.dullyellow (D.fromName field), toDoc localizer RT.None tipe )

        toOverlapDocs : Name -> Type -> Type -> Diff ( D.Doc, D.Doc )
        toOverlapDocs field t1 t2 =
            toDiff localizer RT.None t1 t2 |> mapDiff (Tuple.pair (D.fromName field))

        left : Dict Name ( D.Doc, D.Doc )
        left =
            Dict.map toUnknownDocs (Dict.diff fields1 fields2)

        right : Dict Name ( D.Doc, D.Doc )
        right =
            Dict.map toUnknownDocs (Dict.diff fields2 fields1)

        fieldsDiff : Diff (List ( D.Doc, D.Doc ))
        fieldsDiff =
            let
                fieldsDiffDict : Diff (Dict Name ( D.Doc, D.Doc ))
                fieldsDiffDict =
                    let
                        both : Dict Name (Diff ( D.Doc, D.Doc ))
                        both =
                            Dict.merge
                                (\_ _ acc -> acc)
                                (\field t1 t2 acc -> Dict.insert field (toOverlapDocs field t1 t2) acc)
                                (\_ _ acc -> acc)
                                fields1
                                fields2
                                Dict.empty

                        sequenceA : Dict Name (Diff ( D.Doc, D.Doc )) -> Diff (Dict Name ( D.Doc, D.Doc ))
                        sequenceA =
                            Dict.foldr (\k x acc -> applyDiff acc (mapDiff (Dict.insert k) x)) (pureDiff Dict.empty)
                    in
                    if Dict.isEmpty left && Dict.isEmpty right then
                        sequenceA both

                    else
                        liftA2 Dict.union
                            (sequenceA both)
                            (Diff left right (Different Bag.empty))
            in
            mapDiff Dict.values fieldsDiffDict

        (Diff doc1 doc2 status) =
            fieldsDiff
                |> mapDiff RT.record
                |> applyDiff (extToDiff ext1 ext2)
    in
    (case ( hasFixedFields ext1, hasFixedFields ext2 ) of
        ( True, True ) ->
            let
                minView : Maybe ( Name, ( D.Doc, D.Doc ) )
                minView =
                    Dict.toList left
                        |> List.sortBy Tuple.first
                        |> List.head
            in
            case minView of
                Just ( f, _ ) ->
                    Different (Bag.one (FieldTypo f (Dict.keys fields2)))

                Nothing ->
                    if Dict.isEmpty right then
                        Similar

                    else
                        Different (Bag.one (FieldsMissing (Dict.keys right)))

        ( False, True ) ->
            let
                minView : Maybe ( Name, ( D.Doc, D.Doc ) )
                minView =
                    Dict.toList left
                        |> List.sortBy Tuple.first
                        |> List.head
            in
            case minView of
                Just ( f, _ ) ->
                    Different (Bag.one (FieldTypo f (Dict.keys fields2)))

                Nothing ->
                    Similar

        ( True, False ) ->
            let
                minView : Maybe ( Name, ( D.Doc, D.Doc ) )
                minView =
                    Dict.toList right
                        |> List.sortBy Tuple.first
                        |> List.head
            in
            case minView of
                Just ( f, _ ) ->
                    Different (Bag.one (FieldTypo f (Dict.keys fields1)))

                Nothing ->
                    Similar

        ( False, False ) ->
            Similar
    )
        |> merge status
        |> Diff doc1 doc2


{-| Tells whether a record's set of fields is fixed: true for a closed record
and for one extending a rigid variable, false for one extending a flexible
variable.
-}
hasFixedFields : Extension -> Bool
hasFixedFields ext =
    case ext of
        Closed ->
            True

        FlexOpen _ ->
            False

        RigidOpen _ ->
            True



-- ====== DIFF RECORD EXTENSION ======


{-| Prints the two extension variables, highlighted when `extToStatus` finds
the extensions different.
-}
extToDiff : Extension -> Extension -> Diff (Maybe D.Doc)
extToDiff ext1 ext2 =
    let
        status : Status
        status =
            extToStatus ext1 ext2

        extDoc1 : Maybe D.Doc
        extDoc1 =
            extToDoc ext1

        extDoc2 : Maybe D.Doc
        extDoc2 =
            extToDoc ext2
    in
    case status of
        Similar ->
            Diff extDoc1 extDoc2 status

        Different _ ->
            Diff (Maybe.map D.dullyellow extDoc1) (Maybe.map D.dullyellow extDoc2) status


{-| Compares the actual extension `ext1` with the expected `ext2`.

A flexible extension on either side matches. A closed record and a rigid
extension differ with no problem. Two rigid extensions match when they have the
same name, and otherwise give a `BadRigidVar` for the actual one.

-}
extToStatus : Extension -> Extension -> Status
extToStatus ext1 ext2 =
    case ext1 of
        Closed ->
            case ext2 of
                Closed ->
                    Similar

                FlexOpen _ ->
                    Similar

                RigidOpen _ ->
                    Different Bag.empty

        FlexOpen _ ->
            Similar

        RigidOpen x ->
            case ext2 of
                Closed ->
                    Different Bag.empty

                FlexOpen _ ->
                    Similar

                RigidOpen y ->
                    if x == y then
                        Similar

                    else
                        Different (Bag.one (BadRigidVar x (RigidVar y)))



-- ====== ENCODERS and DECODERS ======


{-| Encodes an error type in the compiler's binary format: one byte naming the
constructor, numbered from 0 in declaration order, followed by its payloads.
`typeDecoder` reads it back.
-}
typeEncoder : Type -> Bytes.Encode.Encoder
typeEncoder type_ =
    case type_ of
        Lambda x y zs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , typeEncoder x
                , typeEncoder y
                , BE.list typeEncoder zs
                ]

        Infinite ->
            Bytes.Encode.unsignedInt8 1

        Error ->
            Bytes.Encode.unsignedInt8 2

        FlexVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string name
                ]

        FlexSuper s x ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , superEncoder s
                , BE.string x
                ]

        RigidVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string name
                ]

        RigidSuper s x ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , superEncoder s
                , BE.string x
                ]

        Type home name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , ModuleName.canonicalEncoder home
                , BE.string name
                , BE.list typeEncoder args
                ]

        Record msgType decoder ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , BE.stdDict BE.string typeEncoder msgType
                , extensionEncoder decoder
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 9

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , typeEncoder a
                , typeEncoder b
                , BE.list typeEncoder cs
                ]

        Alias home name args tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , ModuleName.canonicalEncoder home
                , BE.string name
                , BE.list (BE.jsonPair BE.string typeEncoder) args
                , typeEncoder tipe
                ]


{-| A decoder for an error type written by `typeEncoder`. It fails on a
constructor byte it does not know.
-}
typeDecoder : Bytes.Decode.Decoder Type
typeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Lambda
                            typeDecoder
                            typeDecoder
                            (BD.list typeDecoder)

                    1 ->
                        Bytes.Decode.succeed Infinite

                    2 ->
                        Bytes.Decode.succeed Error

                    3 ->
                        Bytes.Decode.map FlexVar BD.string

                    4 ->
                        Bytes.Decode.map2 FlexSuper
                            superDecoder
                            BD.string

                    5 ->
                        Bytes.Decode.map RigidVar BD.string

                    6 ->
                        Bytes.Decode.map2 RigidSuper
                            superDecoder
                            BD.string

                    7 ->
                        Bytes.Decode.map3 Type
                            ModuleName.canonicalDecoder
                            BD.string
                            (BD.list typeDecoder)

                    8 ->
                        Bytes.Decode.map2 Record
                            (BD.stdDict BD.string typeDecoder)
                            extensionDecoder

                    9 ->
                        Bytes.Decode.succeed Unit

                    10 ->
                        Bytes.Decode.map3 Tuple
                            typeDecoder
                            typeDecoder
                            (BD.list typeDecoder)

                    11 ->
                        Bytes.Decode.map4 Alias
                            ModuleName.canonicalDecoder
                            BD.string
                            (BD.list (BD.jsonPair BD.string typeDecoder))
                            typeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a constraint as one byte, numbered from 0 in declaration order.
-}
superEncoder : Super -> Bytes.Encode.Encoder
superEncoder super =
    Bytes.Encode.unsignedInt8
        (case super of
            Number ->
                0

            Comparable ->
                1

            Appendable ->
                2

            CompAppend ->
                3
        )


{-| A decoder for a constraint written by `superEncoder`, failing on an unknown
byte.
-}
superDecoder : Bytes.Decode.Decoder Super
superDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Number

                    1 ->
                        Bytes.Decode.succeed Comparable

                    2 ->
                        Bytes.Decode.succeed Appendable

                    3 ->
                        Bytes.Decode.succeed CompAppend

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a record extension as one byte, numbered from 0 in declaration
order, followed by the variable's name when there is one.
-}
extensionEncoder : Extension -> Bytes.Encode.Encoder
extensionEncoder extension =
    case extension of
        Closed ->
            Bytes.Encode.unsignedInt8 0

        FlexOpen x ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string x
                ]

        RigidOpen x ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string x
                ]


{-| A decoder for a record extension written by `extensionEncoder`, failing on
an unknown byte.
-}
extensionDecoder : Bytes.Decode.Decoder Extension
extensionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Closed

                    1 ->
                        Bytes.Decode.map FlexOpen BD.string

                    2 ->
                        Bytes.Decode.map RigidOpen BD.string

                    _ ->
                        Bytes.Decode.fail
            )
