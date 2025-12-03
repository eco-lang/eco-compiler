# Bytes Through Ports - Compiler Modification Guide

This document describes the compiler modifications required to enable `Bytes.Bytes` values to be sent through Elm ports in both directions (outgoing and incoming).

## Overview

In standard Elm, ports only support a limited set of types that can be serialized to/from JSON:
- Primitives: `Int`, `Float`, `Bool`, `String`
- `Json.Encode.Value` (arbitrary JSON)
- `Maybe`, `List`, `Array` of supported types
- Records with supported field types
- Tuples of supported types

The `Bytes.Bytes` type is notably absent from this list, even though it has a well-defined JavaScript representation as a `DataView` object.

## JavaScript Representation of Bytes

In the `elm/bytes` package, `Bytes.Bytes` values are represented in JavaScript as `DataView` objects:

```javascript
// From elm/bytes kernel (Elm/Kernel/Bytes.js)
function _Bytes_encode(encoder)
{
    var mutableBytes = new DataView(new ArrayBuffer(__Encode_getWidth(encoder)));
    __Encode_write(encoder)(mutableBytes)(0);
    return mutableBytes;
}
```

This means when you send `Bytes.Bytes` through a port:
- **Outgoing**: JavaScript receives a `DataView` object
- **Incoming**: JavaScript must provide a `DataView` object

## Files Modified

The modification touches **5 files** in the compiler:

| File | Purpose |
|------|---------|
| `compiler/src/Elm/Package.hs` | Define the `elm/bytes` package name constant |
| `compiler/src/Elm/ModuleName.hs` | Define the `Bytes` module canonical name |
| `compiler/src/Data/Name.hs` | Define the `Bytes` type name constant |
| `compiler/src/Canonicalize/Effects.hs` | Allow `Bytes.Bytes` in port payload validation |
| `compiler/src/Optimize/Port.hs` | Generate encoder/decoder code for `Bytes.Bytes` |

## Detailed Changes

### 1. compiler/src/Elm/Package.hs

**Purpose**: Define a constant for the `elm/bytes` package name.

**Add to exports**:
```haskell
module Elm.Package
  ( -- ... existing exports ...
  , bytes  -- ADD THIS
  )
```

**Add at end of file**:
```haskell
{-# NOINLINE bytes #-}
bytes :: Name
bytes =
  toName elm "bytes"
```

This defines `Pkg.bytes` as the package name `elm/bytes`.

---

### 2. compiler/src/Elm/ModuleName.hs

**Purpose**: Define a canonical module name for `Bytes` (package + module path).

**Add to exports**:
```haskell
module Elm.ModuleName
  ( -- ... existing exports ...
  , bytes  -- ADD THIS
  )
```

**Add at end of file**:
```haskell
{-# NOINLINE bytes #-}
bytes :: Canonical
bytes = Canonical Pkg.bytes "Bytes"
```

This defines `ModuleName.bytes` as the canonical name for the `Bytes` module in the `elm/bytes` package.

---

### 3. compiler/src/Data/Name.hs

**Purpose**: Define a name constant for the `Bytes` type.

**Add to exports**:
```haskell
module Data.Name
  ( -- ... existing exports ...
  , bytes  -- ADD THIS
  )
```

**Add at end of file**:
```haskell
{-# NOINLINE bytes #-}
bytes :: Name
bytes = fromChars "Bytes"
```

This defines `Name.bytes` as the string `"Bytes"` (the type name).

---

### 4. compiler/src/Canonicalize/Effects.hs

**Purpose**: Allow `Bytes.Bytes` as a valid port payload type.

The `checkPayload` function validates that types used in ports are serializable. It uses a series of guards to check if a type is allowed.

**Locate the `checkPayload` function** and find this section:

```haskell
checkPayload :: Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkPayload tipe =
  case tipe of
    -- ... alias handling ...

    Can.TType home name args ->
      case args of
        []
          | isJson home name -> Right ()
          | isString home name -> Right ()
          | isIntFloatBool home name -> Right ()
          -- ADD THIS LINE:
          | isBytes home name -> Right ()

        [arg]
          -- ... existing checks ...
```

**Add the `isBytes` helper function** at the end of the file:

```haskell
isBytes :: ModuleName.Canonical -> Name.Name -> Bool
isBytes home name =
  home == ModuleName.bytes
  &&
  name == Name.bytes
```

This function checks if a type is `Bytes.Bytes` by verifying:
1. The module is `Bytes` from the `elm/bytes` package
2. The type name is `Bytes`

---

### 5. compiler/src/Optimize/Port.hs

**Purpose**: Generate JavaScript encoder/decoder code for `Bytes.Bytes` in ports.

#### 5a. Encoder (Outgoing Ports)

**Locate the `toEncoder` function** and find this section:

```haskell
toEncoder :: Can.Type -> Names.Tracker Opt.Expr
toEncoder tipe =
  case tipe of
    -- ... other cases ...

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> encode "float"
          | name == Name.int    -> encode "int"
          | name == Name.bool   -> encode "bool"
          | name == Name.string -> encode "string"
          | name == Name.value  -> Names.registerGlobal ModuleName.basics Name.identity
          -- ADD THIS LINE:
          | name == Name.bytes  -> Names.registerGlobal ModuleName.basics Name.identity
```

The encoder for `Bytes.Bytes` uses `Basics.identity` because:
- The JavaScript representation (`DataView`) can be passed directly to the port subscriber
- No encoding/transformation is needed

#### 5b. Decoder (Incoming Ports)

**Locate the `toDecoder` function** and find this section:

```haskell
toDecoder :: Can.Type -> Names.Tracker Opt.Expr
toDecoder tipe =
  case tipe of
    -- ... other cases ...

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> decode "float"
          | name == Name.int    -> decode "int"
          | name == Name.bool   -> decode "bool"
          | name == Name.string -> decode "string"
          | name == Name.value  -> decode "value"
          -- ADD THIS LINE:
          | name == Name.bytes  -> bytesDecoder
```

**Add the `bytesDecoder` helper**:

For a minimal implementation, you need a decoder that accepts a `DataView` from JavaScript and passes it through. The simplest approach is to use `Json.Decode.value` and trust that JavaScript provides a valid `DataView`:

```haskell
-- Simple approach: trust JS provides a DataView
| name == Name.bytes  -> decode "value"
```

However, this doesn't validate the input. A more robust approach requires a custom decoder (see "Runtime Considerations" below).

---

## Runtime Considerations

### JavaScript Side

When working with Bytes ports:

**Sending to Elm (incoming port)**:
```javascript
// JavaScript must send a DataView
const buffer = new ArrayBuffer(8);
const dataView = new DataView(buffer);
// ... fill the buffer ...
app.ports.receiveBytes.send(dataView);
```

**Receiving from Elm (outgoing port)**:
```javascript
app.ports.sendBytes.subscribe(function(dataView) {
    // dataView is a DataView object
    const uint8Array = new Uint8Array(dataView.buffer);
    // ... use the bytes ...
});
```

### Converting Between DataView and Uint8Array

```javascript
// DataView to Uint8Array
const uint8Array = new Uint8Array(dataView.buffer, dataView.byteOffset, dataView.byteLength);

// Uint8Array to DataView
const dataView = new DataView(uint8Array.buffer, uint8Array.byteOffset, uint8Array.byteLength);
```

---

## Summary of Code Changes

### Minimal Diff for Elm/Package.hs

```diff
 module Elm.Package
   ( -- ... existing exports ...
+  , bytes
   )

+{-# NOINLINE bytes #-}
+bytes :: Name
+bytes =
+  toName elm "bytes"
```

### Minimal Diff for Elm/ModuleName.hs

```diff
 module Elm.ModuleName
   ( -- ... existing exports ...
+  , bytes
   )

+{-# NOINLINE bytes #-}
+bytes :: Canonical
+bytes = Canonical Pkg.bytes "Bytes"
```

### Minimal Diff for Data/Name.hs

```diff
 module Data.Name
   ( -- ... existing exports ...
+  , bytes
   )

+{-# NOINLINE bytes #-}
+bytes :: Name
+bytes = fromChars "Bytes"
```

### Minimal Diff for Canonicalize/Effects.hs

```diff
 checkPayload :: Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
 checkPayload tipe =
   case tipe of
     Can.TType home name args ->
       case args of
         []
           | isJson home name -> Right ()
           | isString home name -> Right ()
           | isIntFloatBool home name -> Right ()
+          | isBytes home name -> Right ()

+isBytes :: ModuleName.Canonical -> Name.Name -> Bool
+isBytes home name =
+  home == ModuleName.bytes
+  &&
+  name == Name.bytes
```

### Minimal Diff for Optimize/Port.hs

```diff
 toEncoder tipe =
   case tipe of
     Can.TType _ name args ->
       case args of
         []
           | name == Name.value  -> Names.registerGlobal ModuleName.basics Name.identity
+          | name == Name.bytes  -> Names.registerGlobal ModuleName.basics Name.identity

 toDecoder tipe =
   case tipe of
     Can.TType _ name args ->
       case args of
         []
           | name == Name.value  -> decode "value"
+          | name == Name.bytes  -> decode "value"
```

---

## Testing

After making these changes, you should be able to:

1. Define outgoing ports with `Bytes.Bytes`:
   ```elm
   port sendBytes : Bytes -> Cmd msg
   ```

2. Define incoming ports with `Bytes.Bytes`:
   ```elm
   port receiveBytes : (Bytes -> msg) -> Sub msg
   ```

3. Use `Bytes.Bytes` in composite port types:
   ```elm
   port sendData : { id : String, payload : Bytes } -> Cmd msg
   port receiveData : (List Bytes -> msg) -> Sub msg
   ```

---

## Git Commits Reference

This feature was implemented in the Lamdera compiler across two commits:

1. **58ae7410** (Nov 29, 2020) - "Experiment: enable Bytes.Bytes support in ports"
   - Added all infrastructure files
   - Encoder used `identity` (correct)
   - No decoder added (incomplete)

2. **406f3fbc** (Jan 17, 2021) - "Port Bytes support working properly"
   - Added proper decoder
   - Used Lamdera-specific Wire3 encoders/decoders for their protocol

For a non-Lamdera implementation, use `identity` for encoding and `decode "value"` for decoding as shown in this guide.
