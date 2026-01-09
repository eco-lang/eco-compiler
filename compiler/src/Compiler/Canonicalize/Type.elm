module Compiler.Canonicalize.Type exposing
    ( CResult
    , canonicalize, toAnnotation
    )

{-| Canonicalize Elm type annotations from source AST to canonical AST.

This module transforms type expressions, validating type constructors, checking
arity of type applications, resolving qualified type names, and collecting free
type variables for use in polymorphic type schemes (Forall quantification).


# Results

@docs CResult


# Canonicalization

@docs canonicalize, toAnnotation

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Data.Name as Name
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Map as Dict exposing (Dict)
import Utils.Main as Utils



-- ====== RESULT ======


{-| Result type for canonicalization operations.

Wraps the reporting result type with canonicalization-specific error information.

-}
type alias CResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== TO ANNOTATION ======


{-| Convert a source type to a canonical type annotation.

Canonicalizes the given source type and wraps it in a Forall quantifier with all
free type variables collected. This creates a polymorphic type scheme suitable
for top-level type annotations.

-}
toAnnotation : SyntaxVersion -> Env.Env -> Src.Type -> CResult i w Can.Annotation
toAnnotation syntaxVersion env srcType =
    canonicalize syntaxVersion env srcType
        |> ReportingResult.andThen (\tipe -> ReportingResult.ok (Can.Forall (addFreeVars Dict.empty tipe) tipe))



-- ====== CANONICALIZE TYPES ======


{-| Canonicalize a source type expression into a canonical type.

Transforms type variables, type constructors, function types, records, tuples,
and units from source AST to canonical AST. Validates type constructor existence,
checks arity of type applications, resolves qualified type names, and handles
syntax version differences (e.g., tuple size restrictions in Elm vs Guida).

-}
canonicalize : SyntaxVersion -> Env.Env -> Src.Type -> CResult i w Can.Type
canonicalize syntaxVersion env (A.At typeRegion tipe) =
    case tipe of
        Src.TVar x ->
            ReportingResult.ok (Can.TVar x)

        Src.TType region name args ->
            Env.findType region env name
                |> ReportingResult.andThen (canonicalizeType syntaxVersion env typeRegion name (List.map Tuple.second args))

        Src.TTypeQual region home name args ->
            Env.findTypeQual region env home name
                |> ReportingResult.andThen (canonicalizeType syntaxVersion env typeRegion name (List.map Tuple.second args))

        Src.TLambda ( _, a ) ( _, b ) ->
            ReportingResult.map Can.TLambda (canonicalize syntaxVersion env a)
                |> ReportingResult.apply (canonicalize syntaxVersion env b)

        Src.TRecord fields maybeExt _ ->
            Dups.checkFields (canonicalizeFields syntaxVersion env fields)
                |> ReportingResult.andThen (Utils.sequenceADict identity compare)
                |> ReportingResult.map (\cfields -> Can.TRecord cfields (Maybe.map (\( _, A.At _ ext ) -> ext) maybeExt))

        Src.TUnit ->
            ReportingResult.ok Can.TUnit

        Src.TTuple ( _, a ) ( _, b ) cs ->
            ReportingResult.map Can.TTuple (canonicalize syntaxVersion env a)
                |> ReportingResult.apply (canonicalize syntaxVersion env b)
                |> ReportingResult.apply
                    (case cs of
                        [] ->
                            ReportingResult.ok []

                        [ ( _, c ) ] ->
                            canonicalize syntaxVersion env c
                                |> ReportingResult.map List.singleton

                        _ ->
                            case syntaxVersion of
                                SV.Elm ->
                                    ReportingResult.throw (Error.TupleLargerThanThree typeRegion)

                                SV.Guida ->
                                    ReportingResult.traverse (canonicalize syntaxVersion env) (List.map Src.c2EolValue cs)
                    )

        Src.TParens ( _, tipe_ ) ->
            canonicalize syntaxVersion env tipe_


canonicalizeFields : SyntaxVersion -> Env.Env -> List (Src.C2 ( Src.C1 (A.Located Name.Name), Src.C1 Src.Type )) -> List ( A.Located Name.Name, CResult i w Can.FieldType )
canonicalizeFields syntaxVersion env fields =
    let
        canonicalizeField : Int -> Src.C2 ( Src.C1 a, Src.C1 Src.Type ) -> ( a, ReportingResult.RResult i w Error.Error Can.FieldType )
        canonicalizeField index ( _, ( ( _, name ), ( _, srcType ) ) ) =
            ( name, ReportingResult.map (Can.FieldType index) (canonicalize syntaxVersion env srcType) )
    in
    List.indexedMap canonicalizeField fields



-- ====== CANONICALIZE TYPE ======


canonicalizeType : SyntaxVersion -> Env.Env -> A.Region -> Name.Name -> List Src.Type -> Env.Type -> CResult i w Can.Type
canonicalizeType syntaxVersion env region name args info =
    ReportingResult.traverse (canonicalize syntaxVersion env) args
        |> ReportingResult.andThen
            (\cargs ->
                case info of
                    Env.Alias arity home argNames aliasedType ->
                        Can.TAlias home name (List.map2 Tuple.pair argNames cargs) (Can.Holey aliasedType) |> checkArity arity region name args

                    Env.Union arity home ->
                        Can.TType home name cargs |> checkArity arity region name args
            )


checkArity : Int -> A.Region -> Name.Name -> List (A.Located arg) -> answer -> CResult i w answer
checkArity expected region name args answer =
    let
        actual : Int
        actual =
            List.length args
    in
    if expected == actual then
        ReportingResult.ok answer

    else
        ReportingResult.throw (Error.BadArity region Error.TypeArity name expected actual)



-- ====== ADD FREE VARS ======


addFreeVars : Dict String Name.Name () -> Can.Type -> Dict String Name.Name ()
addFreeVars freeVars tipe =
    case tipe of
        Can.TLambda arg result ->
            addFreeVars (addFreeVars freeVars result) arg

        Can.TVar var ->
            Dict.insert identity var () freeVars

        Can.TType _ _ args ->
            List.foldl (\b c -> addFreeVars c b) freeVars args

        Can.TRecord fields Nothing ->
            Dict.foldl compare (\_ b c -> addFieldFreeVars c b) freeVars fields

        Can.TRecord fields (Just ext) ->
            Dict.foldl compare (\_ b c -> addFieldFreeVars c b) (Dict.insert identity ext () freeVars) fields

        Can.TUnit ->
            freeVars

        Can.TTuple a b cs ->
            List.foldl (flip addFreeVars) (addFreeVars (addFreeVars freeVars a) b) cs

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, arg ) fvs -> addFreeVars fvs arg) freeVars args


addFieldFreeVars : Dict String Name.Name () -> Can.FieldType -> Dict String Name.Name ()
addFieldFreeVars freeVars (Can.FieldType _ tipe) =
    addFreeVars freeVars tipe
