# Elm/Package.hs Changes

## Location
`compiler/src/Elm/Package.hs`

## Purpose
This file defines constants for Elm package names (author/project pairs). We need to add a constant for the `elm/bytes` package.

## Change 1: Module Exports

Add `bytes` to the export list:

```haskell
module Elm.Package
  ( Name(..)
  , Author
  , Project
  , Canonical(..)
  , isKernel
  , toChars
  , toUrl
  , toFilePath
  , toJsonString
  --
  , dummyName, kernel, core
  , browser, virtualDom, html
  , json, http, url
  , webgl, linearAlgebra
  --
  , suggestions
  , nearbyNames
  --
  , decoder
  , encode
  , keyDecoder
  --
  , parser
  -- NEW: Add bytes export
  , bytes
  )
  where
```

## Change 2: Package Definition

Add at the end of the file (after the other package definitions):

```haskell
{-# NOINLINE bytes #-}
bytes :: Name
bytes =
  toName elm "bytes"
```

## Complete Section (After Change)

The package definitions section should look like this:

```haskell
-- COMMON PACKAGE NAMES

toName :: Author -> [Char] -> Name
toName author project =
  Name author (Utf8.fromChars project)


{-# NOINLINE dummyName #-}
dummyName :: Name
dummyName =
  toName (Utf8.fromChars "author") "project"


{-# NOINLINE kernel #-}
kernel :: Name
kernel =
  toName elm "kernel"


{-# NOINLINE core #-}
core :: Name
core =
  toName elm "core"


{-# NOINLINE browser #-}
browser :: Name
browser =
  toName elm "browser"


{-# NOINLINE virtualDom #-}
virtualDom :: Name
virtualDom =
  toName elm "virtual-dom"


{-# NOINLINE html #-}
html :: Name
html =
  toName elm "html"


{-# NOINLINE json #-}
json :: Name
json =
  toName elm "json"


{-# NOINLINE http #-}
http :: Name
http =
  toName elm "http"


{-# NOINLINE url #-}
url :: Name
url =
  toName elm "url"


{-# NOINLINE webgl #-}
webgl :: Name
webgl =
  toName elm_explorations "webgl"


{-# NOINLINE linearAlgebra #-}
linearAlgebra :: Name
linearAlgebra =
  toName elm_explorations "linear-algebra"


{-# NOINLINE elm #-}
elm :: Author
elm =
  Utf8.fromChars "elm"


{-# NOINLINE elm_explorations #-}
elm_explorations :: Author
elm_explorations =
  Utf8.fromChars "elm-explorations"


-- NEW: Add this definition
{-# NOINLINE bytes #-}
bytes :: Name
bytes =
  toName elm "bytes"
```

## Explanation

- The `toName` helper creates a `Name` from an author and project
- `elm` is the author constant for the "elm" organization
- `"bytes"` is the project name
- The result represents the package `elm/bytes`
- `{-# NOINLINE #-}` pragma ensures the constant is not inlined, keeping it as a single shared reference
