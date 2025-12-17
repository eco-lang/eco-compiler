module Compiler.Canonicalize.Pattern exposing
    ( PResult, Bindings, DupsDict
    , canonicalize
    , verify
    )

{-| Canonicalize Elm patterns from source AST to canonical AST.

This module transforms pattern expressions used in function arguments, let bindings,
and case branches. It validates constructor applications, checks for duplicate
bindings within patterns, and tracks all variables bound by each pattern for use
in scope analysis.


# Results and Bindings

@docs PResult, Bindings, DupsDict


# Canonicalization

@docs canonicalize


# Validation

@docs verify

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Map exposing (Dict)
import Utils.Main as Utils



-- RESULTS


type alias PResult i w a =
    ReportingResult.RResult i w Error.Error a


type alias Bindings =
    Dict String Name.Name A.Region



-- VERIFY


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



-- CANONICALIZE


type alias DupsDict =
    Dups.Tracker A.Region


canonicalize : SyntaxVersion -> Env.Env -> Src.Pattern -> PResult DupsDict w Can.Pattern
canonicalize syntaxVersion env (A.At region pattern) =
    case pattern of
        Src.PAnything _ ->
            ReportingResult.ok Can.PAnything
                |> ReportingResult.map (A.At region)

        Src.PVar name ->
            logVar name region (Can.PVar name)
                |> ReportingResult.map (A.At region)

        Src.PRecord ( _, c2Fields ) ->
            let
                fields : List (A.Located Name.Name)
                fields =
                    List.map Src.c2Value c2Fields
            in
            logFields fields (Can.PRecord (List.map A.toValue fields))
                |> ReportingResult.map (A.At region)

        Src.PUnit _ ->
            ReportingResult.ok Can.PUnit
                |> ReportingResult.map (A.At region)

        Src.PTuple ( _, a ) ( _, b ) cs ->
            ReportingResult.map Can.PTuple (canonicalize syntaxVersion env a)
                |> ReportingResult.apply (canonicalize syntaxVersion env b)
                |> ReportingResult.apply (canonicalizeTuple syntaxVersion region env (List.map Src.c2Value cs))
                |> ReportingResult.map (A.At region)

        Src.PCtor nameRegion name patterns ->
            Env.findCtor nameRegion env name
                |> ReportingResult.andThen (canonicalizeCtor syntaxVersion env region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (A.At region)

        Src.PCtorQual nameRegion home name patterns ->
            Env.findCtorQual nameRegion env home name
                |> ReportingResult.andThen (canonicalizeCtor syntaxVersion env region name (List.map Src.c1Value patterns))
                |> ReportingResult.map (A.At region)

        Src.PList ( _, patterns ) ->
            ReportingResult.map Can.PList (canonicalizeList syntaxVersion env (List.map Src.c2Value patterns))
                |> ReportingResult.map (A.At region)

        Src.PCons ( _, first ) ( _, rest ) ->
            ReportingResult.map Can.PCons (canonicalize syntaxVersion env first)
                |> ReportingResult.apply (canonicalize syntaxVersion env rest)
                |> ReportingResult.map (A.At region)

        Src.PAlias ( _, ptrn ) ( _, A.At reg name ) ->
            canonicalize syntaxVersion env ptrn
                |> ReportingResult.andThen (\cpattern -> logVar name reg (Can.PAlias cpattern name))
                |> ReportingResult.map (A.At region)

        Src.PChr chr ->
            ReportingResult.ok (Can.PChr chr)
                |> ReportingResult.map (A.At region)

        Src.PStr str multiline ->
            ReportingResult.ok (Can.PStr str multiline)
                |> ReportingResult.map (A.At region)

        Src.PInt int _ ->
            ReportingResult.ok (Can.PInt int)
                |> ReportingResult.map (A.At region)

        Src.PParens ( _, pattern_ ) ->
            canonicalize syntaxVersion env pattern_


canonicalizeCtor : SyntaxVersion -> Env.Env -> A.Region -> Name.Name -> List Src.Pattern -> Env.Ctor -> PResult DupsDict w Can.Pattern_
canonicalizeCtor syntaxVersion env region name patterns ctor =
    case ctor of
        Env.Ctor home tipe union index args ->
            let
                toCanonicalArg : Index.ZeroBased -> Src.Pattern -> Can.Type -> ReportingResult.RResult DupsDict w Error.Error Can.PatternCtorArg
                toCanonicalArg argIndex argPattern argTipe =
                    ReportingResult.map (Can.PatternCtorArg argIndex argTipe)
                        (canonicalize syntaxVersion env argPattern)
            in
            Utils.indexedZipWithA toCanonicalArg patterns args
                |> ReportingResult.andThen
                    (\verifiedList ->
                        case verifiedList of
                            Index.LengthMatch cargs ->
                                if tipe == Name.bool && home == ModuleName.basics then
                                    ReportingResult.ok (Can.PBool union (name == Name.true))

                                else
                                    ReportingResult.ok (Can.PCtor { home = home, type_ = tipe, union = union, name = name, index = index, args = cargs })

                            Index.LengthMismatch actualLength expectedLength ->
                                ReportingResult.throw (Error.BadArity region Error.PatternArity name expectedLength actualLength)
                    )

        Env.RecordCtor _ _ _ ->
            ReportingResult.throw (Error.PatternHasRecordCtor region name)


canonicalizeTuple : SyntaxVersion -> A.Region -> Env.Env -> List Src.Pattern -> PResult DupsDict w (List Can.Pattern)
canonicalizeTuple syntaxVersion tupleRegion env extras =
    case extras of
        [] ->
            ReportingResult.ok []

        [ three ] ->
            ReportingResult.map List.singleton (canonicalize syntaxVersion env three)

        _ ->
            case syntaxVersion of
                SV.Elm ->
                    ReportingResult.throw (Error.TupleLargerThanThree tupleRegion)

                SV.Guida ->
                    ReportingResult.traverse (canonicalize syntaxVersion env) extras


canonicalizeList : SyntaxVersion -> Env.Env -> List Src.Pattern -> PResult DupsDict w (List Can.Pattern)
canonicalizeList syntaxVersion env list =
    case list of
        [] ->
            ReportingResult.ok []

        pattern :: otherPatterns ->
            ReportingResult.map (::) (canonicalize syntaxVersion env pattern)
                |> ReportingResult.apply (canonicalizeList syntaxVersion env otherPatterns)



-- LOG BINDINGS


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
