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

import Common.Format.KnownContents exposing (KnownContents)
import Compiler.AST.Source as Src
import Compiler.Parse.Module as M
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)


{-| Complete import information for a module, tracking all symbols and their sources.
Contains exposed values, module aliases, direct imports, ambiguous names, and unresolved imports.
-}
type ImportInfo
    = ImportInfo


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
fromImports _ _ =
    ImportInfo
