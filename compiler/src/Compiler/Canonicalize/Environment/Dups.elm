module Compiler.Canonicalize.Environment.Dups exposing
    ( Info
    , ToError
    , Tracker
    , checkFields
    , checkFields_
    , checkLocatedFields
    , checkLocatedFields_
    , detect
    , detectLocated
    , insert
    , none
    , one
    , union
    , unions
    )

{-| Utilities for detecting duplicate names in declarations.

This module provides a generic duplicate-tracking system used throughout
canonicalization to detect and report duplicate:
- Type names
- Constructor names
- Field names in records
- Variable names
- Type parameters

-}

import Compiler.Data.Name exposing (Name)
import Compiler.Data.OneOrMore as OneOrMore exposing (OneOrMore)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error exposing (Error)
import Compiler.Reporting.Result as ReportingResult
import Data.Map as Dict exposing (Dict)
import Utils.Main as Utils



-- DUPLICATE TRACKER


{-| Tracks potential duplicate names, storing one or more occurrences of each name.
-}
type alias Tracker value =
    Dict String Name (OneOrMore (Info value))


{-| Information about a name occurrence, including its source region and associated value.
-}
type Info value
    = Info A.Region value



-- DETECT


{-| Function that constructs a duplicate name error from name and two conflicting regions.
-}
type alias ToError =
    Name -> A.Region -> A.Region -> Error


{-| Detect duplicate names in a tracker and convert to a dictionary.

Returns an error if any name appears more than once, otherwise returns a dictionary
with one entry per unique name.

-}
detect : ToError -> Tracker a -> ReportingResult.RResult i w Error (Dict String Name a)
detect toError dict =
    Dict.foldl compare
        (\name values ->
            ReportingResult.andThen
                (\acc ->
                    ReportingResult.map (\b -> Dict.insert identity name b acc)
                        (detectHelp toError name values)
                )
        )
        (ReportingResult.ok Dict.empty)
        dict


{-| Like `detect`, but returns located names in the resulting dictionary.

The name keys in the result include their source region, useful when the location
information needs to be preserved for later processing.

-}
detectLocated : ToError -> Tracker a -> ReportingResult.RResult i w Error (Dict String (A.Located Name) a)
detectLocated toError dict =
    let
        nameLocations : Dict String Name A.Region
        nameLocations =
            Utils.mapMapMaybe identity compare extractLocation dict
    in
    dict
        |> Utils.mapMapKeys A.toValue compare (\k -> A.At (Dict.get identity k nameLocations |> Maybe.withDefault A.zero) k)
        |> ReportingResult.mapTraverseWithKey A.toValue A.compareLocated (\(A.At _ name) values -> detectHelp toError name values)


extractLocation : OneOrMore.OneOrMore (Info a) -> Maybe A.Region
extractLocation oneOrMore =
    case oneOrMore of
        OneOrMore.One (Info region _) ->
            Just region

        OneOrMore.More _ _ ->
            Nothing


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



-- CHECK FIELDS


{-| Check for duplicate field names in a list of fields, returning located names.

Used when processing record types and patterns where field location information
needs to be preserved.

-}
checkLocatedFields : List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (Dict String (A.Located Name) a)
checkLocatedFields fields =
    detectLocated Error.DuplicateField (List.foldr addField none fields)


{-| Check for duplicate field names in a list of fields.

Returns an error if any field name appears more than once, otherwise returns
a dictionary mapping field names to their values.

-}
checkFields : List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (Dict String Name a)
checkFields fields =
    detect Error.DuplicateField (List.foldr addField none fields)


addField : ( A.Located Name, a ) -> Tracker a -> Tracker a
addField ( A.At region name, value ) dups =
    Utils.mapInsertWith identity OneOrMore.more name (OneOrMore.one (Info region value)) dups


{-| Check for duplicate field names, transforming values with a region-aware function.

Like `checkLocatedFields` but applies a transformation function to each value that
has access to the field's source region.

-}
checkLocatedFields_ : (A.Region -> a -> b) -> List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (Dict String (A.Located Name) b)
checkLocatedFields_ toValue fields =
    detectLocated Error.DuplicateField (List.foldr (addField_ toValue) none fields)


{-| Check for duplicate field names, transforming values with a region-aware function.

Like `checkFields` but applies a transformation function to each value that
has access to the field's source region.

-}
checkFields_ : (A.Region -> a -> b) -> List ( A.Located Name, a ) -> ReportingResult.RResult i w Error (Dict String Name b)
checkFields_ toValue fields =
    detect Error.DuplicateField (List.foldr (addField_ toValue) none fields)


addField_ : (A.Region -> a -> b) -> ( A.Located Name, a ) -> Tracker b -> Tracker b
addField_ toValue ( A.At region name, value ) dups =
    Utils.mapInsertWith identity OneOrMore.more name (OneOrMore.one (Info region (toValue region value))) dups



-- BUILDING DICTIONARIES


{-| Create an empty tracker with no names.
-}
none : Tracker a
none =
    Dict.empty


{-| Create a tracker with a single name occurrence.
-}
one : Name -> A.Region -> value -> Tracker value
one name region value =
    Dict.singleton identity name (OneOrMore.one (Info region value))


{-| Insert a name occurrence into a tracker.

If the name already exists, both occurrences are tracked for duplicate detection.

-}
insert : Name -> A.Region -> a -> Tracker a -> Tracker a
insert name region value dict =
    Utils.mapInsertWith identity (\new old -> OneOrMore.more old new) name (OneOrMore.one (Info region value)) dict


{-| Combine two trackers, merging occurrences of the same name.
-}
union : Tracker a -> Tracker a -> Tracker a
union a b =
    Utils.mapUnionWith identity compare OneOrMore.more a b


{-| Combine a list of trackers into a single tracker.
-}
unions : List (Tracker a) -> Tracker a
unions dicts =
    List.foldl union Dict.empty dicts
