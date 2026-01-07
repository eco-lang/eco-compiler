# Canonicalize ID Tests Plan

This document outlines the test plan for `compiler/tests/Canonicalize/` which tests that the canonicalizer assigns unique IDs to all expressions and patterns.

## Overview

**Goal**: ~470 tests matching/exceeding the coverage of `compiler/tests/Type/`

**Test Approach**: Property-based testing using fuzzers to build `Compiler.AST.Source` AST nodes directly (not textual source code).

**Verification Logic** (applied to each test):
1. Canonicalization succeeds without errors
2. All expression IDs are unique (no duplicates)
3. All pattern IDs are unique (no duplicates)
4. All IDs are positive (no 0 or negative values)
5. Expression IDs and pattern IDs are disjoint (no overlap)

---

## Directory Structure

```
compiler/tests/Canonicalize/
├── Shared.elm                 -- Fuzzers and test infrastructure
├── LiteralTests.elm           -- 40 tests
├── ListTests.elm              -- 26 tests
├── TupleTests.elm             -- 28 tests
├── RecordTests.elm            -- 36 tests
├── FunctionTests.elm          -- 32 tests
├── CaseTests.elm              -- 32 tests
├── LetTests.elm               -- 30 tests
├── OperatorTests.elm          -- 20 tests (If expressions)
├── LetRecTests.elm            -- 22 tests
├── LetDestructTests.elm       -- 32 tests
├── BinopTests.elm             -- 52 tests
├── PatternArgTests.elm        -- 40 tests
├── AsPatternTests.elm         -- 26 tests
├── HigherOrderTests.elm       -- 30 tests
└── KernelTests.elm            -- 24 tests

compiler/tests/CanonicalizerIdTests.elm  -- Aggregator
```

**Total: 470 tests**

---

## Shared.elm - Fuzzers and Infrastructure

### Expression Fuzzers

```elm
-- Literal expression fuzzers
intExpr : Int -> Expr
intExprFuzzer : Fuzzer Expr
floatExpr : Float -> Expr
floatExprFuzzer : Fuzzer Expr
strExpr : String -> Expr
strExprFuzzer : Fuzzer Expr
chrExpr : Char -> Expr
chrExprFuzzer : Fuzzer Expr
unitExpr : Expr
boolExpr : Bool -> Expr
boolExprFuzzer : Fuzzer Expr

-- Container expression fuzzers
listExpr : List Expr -> Expr
listExprFuzzer : Fuzzer Expr -> Fuzzer Expr
tupleExpr : Expr -> Expr -> Expr
tupleExprFuzzer : Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr
tuple3Expr : Expr -> Expr -> Expr -> Expr
tuple3ExprFuzzer : Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr
recordExpr : List (Name, Expr) -> Expr
recordExprFuzzer : List (Name, Fuzzer Expr) -> Fuzzer Expr

-- Function expression fuzzers
lambdaExpr : List Pattern -> Expr -> Expr
lambdaExprFuzzer : Fuzzer (List Pattern) -> Fuzzer Expr -> Fuzzer Expr
callExpr : Expr -> List Expr -> Expr
callExprFuzzer : Fuzzer Expr -> Fuzzer (List Expr) -> Fuzzer Expr
varExpr : Name -> Expr
varExprFuzzer : Fuzzer Name -> Fuzzer Expr

-- Control flow expression fuzzers
ifExpr : Expr -> Expr -> Expr -> Expr
ifExprFuzzer : Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr
caseExpr : Expr -> List (Pattern, Expr) -> Expr
caseExprFuzzer : Fuzzer Expr -> Fuzzer (List (Pattern, Expr)) -> Fuzzer Expr
letExpr : List Def -> Expr -> Expr
letExprFuzzer : Fuzzer (List Def) -> Fuzzer Expr -> Fuzzer Expr
letRecExpr : List Def -> Expr -> Expr

-- Operator expression fuzzers
negateExpr : Expr -> Expr
negateExprFuzzer : Fuzzer Expr -> Fuzzer Expr
binopExpr : Name -> Expr -> Expr -> Expr
binopExprFuzzer : Fuzzer Name -> Fuzzer Expr -> Fuzzer Expr -> Fuzzer Expr
accessExpr : Expr -> Name -> Expr
accessExprFuzzer : Fuzzer Expr -> Fuzzer Name -> Fuzzer Expr
accessorExpr : Name -> Expr
updateExpr : Expr -> List (Name, Expr) -> Expr
updateExprFuzzer : Fuzzer Expr -> Fuzzer (List (Name, Expr)) -> Fuzzer Expr
parensExpr : Expr -> Expr
```

### Pattern Fuzzers

```elm
pVar : Name -> Pattern
pVarFuzzer : Fuzzer Name -> Fuzzer Pattern
pAnything : Pattern
pAnythingFuzzer : Fuzzer Pattern
pInt : Int -> Pattern
pIntFuzzer : Fuzzer Pattern
pStr : String -> Pattern
pStrFuzzer : Fuzzer Pattern
pChr : Char -> Pattern
pChrFuzzer : Fuzzer Pattern
pUnit : Pattern
pTuple : Pattern -> Pattern -> Pattern
pTupleFuzzer : Fuzzer Pattern -> Fuzzer Pattern -> Fuzzer Pattern
pTuple3 : Pattern -> Pattern -> Pattern -> Pattern
pTuple3Fuzzer : Fuzzer Pattern -> Fuzzer Pattern -> Fuzzer Pattern -> Fuzzer Pattern
pList : List Pattern -> Pattern
pListFuzzer : Fuzzer (List Pattern) -> Fuzzer Pattern
pCons : Pattern -> Pattern -> Pattern
pConsFuzzer : Fuzzer Pattern -> Fuzzer Pattern -> Fuzzer Pattern
pRecord : List Name -> Pattern
pRecordFuzzer : Fuzzer (List Name) -> Fuzzer Pattern
pAlias : Pattern -> Name -> Pattern
pAliasFuzzer : Fuzzer Pattern -> Fuzzer Name -> Fuzzer Pattern
pCtor : Name -> List Pattern -> Pattern
pCtorFuzzer : Fuzzer Name -> Fuzzer (List Pattern) -> Fuzzer Pattern
pParens : Pattern -> Pattern
```

### Definition Fuzzers

```elm
define : Name -> List Pattern -> Expr -> Def
defineFuzzer : Fuzzer Name -> Fuzzer (List Pattern) -> Fuzzer Expr -> Fuzzer Def
destruct : Pattern -> Expr -> Def
destructFuzzer : Fuzzer Pattern -> Fuzzer Expr -> Fuzzer Def
```

### Module Helpers

```elm
makeModule : Name -> Expr -> Source.Module
makeModuleWithDecls : List (Name, Expr) -> Source.Module
makeModuleWithDefs : List Def -> Expr -> Source.Module
```

### Comment Wrappers (for Source AST)

```elm
noComments : FComments
c1 : a -> C1 a           -- ([], a)
c2 : a -> C2 a           -- (([], []), a)
c1Eol : a -> C1Eol a     -- ([], Nothing, a)
c2Eol : a -> C2Eol a     -- (([], [], Nothing), a)
```

### Verification Functions

```elm
-- Main test expectation
expectUniqueIds : Source.Module -> Expectation

-- Run canonicalization and collect IDs
canonicalizeAndCollectIds : Source.Module -> Result Error (Set Int, Set Int)

-- ID collection from canonical AST
collectExprIds : Can.Expr -> Set Int
collectPatternIds : Can.Pattern -> Set Int
collectDefIds : Can.Def -> (Set Int, Set Int)
collectDeclIds : Can.Decl -> (Set Int, Set Int)

-- Verification predicates
allIdsPositive : Set Int -> Bool
allIdsUnique : List Int -> Bool
idsAreDisjoint : Set Int -> Set Int -> Bool
noIdIsZero : Set Int -> Bool
```

### Utility Fuzzers

```elm
nameFuzzer : Fuzzer Name
validIdentifierFuzzer : Fuzzer String
smallListFuzzer : Fuzzer a -> Fuzzer (List a)
nonEmptyListFuzzer : Fuzzer a -> Fuzzer (List a)
```

---

## Test Files - Detailed Breakdown

### 1. LiteralTests.elm (40 tests)

#### Int Literals (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Positive int | `intExpr 42` |
| 2 | Negative int | `intExpr -42` |
| 3 | Zero int | `intExpr 0` |
| 4 | Large positive int | `intExpr 2147483647` |
| 5 | Large negative int | `intExpr -2147483648` |
| 6 | Fuzzed int | `Fuzz.int` → `intExprFuzzer` |
| 7 | Int in parens | `parensExpr (intExpr 42)` |
| 8 | Int in nested parens | `parensExpr (parensExpr (intExpr 42))` |
| 9 | Small positive int | `intExpr 1` |
| 10 | Small negative int | `intExpr -1` |

#### Float Literals (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | Positive float | `floatExpr 3.14` |
| 12 | Negative float | `floatExpr -3.14` |
| 13 | Zero float | `floatExpr 0.0` |
| 14 | Small float | `floatExpr 0.001` |
| 15 | Large float | `floatExpr 1.0e10` |
| 16 | Negative large float | `floatExpr -1.0e10` |
| 17 | Fuzzed float | `Fuzz.float` → `floatExprFuzzer` |
| 18 | Float in parens | `parensExpr (floatExpr 3.14)` |
| 19 | Very small float | `floatExpr 1.0e-10` |
| 20 | Float with many decimals | `floatExpr 3.14159265359` |

#### String Literals (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 21 | Simple string | `strExpr "hello"` |
| 22 | Empty string | `strExpr ""` |
| 23 | String with spaces | `strExpr "hello world"` |
| 24 | String with escapes | `strExpr "hello\nworld\ttab"` |
| 25 | Unicode string | `strExpr "héllo wörld"` |
| 26 | Long string | `strExpr (String.repeat 100 "a")` |
| 27 | Fuzzed string | `Fuzz.string` → `strExprFuzzer` |
| 28 | String in parens | `parensExpr (strExpr "hello")` |

#### Char Literals (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 29 | Letter char | `chrExpr 'a'` |
| 30 | Digit char | `chrExpr '5'` |
| 31 | Symbol char | `chrExpr '@'` |
| 32 | Space char | `chrExpr ' '` |
| 33 | Fuzzed printable char | `charFuzzer` → `chrExprFuzzer` |
| 34 | Char in parens | `parensExpr (chrExpr 'x')` |

#### Unit and Bool (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 35 | Unit expression | `unitExpr` |
| 36 | Unit in parens | `parensExpr unitExpr` |
| 37 | True | `boolExpr True` |
| 38 | False | `boolExpr False` |
| 39 | Fuzzed bool | `Fuzz.bool` → `boolExprFuzzer` |
| 40 | Bool in parens | `parensExpr (boolExpr True)` |

---

### 2. ListTests.elm (26 tests)

#### Empty and Simple Lists (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Empty list | `listExpr []` |
| 2 | Single int list | `listExpr [intExpr 42]` |
| 3 | Two element int list | `listExpr [intExpr 1, intExpr 2]` |
| 4 | Three element int list | `listExpr [intExpr 1, intExpr 2, intExpr 3]` |
| 5 | Large int list (10 elements) | `listExpr [intExpr 1..10]` |
| 6 | Large int list (50 elements) | `listExpr [intExpr 1..50]` |
| 7 | Fuzzed int list | `Fuzz.list Fuzz.int` → `listExprFuzzer` |
| 8 | Empty list in parens | `parensExpr (listExpr [])` |

#### Typed Lists (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | Single float list | `listExpr [floatExpr 3.14]` |
| 10 | Fuzzed float list | `Fuzz.list Fuzz.float` → list |
| 11 | Single string list | `listExpr [strExpr "hello"]` |
| 12 | Fuzzed string list | `Fuzz.list Fuzz.string` → list |
| 13 | Single char list | `listExpr [chrExpr 'a']` |
| 14 | Bool list | `listExpr [boolExpr True, boolExpr False]` |
| 15 | Unit list | `listExpr [unitExpr, unitExpr]` |
| 16 | Mixed list (same type) | `listExpr [intExpr 1, intExpr 2, intExpr 3]` |

#### Nested Lists (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 17 | List of empty lists | `listExpr [listExpr [], listExpr []]` |
| 18 | List of int lists | `listExpr [listExpr [intExpr 1], listExpr [intExpr 2]]` |
| 19 | Deeply nested list (3 levels) | `listExpr [listExpr [listExpr [intExpr 1]]]` |
| 20 | Deeply nested list (4 levels) | 4-level nesting |
| 21 | Mixed depth nested list | different nesting depths |
| 22 | Fuzzed nested list | nested fuzzer |

#### Complex Element Lists (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 23 | List of tuples | `listExpr [tupleExpr ...]` |
| 24 | List of records | `listExpr [recordExpr ...]` |
| 25 | List with tuple elements fuzzed | `Fuzz.int, Fuzz.string` |
| 26 | List of lists of tuples | nested complex elements |

---

### 3. TupleTests.elm (28 tests)

#### 2-Tuples (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Pair of ints | `tupleExpr (intExpr 1) (intExpr 2)` |
| 2 | Pair of ints fuzzed | `Fuzz.int2` |
| 3 | Pair of floats | `tupleExpr (floatExpr 1.0) (floatExpr 2.0)` |
| 4 | Pair of floats fuzzed | `Fuzz.float2` |
| 5 | Pair of strings | `tupleExpr (strExpr "a") (strExpr "b")` |
| 6 | Pair of strings fuzzed | `Fuzz.string2` |
| 7 | Pair of bools | `tupleExpr (boolExpr True) (boolExpr False)` |
| 8 | Pair with units | `tupleExpr unitExpr unitExpr` |
| 9 | Pair with chars | `tupleExpr (chrExpr 'a') (chrExpr 'b')` |
| 10 | Pair in parens | `parensExpr (tupleExpr ...)` |

#### 3-Tuples (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | Triple of ints | `tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)` |
| 12 | Triple of ints fuzzed | `Fuzz.int3` |
| 13 | Triple of mixed types | int, string, float |
| 14 | Triple of mixed types fuzzed | `Fuzz.int, Fuzz.string, Fuzz.float` |
| 15 | Triple with bools | all bools |
| 16 | Triple with units | all units |
| 17 | Triple with chars | all chars |
| 18 | Triple in parens | `parensExpr (tuple3Expr ...)` |

#### Nested Tuples (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 19 | Tuple containing tuple (left) | `tupleExpr (tupleExpr ...) x` |
| 20 | Tuple containing tuple (right) | `tupleExpr x (tupleExpr ...)` |
| 21 | Both elements are tuples | nested both sides |
| 22 | Deeply nested tuple (3 levels) | 3-level nesting |
| 23 | Deeply nested tuple (4 levels) | 4-level nesting |
| 24 | Mixed nesting depths | asymmetric nesting |

#### Mixed Type Tuples (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 25 | Int and String pair | `tupleExpr (intExpr 1) (strExpr "a")` |
| 26 | Tuple with list | `tupleExpr listExpr strExpr` |
| 27 | Tuple with record | `tupleExpr recordExpr intExpr` |
| 28 | Tuple with char fuzzed | char fuzzer |

---

### 4. RecordTests.elm (36 tests)

#### Empty and Single Field (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Empty record | `recordExpr []` |
| 2 | Single int field | `recordExpr [("x", intExpr 1)]` |
| 3 | Single int field fuzzed | fuzzed int value |
| 4 | Single string field | `recordExpr [("name", strExpr "Alice")]` |
| 5 | Single string field fuzzed | fuzzed string value |
| 6 | Single float field | `recordExpr [("amount", floatExpr 1.5)]` |
| 7 | Single float field fuzzed | fuzzed float value |
| 8 | Single bool field fuzzed | fuzzed bool value |

#### Multi-Field Records (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | Two-field record | int + string fields |
| 10 | Two-field record fuzzed | fuzzed values |
| 11 | Three-field record | int + string + bool |
| 12 | Three-field record fuzzed | fuzzed values |
| 13 | Four-field record | 4 different types |
| 14 | Five-field record | 5 int fields |
| 15 | Many-field record (10 fields) | 10 fields |
| 16 | Record in parens | `parensExpr (recordExpr ...)` |

#### Nested Records (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 17 | Record containing record | single nested field |
| 18 | Record with multiple nested records | multiple nested fields |
| 19 | Deeply nested record (3 levels) | 3-level nesting |
| 20 | Deeply nested record (4 levels) | 4-level nesting |
| 21 | Record with list field | list as field value |
| 22 | Record with tuple field | tuple as field value |
| 23 | Record with list of records | list of records as field |
| 24 | Record with nested tuple and list | complex nesting |

#### Record Access (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 25 | Access single field | `accessExpr recordExpr "x"` |
| 26 | Access from multi-field record | access "y" from 3-field |
| 27 | Chained access | `accessExpr (accessExpr r "inner") "x"` |
| 28 | Access on variable | `accessExpr (varExpr "r") "x"` |
| 29 | Access with fuzzed field name | fuzzed valid field name |
| 30 | Access in parens | `parensExpr (accessExpr ...)` |

#### Accessor Functions (2 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 31 | Accessor function .x | `accessorExpr "x"` |
| 32 | Accessor function .name | `accessorExpr "name"` |

#### Record Update (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 33 | Update single field | `updateExpr varExpr [("x", intExpr 100)]` |
| 34 | Update multiple fields | update 2 fields |
| 35 | Update with fuzzed values | fuzzed new values |
| 36 | Update in parens | `parensExpr (updateExpr ...)` |

---

### 5. FunctionTests.elm (32 tests)

#### Lambda Expressions (12 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Identity lambda | `\x -> x` |
| 2 | Const lambda | `\x -> 42` |
| 3 | Two-arg lambda | `\x y -> x` |
| 4 | Three-arg lambda | `\x y z -> x` |
| 5 | Lambda with wildcard | `\_ -> 0` |
| 6 | Lambda with multiple wildcards | `\_ _ -> 0` |
| 7 | Nested lambda | `\x -> \y -> x` |
| 8 | Deeply nested lambda (3 levels) | 3-level nesting |
| 9 | Lambda returning tuple | body is tuple |
| 10 | Lambda returning record | body is record |
| 11 | Lambda returning list | body is list |
| 12 | Lambda in parens | `parensExpr (lambdaExpr ...)` |

#### Function Calls (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 13 | Apply identity to int | `callExpr identity [intExpr 42]` |
| 14 | Apply identity to string | `callExpr identity [strExpr "hi"]` |
| 15 | Apply const to two args | `callExpr const [intExpr 1, strExpr "x"]` |
| 16 | Partial application | `callExpr twoArgFn [oneArg]` |
| 17 | Immediate lambda application | `callExpr (lambdaExpr) [intExpr]` |
| 18 | Multiple argument call | `callExpr fn [a, b, c]` |
| 19 | Nested function calls | `callExpr f [callExpr g [x]]` |
| 20 | Call with complex argument | argument is tuple/record |
| 21 | Call in parens | `parensExpr (callExpr ...)` |
| 22 | Call with fuzzed args | fuzzed argument values |

#### Higher-Order Basics (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 23 | Apply function | `let apply f x = f x in ...` |
| 24 | Apply twice | `let applyTwice f x = f (f x)` |
| 25 | Compose functions | `compose f g x = f (g x)` |
| 26 | Function returning function | `makeAdder n = \x -> x` |
| 27 | Function as argument | pass lambda as arg |
| 28 | Return function from function | nested returns |

#### Negate (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 29 | Negate int | `negateExpr (intExpr 42)` |
| 30 | Negate int fuzzed | `Fuzz.int` → negate |
| 31 | Negate float fuzzed | `Fuzz.float` → negate |
| 32 | Double negate | `negateExpr (negateExpr ...)` |

---

### 6. CaseTests.elm (32 tests)

#### Case on Int (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Single int pattern | case n of 42 -> ...; _ -> ... |
| 2 | Multiple int patterns | case n of 0 -> ...; 1 -> ...; 2 -> ...; _ -> ... |
| 3 | Int binding to variable | case n of x -> x |
| 4 | Int with fuzzed value | fuzzed subject |
| 5 | Many int patterns (10) | 10 integer patterns |
| 6 | Case on int in parens | `parensExpr (caseExpr ...)` |

#### Case on String (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 7 | String patterns | case s of "hello" -> ...; "world" -> ... |
| 8 | Empty string pattern | case s of "" -> ... |
| 9 | String with fuzzed subject | fuzzed string |
| 10 | Multiple string patterns | many string cases |

#### Case on Bool (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | True/False patterns | case b of True -> ...; False -> ... |
| 12 | Bool fuzzed subject | `Fuzz.bool` subject |
| 13 | Bool with wildcard fallback | True -> ...; _ -> ... |
| 14 | Bool with variable binding | case b of x -> x |

#### Case on List (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 15 | Empty list pattern | case xs of [] -> ... |
| 16 | Cons pattern | case xs of h :: t -> h |
| 17 | Singleton list pattern | case xs of [only] -> only |
| 18 | Two-element list pattern | case xs of [a, b] -> ... |
| 19 | Cons with nested pattern | case xs of (a, b) :: t -> ... |
| 20 | Multiple list patterns | [] -> ...; [x] -> ...; _ -> ... |

#### Case on Tuple (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 21 | Pair pattern | case p of (a, b) -> a |
| 22 | Pair with literal patterns | case p of (1, 2) -> ... |
| 23 | Triple pattern | case t of (a, b, c) -> b |
| 24 | Nested tuple pattern | case p of ((a, b), c) -> ... |

#### Wildcard Patterns (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 25 | Wildcard-only case | case n of _ -> "anything" |
| 26 | Wildcard as default | case n of 0 -> ...; _ -> default |
| 27 | Multiple wildcards in tuple | case p of (_, _) -> ... |
| 28 | Wildcard with binding | case p of (x, _) -> x |

#### Nested Case (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 29 | Case in case branch | case (a, b) of (x, y) -> case y of ... |
| 30 | Deeply nested case (3 levels) | 3-level nesting |
| 31 | Case with nested pattern and nested case | complex nesting |
| 32 | Case on case result | case (case x of ...) of ... |

---

### 7. LetTests.elm (30 tests)

#### Basic Let (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Let binding int | let x = 42 in x |
| 2 | Let binding int fuzzed | `Fuzz.int` value |
| 3 | Let binding string | let str = "hi" in str |
| 4 | Let binding string fuzzed | `Fuzz.string` value |
| 5 | Let binding unit | let u = () in u |
| 6 | Let binding bool | let b = True in b |
| 7 | Let binding float fuzzed | `Fuzz.float` value |
| 8 | Let in parens | `parensExpr (letExpr ...)` |

#### Multiple Bindings (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | Chained let bindings | let x = 1 in let y = 2 in y |
| 10 | Three chained lets | let a = ... in let b = ... in let c = ... |
| 11 | Let using previous binding | let x = 1 in let y = x in y |
| 12 | Multiple independent bindings | let a = n in let b = m in (a, b) |
| 13 | Multiple independent fuzzed | fuzzed values |
| 14 | Let with tuple body | let a = 1 in let b = 2 in (a, b) |
| 15 | Let with record body | let a = 1 in {x = a} |
| 16 | Let with list body | let a = 1 in [a, a, a] |

#### Nested Let (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 17 | Deeply nested let (3 levels) | let a = let b = let c = ... |
| 18 | Deeply nested let (4 levels) | 4-level nesting |
| 19 | Let in function body | let f x = let y = x in y |
| 20 | Nested let in both def and body | complex nesting |
| 21 | Let in lambda body | \x -> let y = x in y |
| 22 | Let containing lambda | let f = \x -> x in f |

#### Let with Functions (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 23 | Let binding function | let f = \x -> x in f 42 |
| 24 | Let with function definition syntax | let f x = x in f 42 |
| 25 | Let with multi-arg function | let add x y = x in add 1 2 |
| 26 | Let with recursive call setup | preparing for recursion |

#### Shadowing (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 27 | Let shadowing outer binding | let x = 1 in let x = 2 in x |
| 28 | Lambda shadowing let binding | let x = 1 in (\x -> x) "shadow" |
| 29 | Multiple shadow levels | let x = 1 in let x = 2 in let x = 3 in x |
| 30 | Shadow with different types | let x = 1 in let x = "str" in x |

---

### 8. OperatorTests.elm (20 tests - If Expressions)

#### Simple If (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Simple if-then-else | if True then 1 else 0 |
| 2 | If with fuzzed condition | `Fuzz.bool` condition |
| 3 | If with int branches | both return int |
| 4 | If with string branches | both return string |
| 5 | If with int branches fuzzed | fuzzed branch values |
| 6 | If with string branches fuzzed | fuzzed branch values |

#### Nested If (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 7 | Nested if in then branch | if a then (if b then ...) else ... |
| 8 | Nested if in else branch | if a then ... else (if b then ...) |
| 9 | Nested if in both branches | nested in both |
| 10 | Deeply nested if (3 levels) | 3-level nesting |
| 11 | Deeply nested if (4 levels) | 4-level nesting |
| 12 | If in parens | `parensExpr (ifExpr ...)` |

#### Complex If (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 13 | If with variable condition | if x then ... else ... |
| 14 | If with call as condition | if (f x) then ... else ... |
| 15 | If with tuple results | branches return tuples |
| 16 | If with record results | branches return records |
| 17 | If with list results | branches return lists |
| 18 | If with lambda results | branches return lambdas |
| 19 | If with complex expressions | complex condition and branches |
| 20 | Chained else-if pattern | if a then ... else if b then ... else ... |

---

### 9. LetRecTests.elm (22 tests)

#### Single Recursive (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Self-recursive function | let f x = f x in f 0 |
| 2 | Recursive with base case | let f x = if ... then base else f ... |
| 3 | Recursive countdown | countdown n = if n <= 0 then 0 else countdown (n-1) |
| 4 | Recursive returning list | builds list recursively |
| 5 | Recursive with fuzzed base case | base returns fuzzed int |
| 6 | Recursive with accumulator | tail-recursive style |
| 7 | Recursive with multiple recursive calls | f x = f (f x) |
| 8 | Recursive in parens | `parensExpr (letRecExpr ...)` |

#### Mutual Recursion (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | Two mutually recursive | isEven/isOdd pattern |
| 10 | Three mutually recursive | a→b→c→a cycle |
| 11 | Mutual with different return types | Int ↔ String conversion |
| 12 | Mutual using result of each other | f x = g (g x), g x = f x |
| 13 | Four mutually recursive | 4-function cycle |
| 14 | Mutual with shared helper | a, b both call helper c |
| 15 | Mutual with different arities | different arg counts |
| 16 | Mutual fuzzed base cases | fuzzed values in base cases |

#### Nested LetRec (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 17 | LetRec inside LetRec | outer contains inner letrec |
| 18 | LetRec shadowing outer binding | inner f shadows outer f |
| 19 | Multiple nested LetRec levels (3) | 3-level nesting |
| 20 | Multiple nested LetRec levels (4) | 4-level nesting |
| 21 | LetRec inside regular let | let x = ... in letrec ... |
| 22 | Regular let inside LetRec | letrec f = ... in let x = ... |

---

### 10. LetDestructTests.elm (32 tests)

#### Tuple Destructuring (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Destruct 2-tuple | let (a, b) = (1, 2) in a |
| 2 | Destruct 2-tuple use both | let (a, b) = ... in (a, b) |
| 3 | Destruct 2-tuple fuzzed | fuzzed tuple elements |
| 4 | Destruct 3-tuple | let (a, b, c) = (1, 2, 3) in b |
| 5 | Destruct 3-tuple use all | let (a, b, c) = ... in (a, b, c) |
| 6 | Destruct 3-tuple fuzzed | fuzzed values |
| 7 | Destruct nested tuple | let ((a, b), c) = ... in a |
| 8 | Deeply nested destruct (3 levels) | (((a, b), c), d) |
| 9 | Destruct with wildcards | let (a, _) = ... in a |
| 10 | Destruct in parens | `parensExpr (letDestructExpr ...)` |

#### Record Destructuring (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | Record destruct single field | let { x } = {x=1} in x |
| 12 | Record destruct two fields | let { x, y } = ... in (x, y) |
| 13 | Record destruct three fields | let { a, b, c } = ... in ... |
| 14 | Record destruct fuzzed | fuzzed record fields |
| 15 | Record destruct partial | only extract some fields |
| 16 | Record destruct many fields (5) | 5 fields |
| 17 | Record destruct reordered | different order than definition |
| 18 | Record destruct with fuzzed names | valid field names |

#### List/Cons Destructuring (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 19 | Cons pattern destruct | let (h :: t) = ... in h |
| 20 | Cons with both bindings | let (h :: t) = ... in (h, t) |
| 21 | List pattern destruct | let [a, b] = ... in a |
| 22 | List pattern three elements | let [a, b, c] = ... in b |
| 23 | Nested cons pattern | let ((x, y) :: t) = ... in x |
| 24 | Mixed list patterns | let [a, b] = ... in ... |

#### Complex Destructuring (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 25 | Mixed nested destructuring | let ((a, b), {c}) = ... |
| 26 | Destruct in lambda | \(a, b) -> a |
| 27 | Destruct in function def | foo (a, b) = a |
| 28 | Chained destructuring lets | let (a, b) = ... in let (c, d) = ... |
| 29 | Destruct with as-pattern | let ((a, b) as pair) = ... |
| 30 | Destruct with multiple wildcards | let (_, _, c) = ... in c |
| 31 | Deeply nested mixed | ((a, {b}), [c, d]) |
| 32 | Complex fuzzed destructuring | fuzzed complex patterns |

---

### 11. BinopTests.elm (52 tests)

#### Arithmetic Int (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Int addition | 1 + 2 |
| 2 | Int subtraction | 5 - 3 |
| 3 | Int multiplication | 4 * 5 |
| 4 | Int division | 10 // 2 |
| 5 | Int modulo | 10 % 3 |
| 6 | Int addition fuzzed | `Fuzz.int2` for a + b |
| 7 | Int subtraction fuzzed | `Fuzz.int2` for a - b |
| 8 | Int multiplication fuzzed | `Fuzz.int2` for a * b |
| 9 | Binop in parens | `parensExpr (binopExpr ...)` |
| 10 | Int power | 2 ^ 3 |

#### Arithmetic Float (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | Float addition | 1.5 + 2.5 |
| 12 | Float subtraction | 5.0 - 2.5 |
| 13 | Float multiplication | 3.14 * 2.0 |
| 14 | Float division | 10.0 / 4.0 |
| 15 | Float addition fuzzed | `Fuzz.float2` |
| 16 | Float subtraction fuzzed | `Fuzz.float2` |
| 17 | Float multiplication fuzzed | `Fuzz.float2` |
| 18 | Float division fuzzed | `Fuzz.float2` |

#### Comparison (12 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 19 | Int less-than | 1 < 2 |
| 20 | Int greater-than | 5 > 3 |
| 21 | Int less-than-or-equal | 3 <= 3 |
| 22 | Int greater-than-or-equal | 4 >= 4 |
| 23 | Int equality | 5 == 5 |
| 24 | Int not-equal | 1 /= 2 |
| 25 | Int comparison fuzzed | `Fuzz.int2` for a < b |
| 26 | Float comparison | 1.5 < 2.5 |
| 27 | String comparison | "a" < "b" |
| 28 | Char comparison | 'a' < 'b' |
| 29 | Bool equality | True == True |
| 30 | Comparison fuzzed various types | fuzzed comparisons |

#### Boolean (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 31 | Boolean AND | True && False |
| 32 | Boolean OR | False \|\| True |
| 33 | Boolean AND fuzzed | `Fuzz.bool2` for a && b |
| 34 | Boolean OR fuzzed | `Fuzz.bool2` for a \|\| b |
| 35 | Chained AND | a && b && c |
| 36 | Chained OR | a \|\| b \|\| c |
| 37 | Mixed AND/OR | a && b \|\| c |
| 38 | NOT with AND | not a && b |

#### Append/String (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 39 | String append | "hello" ++ " world" |
| 40 | String append fuzzed | `Fuzz.string2` for a ++ b |
| 41 | String append chained | a ++ b ++ c |
| 42 | List append | [1] ++ [2] |
| 43 | List append fuzzed | fuzzed lists |
| 44 | Empty list append | [] ++ xs |

#### Nested/Complex (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 45 | Nested int arithmetic | (1 + 2) * 3 |
| 46 | Chained comparisons | (1 < 2) && (2 < 3) |
| 47 | Mixed arithmetic and comparison | (1 + 2) > 0 |
| 48 | Binop in let binding | let x = 1 + 2 in x > 0 |
| 49 | Binop with variable operands | let a = 1 in let b = 2 in a + b |
| 50 | Complex nested arithmetic fuzzed | (a + b) * c |
| 51 | Deeply nested binops (4 levels) | ((a + b) * c) - d |
| 52 | Mixed type binops in expression | complex expression |

---

### 12. PatternArgTests.elm (40 tests)

#### Top-Level Function Patterns (12 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Function with tuple pattern | foo (a, b) = a |
| 2 | Function with 3-tuple pattern | foo (a, b, c) = b |
| 3 | Function with record pattern | foo { x } = x |
| 4 | Function with record pattern (2 fields) | foo { x, y } = (x, y) |
| 5 | Function with nested pattern | foo ((a, b), c) = a |
| 6 | Function with deeply nested pattern | foo (((a, b), c), d) = a |
| 7 | Function with multiple pattern args | foo (a, b) (c, d) = (a, c) |
| 8 | Function with mixed patterns | foo (a, b) { x } = (a, x) |
| 9 | Function with list pattern | foo [a, b] = a |
| 10 | Function with cons pattern | foo (h :: t) = h |
| 11 | Function with wildcard in pattern | foo (a, _) = a |
| 12 | Function with unit pattern | foo () = 42 |

#### Lambda Patterns (12 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 13 | Lambda with tuple pattern | \(a, b) -> a |
| 14 | Lambda with 3-tuple pattern | \(a, b, c) -> b |
| 15 | Lambda with record pattern | \{ x, y } -> (x, y) |
| 16 | Lambda with nested pattern | \((a, b), c) -> a |
| 17 | Lambda with deeply nested pattern | \(((a, b), c), d) -> a |
| 18 | Lambda with wildcard in pattern | \(a, _) -> a |
| 19 | Lambda with unit pattern | \() -> 42 |
| 20 | Lambda with list pattern | \[a, b] -> (a, b) |
| 21 | Lambda with cons pattern | \(h :: t) -> h |
| 22 | Lambda multiple pattern args | \(a, b) (c, d) -> (a, c) |
| 23 | Lambda with mixed patterns | \(a, b) { x } -> (a, x) |
| 24 | Lambda in parens with pattern | parens wrapping |

#### Let Function Patterns (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 25 | Let function with tuple pattern | let f (a, b) = a in f |
| 26 | Let function with record pattern | let f { x } = x in f |
| 27 | Let function with nested pattern | let f ((a, b), c) = a in f |
| 28 | Let function with multiple patterns | let f (a, b) (c, d) = ... |
| 29 | Let function with deeply nested | let f (((a, b), c), d) = a |
| 30 | Let function with cons pattern | let f (h :: t) = h in f |
| 31 | Let function with wildcard | let f (a, _) = a in f |
| 32 | Let function with mixed | let f (a, b) { x } = ... |
| 33 | Let function with list pattern | let f [a, b] = a in f |
| 34 | Let function with unit pattern | let f () = 42 in f |

#### Complex Pattern Args (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 35 | Pattern with literal in arg | \(0, b) -> b (if supported) |
| 36 | Multiple functions with patterns | let f (a, b) = ... in let g (c, d) = ... |
| 37 | Nested functions with patterns | let outer (a, b) = let inner (c, d) = ... |
| 38 | Pattern args with fuzzed structure | fuzzed pattern shapes |
| 39 | Pattern args in recursive function | letrec with pattern args |
| 40 | Complex pattern arg chain | multiple complex patterns |

---

### 13. AsPatternTests.elm (26 tests)

#### Simple As-Patterns (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | As-pattern on tuple | let ((a, b) as pair) = (1, 2) in pair |
| 2 | As-pattern using alias only | let (... as pair) = ... in pair |
| 3 | As-pattern using both | let ((a, b) as pair) = ... in (a, pair) |
| 4 | As-pattern on 3-tuple | ((a, b, c) as triple) = ... |
| 5 | As-pattern on record | let ({ x, y } as rec) = ... in rec |
| 6 | As-pattern on list pattern | let ([a, b] as lst) = ... in lst |
| 7 | As-pattern on cons | let ((h :: t) as lst) = ... in lst |
| 8 | As-pattern in parens | parens wrapping |

#### As-Patterns in Case (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | As-pattern in case | case p of ((a, b) as pair) -> pair |
| 10 | As-pattern in multiple branches | as-pattern in each branch |
| 11 | Different as-patterns per branch | different aliases |
| 12 | As-pattern with other patterns | mix of as and regular |
| 13 | Nested as-pattern in case | ((a as x, b) as pair) -> ... |
| 14 | As-pattern with wildcard | (_ as x) -> x |

#### As-Patterns in Lambda/Functions (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 15 | As-pattern in lambda | \((a, b) as pair) -> pair |
| 16 | As-pattern in function arg | foo ((a, b) as pair) = pair |
| 17 | As-pattern in let function | let f ((a, b) as pair) = pair in f |
| 18 | Multiple as-patterns in args | foo (x as a) (y as b) = (a, b) |
| 19 | As-pattern with other arg patterns | foo ((a, b) as pair) { x } = ... |
| 20 | Nested as in function | foo (((a, b) as inner) as outer) = ... |

#### Nested As-Patterns (6 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 21 | Nested as-pattern (2 levels) | (((a, b) as inner) as outer) |
| 22 | Nested as-pattern (3 levels) | 3-level nesting |
| 23 | Multiple as-patterns in tuple | ((a as x), (b as y)) |
| 24 | As-pattern with wildcard inner | ((_ as x), b) |
| 25 | As-pattern chain | deeply nested aliases |
| 26 | Complex nested as-pattern | ((((a, b) as p1) as p2), c as p3) |

---

### 14. HigherOrderTests.elm (30 tests)

#### Functions as Arguments (10 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Apply function to value | let apply f x = f x in ... |
| 2 | Apply twice | let applyTwice f x = f (f x) |
| 3 | Apply n times pattern | applyN n f x |
| 4 | Two function arguments | let applyBoth f g x = g (f x) |
| 5 | Map-like function | let map f x = f x in map |
| 6 | Filter-like function | let filter pred x = ... |
| 7 | Fold-like function | let foldl f acc x = ... |
| 8 | Function composition | let compose f g x = f (g x) |
| 9 | Compose three functions | let compose3 f g h x = f (g (h x)) |
| 10 | Pipeline operator pattern | let pipe x f = f x |

#### Function Returning Function (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 11 | Simple function returning function | let makeAdder n = \x -> n + x |
| 12 | Curried binary function | let add a b = a + b in add |
| 13 | Curried ternary function | let add3 a b c = a + b + c |
| 14 | Nested function returns | \x -> \y -> \z -> (x, y, z) |
| 15 | Function factory | let makeFn config = \x -> ... |
| 16 | Closure capturing | let outer n = let inner x = n + x in inner |
| 17 | Multiple closures | let outer n = (let f x = n + x in f, let g y = n * y in g) |
| 18 | Partial application | let add a b = a + b in add 5 |

#### Composition and Transformation (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 19 | Flip function | let flip f x y = f y x |
| 20 | Const function | let const x y = x |
| 21 | Identity function | let id x = x |
| 22 | Curry function pattern | curry and uncurry |
| 23 | On combinator | let on f g x y = f (g x) (g y) |
| 24 | Fix-point combinator style | self-application pattern |
| 25 | Applicative pattern | let ap f x = f x |
| 26 | Monadic bind pattern | let bind m f = ... |

#### Complex Higher-Order (4 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 27 | Nested higher-order | apply (apply f) x |
| 28 | Higher-order with polymorphic use | same function at different types |
| 29 | Higher-order in let rec | recursive higher-order |
| 30 | Complex HOF chain | compose multiple HOFs |

---

### 15. KernelTests.elm (24 tests)

#### Simple Kernel References (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 1 | Simple typed kernel assignment | kernel function reference |
| 2 | Kernel with simple type Int -> Int | typed kernel |
| 3 | Kernel with polymorphic type a -> a | polymorphic kernel |
| 4 | Kernel with two-arg type | a -> b -> c |
| 5 | Kernel with three-arg type | a -> b -> c -> d |
| 6 | Kernel with list type | List a -> List b |
| 7 | Kernel with tuple type | (a, b) -> c |
| 8 | Kernel in parens | `parensExpr kernelExpr` |

#### Kernel Calling (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 9 | Kernel in let binding | let f = kernel in f 42 |
| 10 | Kernel called directly | kernel 42 |
| 11 | Kernel with multiple args | kernel a b |
| 12 | Kernel partial application | kernel 42 (partial) |
| 13 | Kernel in expression | 1 + kernel 2 |
| 14 | Kernel with list argument | kernel [1, 2, 3] |
| 15 | Kernel with tuple argument | kernel (1, 2) |
| 16 | Kernel with record argument | kernel {x = 1} |

#### Kernel Wrappers and Composition (8 tests)
| # | Test Name | Description |
|---|-----------|-------------|
| 17 | Wrapper around kernel | let wrapper x = kernel x |
| 18 | Wrapper with preprocessing | let wrapper x = kernel (x + 1) |
| 19 | Wrapper with postprocessing | let wrapper x = (kernel x) + 1 |
| 20 | Kernel as higher-order argument | map kernel [1, 2, 3] |
| 21 | Nested kernel calls | kernel (kernel x) |
| 22 | Multiple kernel calls | kernel1 x + kernel2 y |
| 23 | Kernel in case branch | case x of ... -> kernel y |
| 24 | Kernel in if branch | if cond then kernel x else y |

---

## Summary

| Test Suite | # Tests |
|------------|---------|
| LiteralTests | 40 |
| ListTests | 26 |
| TupleTests | 28 |
| RecordTests | 36 |
| FunctionTests | 32 |
| CaseTests | 32 |
| LetTests | 30 |
| OperatorTests | 20 |
| LetRecTests | 22 |
| LetDestructTests | 32 |
| BinopTests | 52 |
| PatternArgTests | 40 |
| AsPatternTests | 26 |
| HigherOrderTests | 30 |
| KernelTests | 24 |
| **Total** | **470** |

---

## Implementation Order

1. **Shared.elm** - Core infrastructure (fuzzers, helpers, verification)
2. **LiteralTests.elm** - Simplest expressions, validate setup
3. **ListTests.elm** - Container basics
4. **TupleTests.elm** - Container basics
5. **RecordTests.elm** - Records with access/update
6. **FunctionTests.elm** - Lambdas and calls
7. **OperatorTests.elm** - If expressions
8. **BinopTests.elm** - Binary operators
9. **LetTests.elm** - Let bindings
10. **CaseTests.elm** - Pattern matching
11. **LetDestructTests.elm** - Destructuring
12. **PatternArgTests.elm** - Pattern arguments
13. **AsPatternTests.elm** - Alias patterns
14. **LetRecTests.elm** - Recursion
15. **HigherOrderTests.elm** - HOFs
16. **KernelTests.elm** - Kernel functions
17. **CanonicalizerIdTests.elm** - Aggregator

---

## Notes

- All tests use property-based fuzzing with `Compiler.AST.Source` builders
- Tests verify ID uniqueness, positivity, and disjointness
- Comment wrappers (`C1`, `C2`, etc.) use empty comments for simplicity
- Each test file has corresponding test in `Type/Constrain/` for reference
