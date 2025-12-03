# Canonicalize/Effects.hs Changes

## Location
`compiler/src/Canonicalize/Effects.hs`

## Purpose
This file handles the canonicalization of effect modules, including **port type validation**. The `checkPayload` function validates that types used in ports can be serialized. We need to add `Bytes.Bytes` as an allowed type.

## Understanding Port Payload Validation

When you declare a port like:

```elm
port sendData : String -> Cmd msg
port receiveData : (Int -> msg) -> Sub msg
```

The compiler validates that `String` and `Int` are valid port payload types. The `checkPayload` function performs this validation recursively for all types used in port signatures.

## Change 1: Add isBytes Check to checkPayload

Find the `checkPayload` function. It has a section that checks zero-argument types:

### BEFORE:
```haskell
checkPayload :: Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkPayload tipe =
  case tipe of
    Can.TAlias _ _ args aliasedType ->
      checkPayload (Type.dealias args aliasedType)

    Can.TType home name args ->
      case args of
        []
          | isJson home name -> Right ()
          | isString home name -> Right ()
          | isIntFloatBool home name -> Right ()

        [arg]
          | isList  home name -> checkPayload arg
          | isMaybe home name -> checkPayload arg
          | isArray home name -> checkPayload arg

        _ ->
          Left (tipe, Error.UnsupportedType name)

    -- ... rest of function ...
```

### AFTER:
```haskell
checkPayload :: Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkPayload tipe =
  case tipe of
    Can.TAlias _ _ args aliasedType ->
      checkPayload (Type.dealias args aliasedType)

    Can.TType home name args ->
      case args of
        []
          | isJson home name -> Right ()
          | isString home name -> Right ()
          | isIntFloatBool home name -> Right ()
          | isBytes home name -> Right ()      -- NEW LINE

        [arg]
          | isList  home name -> checkPayload arg
          | isMaybe home name -> checkPayload arg
          | isArray home name -> checkPayload arg

        _ ->
          Left (tipe, Error.UnsupportedType name)

    -- ... rest of function ...
```

## Change 2: Add isBytes Helper Function

Add the `isBytes` function at the end of the file, alongside the other type-checking helpers:

```haskell
isBytes :: ModuleName.Canonical -> Name.Name -> Bool
isBytes home name =
  home == ModuleName.bytes
  &&
  name == Name.bytes
```

## Complete Helper Functions Section

The helper functions at the end of the file should look like this:

```haskell
isIntFloatBool :: ModuleName.Canonical -> Name.Name -> Bool
isIntFloatBool home name =
  home == ModuleName.basics
  &&
  (name == Name.int || name == Name.float || name == Name.bool)


isString :: ModuleName.Canonical -> Name.Name -> Bool
isString home name =
  home == ModuleName.string
  &&
  name == Name.string


isJson :: ModuleName.Canonical -> Name.Name -> Bool
isJson home name =
  home == ModuleName.jsonEncode
  &&
  name == Name.value


isList :: ModuleName.Canonical -> Name.Name -> Bool
isList home name =
  home == ModuleName.list
  &&
  name == Name.list


isMaybe :: ModuleName.Canonical -> Name.Name -> Bool
isMaybe home name =
  home == ModuleName.maybe
  &&
  name == Name.maybe


isArray :: ModuleName.Canonical -> Name.Name -> Bool
isArray home name =
  home == ModuleName.array
  &&
  name == Name.array


-- NEW: Add this function
isBytes :: ModuleName.Canonical -> Name.Name -> Bool
isBytes home name =
  home == ModuleName.bytes
  &&
  name == Name.bytes
```

## Explanation

The `checkPayload` function determines if a type can go through a port:

1. **Type aliases** are unwrapped and their underlying type is checked
2. **Named types** (`Can.TType`) are checked by their module home and type name:
   - Zero-argument types: `Int`, `Float`, `Bool`, `String`, `Json.Encode.Value`, and now `Bytes`
   - One-argument types: `List a`, `Maybe a`, `Array a` (recursively checked)
3. **Unit** `()` is allowed
4. **Tuples** have each element checked
5. **Records** have each field checked
6. **Type variables** and **functions** are rejected

The `isBytes` check verifies:
- `home == ModuleName.bytes`: The type comes from the `Bytes` module in `elm/bytes`
- `name == Name.bytes`: The type name is `Bytes`

Together this identifies the type `Bytes.Bytes`.

## Required Imports

Ensure these imports are present (they should already be):

```haskell
import qualified Data.Name as Name
import qualified Elm.ModuleName as ModuleName
```
