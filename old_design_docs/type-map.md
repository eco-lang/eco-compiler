BytesFusion Data Type Mapping Report

  Overview

  BytesFusion bridges three distinct type systems:
  1. Eco Runtime - MLIR-based runtime types for the Elm-to-native compiler
  2. Elm Language - Elm's type system as represented in the monomorphized AST
  3. elm/bytes - The binary encoding/decoding library types

  The critical insight: both eco.value (heap pointer) and i64 (Elm Int) are 64-bit values that can be easily confused if type tracking is sloppy.

  ---
  Type Tables

  Table 1: Eco Runtime Types (MLIR)
  ┌────────────┬─────────┬─────────────────────────────────┬─────────────────┐
  │ MLIR Type  │  Size   │           Description           │ Elm Equivalent  │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ !eco.value │ 64-bit  │ Boxed heap pointer (HPointer)   │ Any heap object │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ i64        │ 64-bit  │ Unboxed signed integer          │ Int             │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ f64        │ 64-bit  │ Unboxed IEEE 754 double         │ Float           │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ i16        │ 16-bit  │ Unboxed unicode codepoint (BMP) │ Char            │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ i1         │ 1-bit   │ Boolean flag                    │ Bool            │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ i32        │ 32-bit  │ Size/count values               │ Internal use    │
  ├────────────┼─────────┼─────────────────────────────────┼─────────────────┤
  │ !bf.cursor │ 128-bit │ Pair of pointers {i8*, i8*}     │ Internal use    │
  └────────────┴─────────┴─────────────────────────────────┴─────────────────┘
  Source: Types.elm:48-71, BFOps.td:51-61

  Table 2: Elm Language Types (MonoType)
  ┌───────────────┬──────────────┬──────────────────┐
  │   MonoType    │ MLIR Mapping │     Storage      │
  ├───────────────┼──────────────┼──────────────────┤
  │ MInt          │ i64          │ Unboxed          │
  ├───────────────┼──────────────┼──────────────────┤
  │ MFloat        │ f64          │ Unboxed          │
  ├───────────────┼──────────────┼──────────────────┤
  │ MChar         │ i16          │ Unboxed          │
  ├───────────────┼──────────────┼──────────────────┤
  │ MBool         │ i1           │ Unboxed          │
  ├───────────────┼──────────────┼──────────────────┤
  │ MString       │ !eco.value   │ Heap (ElmString) │
  ├───────────────┼──────────────┼──────────────────┤
  │ MList _       │ !eco.value   │ Heap             │
  ├───────────────┼──────────────┼──────────────────┤
  │ MTuple _      │ !eco.value   │ Heap             │
  ├───────────────┼──────────────┼──────────────────┤
  │ MRecord _     │ !eco.value   │ Heap             │
  ├───────────────┼──────────────┼──────────────────┤
  │ MCustom _ _ _ │ !eco.value   │ Heap             │
  ├───────────────┼──────────────┼──────────────────┤
  │ MFunction _ _ │ !eco.value   │ Heap (Closure)   │
  └───────────────┴──────────────┴──────────────────┘
  Source: Types.elm:80-124

  Table 3: elm/bytes Encode Types
  ┌──────────────────┬────────────────┬────────────┬────────────────┬────────────┐
  │ Encoder Function │ Elm Input Type │ Wire Bytes │  BF Write Op   │  Op Input  │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ unsignedInt8     │ Int            │ 1          │ bf.write.u8    │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ signedInt8       │ Int            │ 1          │ bf.write.u8    │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ unsignedInt16    │ Int            │ 2          │ bf.write.u16   │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ signedInt16      │ Int            │ 2          │ bf.write.u16   │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ unsignedInt32    │ Int            │ 4          │ bf.write.u32   │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ signedInt32      │ Int            │ 4          │ bf.write.u32   │ i64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ float32          │ Float          │ 4          │ bf.write.f32   │ f64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ float64          │ Float          │ 8          │ bf.write.f64   │ f64        │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ bytes            │ Bytes          │ variable   │ bf.write.bytes │ !eco.value │
  ├──────────────────┼────────────────┼────────────┼────────────────┼────────────┤
  │ string           │ String         │ variable   │ bf.write.utf8  │ !eco.value │
  └──────────────────┴────────────────┴────────────┴────────────────┴────────────┘
  Source: Reify.elm:139-185, BFOps.td:163-260

  Table 4: elm/bytes Decode Types
  ┌──────────────────┬────────────┬───────────────┬────────────┬────────────┐
  │ Decoder Function │ Wire Bytes │  BF Read Op   │ Op Output  │ Elm Result │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ unsignedInt8     │ 1          │ bf.read.u8    │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ signedInt8       │ 1          │ bf.read.i8    │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ unsignedInt16    │ 2          │ bf.read.u16   │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ signedInt16      │ 2          │ bf.read.i16   │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ unsignedInt32    │ 4          │ bf.read.u32   │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ signedInt32      │ 4          │ bf.read.i32   │ i64        │ Int        │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ float32          │ 4          │ bf.read.f32   │ f64        │ Float      │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ float64          │ 8          │ bf.read.f64   │ f64        │ Float      │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ bytes n          │ n          │ bf.read.bytes │ !eco.value │ Bytes      │
  ├──────────────────┼────────────┼───────────────┼────────────┼────────────┤
  │ string n         │ n          │ bf.read.utf8  │ !eco.value │ String     │
  └──────────────────┴────────────┴───────────────┴────────────┴────────────┘
  Source: BFOps.td:326-477, LoopIR.elm:59-75

  ---
  Critical Type Transitions

  1. Buffer Allocation Flow

  bf.alloc(i32 size) → i64 (raw buffer handle)
  bf.wrap_buffer(i64) → !eco.value (for passing to eco functions)
  bf.cursor.init(i64) → !bf.cursor (for write operations)
  bf.decoder.cursor.init(!eco.value OR i64) → !bf.cursor (for read operations)

  Important: bf.alloc returns i64 (a raw pointer), NOT !eco.value. You must use bf.wrap_buffer to convert it when passing to functions that expect !eco.value.

  2. Decoded Value to Maybe Wrapping

  bf.read.f64 → f64 (unboxed)
  eco.box(f64) → !eco.value (boxed)
  eco.construct.custom(Just, !eco.value) → !eco.value (Maybe wrapper)

  Current Bug Location: Emit.elm:1306-1365 - The emitJustResultWithVar function now correctly boxes i64/f64 values before wrapping in Just.

  3. Type Confusion Risk Points
  Location: bf.alloc result
  Risk: i64 confused with !eco.value
  Mitigation: Both are 64-bit; use bf.wrap_buffer
  ────────────────────────────────────────
  Location: Decoded integers
  Risk: i64 confused with !eco.value
  Mitigation: Track in varTypes dict; box before ADT construction
  ────────────────────────────────────────
  Location: String/Bytes reads
  Risk: bf.read.* can return i64 (for compat)
  Mitigation: BFOps.td now uses AnyType
  ────────────────────────────────────────
  Location: Width computations
  Risk: bf.utf8_width returns i32
  Mitigation: Don't confuse with i64 values
  ---
  Data Flow Diagrams

  Encoding Flow

  Elm Value (MonoExpr)
      ↓ compileExpr
  MLIR primitive (i64/f64) OR heap ref (!eco.value)
      ↓ bf.write.*
  Cursor advancement (!bf.cursor → !bf.cursor)
      ↓ bf.wrap_buffer
  !eco.value (Bytes result)

  Decoding Flow

  !eco.value (Bytes input)
      ↓ bf.decoder.cursor.init
  !bf.cursor
      ↓ bf.require (bounds check)
  i1 (ok flag)
      ↓ scf.if
      ├─ then: bf.read.* → i64/f64 (decoded primitive)
      │         ↓ eco.box (if primitive)
      │         !eco.value
      │         ↓ eco.construct.custom(Just)
      │         !eco.value (Maybe result)
      └─ else: eco.construct.custom(Nothing)
               !eco.value (Nothing)

  ---
  Summary of Type Semantics

  1. !eco.value: The universal boxed type. All heap objects (String, Bytes, List, Custom types, etc.) are represented as this. It's physically a 64-bit heap pointer.
  2. i64: Elm's Int type, stored unboxed. Also used for raw buffer handles from bf.alloc. Danger: Can be confused with !eco.value since both are 64-bit.
  3. f64: Elm's Float type, stored unboxed.
  4. !bf.cursor: A pair of byte pointers (current, end) for traversing byte buffers. Not an Elm-visible type.
  5. Wire integers: The elm/bytes library supports 8/16/32-bit integers (signed and unsigned), but ALL are widened to i64 when decoded (Elm's single Int type). Similarly, float32 is widened to f64.
  6. Bytes vs String: Both are !eco.value heap objects. The difference is in the internal representation (raw bytes vs UTF-16 encoding for String).
