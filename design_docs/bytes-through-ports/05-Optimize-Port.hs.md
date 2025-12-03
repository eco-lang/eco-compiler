# Optimize/Port.hs Changes

## Location
`compiler/src/Optimize/Port.hs`

## Purpose
This file generates the JavaScript encoder/decoder code for port payloads. When Elm code sends data through a port, this module generates the code that transforms Elm values to JavaScript-compatible values (encoder), and vice versa for incoming ports (decoder).

## Understanding Port Code Generation

For a port like:
```elm
port sendNumber : Int -> Cmd msg
```

The compiler generates JavaScript that encodes the `Int` using `Json.Encode.int`. The `toEncoder` function produces this encoding logic.

For an incoming port like:
```elm
port receiveNumber : (Int -> msg) -> Sub msg
```

The compiler generates JavaScript that decodes the incoming value using `Json.Decode.int`. The `toDecoder` function produces this decoding logic.

## Change 1: Add Bytes Encoder (toEncoder)

Find the `toEncoder` function. Locate the section handling zero-argument types:

### BEFORE:
```haskell
toEncoder :: Can.Type -> Names.Tracker Opt.Expr
toEncoder tipe =
  case tipe of
    Can.TAlias _ _ args alias ->
      toEncoder (Type.dealias args alias)

    Can.TLambda _ _ ->
      error "toEncoder: function"

    Can.TVar _ ->
      error "toEncoder: type variable"

    Can.TUnit ->
      Opt.Function [Name.dollar] <$> encode "null"

    Can.TTuple a b c ->
      encodeTuple a b c

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> encode "float"
          | name == Name.int    -> encode "int"
          | name == Name.bool   -> encode "bool"
          | name == Name.string -> encode "string"
          | name == Name.value  -> Names.registerGlobal ModuleName.basics Name.identity

        [arg]
          | name == Name.maybe -> encodeMaybe arg
          | name == Name.list  -> encodeList arg
          | name == Name.array -> encodeArray arg

        _ ->
          error "toEncoder: bad custom type"

    -- ... rest of function ...
```

### AFTER:
```haskell
toEncoder :: Can.Type -> Names.Tracker Opt.Expr
toEncoder tipe =
  case tipe of
    Can.TAlias _ _ args alias ->
      toEncoder (Type.dealias args alias)

    Can.TLambda _ _ ->
      error "toEncoder: function"

    Can.TVar _ ->
      error "toEncoder: type variable"

    Can.TUnit ->
      Opt.Function [Name.dollar] <$> encode "null"

    Can.TTuple a b c ->
      encodeTuple a b c

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> encode "float"
          | name == Name.int    -> encode "int"
          | name == Name.bool   -> encode "bool"
          | name == Name.string -> encode "string"
          | name == Name.value  -> Names.registerGlobal ModuleName.basics Name.identity
          | name == Name.bytes  -> Names.registerGlobal ModuleName.basics Name.identity  -- NEW

        [arg]
          | name == Name.maybe -> encodeMaybe arg
          | name == Name.list  -> encodeList arg
          | name == Name.array -> encodeArray arg

        _ ->
          error "toEncoder: bad custom type"

    -- ... rest of function ...
```

## Change 2: Add Bytes Decoder (toDecoder)

Find the `toDecoder` function. Locate the section handling zero-argument types:

### BEFORE:
```haskell
toDecoder :: Can.Type -> Names.Tracker Opt.Expr
toDecoder tipe =
  case tipe of
    Can.TLambda _ _ ->
      error "functions should not be allowed through input ports"

    Can.TVar _ ->
      error "type variables should not be allowed through input ports"

    Can.TAlias _ _ args alias ->
      toDecoder (Type.dealias args alias)

    Can.TUnit ->
      decodeTuple0

    Can.TTuple a b c ->
      decodeTuple a b c

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> decode "float"
          | name == Name.int    -> decode "int"
          | name == Name.bool   -> decode "bool"
          | name == Name.string -> decode "string"
          | name == Name.value  -> decode "value"

        [arg]
          | name == Name.maybe -> decodeMaybe arg
          | name == Name.list  -> decodeList arg
          | name == Name.array -> decodeArray arg

        _ ->
          error "toDecoder: bad type"

    -- ... rest of function ...
```

### AFTER:
```haskell
toDecoder :: Can.Type -> Names.Tracker Opt.Expr
toDecoder tipe =
  case tipe of
    Can.TLambda _ _ ->
      error "functions should not be allowed through input ports"

    Can.TVar _ ->
      error "type variables should not be allowed through input ports"

    Can.TAlias _ _ args alias ->
      toDecoder (Type.dealias args alias)

    Can.TUnit ->
      decodeTuple0

    Can.TTuple a b c ->
      decodeTuple a b c

    Can.TType _ name args ->
      case args of
        []
          | name == Name.float  -> decode "float"
          | name == Name.int    -> decode "int"
          | name == Name.bool   -> decode "bool"
          | name == Name.string -> decode "string"
          | name == Name.value  -> decode "value"
          | name == Name.bytes  -> decode "value"  -- NEW

        [arg]
          | name == Name.maybe -> decodeMaybe arg
          | name == Name.list  -> decodeList arg
          | name == Name.array -> decodeArray arg

        _ ->
          error "toDecoder: bad type"

    -- ... rest of function ...
```

## Explanation of the Encoder Choice

```haskell
| name == Name.bytes  -> Names.registerGlobal ModuleName.basics Name.identity
```

This uses `Basics.identity` as the encoder. Why?

1. **Elm's `Bytes.Bytes` is already a JavaScript `DataView`**: The `elm/bytes` kernel stores bytes as a `DataView` object in JavaScript.

2. **No transformation needed**: Unlike `Int` (which needs `Json.Encode.int`) or records (which need `Json.Encode.object`), the `DataView` can be passed directly to JavaScript.

3. **The `identity` function** simply returns its argument unchanged, which is exactly what we want.

This means when Elm sends `Bytes` through an outgoing port, JavaScript receives the raw `DataView` object.

## Explanation of the Decoder Choice

```haskell
| name == Name.bytes  -> decode "value"
```

This uses `Json.Decode.value` as the decoder. Why?

1. **Trust the JavaScript side**: When JavaScript sends data to an incoming Bytes port, we trust it's providing a valid `DataView`.

2. **`Json.Decode.value`** accepts any JavaScript value and passes it through unchanged.

3. **No validation**: This doesn't validate that the incoming value is actually a `DataView`. If JavaScript sends something else, runtime errors may occur when the Elm code tries to use it as `Bytes`.

### Alternative: Stricter Validation

For stricter validation, you could create a custom decoder that checks `instanceof DataView`. However, this would require:
1. Adding kernel JavaScript code
2. Creating a new decoder function
3. More complex integration

The `decode "value"` approach is simpler and works when you control both the Elm and JavaScript sides.

## Helper Functions Reference

The `encode` and `decode` helpers are defined at the bottom of Port.hs:

```haskell
encode :: Name.Name -> Names.Tracker Opt.Expr
encode name =
  Names.registerGlobal ModuleName.jsonEncode name


decode :: Name.Name -> Names.Tracker Opt.Expr
decode name =
  Names.registerGlobal ModuleName.jsonDecode name
```

- `encode "float"` → generates code for `Json.Encode.float`
- `decode "value"` → generates code for `Json.Decode.value`
- `Names.registerGlobal ModuleName.basics Name.identity` → generates code for `Basics.identity`

## Complete Zero-Argument Type Section (After Changes)

```haskell
-- In toEncoder:
Can.TType _ name args ->
  case args of
    []
      | name == Name.float  -> encode "float"
      | name == Name.int    -> encode "int"
      | name == Name.bool   -> encode "bool"
      | name == Name.string -> encode "string"
      | name == Name.value  -> Names.registerGlobal ModuleName.basics Name.identity
      | name == Name.bytes  -> Names.registerGlobal ModuleName.basics Name.identity

-- In toDecoder:
Can.TType _ name args ->
  case args of
    []
      | name == Name.float  -> decode "float"
      | name == Name.int    -> decode "int"
      | name == Name.bool   -> decode "bool"
      | name == Name.string -> decode "string"
      | name == Name.value  -> decode "value"
      | name == Name.bytes  -> decode "value"
```
