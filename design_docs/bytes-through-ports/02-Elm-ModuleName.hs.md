# Elm/ModuleName.hs Changes

## Location
`compiler/src/Elm/ModuleName.hs`

## Purpose
This file defines canonical module names (package + module path). We need to add a constant for the `Bytes` module from the `elm/bytes` package.

## Change 1: Module Exports

Add `bytes` to the export list:

```haskell
module Elm.ModuleName
  ( Raw
  , toChars
  , toFilePath
  , toHyphenPath
  --
  , encode
  , decoder
  , parser
  --
  , Canonical(..)
  , basics, char, string
  , maybe, result, list, array, dict, tuple
  , platform, cmd, sub
  , debug
  , virtualDom
  , jsonDecode, jsonEncode
  , webgl, texture, vector2, vector3, vector4, matrix4
  -- NEW: Add bytes export
  , bytes
  )
  where
```

## Change 2: Module Definition

Add at the end of the file (after the WebGL definitions):

```haskell
-- BYTES

{-# NOINLINE bytes #-}
bytes :: Canonical
bytes = Canonical Pkg.bytes "Bytes"
```

## Complete Section (After Change)

The module definitions should end like this:

```haskell
-- WEBGL


{-# NOINLINE webgl #-}
webgl :: Canonical
webgl = Canonical Pkg.webgl "WebGL"


{-# NOINLINE texture #-}
texture :: Canonical
texture = Canonical Pkg.webgl "WebGL.Texture"


{-# NOINLINE vector2 #-}
vector2 :: Canonical
vector2 = Canonical Pkg.linearAlgebra "Math.Vector2"


{-# NOINLINE vector3 #-}
vector3 :: Canonical
vector3 = Canonical Pkg.linearAlgebra "Math.Vector3"


{-# NOINLINE vector4 #-}
vector4 :: Canonical
vector4 = Canonical Pkg.linearAlgebra "Math.Vector4"


{-# NOINLINE matrix4 #-}
matrix4 :: Canonical
matrix4 = Canonical Pkg.linearAlgebra "Math.Matrix4"


-- NEW: Add this section
-- BYTES

{-# NOINLINE bytes #-}
bytes :: Canonical
bytes = Canonical Pkg.bytes "Bytes"
```

## Data Type Reference

The `Canonical` type is defined in this same file:

```haskell
data Canonical =
  Canonical
    { _package :: !Pkg.Name
    , _module :: !Name.Name
    }
```

## Explanation

- `Canonical` combines a package name with a module path
- `Pkg.bytes` is the package name we defined in `Elm/Package.hs` (i.e., `elm/bytes`)
- `"Bytes"` is the module name within that package
- Together they form the canonical name for `Bytes.Bytes` type's home module
- This is used by the compiler to identify when a type comes from the `Bytes` module

## Required Import

Make sure `Elm.Package` is imported (it should already be):

```haskell
import qualified Elm.Package as Pkg
```
