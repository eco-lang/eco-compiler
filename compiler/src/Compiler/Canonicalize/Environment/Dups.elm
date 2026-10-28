module Compiler.Canonicalize.Environment.Dups exposing (Info, ToError, Tracker, checkFields, checkLocatedFields, detect, insert, none, one, union, unions)

{-| Canonicalization must reject a name defined twice in one scope, and the
error has to point at two of the places it was defined. This module is the
one mechanism for that check, whatever kind of name is being checked.

A _tracker_ maps each name to every occurrence of it collected so far. An
occurrence is the region the name was written at, together with whatever value
the caller wants to keep for it. Trackers are built with `none`, `one`,
`insert`, `union` and `unions`, and nothing is checked while they are built.

The check happens once, in `detect`, which turns a tracker into a `Dict` from
each name to its one value, or fails on a name with more than one occurrence.
The caller supplies the error constructor as a `ToError`, so the same tracker
serves declarations, types, constructors, pattern variables, type arguments,
exports and record fields alike. `checkFields` and `checkLocatedFields` do the
whole job for a list of record fields.

@docs Info, ToError, Tracker, checkFields, checkLocatedFields, detect, insert, none, one, union, unions

-}

import Compiler.Data.Name exposing (Name)
import Compiler.Data.OneOrMore as OneOrMore exposing (OneOrMore)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error exposing (Error)
import Compiler.Reporting.Result as ReportingResult
import Data.Map as DataMap
import Dict exposing (Dict)
import Utils.Main as Utils



-- ====== DUPLICATE TRACKER ======


{-| A collection of name occurrences, keyed by name, holding every occurrence of
each name that has been added.

This is a name for a `Dict`, not a new type.

-}
type alias Tracker value =
    Dict Name (OneOrMore (Info value))


{-| One occurrence of a name: the region it was written at, and the value the
caller keeps for it.
-}
type Info value
    = Info A.Region value



-- ====== DETECT ======


{-| A function that builds the error for a duplicated name, given the name and
the regions of two of its occurrences.
-}
type alias ToError =
    Name -> A.Region -> A.Region -> Error


{-| Returns a `Dict` from each name in the tracker to the value of its one
occurrence, or fails with the errors `toError` builds for the names that occur
more than once.

Every name is checked, in ascending order, and each duplicated one adds an
error, so the failure carries one error per duplicated name, in that order.
Each error's two regions are the name's first two occurrences in the order the
tracker holds them.

-}
detect : ToError -> Tracker a -> ReportingResult.RResult i w Error (Dict Name a)
detect toError dict =
    ReportingResult.traverse
        (\( name, values ) -> ReportingResult.map (Tuple.pair name) (detectHelp toError name values))
        (Dict.toList dict)
        |> ReportingResult.map Dict.fromList


{-| Returns what `detect` returns, but with each key carrying the region of the
name's occurrence.

The failure is the same as `detect`'s. A duplicated name is keyed at `A.zero`,
but the check then fails, so no such key is ever returned.

-}
detectLocated : ToError -> Tracker a -> ReportingResult.RResult i w Error (DataMap.Dict String (A.Located Name) a)
detectLocated toError dict =
    let
        nameLocations : Dict Name A.Region
        nameLocations =
            Utils.dictMapMaybe extractLocation dict
    in
    dict
        |> Dict.foldl (\k x xs -> ( A.At (Dict.get k nameLocations |> Maybe.withDefault A.zero) k, x ) :: xs) []
        |> DataMap.fromList A.toValue
        |> ReportingResult.mapTraverseWithKey A.toValue (\(A.At _ name) values -> detectHelp toError name values)


{-| Returns the region of a name's occurrence when it has exactly one, and
`Nothing` otherwise.
-}
extractLocation : OneOrMore.OneOrMore (Info a) -> Maybe A.Region
extractLocation oneOrMore =
    case oneOrMore of
        OneOrMore.One (Info region _) ->
            Just region

        OneOrMore.More _ _ ->
            Nothing


{-| Returns the value of a name's only occurrence, or fails with the error
`toError` builds from the regions of its first two occurrences.
-}
detectHelp : ToError -> Name -> OneOrMore (Info a) -> ReportingResult.RResult i w Error a
detectHelp toError name values =
    case values of
        OneOrMore.One (Info _ value) ->
            ReportingResult.ok value

        OneOrMore.More left right ->
            let
                ( Info r1 _, Info r2 _ ) =
                    OneOrMore.getFirstTwo left right
            in
            ReportingResult.throw (toError name r1 r2)



-- ====== CHECK FIELDS ======


{-| Returns a dictionary from each field name, carrying the region it was
written at, to its value, or fails with a `DuplicateField` for each field
name that occurs more than once, in ascending order of name.
-}
checkLocatedFields : List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (DataMap.Dict String (A.Located Name) a)
checkLocatedFields fields =
    detectLocated Error.DuplicateField (List.foldr addField none fields)


{-| Returns a dictionary from each field name to its value, or fails with a
`DuplicateField` for each field name that occurs more than once, in ascending
order of name. The regions in each error are those of the name's first two
occurrences in the list.
-}
checkFields : List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (Dict Name a)
checkFields fields =
    detect Error.DuplicateField (List.foldr addField none fields)


{-| Adds a field's name, region and value to the tracker, ahead of any
occurrence of the same name already there.
-}
addField : ( A.Located Name, a ) -> Tracker a -> Tracker a
addField ( A.At region name, value ) dups =
    Utils.dictInsertWith OneOrMore.more name (OneOrMore.one (Info region value)) dups



-- ====== BUILDING DICTIONARIES ======


{-| A tracker with no names in it.
-}
none : Tracker a
none =
    Dict.empty


{-| Creates a tracker holding one occurrence of `name`.
-}
one : Name -> A.Region -> value -> Tracker value
one name region value =
    Dict.singleton name (OneOrMore.one (Info region value))


{-| Adds an occurrence of `name` to the tracker, after any occurrence of the
same name already there.
-}
insert : Name -> A.Region -> a -> Tracker a -> Tracker a
insert name region value dict =
    Utils.dictInsertWith (\new old -> OneOrMore.more old new) name (OneOrMore.one (Info region value)) dict


{-| Returns a tracker holding every occurrence in `a` and in `b`. Where both
hold a name, the occurrences in `a` come first.
-}
union : Tracker a -> Tracker a -> Tracker a
union a b =
    Utils.dictUnionWith OneOrMore.more a b


{-| Returns a tracker holding every occurrence in every tracker of the list.
Where several hold a name, an earlier tracker's occurrences come before a later
one's, so the occurrences stay in source order when the list is.
-}
unions : List (Tracker a) -> Tracker a
unions dicts =
    List.foldl (\dict acc -> union acc dict) Dict.empty dicts
