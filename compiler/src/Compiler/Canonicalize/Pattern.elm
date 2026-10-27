module Compiler.Canonicalize.Pattern exposing
    ( PResult, Bindings, DupsDict
    , canonicalizeWithIds, traverseWithIds
    , verify, verifyWithIds
    )

{-| A pattern binds names, and the body it guards can only be canonicalized once
those names are known. This module turns source patterns, from function and
lambda arguments, `case` branches and `let` destructurings, into canonical
patterns, and reports the names each one binds.

Canonicalizing a pattern resolves each constructor it names through the
environment and checks it is given the right number of arguments. A
constructor of a record alias cannot be matched on and is an error, and so is a
tuple pattern of more than three elements. A constructor of the `Bool` type in
`Basics` becomes a `PBool`; a constructor named `True` or `False` in any other
type stays an ordinary constructor pattern.

Each canonical pattern node takes a node id from an `Ids.IdState` counter that
the caller threads in and gets back. A node takes its id after the ids of its
sub-patterns. A parenthesised pattern makes no node of its own.

While patterns are canonicalized, every name they bind is recorded in a
`DupsDict`: a variable, each field of a record pattern, and the name after
`as`. The tracker travels in the info slot of the result, so nothing is checked
as it grows. `verify` and `verifyWithIds` close a pattern computation: they run
it from an empty tracker, fail with `DuplicatePattern` on a name bound twice,
and otherwise hand back the _bindings_, each bound name with the region where
it is bound. Because they leave the caller's own info slot untouched, the
result can be used inside a computation that keeps something else there.


# Results and Bindings

@docs PResult, Bindings, DupsDict


# Canonicalization

@docs canonicalizeWithIds, traverseWithIds


# Validation

@docs verify, verifyWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Ids as Ids
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)



-- ====== RESULTS ======


{-| A reporting result whose errors are canonicalization errors.

While patterns are canonicalized, the info slot `i` is a `DupsDict`. This is a
name for `ReportingResult.RResult`, not a new type.

-}
type alias PResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| The names a pattern binds, each with the region where it is bound.
-}
type alias Bindings =
    Dict Name.Name A.Region



-- ====== VERIFY ======


{-| Runs a pattern computation from an empty tracker and returns its value
together with the names it bound.

A name bound more than once fails with `DuplicatePattern` in `context`; only
the first duplicated name in name order is reported. If the computation itself
fails, its errors are returned and the names are not checked. The caller's info
slot is passed through unchanged.

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


{-| Does what `verify` does for a computation whose value is paired with an
`Ids.IdState`, and returns the state as the third component, beside the value
and the bindings.
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


{-| The names bound so far while patterns are canonicalized, each occurrence
kept with the region where it is bound, so that `verify` can report two
bindings of one name. This is a name for a `Dups.Tracker`, not a new type.
-}
type alias DupsDict =
    Dups.Tracker A.Region


{-| Wraps a pattern node at `region` with the next id from `state`, and
returns the advanced state.
-}
makePattern : A.Region -> Ids.IdState -> Can.Pattern_ -> ( Can.Pattern, Ids.IdState )
makePattern region state node =
    let
        ( id, newState ) =
            Ids.allocId state
    in
    ( A.At region { id = id, node = node }, newState )


{-| Canonicalizes one source pattern, giving its nodes ids from `state0`, and
returns the canonical pattern with the advanced state.

Each name it binds is added to the tracker in the info slot. A constructor that
cannot be found, is given the wrong number of arguments (`BadArity`), or
belongs to a record alias (`PatternHasRecordCtor`) is an error, as is a tuple
of more than three elements (`TupleLargerThanThree`).

-}
canonicalizeWithIds : Env.Env -> Ids.IdState -> Src.Pattern -> PResult DupsDict w ( Can.Pattern, Ids.IdState )
canonicalizeWithIds env state0 (A.At region pattern) =
    case pattern of
        Src.PAnything _ ->
            logVar_ Can.PAnything
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
            canonicalizeWithIds env state0 a
                |> ReportingResult.andThen
                    (\( canA, state1 ) ->
                        canonicalizeWithIds env state1 b
                            |> ReportingResult.andThen
                                (\( canB, state2 ) ->
                                    canonicalizeTupleWithIds region env state2 (List.map Src.c2Value cs)
                                        |> ReportingResult.map
                                            (\( canCs, state3 ) ->
                                                makePattern region state3 (Can.PTuple canA canB canCs)
                                            )
                                )
                    )

        Src.PCtor nameRegion name patterns ->
            Env.findCtor nameRegion env name
                |> ReportingResult.andThen (canonicalizeCtorWithIds env state0 region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (\( pattern_, state1 ) -> makePattern region state1 pattern_)

        Src.PCtorQual nameRegion home name patterns ->
            Env.findCtorQual nameRegion env home name
                |> ReportingResult.andThen (canonicalizeCtorWithIds env state0 region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (\( pattern_, state1 ) -> makePattern region state1 pattern_)

        Src.PList ( _, patterns ) ->
            canonicalizeListWithIds env state0 (List.map Src.c2Value patterns)
                |> ReportingResult.map
                    (\( canPatterns, state1 ) ->
                        makePattern region state1 (Can.PList canPatterns)
                    )

        Src.PCons ( _, first ) ( _, rest ) ->
            canonicalizeWithIds env state0 first
                |> ReportingResult.andThen
                    (\( canFirst, state1 ) ->
                        canonicalizeWithIds env state1 rest
                            |> ReportingResult.map
                                (\( canRest, state2 ) ->
                                    makePattern region state2 (Can.PCons canFirst canRest)
                                )
                    )

        Src.PAlias ( _, ptrn ) ( _, A.At reg name ) ->
            canonicalizeWithIds env state0 ptrn
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
            canonicalizeWithIds env state0 pattern_


{-| Returns `value` and records no name, which is what a wildcard binds.
-}
logVar_ : a -> PResult DupsDict w a
logVar_ value =
    ReportingResult.ok value


{-| Canonicalizes the arguments of a constructor pattern against the
constructor `ctor` that `name` resolved to, and returns the pattern node.

A constructor of `Bool` from `Basics` gives a `PBool`. Too many or too few
arguments give `BadArity` at `region`, after the arguments that pair up have
been canonicalized.

-}
canonicalizeCtorWithIds : Env.Env -> Ids.IdState -> A.Region -> Name.Name -> List Src.Pattern -> Env.Ctor -> PResult DupsDict w ( Can.Pattern_, Ids.IdState )
canonicalizeCtorWithIds env state0 region name patterns ctor =
    case ctor of
        Env.Ctor home tipe union index args ->
            canonicalizeCtorArgsWithIds env state0 patterns args
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


{-| Canonicalizes argument patterns in order, pairing each with the
constructor's argument type at the same zero-based index, or reports both
counts when the lists differ in length.
-}
canonicalizeCtorArgsWithIds : Env.Env -> Ids.IdState -> List Src.Pattern -> List (Can.Type Name) -> PResult DupsDict w ( Index.VerifiedList Can.PatternCtorArg, Ids.IdState )
canonicalizeCtorArgsWithIds env state0 patterns args =
    canonicalizeCtorArgsWithIdsHelp env state0 Index.first patterns args []


{-| Does the work of `canonicalizeCtorArgsWithIds`, with `acc` holding the
arguments paired so far in reverse and `index` the position of the next.

On a mismatch the first count is the number of patterns and the second the
number of argument types.

-}
canonicalizeCtorArgsWithIdsHelp : Env.Env -> Ids.IdState -> Index.ZeroBased -> List Src.Pattern -> List (Can.Type Name) -> List Can.PatternCtorArg -> PResult DupsDict w ( Index.VerifiedList Can.PatternCtorArg, Ids.IdState )
canonicalizeCtorArgsWithIdsHelp env state0 index patterns args acc =
    case ( patterns, args ) of
        ( [], [] ) ->
            ReportingResult.ok ( Index.LengthMatch (List.reverse acc), state0 )

        ( pattern :: restPatterns, argType :: restArgs ) ->
            canonicalizeWithIds env state0 pattern
                |> ReportingResult.andThen
                    (\( canPattern, state1 ) ->
                        let
                            ctorArg =
                                Can.PatternCtorArg index argType canPattern
                        in
                        canonicalizeCtorArgsWithIdsHelp env state1 (Index.next index) restPatterns restArgs (ctorArg :: acc)
                    )

        ( [], _ ) ->
            ReportingResult.ok ( Index.LengthMismatch (List.length acc) (List.length acc + List.length args), state0 )

        ( _, [] ) ->
            ReportingResult.ok ( Index.LengthMismatch (List.length acc + List.length patterns) (List.length acc), state0 )


{-| Canonicalizes the elements of a tuple pattern after its first two, of
which there may be at most one; more is `TupleLargerThanThree` at
`tupleRegion`.
-}
canonicalizeTupleWithIds : A.Region -> Env.Env -> Ids.IdState -> List Src.Pattern -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
canonicalizeTupleWithIds tupleRegion env state0 extras =
    case extras of
        [] ->
            ReportingResult.ok ( [], state0 )

        [ three ] ->
            canonicalizeWithIds env state0 three
                |> ReportingResult.map (\( p, s ) -> ( [ p ], s ))

        _ ->
            ReportingResult.throw (Error.TupleLargerThanThree tupleRegion)


{-| Canonicalizes the entries of a list pattern in order, threading the id
state through them.
-}
canonicalizeListWithIds : Env.Env -> Ids.IdState -> List Src.Pattern -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
canonicalizeListWithIds env state0 list =
    case list of
        [] ->
            ReportingResult.ok ( [], state0 )

        pattern :: otherPatterns ->
            canonicalizeWithIds env state0 pattern
                |> ReportingResult.andThen
                    (\( canPattern, state1 ) ->
                        canonicalizeListWithIds env state1 otherPatterns
                            |> ReportingResult.map
                                (\( restPatterns, state2 ) ->
                                    ( canPattern :: restPatterns, state2 )
                                )
                    )



-- ====== LOG BINDINGS ======


{-| Returns `value` and records `name` as bound at `region`.
-}
logVar : Name.Name -> A.Region -> a -> PResult DupsDict w a
logVar name region value =
    ReportingResult.RResult <|
        \andThenings warnings ->
            ReportingResult.ROk (Dups.insert name region region andThenings) warnings value


{-| Returns `value` and records each field of a record pattern as a name bound
at the field's region.
-}
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


{-| Canonicalizes several patterns in order, as `canonicalizeWithIds` does
each, threading the id state from one to the next, and returns them in the
same order.

All their names go into the one tracker, so a name bound in two of the
patterns is a duplicate when the result is verified.

-}
traverseWithIds :
    Env.Env
    -> Ids.IdState
    -> List Src.Pattern
    -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
traverseWithIds env state patterns =
    traverseWithIdsHelp env state patterns []


{-| Does the work of `traverseWithIds`, with `accum` holding the patterns done
so far in reverse.
-}
traverseWithIdsHelp :
    Env.Env
    -> Ids.IdState
    -> List Src.Pattern
    -> List Can.Pattern
    -> PResult DupsDict w ( List Can.Pattern, Ids.IdState )
traverseWithIdsHelp env state patterns accum =
    case patterns of
        [] ->
            ReportingResult.ok ( List.reverse accum, state )

        pattern :: rest ->
            canonicalizeWithIds env state pattern
                |> ReportingResult.andThen
                    (\( canPattern, newState ) ->
                        traverseWithIdsHelp env newState rest (canPattern :: accum)
                    )
