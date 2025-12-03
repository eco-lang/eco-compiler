# Data/Name.hs Changes

## Location
`compiler/src/Data/Name.hs`

## Purpose
This file defines constants for commonly-used names (type names, function names, etc.). We need to add a constant for the type name `Bytes`.

## Change 1: Module Exports

Add `bytes` to the export list. Find the common names section:

```haskell
module Data.Name
  ( Name
  --
  , toChars
  , toElmString
  , toBuilder
  --
  , fromPtr
  , fromChars
  --
  , getKernel
  , hasDot
  , splitDots
  , isKernel
  , isNumberType
  , isComparableType
  , isAppendableType
  , isCompappendType
  , fromVarIndex
  , fromWords
  , fromManyNames
  , fromTypeVariable
  , fromTypeVariableScheme
  , sepBy
  --
  , int, float, bool, char, string
  , maybe, result, list, array, dict, tuple, jsArray
  , task, router, cmd, sub, platform, virtualDom
  , shader, debug, debugger, bitwise, basics
  , utils, negate, true, false, value
  , node, program, _main, _Main, dollar, identity
  , replModule, replValueToPrint
  -- NEW: Add bytes export
  , bytes
  )
  where
```

## Change 2: Name Definition

Add at the end of the file (after `replValueToPrint`):

```haskell
{-# NOINLINE bytes #-}
bytes :: Name
bytes = fromChars "Bytes"
```

## Complete Section (After Change)

The common names section at the end of the file should end like this:

```haskell
{-# NOINLINE dollar #-}
dollar :: Name
dollar = fromChars "$"


{-# NOINLINE identity #-}
identity :: Name
identity = fromChars "identity"


{-# NOINLINE replModule #-}
replModule :: Name
replModule = fromChars "Elm_Repl"


{-# NOINLINE replValueToPrint #-}
replValueToPrint :: Name
replValueToPrint = fromChars "repl_input_value_"


-- NEW: Add this definition
{-# NOINLINE bytes #-}
bytes :: Name
bytes = fromChars "Bytes"
```

## Explanation

- `Name` is the compiler's internal representation of identifiers
- `fromChars "Bytes"` creates a `Name` from the string `"Bytes"`
- This matches the type name `Bytes` in `Bytes.Bytes`
- The constant is used in type checking to identify when we're dealing with the `Bytes` type

## Pattern Used

This follows the same pattern as other type names in the file:

```haskell
{-# NOINLINE int #-}
int :: Name
int = fromChars "Int"

{-# NOINLINE float #-}
float :: Name
float = fromChars "Float"

{-# NOINLINE bool #-}
bool :: Name
bool = fromChars "Bool"

-- ... etc ...
```
