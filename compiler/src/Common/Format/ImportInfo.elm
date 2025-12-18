module Common.Format.ImportInfo exposing
    ( ImportInfo(..)
    , fromModule
    )

{-| Track and resolve import information for Elm modules.

This module analyzes a module's import declarations to build a comprehensive mapping
of exposed values, type aliases, module aliases, and direct imports. It handles both
explicit imports and exposing-all imports, resolving symbol names to their defining modules.

The import resolution system supports:

  - Direct unqualified imports (e.g., `import List`)
  - Module aliases (e.g., `import Dict as D`)
  - Exposed values (e.g., `import Maybe exposing (Maybe, withDefault)`)
  - Exposing-all imports (e.g., `import Html exposing (..)`)
  - Default imports (Basics, List, Maybe)


# Types

@docs ImportInfo


# Building Import Information

@docs fromModule

-}

import Basics.Extra exposing (flip)
import Common.Format.Bimap as Bimap exposing (Bimap)
import Common.Format.KnownContents as KnownContents exposing (KnownContents)
import Compiler.AST.Source as Src
import Compiler.Elm.Compiler.Imports as Imports
import Compiler.Parse.Module as M
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)


{-| Complete import information for a module, tracking all symbols and their sources.
Contains exposed values, module aliases, direct imports, ambiguous names, and unresolved imports.
-}
type ImportInfo
    = ImportInfo
        { exposed : Dict String String String
        , aliases : Bimap String String
        , directImports : EverySet String String
        , ambiguous : Dict String String (List String)
        , unresolvedExposingAll : EverySet String String -- any modules with exposing(..) and we didn't know the module contents
        }


{-| Build import information from a parsed module, using known contents to resolve exposing-all imports.
-}
fromModule : KnownContents -> M.Module -> ImportInfo
fromModule knownContents modu =
    let
        ( _, imports ) =
            modu.imports
    in
    fromImports knownContents (importsToDict (List.map Src.c1Value imports))


{-| Convert a list of imports to a dictionary keyed by module name.
-}
importsToDict : List Src.Import -> Dict String String Src.Import
importsToDict =
    List.map (\((Src.Import ( _, A.At _ name ) _ _) as import_) -> ( name, import_ ))
        >> Dict.fromList identity


{-| Build import information from a dictionary of imports, resolving symbols to their source modules.
-}
fromImports : KnownContents -> Dict String String Src.Import -> ImportInfo
fromImports knownContents rawImports =
    let
        defaultImports : Dict String String Src.Import
        defaultImports =
            -- TODO check if we need to have only these 3: Basics, List, Maybe
            -- [ ( [ "Basics" ], OpenListing (C ( [], [] ) ()) )
            -- , ( [ "List" ], ClosedListing )
            -- , ( [ "Maybe" ]
            --   , ExplicitListing
            --         (DetailedListing mempty mempty <|
            --             Dict.fromList
            --                 [ ( UppercaseIdentifier "Maybe"
            --                   , C ( [], [] ) <|
            --                         C [] <|
            --                             ExplicitListing
            --                                 (Dict.fromList
            --                                     [ ( UppercaseIdentifier "Nothing", C ( [], [] ) () )
            --                                     , ( UppercaseIdentifier "Just", C ( [], [] ) () )
            --                                     ]
            --                                 )
            --                                 False
            --                   )
            --                 ]
            --         )
            --         False
            --   )
            -- ]
            importsToDict (List.map Src.c1Value Imports.defaults)

        imports : Dict String String Src.Import
        imports =
            Dict.union rawImports defaultImports

        -- NOTE: this MUST prefer rawImports when there is a duplicate key
        -- these are things we know will get exposed for certain modules when we see "exposing (..)"
        -- only things that are currently useful for Elm 0.19 upgrade are included
        moduleContents : String -> List String
        moduleContents moduleName =
            case moduleName of
                "Basics" ->
                    [ "identity"
                    ]

                "Html.Attributes" ->
                    [ "style"
                    ]

                "List" ->
                    [ "filterMap"
                    ]

                "Maybe" ->
                    [ "Nothing"
                    , "Just"
                    ]

                _ ->
                    KnownContents.get moduleName knownContents
                        |> Maybe.withDefault []

        getExposed : String -> Src.Import -> Dict String String String
        getExposed moduleName (Src.Import _ _ ( _, exposing_ )) =
            Dict.fromList identity <|
                List.map (flip Tuple.pair moduleName) <|
                    case exposing_ of
                        Src.Open _ _ ->
                            moduleContents moduleName

                        Src.Explicit _ ->
                            -- TODO
                            -- (map VarName <| Dict.keys <| AST.Module.values details)
                            --     <> (map TypeName <| Dict.keys <| AST.Module.types details)
                            --     <> (map CtorName <| foldMap (getCtorListings << extract << extract) <| Dict.elems <| AST.Module.types details)
                            []

        -- getCtorListings : Listing (CommentedMap name ()) -> List name
        -- getCtorListings listing =
        --     case listing of
        --         ClosedListing ->
        --             []
        --         OpenListing _ ->
        --             -- TODO: exposing (Type(..)) should pull in variant names from knownContents,
        --             -- though this should also be a warning because we can't know for sure which of those are for this type
        --             []
        --         ExplicitListing ctors _ ->
        --             Dict.keys ctors
        exposed : Dict String String String
        exposed =
            -- TODO: mark ambiguous names if multiple modules expose them
            Dict.foldl compare (\k v a -> getExposed k v |> Dict.union a) Dict.empty imports

        aliases : Bimap String String
        aliases =
            let
                getAlias : Src.Import -> Maybe String
                getAlias (Src.Import _ maybeAlias _) =
                    Maybe.map Src.c2Value maybeAlias

                liftMaybe : ( a, Maybe b ) -> Maybe ( a, b )
                liftMaybe value =
                    case value of
                        ( _, Nothing ) ->
                            Nothing

                        ( a, Just b ) ->
                            Just ( a, b )
            in
            Dict.toList compare imports
                |> List.map (Tuple.mapSecond getAlias)
                |> List.filterMap liftMaybe
                |> List.map (\( a, b ) -> ( b, a ))
                |> Bimap.fromList identity identity

        noAlias : Src.Import -> Bool
        noAlias (Src.Import _ maybeAlias _) =
            case maybeAlias of
                Just _ ->
                    False

                Nothing ->
                    True

        directs : EverySet String String
        directs =
            EverySet.union
                (EverySet.singleton identity "Basics")
                (Dict.filter (\_ -> noAlias) imports
                    |> Dict.keys compare
                    |> EverySet.fromList identity
                )

        ambiguous : Dict String String (List String)
        ambiguous =
            Dict.empty

        exposesAll : Src.Import -> Bool
        exposesAll (Src.Import _ _ ( _, exposing_ )) =
            case exposing_ of
                Src.Open _ _ ->
                    True

                Src.Explicit _ ->
                    False

        unresolvedExposingAll : EverySet String String
        unresolvedExposingAll =
            Dict.filter (\_ -> exposesAll) rawImports
                |> Dict.keys compare
                |> EverySet.fromList identity
                |> EverySet.filter (not << KnownContents.isKnown knownContents)
    in
    ImportInfo
        { exposed = exposed
        , aliases = aliases
        , directImports = directs
        , ambiguous = ambiguous
        , unresolvedExposingAll = unresolvedExposingAll
        }
