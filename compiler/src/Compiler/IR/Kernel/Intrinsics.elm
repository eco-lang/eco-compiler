module Compiler.IR.Kernel.Intrinsics exposing (Intrinsic(..), Operation(..), CompareKind(..), kernelIntrinsicOn, kernelIntrinsic, kernelFloatConstant)

{-| Which kernel calls are _intrinsics_: calls the MLIR back end lowers to an
inline operation instead of a call to the kernel function.

`kernelIntrinsicOn` makes that decision from the kernel function's home and
name and the monomorphic types of its arguments and result. The decision is
needed by the back end, which emits the operation, by the inliner, which prices an
intrinsic call as an operation rather than a call, and by the constant-thunk
analysis, which asks whether a call is pure arithmetic, so it lives here, below
all three. `Compiler.GenerateMlir.Intrinsics` emits the MLIR for each
`Operation`, and `Compiler.GenerateMlir.Expr` for `ConstructList`.

The decision is a whitelist: every shape not listed gets `Nothing` and stays
an ordinary kernel call. Declining is always safe; choosing the wrong operation
is not.

This module reads no configuration and sees no SSA types. Where an intrinsic is
also switched by a configuration flag, or needs the operands' SSA types to
agree with it, `Compiler.GenerateMlir.Expr` applies that test after this
module has chosen.

@docs Intrinsic, Operation, CompareKind, kernelIntrinsicOn, kernelIntrinsic, kernelFloatConstant

-}

import Compiler.Core.Name as Name
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Abi as MonoAbi
import Mlir.Mlir exposing (MlirType)



-- ====== INTRINSIC TYPE ======


{-| The inline operation a kernel call is lowered to instead of a call, with
its operands, of type `a`: one per argument of the kernel function, in its
argument order.

`ConstructList` is `List.cons`, with the head and the tail;
`headMlirType` is the ABI type of the head, which decides the kind recorded for
the head slot of the new cell. It is kept apart from the other intrinsics, the
`Operation`s, because it is the one whose operands may need boxing: an
`Operation` takes each operand either as it is or unboxed.

Where a constructor of `Operation` carries `op`, it is the name of the MLIR operation to
emit, such as `"eco.int.add"`; the constructor says what kind of operands and
result that operation has.

`UnaryInt`, `BinaryInt`, `UnaryFloat`, `BinaryFloat`, `UnaryBool` and
`BinaryBool` take and give values of one type. `IntComparison`,
`FloatComparison` and `CharComparison` take two values of their type and give a
Bool, as does `FloatClassify` from one Float. `IntToFloat` is `toFloat`;
`FloatToInt` is one of `round`, `floor`, `ceiling` and `truncate`.

`CharToInt` and `CharFromInt` are `Char.toCode` and `Char.fromCode`;
`StringFromInt` and `StringFromFloat` are `String.fromNumber` at Int and Float;
`StringLength` is `String.length`.

The `Array` constructors are the `JsArray` kernel functions: `ArrayGet` is
`unsafeGet`, `ArraySet` is `unsafeSet`, and the others share their names.
Where one carries `elementMlirType`, it is the ABI type of the array's
elements, which decides whether a slot is read or written unboxed.
`ArrayLength`, `ArraySlice` and `ArrayAppendN` do not need it.

`AppendString` and `AppendList` are `++` on two Strings and on two Lists.

`CompareToOrder` is `compare` on two values of the kind it carries, giving an
`Order`. `StringOrderCompare` is `<`, `<=`, `>` or `>=` on two Strings: the
Strings are compared to a signed number, and `op` is the Int comparison that
tests that number against zero.

`ValueEq` is `==` on two boxed values of the same type, and `BoolEq` is `==`
on two Bools; with `negate` set, each is `/=` instead.

-}
type Intrinsic a
    = ConstructList { headMlirType : MlirType } a a
    | Operation (Operation a)


{-| An intrinsic other than `ConstructList`: the inline operation, with its
operands, that a kernel call becomes. The constructors are described under
`Intrinsic`.
-}
type Operation a
    = UnaryInt { op : String } a
    | BinaryInt { op : String } a a
    | UnaryFloat { op : String } a
    | BinaryFloat { op : String } a a
    | UnaryBool { op : String } a
    | BinaryBool { op : String } a a
    | IntToFloat a
    | FloatToInt { op : String } a
    | IntComparison { op : String } a a
    | FloatComparison { op : String } a a
    | CharComparison { op : String } a a
    | FloatClassify { op : String } a
    | CharToInt a
    | CharFromInt a
    | StringFromInt a
    | StringFromFloat a
    | StringLength a
    | ArrayGet { elementMlirType : MlirType } a a
    | ArraySet { elementMlirType : MlirType } a a a
    | ArrayLength a
    | ArraySingleton { elementMlirType : MlirType } a
    | ArrayPush { elementMlirType : MlirType } a a
    | ArraySlice a a a
    | ArrayAppendN a a a
    | AppendString a a
    | AppendList a a
    | CompareToOrder { kind : CompareKind } a a
    | StringOrderCompare { op : String } a a
    | ValueEq { negate : Bool } a a
    | BoolEq { negate : Bool } a a


{-| The type of the two operands of a `compare` lowered to `CompareToOrder`,
which selects the operation that compares them.
-}
type CompareKind
    = CompareIntKind
    | CompareFloatKind
    | CompareCharKind
    | CompareStringKind



-- ====== INTRINSIC LOOKUP ======


{-| Returns the intrinsic that a call of kernel function `name` from kernel
module `home` lowers to, or `Nothing` when the call stays a kernel call. Each
of `args` is an argument the call supplies, paired with its monomorphic type;
`resultType` is the type of the call's result.

The intrinsic carries the arguments as its operands, in the kernel function's
argument order, so it always has exactly the operands its operation takes.

`home` is the bare module name, such as `"Basics"` or `"JsArray"`; the kernel
prefix is not consulted. A call supplies at least one argument. A kernel used
as a value is not a call; `kernelFloatConstant` says which of those are
constants.

-}
kernelIntrinsicOn : Name.Name -> Name.Name -> List ( a, Mono.MonoType ) -> Mono.MonoType -> Maybe (Intrinsic a)
kernelIntrinsicOn home name args resultType =
    case home of
        "Basics" ->
            basicsIntrinsic name args |> Maybe.map Operation

        "Bitwise" ->
            bitwiseIntrinsic name args |> Maybe.map Operation

        "Utils" ->
            utilsIntrinsic name args |> Maybe.map Operation

        "JsArray" ->
            jsArrayIntrinsic name args resultType |> Maybe.map Operation

        "List" ->
            listIntrinsic name args resultType

        "Char" ->
            charIntrinsic name args |> Maybe.map Operation

        "String" ->
            stringIntrinsic name args |> Maybe.map Operation

        _ ->
            Nothing


{-| Returns `kernelIntrinsicOn` for a call whose arguments have the types
`argTypes`, with those types as the operands, for a caller that asks only
whether, and as what, the call is an intrinsic.
-}
kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe (Intrinsic Mono.MonoType)
kernelIntrinsic home name argTypes resultType =
    kernelIntrinsicOn home name (List.map (\ty -> ( ty, ty )) argTypes) resultType


{-| Returns the value of the kernel value `name` from kernel module `home` when
it is a Float constant replaced by its value, `pi` or `e`, and `Nothing` for
every other kernel value.

They are reached only through `Basics.pi` and `Basics.e`, whose type is
`Float`.

-}
kernelFloatConstant : Name.Name -> Name.Name -> Maybe Float
kernelFloatConstant home name =
    case ( home, name ) of
        ( "Basics", "pi" ) ->
            Just 3.141592653589793

        ( "Basics", "e" ) ->
            Just 2.718281828459045

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Basics` kernel function `name`:
Int, Float and Bool arithmetic, comparison and conversion.

Every arm is chosen by the name and the argument types alone, because the
result type of a call can still be a type variable where the call sits in a
polymorphic context. `logBase` has no intrinsic.

`and` and `or` here are strict in both arguments. They are reached only for
the functions themselves, such as `(&&)` passed as a value; the `&&` and `||`
operators are short-circuited before this point.

-}
basicsIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Maybe (Operation a)
basicsIntrinsic name args =
    case ( name, args ) of
        ( "add", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.add" } a b)

        ( "sub", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.sub" } a b)

        ( "mul", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.mul" } a b)

        ( "idiv", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.div" } a b)

        ( "modBy", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.modby" } a b)

        ( "remainderBy", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.remainderby" } a b)

        ( "negate", [ ( a, Mono.MInt ) ] ) ->
            Just (UnaryInt { op = "eco.int.negate" } a)

        ( "abs", [ ( a, Mono.MInt ) ] ) ->
            Just (UnaryInt { op = "eco.int.abs" } a)

        ( "pow", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.pow" } a b)

        ( "add", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.add" } a b)

        ( "sub", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.sub" } a b)

        ( "mul", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.mul" } a b)

        ( "fdiv", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.div" } a b)

        ( "negate", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.negate" } a)

        ( "abs", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.abs" } a)

        ( "pow", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.pow" } a b)

        ( "sqrt", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" } a)

        ( "sin", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.sin" } a)

        ( "cos", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.cos" } a)

        ( "tan", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.tan" } a)

        ( "asin", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.asin" } a)

        ( "acos", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.acos" } a)

        ( "atan", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.atan" } a)

        ( "atan2", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.atan2" } a b)

        ( "logBase", [ ( _, Mono.MFloat ), ( _, Mono.MFloat ) ] ) ->
            Nothing

        ( "log", [ ( a, Mono.MFloat ) ] ) ->
            Just (UnaryFloat { op = "eco.float.log" } a)

        ( "isNaN", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatClassify { op = "eco.float.isNaN" } a)

        ( "isInfinite", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" } a)

        ( "toFloat", [ ( a, Mono.MInt ) ] ) ->
            Just (IntToFloat a)

        ( "round", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatToInt { op = "eco.float.round" } a)

        ( "floor", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatToInt { op = "eco.float.floor" } a)

        ( "ceiling", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatToInt { op = "eco.float.ceiling" } a)

        ( "truncate", [ ( a, Mono.MFloat ) ] ) ->
            Just (FloatToInt { op = "eco.float.truncate" } a)

        ( "min", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.min" } a b)

        ( "max", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.max" } a b)

        ( "min", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.min" } a b)

        ( "max", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (BinaryFloat { op = "eco.float.max" } a b)

        ( "lt", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.lt" } a b)

        ( "le", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.le" } a b)

        ( "gt", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.gt" } a b)

        ( "ge", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.ge" } a b)

        ( "eq", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.eq" } a b)

        ( "neq", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.ne" } a b)

        ( "lt", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.lt" } a b)

        ( "le", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.le" } a b)

        ( "gt", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.gt" } a b)

        ( "ge", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.ge" } a b)

        ( "eq", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.eq" } a b)

        ( "neq", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.ne" } a b)

        ( "not", [ ( a, Mono.MBool ) ] ) ->
            Just (UnaryBool { op = "eco.bool.not" } a)

        ( "and", [ ( a, Mono.MBool ), ( b, Mono.MBool ) ] ) ->
            Just (BinaryBool { op = "eco.bool.and" } a b)

        ( "or", [ ( a, Mono.MBool ), ( b, Mono.MBool ) ] ) ->
            Just (BinaryBool { op = "eco.bool.or" } a b)

        ( "xor", [ ( a, Mono.MBool ), ( b, Mono.MBool ) ] ) ->
            Just (BinaryBool { op = "eco.bool.xor" } a b)

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Bitwise` kernel function `name` on
Int arguments.
-}
bitwiseIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Maybe (Operation a)
bitwiseIntrinsic name args =
    case ( name, args ) of
        ( "and", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.and" } a b)

        ( "or", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.or" } a b)

        ( "xor", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.xor" } a b)

        ( "complement", [ ( a, Mono.MInt ) ] ) ->
            Just (UnaryInt { op = "eco.int.complement" } a)

        ( "shiftLeftBy", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.shl" } a b)

        ( "shiftRightBy", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.shr" } a b)

        ( "shiftRightZfBy", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (BinaryInt { op = "eco.int.shru" } a b)

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Utils` kernel function `name`:
equality, ordering, `compare` and `++`.

Int, Float and Char get their own comparison operations; Chars compare in
code-point order (KERN\_008). Two Bools are compared as Bools. Two
values of the same boxed type (see `boxedComparable`) get `ValueEq`; a type
variable or a function type gets no intrinsic and stays a kernel call.
`compare` is an intrinsic for Int, Float, Char and
String, and ordering for String too; every other boxed key stays a kernel call.
`++` is an intrinsic for two Strings or two Lists, and for any other pair,
including one with a type-variable operand, stays a kernel call, which chooses
by the values at run time.

-}
utilsIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Maybe (Operation a)
utilsIntrinsic name args =
    case ( name, args ) of
        ( "equal", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.eq" } a b)

        ( "notEqual", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.ne" } a b)

        ( "lt", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.lt" } a b)

        ( "le", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.le" } a b)

        ( "gt", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.gt" } a b)

        ( "ge", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (IntComparison { op = "eco.int.ge" } a b)

        ( "equal", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.eq" } a b)

        ( "notEqual", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.ne" } a b)

        ( "lt", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.lt" } a b)

        ( "le", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.le" } a b)

        ( "gt", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.gt" } a b)

        ( "ge", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (FloatComparison { op = "eco.float.ge" } a b)

        ( "equal", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.eq" } a b)

        ( "notEqual", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.ne" } a b)

        ( "lt", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.lt" } a b)

        ( "le", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.le" } a b)

        ( "gt", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.gt" } a b)

        ( "ge", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CharComparison { op = "eco.char.ge" } a b)

        ( "equal", [ ( a, Mono.MBool ), ( b, Mono.MBool ) ] ) ->
            Just (BoolEq { negate = False } a b)

        ( "notEqual", [ ( a, Mono.MBool ), ( b, Mono.MBool ) ] ) ->
            Just (BoolEq { negate = True } a b)

        ( "equal", [ ( a, x ), ( b, y ) ] ) ->
            if boxedComparable x && x == y then
                Just (ValueEq { negate = False } a b)

            else
                Nothing

        ( "notEqual", [ ( a, x ), ( b, y ) ] ) ->
            if boxedComparable x && x == y then
                Just (ValueEq { negate = True } a b)

            else
                Nothing

        ( "compare", [ ( a, Mono.MInt ), ( b, Mono.MInt ) ] ) ->
            Just (CompareToOrder { kind = CompareIntKind } a b)

        ( "compare", [ ( a, Mono.MFloat ), ( b, Mono.MFloat ) ] ) ->
            Just (CompareToOrder { kind = CompareFloatKind } a b)

        ( "compare", [ ( a, Mono.MChar ), ( b, Mono.MChar ) ] ) ->
            Just (CompareToOrder { kind = CompareCharKind } a b)

        ( "compare", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (CompareToOrder { kind = CompareStringKind } a b)

        -- The string comparison's sign is not clamped to -1, 0 or 1, so the
        -- test is always against 0.
        ( "lt", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (StringOrderCompare { op = "eco.int.lt" } a b)

        ( "le", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (StringOrderCompare { op = "eco.int.le" } a b)

        ( "gt", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (StringOrderCompare { op = "eco.int.gt" } a b)

        ( "ge", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (StringOrderCompare { op = "eco.int.ge" } a b)

        ( "append", [ ( a, Mono.MString ), ( b, Mono.MString ) ] ) ->
            Just (AppendString a b)

        ( "append", [ ( a, Mono.MList _ _ ), ( b, Mono.MList _ _ ) ] ) ->
            Just (AppendList a b)

        -- Spelled out, though the last arm gives the same answer.
        ( "append", [ ( _, Mono.MString ), ( _, Mono.MList _ _ ) ] ) ->
            Nothing

        ( "append", [ ( _, Mono.MList _ _ ), ( _, Mono.MString ) ] ) ->
            Nothing

        _ ->
            Nothing


{-| Returns the intrinsic for `Char.toCode` on a Char or `Char.fromCode` on an
Int.
-}
charIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Maybe (Operation a)
charIntrinsic name args =
    case ( name, args ) of
        ( "toCode", [ ( a, Mono.MChar ) ] ) ->
            Just (CharToInt a)

        ( "fromCode", [ ( a, Mono.MInt ) ] ) ->
            Just (CharFromInt a)

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `String` kernel function `name`:
`fromNumber` at Int or Float, and `length` applied to a String. A reference to
`length` that is not applied has no argument types and gets none.
-}
stringIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Maybe (Operation a)
stringIntrinsic name args =
    case ( name, args ) of
        ( "fromNumber", [ ( a, Mono.MInt ) ] ) ->
            Just (StringFromInt a)

        ( "fromNumber", [ ( a, Mono.MFloat ) ] ) ->
            Just (StringFromFloat a)

        ( "length", [ ( a, Mono.MString ) ] ) ->
            Just (StringLength a)

        _ ->
            Nothing


{-| Returns whether `==` on two values of type `ty` may be the boxed equality
operation: `True` for String, unit, List, tuple, record and custom types, all
of which are passed as `!eco.value`.

Int, Float, Char and Bool have their own arms in `utilsIntrinsic` and give
`False` here, as do a type variable and a function.

-}
boxedComparable : Mono.MonoType -> Bool
boxedComparable ty =
    case ty of
        Mono.MString ->
            True

        Mono.MUnit ->
            True

        Mono.MList _ _ ->
            True

        Mono.MTuple _ _ ->
            True

        Mono.MRecord _ _ ->
            True

        Mono.MCustom _ _ _ _ ->
            True

        _ ->
            False


{-| Returns `ArraySet` of `index`, `value` and `array` for an element of type
`elt`, or `Nothing` when `elt` is a type variable, whose ABI type, and so the
slot kind, is not known.
-}
concreteArraySet : Mono.MonoType -> a -> a -> a -> Maybe (Operation a)
concreteArraySet elt index value array =
    case elt of
        Mono.MVar _ _ ->
            Nothing

        _ ->
            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi elt } index value array)


{-| Returns the element type of `ty` when it is a `JsArray` or an `Array` with
its one type argument, and `Nothing` for any other type.

The element type of a `JsArray` call is read from here, because the array
arguments of a `JsArray` function are specialized per element type while its
other arguments and its result may not be.

-}
arrayElementType : Mono.MonoType -> Maybe Mono.MonoType
arrayElementType ty =
    case ty of
        Mono.MCustom _ _ "JsArray" [ elt ] ->
            Just elt

        Mono.MCustom _ _ "Array" [ elt ] ->
            Just elt

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `JsArray` kernel function `name`.

The intrinsics that touch an element need its ABI type, because an Int, Float
or Char element is stored unboxed. `unsafeGet` and `unsafeSet` take it from
the array argument where they can (see `arrayElementType`).

`unsafeGet` declines when the array's element is a type variable. When the
array's element type cannot be read at all it falls back on the result type,
but only when that is unboxed: the result of a function specialized on its own
can be boxed although the element is not. `unsafeSet` falls back on the value
argument, and declines only when that is also a type variable. `singleton`
takes the element from its result, and `push` from its value argument.

-}
jsArrayIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Mono.MonoType -> Maybe (Operation a)
jsArrayIntrinsic name args resultType =
    case name of
        "singleton" ->
            case ( args, arrayElementType resultType ) of
                ( [ ( value, _ ) ], Just elt ) ->
                    Just (ArraySingleton { elementMlirType = MonoAbi.monoTypeToAbi elt } value)

                _ ->
                    Nothing

        "push" ->
            case args of
                [ ( value, elt ), ( array, _ ) ] ->
                    Just (ArrayPush { elementMlirType = MonoAbi.monoTypeToAbi elt } value array)

                _ ->
                    Nothing

        "slice" ->
            case args of
                [ ( start, Mono.MInt ), ( end, Mono.MInt ), ( array, _ ) ] ->
                    Just (ArraySlice start end array)

                _ ->
                    Nothing

        "appendN" ->
            case args of
                [ ( n, Mono.MInt ), ( dest, _ ), ( source, _ ) ] ->
                    Just (ArrayAppendN n dest source)

                _ ->
                    Nothing

        "length" ->
            case ( args, resultType ) of
                ( [ ( array, _ ) ], Mono.MInt ) ->
                    Just (ArrayLength array)

                _ ->
                    Nothing

        "unsafeGet" ->
            case args of
                [ ( index, Mono.MInt ), ( array, arrayTy ) ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            -- The kernel call reads the slot kind from the
                            -- array at run time; an inline read cannot.
                            Nothing

                        Just elt ->
                            Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi elt } index array)

                        Nothing ->
                            -- A boxed result type may be a widened stand-in for
                            -- an unboxed element.
                            if MonoAbi.monoTypeToAbi resultType == MonoAbi.ecoValue then
                                Nothing

                            else
                                Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi resultType } index array)

                _ ->
                    Nothing

        "unsafeSet" ->
            case args of
                [ ( index, Mono.MInt ), ( value, elt ), ( array, arrayTy ) ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            concreteArraySet elt index value array

                        Just fromArray ->
                            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi fromArray } index value array)

                        Nothing ->
                            concreteArraySet elt index value array

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns `ConstructList` for `List.cons` with a head and a tail, or
`Nothing` when the head's slot kind is not settled (see `consHeadAbi`) or when
the tail or the result is not passed as `!eco.value`.
-}
listIntrinsic : Name.Name -> List ( a, Mono.MonoType ) -> Mono.MonoType -> Maybe (Intrinsic a)
listIntrinsic name args resultType =
    case ( name, args ) of
        ( "cons", [ ( head, headTy ), ( tail, tailTy ) ] ) ->
            case consHeadAbi headTy of
                Just headMlirType ->
                    if boxedSlot tailTy && boxedSlot resultType then
                        Just (ConstructList { headMlirType = headMlirType } head tail)

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the ABI type of a list head of type `headTy`, which is the kind
its slot is given, or `Nothing` when that is not settled.

Int, Float and Char are unboxed and any other type is boxed, as it is passed
as `!eco.value`. A `number` type variable gives `Nothing`: it may still
become Int or Float, and its slot kind must not be fixed before it does.

-}
consHeadAbi : Mono.MonoType -> Maybe MlirType
consHeadAbi headTy =
    case headTy of
        Mono.MInt ->
            Just MonoAbi.ecoInt

        Mono.MFloat ->
            Just MonoAbi.ecoFloat

        Mono.MChar ->
            Just MonoAbi.ecoChar

        Mono.MVar _ Mono.CNumber ->
            Nothing

        _ ->
            Just MonoAbi.ecoValue


{-| Returns whether a value of type `t` is passed as `!eco.value`.
-}
boxedSlot : Mono.MonoType -> Bool
boxedSlot t =
    MonoAbi.isEcoValueType (MonoAbi.monoTypeToAbi t)
