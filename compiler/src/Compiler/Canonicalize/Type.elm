module Compiler.Canonicalize.Type exposing
    ( CResult
    , canonicalize, toAnnotation
    )

{-| Types written in source, in annotations and declarations, name other types
as they are spelled in the module, so before they can be checked each name must
be resolved to the type it refers to. This module does that for one type
expression.

`canonicalize` turns a source type into a canonical one. Each type name is
looked up in the environment (`Compiler.Canonicalize.Environment` owns how
names are found and what an unknown or ambiguous name reports), and the use
must give exactly as many arguments as the type has parameters. A use of a type
alias is kept as an alias use: it becomes a `Can.TAlias` carrying the alias's
home, its parameter names paired with the arguments, and the aliased type as a
`Holey` body, still written in terms of the parameter names. The alias is not
expanded here.

`toAnnotation` canonicalizes a type and quantifies it over its type variables,
giving the type scheme of an annotation.


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
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)



-- ====== RESULT ======


{-| A canonicalization computation: a `Compiler.Reporting.Result` computation
whose errors are canonicalization errors.
-}
type alias CResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== TO ANNOTATION ======


{-| Canonicalizes `srcType` and quantifies the result over its type variables,
giving a `Can.Forall`.

The variables quantified over are every type variable the type mentions,
including record extension variables and variables in an alias's arguments, but
not the parameter names inside an alias's body, which the alias itself binds.

-}
toAnnotation : Env.Env -> Src.Type -> CResult i w (Can.Annotation Name)
toAnnotation env srcType =
    canonicalize env srcType
        |> ReportingResult.andThen (\tipe -> ReportingResult.ok (Can.Forall (addFreeVars Dict.empty tipe) tipe))



-- ====== CANONICALIZE TYPES ======


{-| Canonicalizes a source type expression in `env`.

Parentheses are dropped and arrows are built with `Can.tLambda`. A named type
becomes a `Can.TType`, or a `Can.TAlias` with a `Holey` body for an alias, and
fails if the name is not in scope or is given the wrong number of arguments. A
record field records its position in the source as its `Can.FieldType` index.

It fails for a tuple of more than three elements, a record with more than
`HeapLimits.maxRecordFields` fields, or a record naming a field twice.

-}
canonicalize : Env.Env -> Src.Type -> CResult i w (Can.Type Name)
canonicalize env (A.At typeRegion tipe) =
    case tipe of
        Src.TVar x ->
            ReportingResult.ok (Can.TVar x)

        Src.TType region name args ->
            Env.findType region env name
                |> ReportingResult.andThen (canonicalizeType env typeRegion name (List.map Tuple.second args))

        Src.TTypeQual region home name args ->
            Env.findTypeQual region env home name
                |> ReportingResult.andThen (canonicalizeType env typeRegion name (List.map Tuple.second args))

        Src.TLambda ( _, a ) ( _, b ) ->
            ReportingResult.map Can.tLambda (canonicalize env a)
                |> ReportingResult.apply (canonicalize env b)

        Src.TRecord fields maybeExt _ ->
            if List.length fields > HeapLimits.maxRecordFields then
                -- The runtime's record object cannot hold more fields than this.
                ReportingResult.throw (Error.TooLarge typeRegion (Error.TooManyRecordFields Nothing) (List.length fields) HeapLimits.maxRecordFields)

            else
                Dups.checkFields (canonicalizeFields env fields)
                    |> ReportingResult.andThen sequenceAElmDict
                    |> ReportingResult.map (\cfields -> Can.TRecord cfields (Maybe.map (\( _, A.At _ ext ) -> ext) maybeExt))

        Src.TUnit ->
            ReportingResult.ok Can.TUnit

        Src.TTuple ( _, a ) ( _, b ) cs ->
            ReportingResult.map Can.TTuple (canonicalize env a)
                |> ReportingResult.apply (canonicalize env b)
                |> ReportingResult.apply
                    (case cs of
                        [] ->
                            ReportingResult.ok []

                        [ ( _, c ) ] ->
                            canonicalize env c
                                |> ReportingResult.map List.singleton

                        _ ->
                            ReportingResult.throw (Error.TupleLargerThanThree typeRegion)
                    )

        Src.TParens ( _, tipe_ ) ->
            canonicalize env tipe_


{-| Pairs each record field's name with the computation that canonicalizes its
type, tagged with the field's position in `fields`, counting from zero.
-}
canonicalizeFields : Env.Env -> List (Src.C2 ( Src.C1 (A.Located Name.Name), Src.C1 Src.Type )) -> List ( A.Located Name.Name, CResult i w (Can.FieldType Name) )
canonicalizeFields env fields =
    let
        canonicalizeField : Int -> Src.C2 ( Src.C1 a, Src.C1 Src.Type ) -> ( a, ReportingResult.RResult i w Error.Error (Can.FieldType Name) )
        canonicalizeField index ( _, ( ( _, name ), ( _, srcType ) ) ) =
            ( name, ReportingResult.map (Can.FieldType index) (canonicalize env srcType) )
    in
    List.indexedMap canonicalizeField fields


{-| Runs the computation under each key, in key order, and collects the values
under the same keys.

It stops at the first computation that fails, so only that one's errors are
reported; the later ones never run.

-}
sequenceAElmDict : Dict comparable (ReportingResult.RResult i w e v) -> ReportingResult.RResult i w e (Dict comparable v)
sequenceAElmDict dict =
    Dict.foldl
        (\k resultV accResult ->
            ReportingResult.andThen
                (\acc ->
                    ReportingResult.map (\v -> Dict.insert k v acc) resultV
                )
                accResult
        )
        (ReportingResult.ok Dict.empty)
        dict



-- ====== CANONICALIZE TYPE ======


{-| Canonicalizes the arguments of a use of the type `name`, then builds the use
from what the environment says `name` is: a `Can.TAlias` with a `Holey` body for
an alias, a `Can.TType` for a custom type.

The argument count is checked only once every argument has canonicalized, and a
wrong count is reported at `region`.

-}
canonicalizeType : Env.Env -> A.Region -> Name.Name -> List Src.Type -> Env.Type -> CResult i w (Can.Type Name)
canonicalizeType env region name args info =
    ReportingResult.traverse (canonicalize env) args
        |> ReportingResult.andThen
            (\cargs ->
                case info of
                    Env.Alias arity home argNames aliasedType ->
                        Can.TAlias home name (List.map2 Tuple.pair argNames cargs) (Can.Holey aliasedType) |> checkArity arity region name args

                    Env.Union arity home ->
                        Can.TType home name cargs |> checkArity arity region name args
            )


{-| Succeeds with `answer` when `args` has `expected` elements, and otherwise
fails with a type `BadArity` error at `region`.
-}
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


{-| Adds to `freeVars` every type variable `tipe` mentions, including record
extension variables.

An alias use contributes only the variables in its arguments; its body is not
visited.

-}
addFreeVars : Dict Name.Name () -> Can.Type Name -> Dict Name.Name ()
addFreeVars freeVars tipe =
    case tipe of
        Can.TLambda _ arg result ->
            addFreeVars (addFreeVars freeVars result) arg

        Can.TVar var ->
            Dict.insert var () freeVars

        Can.TType _ _ args ->
            List.foldl (\b c -> addFreeVars c b) freeVars args

        Can.TRecord fields Nothing ->
            Dict.foldl (\_ b c -> addFieldFreeVars c b) freeVars fields

        Can.TRecord fields (Just ext) ->
            Dict.foldl (\_ b c -> addFieldFreeVars c b) (Dict.insert ext () freeVars) fields

        Can.TUnit ->
            freeVars

        Can.TTuple a b cs ->
            List.foldl (flip addFreeVars) (addFreeVars (addFreeVars freeVars a) b) cs

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, arg ) fvs -> addFreeVars fvs arg) freeVars args


{-| Adds to `freeVars` every type variable a record field's type mentions.
-}
addFieldFreeVars : Dict Name.Name () -> Can.FieldType Name -> Dict Name.Name ()
addFieldFreeVars freeVars (Can.FieldType _ tipe) =
    addFreeVars freeVars tipe
