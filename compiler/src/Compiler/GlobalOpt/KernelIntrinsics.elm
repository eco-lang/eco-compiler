module Compiler.GlobalOpt.KernelIntrinsics exposing (Intrinsic(..), CompareKind(..), kernelIntrinsic)

{-| Which kernel calls are _intrinsics_: calls the MLIR back end lowers to an
inline operation instead of a call to the kernel function.

`kernelIntrinsic` makes that decision from the kernel function's home and name
and the monomorphic types of its arguments and result. The decision is needed
both by the back end, which emits the operation, and by the inliner, which
prices an intrinsic call as an operation rather than a call, so it lives here,
below both. `Compiler.Generate.MLIR.Intrinsics` emits the MLIR for each
`Intrinsic`.

@docs Intrinsic, CompareKind, kernelIntrinsic

-}

import Compiler.AST.MonoAbi as MonoAbi
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Mlir.Mlir exposing (MlirType)



-- ====== INTRINSIC TYPE ======


{-| Intrinsic operation type representing operations that can be lowered directly to MLIR.
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


{-| Operand kind selector for the `Utils.compare` intrinsic.
-}
type CompareKind
    = CompareIntKind
    | CompareFloatKind
    | CompareCharKind
    | CompareStringKind



-- ====== INTRINSIC LOOKUP ======


{-| Look up an intrinsic for a kernel function call.
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


basicsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
basicsIntrinsic name argTypes resultType =
    -- Note: We match primarily on argument types because the result type from
    -- the MonoCall might be a type variable (MVar) when the call is used in a
    -- polymorphic context (e.g., `Debug.log "x" (negate 5)` where the result type
    -- inherits from Debug.log's `a` parameter). For functions where the return type
    -- is the same as the argument type, we use wildcard matching on resultType.
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

        -- Boolean operations.
        --
        -- `eco.bool.and` / `eco.bool.or` are strict in both arguments; they are
        -- only reached for first-class references to Basics.and / Basics.or
        -- (e.g. `(&&)` passed as a value). Short-circuit semantics for the
        -- (&&) / (||) operators are implemented earlier in TypedOptimized by
        -- rewriting Binop to If, and do not flow through this path.
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


utilsIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
utilsIntrinsic name argTypes =
    case ( name, argTypes ) of
        -- Int comparisons
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

        -- Float comparisons
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

        -- Char comparisons (i16 unboxed). Equality is signedness-agnostic;
        -- ordering uses unsigned predicates because Char is a Unicode code
        -- point.
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

        -- Compare-to-Order intrinsics: return one of the three pre-allocated
        -- Order singletons. Boxed-key compares (Strings, lists, tuples,
        -- records, user comparables) keep falling through to the kernel call.
        -- kernel-opt-03 3a. Bool equality never needed the kernel: both sides are
        -- already i1 in SSA, and the boxed round-trip was pure arm-1/arm-2
        -- traffic. NOT config-gated -- one arith.xori is unconditionally better.
        ( "equal", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = False })

        ( "notEqual", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = True })

        -- kernel-opt-03 3b. Everything whose ABI is unconditionally !eco.value.
        -- MVar / MFunction are deliberately EXCLUDED (whitelist discipline, NOT
        -- a divergence fix -- arm 1 agrees with eqHelp on every shape, closures
        -- included, because `if (a == b) return true` precedes the tag switch):
        -- MVar _ CNumber may still resolve to an UNBOXED MInt/MFloat so its SSA
        -- type is not knowably !eco.value here, and MFunction's ABI may be a PAP.
        -- The config gate and the ACTUAL SSA-type test are applied by
        -- Expr.gateIntrinsic, which is the only place that can see them.
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

        -- String compares leave the boxed kernel root (Elm_Kernel_Utils_compare)
        -- for a typed op; the remaining boxed-key compares (lists, tuples,
        -- records, user comparables) still fall through to the kernel call.
        ( "compare", [ Mono.MString, Mono.MString ] ) ->
            Just (CompareToOrder { kind = CompareStringKind })

        -- ++ on statically-known String / List (kernel-opt-05). The residue --
        -- ANY MVar operand -- falls through to `_ -> Nothing` below and keeps
        -- emitting eco.call @Elm_Kernel_Utils_append verbatim. The config gate
        -- is applied by Expr.gateIntrinsic, so this module stays config-free.
        -- kernel-opt-06: String ordering joins `compare` at the intrinsic
        -- boundary. Structural orderings (lists, tuples, records, user
        -- comparables) still fall through to Elm_Kernel_Utils_{lt,le,gt,ge}.
        -- The cmp3 sign is UNCLAMPED, so the test is always against 0.
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

        -- Defensive: a mixed String/List pair violates `appendable a => a -> a
        -- -> a`. These arms keep such a pair on the polymorphic kernel, which
        -- still routes by runtime tag, rather than mis-dispatching it.
        ( "append", [ Mono.MString, Mono.MList _ _ ] ) ->
            Nothing

        ( "append", [ Mono.MList _ _, Mono.MString ] ) ->
            Nothing

        _ ->
            Nothing


charIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
charIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "toCode", [ Mono.MChar ] ) ->
            Just CharToInt

        ( "fromCode", [ Mono.MInt ] ) ->
            Just CharFromInt

        _ ->
            Nothing


stringIntrinsic : Name.Name -> List Mono.MonoType -> Maybe Intrinsic
stringIntrinsic name argTypes =
    case ( name, argTypes ) of
        ( "fromNumber", [ Mono.MInt ] ) ->
            Just StringFromInt

        ( "fromNumber", [ Mono.MFloat ] ) ->
            Just StringFromFloat

        -- kernel-opt-04. Requires the SATURATED shape: argTypes = [ MString ].
        -- A bare `Elm.Kernel.String.length` reference reaches generateVarKernel
        -- with argTypes = [] (Expr.elm:775) and therefore still falls through to
        -- the papCreate/kernel-decl path -- whitelist discipline, unlisted forms
        -- keep today's behaviour. The `stringLengthOp` config gate is applied by
        -- Expr.gateIntrinsic, so this module stays config-free.
        ( "length", [ Mono.MString ] ) ->
            Just StringLength

        _ ->
            Nothing


{-| MonoTypes whose ABI representation is unconditionally `!eco.value`
(REP\_ABI\_001) and whose kernel equality has no closure/primitive hazard.
Whitelist discipline: anything not listed keeps today's boxed kernel call.

The leading `Int` on the aggregate constructors is a STRUCTURAL HASH derived from
the payload, not an identity, so `x == y` on two structurally identical types is
`True` and the caller's `x == y` guard is a real same-type test.

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
            -- MInt/MFloat/MChar are handled by the primitive arms above and
            -- MBool by 3a; MVar/MFunction deliberately fall through.
            False


{-| `ArraySet` from a value type, declining when it is not concrete. Guessing
a kind for an unknown element is the defect `unsafeGet` above documents.
-}
concreteArraySet : Mono.MonoType -> Maybe Intrinsic
concreteArraySet elt =
    case elt of
        Mono.MVar _ _ ->
            Nothing

        _ ->
            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi elt })


{-| The element type of a `JsArray`, if it is recoverable.

**The constructor is `JsArray`, not `Array`.** `Elm.JsArray` declares
`type JsArray a`, so a monomorphized `JsArray Int` is
`MCustom _ (elm/core, Elm.JsArray) "JsArray" [ MInt ]` — as the LSS type dump
spells it, `Xelm core Elm.JsArray JsArray(I)`. Matching only `"Array"` (this
helper's original spelling, and the spelling in the intrinsic arms' comments)
therefore never matched anything: `singleton` silently declined to a kernel
call, and `unsafeGet` was left reading its element kind out of `resultType`,
which is the defect `plans/pre-mono-inline-simplify.md` §13 root-causes.

`"Array"` is kept because `Array.Array a` is also a one-argument type whose
argument is its element, so the arm is correct where it does fire.

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


jsArrayIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
jsArrayIntrinsic name argTypes resultType =
    case name of
        "empty" ->
            -- JsArray.empty : Array a — element kind is recovered later when
            -- the array is first written. No element-type attribute on the op.
            case argTypes of
                [] ->
                    Just ArrayEmpty

                _ ->
                    Nothing

        "singleton" ->
            -- JsArray.singleton : a -> Array a — element kind from the result
            -- (resultType = MCustom _ "JsArray" [elt]); robust when the value
            -- arg type is a polymorphic var.
            case ( argTypes, arrayElementType resultType ) of
                ( [ _ ], Just elt ) ->
                    Just (ArraySingleton { elementMlirType = MonoAbi.monoTypeToAbi elt })

                _ ->
                    Nothing

        "push" ->
            -- JsArray.push : a -> Array a -> Array a
            case argTypes of
                [ elt, _ ] ->
                    Just (ArrayPush { elementMlirType = MonoAbi.monoTypeToAbi elt })

                _ ->
                    Nothing

        "slice" ->
            -- JsArray.slice : Int -> Int -> Array a -> Array a
            case argTypes of
                [ Mono.MInt, Mono.MInt, _ ] ->
                    Just ArraySlice

                _ ->
                    Nothing

        "appendN" ->
            -- JsArray.appendN : Int -> Array a -> Array a -> Array a
            case argTypes of
                [ Mono.MInt, _, _ ] ->
                    Just ArrayAppendN

                _ ->
                    Nothing

        "length" ->
            -- JsArray.length : Array a -> Int
            case resultType of
                Mono.MInt ->
                    Just ArrayLength

                _ ->
                    Nothing

        "unsafeGet" ->
            -- JsArray.unsafeGet : Int -> Array a -> a — element kind from the
            -- ARRAY ARGUMENT, never from `resultType`.
            --
            -- `resultType` is the mono type of the call expression being
            -- emitted. Inlined into a caller that wants an `i64` that is `MInt`
            -- and the slot is read unboxed; but when this kernel is emitted as
            -- a STANDALONE SPEC the same expression is the spec's own declared
            -- result, which is boxed — so the spec read an unboxed Int slot as
            -- `!eco.value` and its caller then `eco.unbox`ed a raw int.
            -- SIGSEGV in the mutator, and only ever reachable when the inliner
            -- declined this callee (cost 1 against a default budget of 10, so
            -- it always inlined and the defect stayed hidden).
            -- `plans/pre-mono-inline-simplify.md` §13 has the two MLIR dumps.
            --
            -- The array argument is specialized per element type — a program
            -- with an `Array Int` and an `Array Float` emits four distinct
            -- `unsafeGet` specs — so the concrete element is available here.
            -- `singleton` above already takes this route for the same reason.
            --
            -- DECLINE when the element is not concrete rather than defaulting
            -- to a boxed kind: a boxed default standing in for an unknown
            -- element kind is exactly the defect above.
            case argTypes of
                [ Mono.MInt, arrayTy ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            -- The element is still a VARIABLE, which is how
                            -- `unsafeGet`'s own specialization arrives: its
                            -- array parameter is element-polymorphic, so one
                            -- spec body serves both boxed and unboxed element
                            -- kinds. An unboxed slot read cannot be emitted
                            -- for an unknown kind, so decline and let the
                            -- generic kernel call — which resolves the kind
                            -- from the array at runtime — do the read.
                            Nothing

                        Just elt ->
                            Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi elt })

                        Nothing ->
                            -- The array's element is not recoverable here.
                            -- `resultType` is then usable ONLY while it is a
                            -- concrete UNBOXED primitive: a widened result is
                            -- exactly the defect above, and an unboxed one
                            -- cannot have been widened.
                            if MonoAbi.monoTypeToAbi resultType == MonoAbi.ecoValue then
                                Nothing

                            else
                                Just (ArrayGet { elementMlirType = MonoAbi.monoTypeToAbi resultType })

                _ ->
                    Nothing

        "unsafeSet" ->
            -- JsArray.unsafeSet : Int -> a -> Array a -> Array a
            -- argTypes = [ MInt, elt, MCustom _ "JsArray" [elt] ]
            --
            -- The ARRAY argument is preferred over the value argument for the
            -- same reason as `unsafeGet` and `singleton`: it is specialized per
            -- element type, whereas the value argument can arrive as a
            -- polymorphic var. The value argument stays as the fallback because
            -- it was the only source before and is correct wherever it is
            -- concrete; if neither is, decline rather than guess a kind.
            case argTypes of
                [ Mono.MInt, elt, arrayTy ] ->
                    case arrayElementType arrayTy of
                        Just (Mono.MVar _ _) ->
                            -- Element-polymorphic array (see `unsafeGet`): fall
                            -- through to the value argument, which is a real
                            -- argument and may still be concrete.
                            concreteArraySet elt

                        Just fromArray ->
                            Just (ArraySet { elementMlirType = MonoAbi.monoTypeToAbi fromArray })

                        Nothing ->
                            -- Unlike `unsafeGet`, the value argument here IS
                            -- the element, and it is an ARGUMENT — never a
                            -- widened spec result — so it stays trustworthy.
                            concreteArraySet elt

                _ ->
                    Nothing

        _ ->
            Nothing


{-| `List.cons` (`::`) -> `eco.construct.list` (kernel-opt-01). The head slot's
2-bit kind is a HEAP layout decision (REP\_BOUNDARY\_002, invariants.csv:24) and must
reproduce the axis `kernelInstanceSymbol` uses for the `_Int`/`_Float`/`_Char` C
variants (Generate/MLIR/KernelAbi.elm:310-317). Anything outside that axis — an
unsettled `CNumber` head, a scalar tail/result (the `kernelDevirtShapeOk` hazard,
MonoSolver/Translate.elm:1869-1892), a non-binary application — DECLINES and keeps
today's kernel call (whitelist discipline).

The `Config`-level flag is applied by `Expr.consIntrinsicFor`, not here: this module
takes no `EcoConfig`, and the SSA-type admissibility test needs Expr's view anyway.

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


{-| The head's ABI type, or `Nothing` when the numeric axis is not settled.
`MVar _ CNumber` maps to `i64` under `monoTypeToAbi` (`Compiler.AST.MonoAbi`) but does
NOT match the `_Int` suffix arm, so today's site calls the BOXED root symbol with an
i64 head — an unsettled shape this intrinsic must not freeze into a heap layout.
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


boxedSlot : Mono.MonoType -> Bool
boxedSlot t =
    MonoAbi.isEcoValueType (MonoAbi.monoTypeToAbi t)


{-| Returns whether the type is a type variable (`MVar`). Used for relaxed
intrinsic matching when the result type might be polymorphic.
-}
isTypeVar : Mono.MonoType -> Bool
isTypeVar t =
    case t of
        Mono.MVar _ _ ->
            True

        _ ->
            False
