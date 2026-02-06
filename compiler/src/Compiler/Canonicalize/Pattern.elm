module Compiler.Canonicalize.Pattern exposing
    ( PResult, Bindings, DupsDict
    , canonicalizeWithIds, traverseWithIds
    , verify, verifyWithIds
    )

{-| Canonicalize Elm patterns from source AST to canonical AST.

This module transforms pattern expressions used in function arguments, let bindings,
and case branches. It validates constructor applications, checks for duplicate
bindings within patterns, and tracks all variables bound by each pattern for use
in scope analysis.


# Results and Bindings

@docs PResult, Bindings, DupsDict


# Canonicalization

@docs canonicalizeWithIds, traverseWithIds


# Validation

@docs verify, verifyWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Ids as Ids
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Map exposing (Dict)



-- ====== RESULTS ======


{-| Result type for pattern canonicalization operations.

A specialized result type that threads duplicate tracking information and
canonicalization errors through the pattern analysis pipeline.

-}
type alias PResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| Dictionary mapping variable names to their canonical names and source regions.

Tracks all variables bound by a pattern for use in scope analysis and error reporting.

-}
type alias Bindings =
    Dict String Name.Name A.Region



-- ====== VERIFY ======


{-| Verify that a pattern has no duplicate bindings and extract all variable bindings.

Takes a canonicalized pattern result and checks for duplicate variable names within
the pattern. Returns both the canonicalized pattern and a dictionary of all bindings
if successful, or errors if duplicates are found.

-}
verify : Error.DuplicatePatternContext -> PResult DupsDict w a -> PResult i w ( a, Bindings )
verify context (ReportingResult.RResult k) =
    ReportingResult.RResult <|
        \info warnings ->
            case k Dups.none warnings of
                ReportingResult.RErr _ warnings1 errors ->
                    ReportingResult.RErr info warnings1 errors

                ReportingResult.ROk andThenings warnings1 value ->
                    case Dups.detect (Error.DuplicatePattern context) andThenings of
                        ReportingResult.RResult k1 ->
                            case k1 () () of
                                ReportingResult.RErr () () errs ->
                                    ReportingResult.RErr info warnings1 errs

                                ReportingResult.ROk () () dict ->
                                    ReportingResult.ROk info warnings1 ( value, dict )


{-| Verify patterns that were canonicalized with ID threading.

This is similar to `verify` but also extracts the IdState from the result tuple.
Use this when patterns were canonicalized with `canonicalizeWithIds`.

-}
verifyWithIds : Error.DuplicatePatternContext -> PResult DupsDict w ( a, Ids.IdState ) -> PResult i w ( a, Bindings, Ids.IdState )
verifyWithIds context (ReportingResult.RResult k) =
    ReportingResult.RResult <|
        \info warnings ->
            case k Dups.none warnings of
                ReportingResult.RErr _ warnings1 errors ->
                    ReportingResult.RErr info warnings1 errors

                ReportingResult.ROk andThenings warnings1 ( value, idState ) ->
                    case Dups.detect (Error.DuplicatePattern context) andThenings of
                        ReportingResult.RResult k1 ->
                            case k1 () () of
                                ReportingResult.RErr () () errs ->
                                    ReportingResult.RErr info warnings1 errs

                                ReportingResult.ROk () () dict ->
                                    ReportingResult.ROk info warnings1 ( value, dict, idState )



-- ====== CANONICALIZE ======


{-| Tracker for detecting duplicate variable bindings within patterns.

Records each variable name and its source region to enable duplicate detection
and helpful error messages showing both binding locations.

-}
type alias DupsDict =
    Dups.Tracker A.Region


{-| Create a canonical pattern with an ID.
-}
makePattern : A.Region -> Ids.IdState -> Can.Pattern_ -> ( Can.Pattern, Ids.IdState )
makePattern region state node =
    let
        ( id, newState ) =
            Ids.allocId state
    in
    ( A.At region { id = id, node = node }, newState )


{-| Transform a source pattern with ID state threading.

Like canonicalize but also threads an IdState through to assign unique IDs
to each pattern. Returns both the canonical pattern and the updated state.

-}
canonicalizeWithIds : SyntaxVersion -> Env.Env -> Ids.IdState -> Src.Pattern -> PResult DupsDict w ( Can.Pattern, Ids.IdState )
canonicalizeWithIds syntaxVersion env state0 (A.At region pattern) =
    case pattern of
        Src.PAnything _ ->
            logVar_ region Can.PAnything
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PVar name ->
            logVar name region (Can.PVar name)
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PRecord ( _, c2Fields ) ->
            let
                fields : List (A.Located Name.Name)
                fields =
                    List.map Src.c2Value c2Fields
            in
            logFields fields (Can.PRecord (List.map A.toValue fields))
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PUnit _ ->
            ReportingResult.ok Can.PUnit
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PTuple ( _, a ) ( _, b ) cs ->
            canonicalizeWithIds syntaxVersion env state0 a
                |> ReportingResult.andThen
                    (\( canA, state1 ) ->
                        canonicalizeWithIds syntaxVersion env state1 b
                            |> ReportingResult.andThen
                                (\( canB, state2 ) ->
                                    canonicalizeTupleWithIds syntaxVersion region env state2 (List.map Src.c2Value cs)
                                        |> ReportingResult.map
                                            (\( canCs, state3 ) ->
                                                makePattern region state3 (Can.PTuple canA canB canCs)
                                            )
                                )
                    )

        Src.PCtor nameRegion name patterns ->
            Env.findCtor nameRegion env name
                |> ReportingResult.andThen (canonicalizeCtorWithIds syntaxVersion env state0 region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (\( pattern_, state1 ) -> makePattern region state1 pattern_)

        Src.PCtorQual nameRegion home name patterns ->
            Env.findCtorQual nameRegion env home name
                |> ReportingResult.andThen (canonicalizeCtorWithIds syntaxVersion env state0 region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (\( pattern_, state1 ) -> makePattern region state1 pattern_)

        Src.PList ( _, patterns ) ->
            canonicalizeListWithIds syntaxVersion env state0 (List.map Src.c2Value patterns)
                |> ReportingResult.map
                    (\( canPatterns, state1 ) ->
                        makePattern region state1 (Can.PList canPatterns)
                    )

        Src.PCons ( _, first ) ( _, rest ) ->
            canonicalizeWithIds syntaxVersion env state0 first
                |> ReportingResult.andThen
                    (\( canFirst, state1 ) ->
                        canonicalizeWithIds syntaxVersion env state1 rest
                            |> ReportingResult.map
                                (\( canRest, state2 ) ->
                                    makePattern region state2 (Can.PCons canFirst canRest)
                                )
                    )

        Src.PAlias ( _, ptrn ) ( _, A.At reg name ) ->
            canonicalizeWithIds syntaxVersion env state0 ptrn
                |> ReportingResult.andThen
                    (\( cpattern, state1 ) ->
                        logVar name reg (Can.PAlias cpattern name)
                            |> ReportingResult.map (\pattern_ -> makePattern region state1 pattern_)
                    )

        Src.PChr chr ->
            ReportingResult.ok (Can.PChr chr)
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PStr str multiline ->
            ReportingResult.ok (Can.PStr str multiline)
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PInt int _ ->
            ReportingResult.ok (Can.PInt int)
                |> ReportingResult.map (\pattern_ -> makePattern region state0 pattern_)

        Src.PParens ( _, pattern_ ) ->
            canonicalizeWithIds syntaxVersion env state0 pattern_


{-| Helper to pass through a pattern without logging.
-}
logVar_ : A.Region -> a -> PResult DupsDict w a
logVar_ _ value =
    ReportingResult.ok value


canonicalizeCtorWithIds : SyntaxVersion -> Env.Env -> Ids.IdState -> A.Region -> Name.Name -> List Src.Pattern -> Env.Ctor -> PResult DupsDict w ( Can.Pattern_, Ids.IdState )
canonicalizeCtorWithIds syntaxVersion env state0 region name patterns ctor =
    case ctor of
        Env.Ctor home tipe union index args ->
            canonicalizeCtorArgsWithIds syntaxVersion env state0 patterns args
                |> ReportingResult.andThen
                    (\( cargs, finalState ) ->
                        case cargs of
                            Index.LengthMatch cargsResult ->
                                if tipe == Name.bool && home == ModuleName.basics then
                                    ReportingResult.ok ( Can.PBool union (name == Name.true), finalState )

                                else
                                    ReportingResult.ok ( Can.PCtor { home = home, type_ = tipe, union = union, name = name, index = index, args = cargsResult }, finalState )

                            Index.LengthMismatch actualLength expectedLength ->
                                ReportingResult.throw (Error.BadArity region Error.PatternArity name expectedLength actualLength)
                    )

        Env.RecordCtor _ _ _ ->
            ReportingResult.throw (Error.PatternHasRecordCtor region name)


canonicalizeCtorArgsWithIds : SyntaxVersion -> Env.Env -> Ids.IdState -> List Src.Pattern -> List Can.Type -> PResult DupsDict w ( Index.VerifiedList Can.PatternCtorArg, Ids.IdState )
canonicalizeCtorArgsWithIds syntaxVersion env state0 patterns args =
    canonicalizeCtorArgsWithIdsHelp syntaxVersion env state0 Index.first patterns args []


canonicalizeCtorArgsWithIdsHelp : SyntaxVersion -> Env.Env -> Ids.IdState -> Index.ZeroBased -> List Src.Pattern -> List Can.Type -> List Can.PatternCtorArg -> PResult DupsDict w ( Index.VerifiedList Can.PatternCtorArg, Ids.IdState )
canonicalizeCtorArgsWithIdsHelp syntaxVersion env state0 index patterns args acc =
    case ( patterns, args ) of
        ( [], [] ) ->
            ReportingResult.ok ( Index.LengthMatch (List.reverse acc), state0 )

        ( pattern :: restPatterns, argType :: restArgs ) ->
            canonicalizeWithIds syntaxVersion env state0 pattern
                |> ReportingResult.andThen
                    (\( canPattern, state1 ) ->
                        let
                            ctorArg =
                                Can.PatternCtorArg index argType canPattern
                        in
                        canonicalizeCtorArgsWithIdsHelp syntaxVersion env state1 (Index.next index) restPatterns restArgs (ctorArg :: acc)
                    )

        ( [], _ ) ->
            ReportingResult.ok ( Index.LengthMismatch (List.length acc) (List.length acc + List.length args), state0 )

        ( _, [] ) ->
            ReportingResult.ok ( Index.LengthMismatch (List.length acc + List.length patterns) (List.length acc), state0 )


canonicalizeTupleWithIds : SyntaxVersion -> A.Region -> Env.Env -> Ids.IdState -> List Src.Pattern -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
canonicalizeTupleWithIds syntaxVersion tupleRegion env state0 extras =
    case extras of
        [] ->
            ReportingResult.ok ( [], state0 )

        [ three ] ->
            canonicalizeWithIds syntaxVersion env state0 three
                |> ReportingResult.map (\( p, s ) -> ( [ p ], s ))

        _ ->
            case syntaxVersion of
                SV.Elm ->
                    ReportingResult.throw (Error.TupleLargerThanThree tupleRegion)

                SV.Guida ->
                    canonicalizeListWithIds syntaxVersion env state0 extras


canonicalizeListWithIds : SyntaxVersion -> Env.Env -> Ids.IdState -> List Src.Pattern -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
canonicalizeListWithIds syntaxVersion env state0 list =
    case list of
        [] ->
            ReportingResult.ok ( [], state0 )

        pattern :: otherPatterns ->
            canonicalizeWithIds syntaxVersion env state0 pattern
                |> ReportingResult.andThen
                    (\( canPattern, state1 ) ->
                        canonicalizeListWithIds syntaxVersion env state1 otherPatterns
                            |> ReportingResult.map
                                (\( restPatterns, state2 ) ->
                                    ( canPattern :: restPatterns, state2 )
                                )
                    )



-- ====== LOG BINDINGS ======


logVar : Name.Name -> A.Region -> a -> PResult DupsDict w a
logVar name region value =
    ReportingResult.RResult <|
        \andThenings warnings ->
            ReportingResult.ROk (Dups.insert name region region andThenings) warnings value


logFields : List (A.Located Name.Name) -> a -> PResult DupsDict w a
logFields fields value =
    let
        addField : A.Located Name.Name -> Dups.Tracker A.Region -> Dups.Tracker A.Region
        addField (A.At region name) dict =
            Dups.insert name region region dict
    in
    ReportingResult.RResult <|
        \andThenings warnings ->
            ReportingResult.ROk (List.foldl addField andThenings fields) warnings value



-- ====== Traverse With IDs ======


{-| Traverse a list of patterns, threading IdState through each canonicalization.

This is used when canonicalizing multiple patterns that should share the same
ID space, such as lambda arguments or case patterns.

-}
traverseWithIds :
    SyntaxVersion
    -> Env.Env
    -> Ids.IdState
    -> List Src.Pattern
    -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
traverseWithIds syntaxVersion env state patterns =
    traverseWithIdsHelp syntaxVersion env state patterns []


traverseWithIdsHelp :
    SyntaxVersion
    -> Env.Env
    -> Ids.IdState
    -> List Src.Pattern
    -> List Can.Pattern
    -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
traverseWithIdsHelp syntaxVersion env state patterns accum =
    case patterns of
        [] ->
            ReportingResult.ok ( List.reverse accum, state )

        pattern :: rest ->
            canonicalizeWithIds syntaxVersion env state pattern
                |> ReportingResult.andThen
                    (\( canPattern, newState ) ->
                        traverseWithIdsHelp syntaxVersion env newState rest (canPattern :: accum)
                    )
