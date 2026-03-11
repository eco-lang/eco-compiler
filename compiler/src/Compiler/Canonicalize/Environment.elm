module Compiler.Canonicalize.Environment exposing
    ( EResult
    , Env, Exposed, Qualified
    , Info(..), Var(..), Type(..), Ctor(..), Binop(..), BinopData
    , addLocals, mergeInfo
    , findType, findTypeQual, findCtor, findCtorQual, findBinop
    )

{-| Environment for canonicalization, tracking available names and their definitions.

This module maintains the canonicalization environment which maps names to their
definitions. It handles both unqualified (exposed) and qualified imports, detects
ambiguous references when multiple modules expose the same name, and manages
local variable scoping with shadowing checks.


# Results

@docs EResult


# Environment

@docs Env, Exposed, Qualified


# Name Information

@docs Info, Var, Type, Ctor, Binop, BinopData


# Environment Operations

@docs addLocals, mergeInfo


# Lookup Operations

@docs findType, findTypeQual, findCtor, findCtorQual, findBinop

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)
import Data.Set as EverySet
import Maybe exposing (Maybe(..))
import System.TypeCheck.IO exposing (Canonical)



-- ====== RESULT ======


{-| Result type for environment operations that may produce canonicalization errors.
-}
type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== ENVIRONMENT ======


{-| The canonicalization environment tracks all names available in the current scope.
It maintains both exposed (unqualified) and qualified imports, along with local variables.
-}
type alias Env =
    { home : Canonical
    , vars : Dict Name.Name Var
    , types : Exposed Type
    , ctors : Exposed Ctor
    , binops : Exposed Binop
    , q_vars : Qualified Can.Annotation
    , q_types : Qualified Type
    , q_ctors : Qualified Ctor
    }


{-| A map of exposed (unqualified) names to their definitions.
Multiple modules can expose the same name, leading to ambiguity.
-}
type alias Exposed a =
    Dict Name.Name (Info a)


{-| A two-level map for qualified names: module prefix -> name -> definition.
Allows referencing names via `Module.name` syntax.
-}
type alias Qualified a =
    Dict Name.Name (Dict Name.Name (Info a))



-- ====== INFO ======


{-| Information about a name: either specific to one module or ambiguous across multiple.
When the same name is exposed by multiple imports, it becomes ambiguous.
-}
type Info a
    = Specific Canonical a
    | Ambiguous Canonical (OneOrMore.OneOrMore Canonical)


{-| Merge two Info values, detecting when the same name comes from different modules.
Results in an Ambiguous info if modules differ.
-}
mergeInfo : Info a -> Info a -> Info a
mergeInfo info1 info2 =
    case info1 of
        Specific h1 _ ->
            case info2 of
                Specific h2 _ ->
                    if h1 == h2 then
                        info1

                    else
                        Ambiguous h1 (OneOrMore.one h2)

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more (OneOrMore.one h2) hs2)

        Ambiguous h1 hs1 ->
            case info2 of
                Specific h2 _ ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.one h2))

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.more (OneOrMore.one h2) hs2))



-- ====== VARIABLES ======


{-| Represents a variable in scope: either local, top-level, or imported from another module.
Foreigns tracks when multiple modules expose the same variable name (ambiguous imports).
-}
type Var
    = Local A.Region
    | TopLevel A.Region
    | Foreign Canonical Can.Annotation
    | Foreigns Canonical (OneOrMore.OneOrMore Canonical)



-- ====== TYPES ======


{-| Represents a type definition: either a type alias or a union (custom) type.
The Int tracks the number of type parameters.
-}
type Type
    = Alias Int Canonical (List Name.Name) Can.Type
    | Union Int Canonical



-- ====== CTORS ======


{-| Represents a constructor: either a record constructor or a union type variant.
Record constructors are special constructors for extensible records.
-}
type Ctor
    = RecordCtor Canonical (List Name.Name) Can.Type
    | Ctor Canonical Name.Name Can.Union Index.ZeroBased (List Can.Type)



-- ====== BINOPS ======


{-| Complete information about a binary operator including its precedence,
associativity, and the function it desugars to.
-}
type alias BinopData =
    { op : Name.Name
    , home : Canonical
    , name : Name.Name
    , annotation : Can.Annotation
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


{-| Wrapper type for binary operator information.
-}
type Binop
    = Binop BinopData



-- ====== ADD LOCALS ======


{-| Add local variable bindings to the environment, checking for shadowing.
Returns an error if any new local shadows an existing local or top-level binding.
Foreign bindings can be shadowed without error.
-}
addLocals : Dict Name.Name A.Region -> Env -> EResult i w Env
addLocals names env =
    ReportingResult.map (\newVars -> { env | vars = newVars })
        (Dict.merge
            (\name region -> ReportingResult.map (Dict.insert name (addLocalLeft name region)))
            (\name region var acc ->
                addLocalBoth name region var
                    |> ReportingResult.andThen (\var_ -> ReportingResult.map (Dict.insert name var_) acc)
            )
            (\name var -> ReportingResult.map (Dict.insert name var))
            names
            env.vars
            (ReportingResult.ok Dict.empty)
        )


addLocalLeft : Name.Name -> A.Region -> Var
addLocalLeft _ region =
    Local region


addLocalBoth : Name.Name -> A.Region -> Var -> EResult i w Var
addLocalBoth name region var =
    case var of
        Foreign _ _ ->
            ReportingResult.ok (Local region)

        Foreigns _ _ ->
            ReportingResult.ok (Local region)

        Local parentRegion ->
            ReportingResult.throw (Error.Shadowing name parentRegion region)

        TopLevel parentRegion ->
            ReportingResult.throw (Error.Shadowing name parentRegion region)



-- ====== FIND TYPE ======


{-| Look up an unqualified type name in the environment.
Returns an error if the type is not found or is ambiguous.
-}
findType : A.Region -> Env -> Name.Name -> EResult i w Type
findType region { types, q_types } name =
    case Dict.get name types of
        Just (Specific _ tipe) ->
            ReportingResult.ok tipe

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousType region Nothing name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundType region Nothing name (toPossibleNames types q_types))


{-| Look up a qualified type name (e.g., `Dict.Dict`) in the environment.
Returns an error if the module or type is not found, or if the type is ambiguous.
-}
findTypeQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Type
findTypeQual region { types, q_types } prefix name =
    case Dict.get prefix q_types of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ tipe) ->
                    ReportingResult.ok tipe

                Just (Ambiguous h hs) ->
                    ReportingResult.throw (Error.AmbiguousType region (Just prefix) name h hs)

                Nothing ->
                    ReportingResult.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))

        Nothing ->
            ReportingResult.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))



-- ====== FIND CTOR ======


{-| Look up an unqualified constructor name in the environment.
Returns an error if the constructor is not found or is ambiguous.
-}
findCtor : A.Region -> Env -> Name.Name -> EResult i w Ctor
findCtor region { ctors, q_ctors } name =
    case Dict.get name ctors of
        Just (Specific _ ctor) ->
            ReportingResult.ok ctor

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousVariant region Nothing name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundVariant region Nothing name (toPossibleNames ctors q_ctors))


{-| Look up a qualified constructor name (e.g., `Maybe.Just`) in the environment.
Returns an error if the module or constructor is not found, or if the constructor is ambiguous.
-}
findCtorQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Ctor
findCtorQual region { ctors, q_ctors } prefix name =
    case Dict.get prefix q_ctors of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ pattern) ->
                    ReportingResult.ok pattern

                Just (Ambiguous h hs) ->
                    ReportingResult.throw (Error.AmbiguousVariant region (Just prefix) name h hs)

                Nothing ->
                    ReportingResult.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))

        Nothing ->
            ReportingResult.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))



-- ====== FIND BINOP ======


{-| Look up a binary operator by its symbol in the environment.
Returns an error if the operator is not found or is ambiguous.
-}
findBinop : A.Region -> Env -> Name.Name -> EResult i w Binop
findBinop region { binops } name =
    case Dict.get name binops of
        Just (Specific _ binop) ->
            ReportingResult.ok binop

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousBinop region name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundBinop region name (EverySet.fromList identity (Dict.keys binops)))



-- ====== TO POSSIBLE NAMES ======


toPossibleNames : Exposed a -> Qualified a -> Error.PossibleNames
toPossibleNames exposed qualified =
    Error.PossibleNames (EverySet.fromList identity (Dict.keys exposed)) (Dict.map (\_ -> Dict.keys >> EverySet.fromList identity) qualified)
