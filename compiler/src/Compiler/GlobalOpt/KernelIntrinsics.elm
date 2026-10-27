module Compiler.GlobalOpt.KernelIntrinsics exposing (Intrinsic(..), CompareKind(..), kernelIntrinsic)

{-| Which kernel calls are _intrinsics_: calls the MLIR back end lowers to an
inline operation instead of a call to the kernel function.

`kernelIntrinsic` makes that decision from the kernel function's home and name
and the monomorphic types of its arguments and result. The decision is needed
by the back end, which emits the operation, by the inliner, which prices an
intrinsic call as an operation rather than a call, and by the constant-thunk
analysis, which asks whether a call is pure arithmetic, so it lives here, below
all three. `Compiler.Generate.MLIR.Intrinsics` emits the MLIR for each
`Intrinsic`.

The decision is a whitelist: every shape not listed gets `Nothing` and stays
an ordinary kernel call. Declining is always safe; choosing the wrong operation
is not.

This module reads no configuration and sees no SSA types. Where an intrinsic is
also switched by a configuration flag, or needs the operands' SSA types to
agree with it, `Compiler.Generate.MLIR.Expr` applies that test after this
module has chosen.

@docs Intrinsic, CompareKind, kernelIntrinsic

-}

import Compiler.AST.MonoAbi as MonoAbi
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Mlir.Mlir exposing (MlirType)



-- ====== INTRINSIC TYPE ======


{-| The inline operation a kernel call is lowered to instead of a call.

Where a constructor carries `op`, it is the name of the MLIR operation to
emit, such as `"eco.int.add"`; the constructor says what kind of operands and
result that operation has.

`UnaryInt`, `BinaryInt`, `UnaryFloat`, `BinaryFloat`, `UnaryBool` and
`BinaryBool` take and give values of one type. `IntComparison`,
`FloatComparison` and `CharComparison` take two values of their type and give a
Bool, as does `FloatClassify` from one Float. `IntToFloat` is `toFloat`;
`FloatToInt` is one of `round`, `floor`, `ceiling` and `truncate`.

`ConstantFloat` is a kernel constant (`pi` or `e`) replaced by its value.

`CharToInt` and `CharFromInt` are `Char.toCode` and `Char.fromCode`;
`StringFromInt` and `StringFromFloat` are `String.fromNumber` at Int and Float;
`StringLength` is `String.length`.

The `Array` constructors are the `JsArray` kernel functions: `ArrayGet` is
`unsafeGet`, `ArraySet` is `unsafeSet`, and the others share their names.
Where one carries `elementMlirType`, it is the ABI type of the array's
elements, which decides whether a slot is read or written unboxed.
`ArrayEmpty`, `ArrayLength`, `ArraySlice` and `ArrayAppendN` do not need it.

`ConstructList` is `List.cons`; `headMlirType` is the ABI type of the head,
which decides the kind recorded for the head slot of the new cell.

`AppendString` and `AppendList` are `++` on two Strings and on two Lists.

`CompareToOrder` is `compare` on two values of the kind it carries, giving an
`Order`. `StringOrderCompare` is `<`, `<=`, `>` or `>=` on two Strings: the
Strings are compared to a signed number, and `op` is the Int comparison that
tests that number against zero.

`ValueEq` is `==` on two boxed values of the same type, and `BoolEq` is `==`
on two Bools; with `negate` set, each is `/=` instead.

-}
type Intrinsic
    = UnaryInt { op : String }
    | BinaryInt { op : String }
    | UnaryFloat { op : String }
    | BinaryFloat { op : String }
    | UnaryBool { op : String }
    | BinaryBool { op : String }
    | IntToFloat
    | FloatToInt { op : String }
    | IntComparison { op : String }
    | FloatComparison { op : String }
    | CharComparison { op : String }
    | FloatClassify { op : String }
    | ConstantFloat { value : Float }
    | CharToInt
    | CharFromInt
    | StringFromInt
    | StringFromFloat
    | StringLength
    | ArrayGet { elementMlirType : MlirType }
    | ArraySet { elementMlirType : MlirType }
    | ArrayLength
    | ArrayEmpty
    | ArraySingleton { elementMlirType : MlirType }
    | ArrayPush { elementMlirType : MlirType }
    | ArraySlice
    | ArrayAppendN
    | ConstructList { headMlirType : MlirType }
    | AppendString
    | AppendList
    | CompareToOrder { kind : CompareKind }
    | StringOrderCompare { op : String }
    | ValueEq { negate : Bool }
    | BoolEq { negate : Bool }


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
module `home` lowers to, given the monomorphic types of its arguments and of
its result, or `Nothing` when the call stays a kernel call.

`home` is the bare module name, such as `"Basics"` or `"JsArray"`; the kernel
prefix is not consulted. `argTypes` lists the arguments actually supplied, so a
reference to a kernel function that is not applied passes `[]` and gets an
intrinsic only for a constant such as `pi`.

-}
kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics" ->
            basicsIntrinsic name argTypes resultType

        "Bitwise" ->
            bitwiseIntrinsic name argTypes

        "Utils" ->
            utilsIntrinsic name argTypes

        "JsArray" ->
            jsArrayIntrinsic name argTypes resultType

        "List" ->
            listIntrinsic name argTypes resultType

        "Char" ->
            charIntrinsic name argTypes

        "String" ->
            stringIntrinsic name argTypes

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Basics` kernel function `name`:
Int, Float and Bool arithmetic, comparison and conversion.

Every arm but the constants is chosen by the argument types alone, because the
result type of a call can still be a type variable where the call sits in a
polymorphic context. For the same reason `pi` and `e` accept a type-variable
result as well as `Float`. `logBase` has no intrinsic.

`and` and `or` here are strict in both arguments. They are reached only for
the functions themselves, such as `(&&)` passed as a value; the `&&` and `||`
operators are short-circuited before this point.

-}
basicsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
basicsIntrinsic name argTypes resultType =
    case ( name, argTypes ) of
        ( "pi", [] ) ->
            if resultType == Mono.MFloat || isTypeVar resultType then
                Just (ConstantFloat { value = 3.141592653589793 })

            else
                Nothing

        ( "e", [] ) ->
            if resultType == Mono.MFloat || isTypeVar resultType then
                Just (ConstantFloat { value = 2.718281828459045 })

            else
                Nothing

        ( "add", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.add" })

        ( "sub", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.sub" })

        ( "mul", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.mul" })

        ( "idiv", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.div" })

        ( "modBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.modby" })

        ( "remainderBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.remainderby" })

        ( "negate", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.negate" })

        ( "abs", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.abs" })

        ( "pow", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.pow" })

        ( "add", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.add" })

        ( "sub", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.sub" })

        ( "mul", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.mul" })

        ( "fdiv", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.div" })

        ( "negate", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.negate" })

        ( "abs", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.abs" })

        ( "pow", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.pow" })

        ( "sqrt", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" })

        ( "sin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sin" })

        ( "cos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.cos" })

        ( "tan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.tan" })

        ( "asin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.asin" })

        ( "acos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.acos" })

        ( "atan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.atan" })

        ( "atan2", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.atan2" })

        ( "logBase", [ Mono.MFloat, Mono.MFloat ] ) ->
            Nothing

        ( "log", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        ( "isNaN", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "isInfinite", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        ( "toFloat", [ Mono.MInt ] ) ->
            Just IntToFloat

        ( "round", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.round" })

        ( "floor", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.floor" })

        ( "ceiling", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.ceiling" })

        ( "truncate", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.truncate" })

        ( "min", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "max", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.max" })

        ( "min", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "max", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        ( "lt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "eq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "neq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "eq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "neq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        ( "not", [ Mono.MBool ] ) ->
            Just (UnaryBool { op = "eco.bool.not" })

        ( "and", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.and" })

        ( "or", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.or" })

        ( "xor", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.xor" })

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Bitwise` kernel function `name` on
Int arguments.
-}
bitwiseIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
bitwiseIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "and", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.and" })

        ( "or", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.or" })

        ( "xor", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.xor" })

        ( "complement", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.complement" })

        ( "shiftLeftBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shl" })

        ( "shiftRightBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shr" })

        ( "shiftRightZfBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shru" })

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `Utils` kernel function `name`:
equality, ordering, `compare` and `++`.

Int, Float and Char get their own comparison operations. Char ordering
compares unsigned. Two Bools are compared as Bools. Two
values of the same boxed type (see `boxedComparable`) get `ValueEq`; a type
variable or a function type gets no intrinsic and stays a kernel call.
`compare` is an intrinsic for Int, Float, Char and
String, and ordering for String too; every other boxed key stays a kernel call.
`++` is an intrinsic for two Strings or two Lists, and for any other pair,
including one with a type-variable operand, stays a kernel call, which chooses
by the values at run time.

-}
utilsIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
utilsIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "equal", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "notEqual", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "equal", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "notEqual", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "equal", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.eq" })

        ( "notEqual", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.ne" })

        ( "lt", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.lt" })

        ( "le", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.le" })

        ( "gt", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.gt" })

        ( "ge", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.ge" })

        ( "equal", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = False })

        ( "notEqual", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = True })

        ( "equal", [ x, y ] ) ->
            if boxedComparable x && x == y then
                Just (ValueEq { negate = False })

            else
                Nothing

        ( "notEqual", [ x, y ] ) ->
            if boxedComparable x && x == y then
                Just (ValueEq { negate = True })

            else
                Nothing

        ( "compare", [ Mono.MInt, Mono.MInt ] ) ->
            Just (CompareToOrder { kind = CompareIntKind })

        ( "compare", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (CompareToOrder { kind = CompareFloatKind })

        ( "compare", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CompareToOrder { kind = CompareCharKind })

        ( "compare", [ Mono.MString, Mono.MString ] ) ->
            Just (CompareToOrder { kind = CompareStringKind })

        -- The string comparison's sign is not clamped to -1, 0 or 1, so the
        -- test is always against 0.
        ( "lt", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.lt" })

        ( "le", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.le" })

        ( "gt", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.gt" })

        ( "ge", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.ge" })

        ( "append", [ Mono.MString, Mono.MString ] ) ->
            Just AppendString

        ( "append", [ Mono.MList _ _, Mono.MList _ _ ] ) ->
            Just AppendList

        -- Spelled out, though the last arm gives the same answer.
        ( "append", [ Mono.MString, Mono.MList _ _ ] ) ->
            Nothing

        ( "append", [ Mono.MList _ _, Mono.MString ] ) ->
            Nothing

        _ ->
            Nothing


{-| Returns the intrinsic for `Char.toCode` on a Char or `Char.fromCode` on an
Int.
-}
charIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
charIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "toCode", [ Mono.MChar ] ) ->
            Just CharToInt

        ( "fromCode", [ Mono.MInt ] ) ->
            Just CharFromInt

        _ ->
            Nothing


{-| Returns the intrinsic for a call of the `String` kernel function `name`:
`fromNumber` at Int or Float, and `length` applied to a String. A reference to
`length` that is not applied has no argument types and gets none.
-}
stringIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
stringIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "fromNumber", [ Mono.MInt ] ) ->
            Just StringFromInt

        ( "fromNumber", [ Mono.MFloat ] ) ->
            Just StringFromFloat

        ( "length", [ Mono.MString ] ) ->
            Just StringLength

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


{-| Returns `ArraySet` for an element of type `elt`, or `Nothing` when `elt`
is a type variable, whose ABI type, and so the slot kind, is not known.
-}
concreteArraySet : Mono.MonoType -> Maybe Intrinsic
concreteArraySet elt =
    case elt of
        Mono.MVar _ _ ->
            Nothing

        _ ->
            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi elt })


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
jsArrayIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
jsArrayIntrinsic name argTypes resultType =
    case name of
        "empty" ->
            case argTypes of
                [] ->
                    Just ArrayEmpty

                _ ->
                    Nothing

        "singleton" ->
            case ( argTypes, arrayElementType resultType ) of
                ( [ _ ], Just elt ) ->
                    Just (ArraySingleton { elementMlirType = MonoAbi.monoTypeToAbi elt })

                _ ->
                    Nothing

        "push" ->
            case argTypes of
                [ elt, _ ] ->
                    Just (ArrayPush { elementMlirType = MonoAbi.monoTypeToAbi elt })

                _ ->
                    Nothing

        "slice" ->
            case argTypes of
                [ Mono.MInt, Mono.MInt, _ ] ->
                    Just ArraySlice

                _ ->
                    Nothing

        "appendN" ->
            case argTypes of
                [ Mono.MInt, _, _ ] ->
                    Just ArrayAppendN

                _ ->
                    Nothing

        "length" ->
            case resultType of
                Mono.MInt ->
                    Just ArrayLength

                _ ->
                    Nothing

        "unsafeGet" ->
            case argTypes of
                [ Mono.MInt, arrayTy ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            -- The kernel call reads the slot kind from the
                            -- array at run time; an inline read cannot.
                            Nothing

                        Just elt ->
                            Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi elt })

                        Nothing ->
                            -- A boxed result type may be a widened stand-in for
                            -- an unboxed element.
                            if MonoAbi.monoTypeToAbi resultType == MonoAbi.ecoValue then
                                Nothing

                            else
                                Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi resultType })

                _ ->
                    Nothing

        "unsafeSet" ->
            case argTypes of
                [ Mono.MInt, elt, arrayTy ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            concreteArraySet elt

                        Just fromArray ->
                            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi fromArray })

                        Nothing ->
                            concreteArraySet elt

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns `ConstructList` for `List.cons` with a head and a tail, or
`Nothing` when the head's slot kind is not settled (see `consHeadAbi`) or when
the tail or the result is not passed as `!eco.value`.
-}
listIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
listIntrinsic name argTypes resultType =
    case ( name, argTypes ) of
        ( "cons", [ headTy, tailTy ] ) ->
            case consHeadAbi headTy of
                Just headMlirType ->
                    if boxedSlot tailTy && boxedSlot resultType then
                        Just (ConstructList { headMlirType = headMlirType })

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the ABI type of a list head of type `headTy`, which is the kind
its slot is given, or `Nothing` when that is not settled.

Int, Float and Char are unboxed and any other type that is passed as
`!eco.value` is boxed. A `number` type variable gives `Nothing`: it may still
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
            if MonoAbi.isEcoValueType (MonoAbi.monoTypeToAbi headTy) then
                Just MonoAbi.ecoValue

            else
                Nothing


{-| Returns whether a value of type `t` is passed as `!eco.value`.
-}
boxedSlot : Mono.MonoType -> Bool
boxedSlot t =
    MonoAbi.isEcoValueType (MonoAbi.monoTypeToAbi t)


{-| Returns whether `t` is a type variable.
-}
isTypeVar : Mono.MonoType -> Bool
isTypeVar t =
    case t of
        Mono.MVar _ _ ->
            True

        _ ->
            False
