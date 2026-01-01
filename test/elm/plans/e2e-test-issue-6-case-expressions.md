# E2E Test Issue 6: Case Expressions Not Compiled Correctly

## Affected Tests (~20)

- CaseIntTest.elm
- CaseDefaultTest.elm
- CaseDeeplyNestedTest.elm
- CaseManyBranchesTest.elm
- CaseNestedTest.elm
- CaseListTest.elm
- CaseStringTest.elm
- CaseBoolTest.elm
- CaseMaybeTest.elm
- CaseCustomTypeTest.elm
- CustomTypeBasicTest.elm
- AnonymousFunctionTest.elm (lambda returning case result)
- RecursiveFactorialTest.elm (uses case)
- RecursiveFibonacciTest.elm (uses case)
- And others...

## Analysis

### Symptom
Case expressions always return the same value (`Ctor0`) regardless of the pattern being matched:

```
Expected: case1: "one"
Actual:   case1: Ctor0

Expected: day1: "Monday"
Actual:   day1: Ctor0
```

### Root Cause

Case expression bodies are not being generated. The compiler produces empty functions that return a default `Ctor0` construct.

Example from `CaseBoolTest.elm`:
```elm
boolToStr b =
    case b of
        True -> "yes"
        False -> "no"
```

Generated MLIR:
```mlir
"func.func"() ({
    ^bb0(%b: !eco.value):
      -- No branching logic!
      -- No check of %b's value!
      -- Just returns Ctor0 unconditionally:
      %1 = "eco.construct"() {size = 0, tag = 0} : () -> !eco.value
      "eco.return"(%1) : (!eco.value) -> ()
}) {sym_name = "CaseBoolTest_boolToStr_$_1"}
```

The function should:
1. Examine the value of `%b`
2. Branch based on whether it's True or False
3. Return the appropriate string literal

But instead it:
1. Ignores `%b` completely
2. Returns an empty constructor (tag=0, size=0) which displays as `Ctor0`

### What The Code Should Look Like

```mlir
"func.func"() ({
    ^bb0(%b: !eco.value):
      // Extract the boolean value (True=1, False=0)
      %tag = "eco.getTag"(%b) : (!eco.value) -> i64

      // Branch based on tag
      %is_true = "arith.cmpi" eq, %tag, 1 : i64
      "cf.cond_br"(%is_true, ^true_branch, ^false_branch)

    ^true_branch:
      %yes = "eco.string_literal"() {value = "yes"} : () -> !eco.value
      "eco.return"(%yes) : (!eco.value) -> ()

    ^false_branch:
      %no = "eco.string_literal"() {value = "no"} : () -> !eco.value
      "eco.return"(%no) : (!eco.value) -> ()
}) {sym_name = "CaseBoolTest_boolToStr_$_1"}
```

### Related: Custom Type Pattern Matching

Similar issue for custom types. Example from `CaseIntTest.elm`:
```elm
intToStr n =
    case n of
        1 -> "one"
        2 -> "two"
        _ -> "other"
```

Should generate:
1. Compare `n` to 1, branch if equal
2. Compare `n` to 2, branch if equal
3. Default branch for other values

But generates:
```mlir
%1 = "eco.construct"() {tag = 0} : () -> !eco.value  // Just Ctor0
```

### Compiler Investigation Needed

The issue is in the Guida compiler's code generation for case expressions. The compiler is:
1. Recognizing the case expression syntax
2. Creating a function with the right signature
3. **Not generating the pattern matching logic**
4. **Not generating the branch bodies**
5. Emitting a placeholder `Ctor0` return

## Proposed Solution

### Step 1: Identify Compiler Bug Location

Find where case expressions are handled in the Guida compiler. Look for:
- Pattern matching IR generation
- Decision tree or pattern matrix compilation
- Branch/switch statement emission

### Step 2: Fix Case Expression Compilation

The compiler needs to generate:

#### For Literal Patterns (Int, Char, String):
```mlir
// case n of 1 -> ... ; 2 -> ... ; _ -> ...
%is_1 = "arith.cmpi" eq, %n, 1 : i64
"cf.cond_br"(%is_1, ^case_1, ^check_2)

^check_2:
  %is_2 = "arith.cmpi" eq, %n, 2 : i64
  "cf.cond_br"(%is_2, ^case_2, ^default)

^case_1:
  // body for n == 1

^case_2:
  // body for n == 2

^default:
  // body for _
```

#### For Boolean Patterns:
```mlir
// case b of True -> ... ; False -> ...
// If b is i64: 1=True, 0=False
"cf.cond_br"(%b, ^true_case, ^false_case)
```

#### For Custom Type Patterns:
```mlir
// case shape of Circle r -> ... ; Rectangle w h -> ...
%tag = "eco.getTag"(%shape) : (!eco.value) -> i64
"cf.switch" %tag [
  0 -> ^circle_case,
  1 -> ^rectangle_case
] default: ^unreachable

^circle_case:
  %r = "eco.extractField"(%shape, 0) : (!eco.value) -> !eco.value
  // body using r

^rectangle_case:
  %w = "eco.extractField"(%shape, 0) : (!eco.value) -> !eco.value
  %h = "eco.extractField"(%shape, 1) : (!eco.value) -> !eco.value
  // body using w, h
```

#### For List Patterns:
```mlir
// case list of [] -> ... ; x :: xs -> ...
%is_nil = "eco.isNil"(%list) : (!eco.value) -> i1
"cf.cond_br"(%is_nil, ^empty_case, ^cons_case)

^cons_case:
  %x = "eco.head"(%list) : (!eco.value) -> !eco.value
  %xs = "eco.tail"(%list) : (!eco.value) -> !eco.value
  // body using x, xs
```

#### For Maybe Patterns:
```mlir
// case maybe of Just x -> ... ; Nothing -> ...
%tag = "eco.getTag"(%maybe) : (!eco.value) -> i64
%is_just = "arith.cmpi" eq, %tag, 1 : i64  // Just has tag 1
"cf.cond_br"(%is_just, ^just_case, ^nothing_case)

^just_case:
  %x = "eco.extractField"(%maybe, 0) : (!eco.value) -> !eco.value
  // body using x
```

### Step 3: Handle Nested Patterns

For nested patterns like:
```elm
case pair of
    (Just x, Just y) -> ...
    (Nothing, _) -> ...
    (_, Nothing) -> ...
```

Generate decision tree that checks outer structure first, then inner.

### Step 4: Handle Exhaustiveness

Ensure all patterns are covered. For non-exhaustive patterns, either:
- Compiler error (Elm's approach)
- Runtime error branch

## Implementation Steps

1. **Locate case expression handling** in Guida compiler
2. **Implement pattern compilation** for each pattern type:
   - Literal patterns (Int, Char, String)
   - Constructor patterns (Bool, Maybe, Result, Custom)
   - List patterns ([], ::)
   - Tuple patterns
   - Record patterns
   - Wildcard (_)
3. **Generate control flow** (cf.cond_br, cf.switch)
4. **Generate field extraction** for constructor patterns
5. **Handle nested patterns** recursively
6. **Test each pattern type** independently

## Files to Modify

- Guida compiler: case expression codegen
- Guida compiler: pattern matching IR
- Possibly add new eco dialect ops:
  - `eco.getTag` - extract constructor tag
  - `eco.extractField` - extract field from constructor
  - `eco.isNil` - check for empty list

## Estimated Complexity

High - This is a fundamental compiler feature. Pattern matching compilation is complex, especially for:
- Nested patterns
- Guard expressions (if Elm supports them)
- Efficient decision trees vs naive sequential checks

## Priority

**Critical** - Case expressions are fundamental to Elm. Without them, most programs can't work. This should be the highest priority fix.
