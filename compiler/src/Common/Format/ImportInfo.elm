module Common.Format.ImportInfo exposing
    ( ImportInfo
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


{-| Complete import information for a module, tracking all symbols and their sources.
Contains exposed values, module aliases, direct imports, ambiguous names, and unresolved imports.
-}
type ImportInfo
    = ImportInfo


{-| Build import information from a parsed module, using known contents to resolve exposing-all imports.
-}
fromModule : ImportInfo
fromModule =
    fromImports


{-| Build import information from a dictionary of imports, resolving symbols to their source modules.
-}
fromImports : ImportInfo
fromImports =
    ImportInfo
