# Elm Style Guide

## Philosophy

Elm's power comes from composing simple, orthogonal features. Start simple and let complexity emerge - don't anticipate it. Most applications never need advanced patterns.

---

## Design Patterns

### Life of a File

Start in a single file with `Model`, `Msg`, `update`, and `view`. Don't prematurely modularize. Refactor when the shape emerges naturally.

### Smallest Type

Use extensible records so functions only require fields they use. Avoid stringly-typed fields - prefer custom types.

```elm
-- Good: requires only what it uses
greet : { r | name : String } -> String

-- Good: type-safe roles
type Role = Admin | Member | Guest
```

### Opaque Types

Hide constructors to create abstraction barriers. Essential for packages; beneficial for applications.

```elm
module UserId exposing (UserId, fromString, toString)

type UserId = UserId String  -- Constructor not exposed
```

### State Machines

Model state explicitly with custom types. Excel for async operations, UI flows, and discrete state logic.

```elm
type RemoteData data
    = NotAsked | Loading | Success data | Failure Http.Error
```

### Parse Don't Validate

Parse untrusted input into domain types at boundaries. Validation defers problems; parsing solves them.

### Flat State

Elm is single-threaded with immutable data - safe to share state. Build applications flat; use extensible records to slice the model for sub-modules.

```elm
-- Module function works with any record containing these fields
UserSettings.view : { r | userName : String, theme : Theme } -> Html msg
```

### Nested TEA

Only use nested TEA for N similar components with independent state and effects. For single-use constructs, break out functions instead.

### Anti-Patterns

- **Actor Model Fetish**: Avoid excessive message passing between modules. Prefer flat state and function composition.
- **IO Monad Fetish**: Don't over-abstract side effects. Use `Cmd` directly; encapsulate by constraining `Msg` exposure.

---

## Formatting

- **Indentation**: 4 spaces, no tabs
- **Type annotations**: Always provide for top-level definitions
- **Imports**: Order by standard library, external packages, project modules
- **Pipelines**: Each step on its own line
- **Records**: Multi-line with fields aligned, leading commas

```elm
module Compiler.AST.Canonical exposing
    ( Module(..), ModuleData, Exports(..)
    , Expr, ExprInfo, Expr_(..)
    )

import Dict exposing (Dict)
import Json.Decode as Decode
import Page.Home

type alias Model =
    { userId : String
    , userName : String
    }

result =
    input
        |> String.trim
        |> String.toLower
```

---

## Comments

Comments should be proper English sentences ending with a period. Be accurate and concise. Only comment things that a code reader should really have brought to their attention.

### What to Comment

- **Module purpose**: Every module should have a doc comment explaining its role.
- **Exposed function purpose**: Every exposed function should have a doc comment describing what it does.
- **Type purpose**: Custom types and type aliases should have doc comments explaining their role.
- **Field purpose**: Record fields should have comments explaining their role when not self-evident.
- **Non-obvious code**: Add inline comments where logic is not self-evident.
- **Pre-conditions**: Mention when a function requires certain conditions or has constraints.
- **Caching/optimization notes**: Explain why data is structured a certain way when it's for performance.

### Module Documentation

Use `{-| ... -}` at the top of the module after the `exposing` clause:

```elm
module UserId exposing (UserId, fromString, toString)

{-| Opaque user identifier with validation.

This module provides a validated UserId type that guarantees
non-empty identifiers throughout the application.


# Creation

@docs UserId, fromString


# Conversion

@docs toString

-}
```

### Function Documentation

Place `{-| ... -}` immediately before exposed functions:

```elm
{-| Parse a string into a UserId.

Returns Nothing if the string is empty.

    fromString "abc123" == Just (UserId "abc123")
    fromString ""       == Nothing

-}
fromString : String -> Maybe UserId
fromString str =
    ...
```

For internal (unexposed) functions, use `--` comments when needed:

```elm
-- Normalize the ID by trimming whitespace and lowercasing.
normalizeId : String -> String
normalizeId str =
    str |> String.trim |> String.toLower
```

### Type Documentation

Document custom types and type aliases:

```elm
{-| An expression with source location annotation and unique ID.
-}
type alias Expr =
    A.Located ExprInfo


{-| Expression variants in the canonical AST.

Many variants include cached type annotations for efficient type inference.

-}
type Expr_
    = VarLocal Name
    | VarTopLevel IO.Canonical Name
    | ...
```

### Field Comments

Use `--` comments after fields when their purpose is not self-evident:

```elm
type alias Model =
    { userId : String           -- Unique identifier from auth system.
    , displayName : String      -- User-chosen name for UI display.
    , sessionToken : String     -- JWT token, expires after 24 hours.
    , lastActivity : Time.Posix -- Used for idle timeout calculation.
    }
```

For complex records, use comments above groups of related fields:

```elm
type alias Config =
    { -- Server connection
      apiUrl : String
    , timeout : Int

    -- Feature flags
    , enableBeta : Bool
    , debugMode : Bool
    }
```

### Custom Type Variant Comments

Add comments for variants when their meaning is not obvious:

```elm
type RemoteData data
    = NotAsked   -- Initial state, no request made yet.
    | Loading    -- Request in flight.
    | Success data
    | Failure Http.Error


type Color
    = White -- Not yet marked (potential garbage).
    | Grey  -- Marked but children not yet scanned.
    | Black -- Marked and all children scanned.
```

### Section Headers

Use comment headers to organize code within a file:

```elm
-- ====== Expressions ======


type alias Expr =
    A.Located ExprInfo


-- ====== Types ======


type Type
    = TVar Name
    | TLambda Type Type
```

Or simpler for TEA modules:

```elm
-- MODEL


type alias Model =
    ...


-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update =
    ...


-- VIEW


view : Model -> Html Msg
view =
    ...
```

### Internal Implementation Notes

Use `{- ... -}` for multi-line internal notes not intended for documentation:

```elm
{- Internal note: Creating a canonical AST means finding the home module
   for all variables. So if you have L.map, you need to figure out that
   it is from the elm/core package in the List module.

   In later phases (e.g. type inference, exhaustiveness checking, optimization)
   you need to look up additional info from these modules. What is the type?
   What are the alternative type constructors? These lookups can be quite costly,
   especially in type inference.
-}
```

### Cache Markers

Mark cached data with comments explaining why it exists:

```elm
type Expr_
    = VarOperator Name IO.Canonical Name Annotation -- CACHE real name for optimization
    | Binop Name IO.Canonical Name Annotation Expr Expr -- CACHE real name for optimization
    | ...
```

Or more explicitly:

```elm
type alias CtorData =
    { name : Name
    , index : Index.ZeroBased
    , numArgs : Int
    , allCtors : List Name -- CACHE for exhaustiveness checking
    , annotation : Annotation -- CACHE for type inference
    }
```

---

## Summary

1. Start simple (Life of a File)
2. Keep types small and functions focused
3. Use opaque types for encapsulation
4. Model state explicitly with custom types
5. Parse at boundaries, validate never
6. Keep state flat, slice with extensible records
7. Avoid Actor Model and IO Monad patterns
