# Plan: Disablable commands — disable `repl`/`test`, remove `format`

## Overview

Instead of commenting out `repl`/`test` (which would leave `Terminal/Repl.elm`,
`Terminal/Test.elm` and their helpers unreferenced, so elm-review's `NoUnused.*` rules
would demand their deletion), we add a first-class **enabled/disabled** semantic to the
command list. A disabled command's code stays fully referenced and type-checked, but it
is hidden from the CLI: not routable, not shown in `--help`/overview.

`format` is genuinely going away, so it is fully removed.

## Why a "disabled" marker instead of comments

elm-review reachability is **static**: a top-level value is "used" if it is referenced
from another reachable top-level, regardless of runtime behavior. So if the command
list still mentions `repl` (even via a marker that discards it), then:

- `app` → `repl` → `interpreter` stays reachable, and
- `repl`'s body still references `Repl.run` / `Repl.Flags`, keeping the
  `Terminal.Repl` import and module alive.

Same chain for `test` → `int` / `parseInt` and the `Terminal.Test` module. So nothing
is reported unused, yet the command never appears at runtime.

## Design

Add the semantic to the terminal framework so `app` itself owns it (the single consumer
of the command list). Two trivial combinators tag each registration, and `app` filters.

### 1. `compiler/src/Terminal/Terminal.elm`

**Exposing list** — add `enabled` and `disabled`:

```elm
module Terminal.Terminal exposing
    ( app
    , enabled, disabled
    , flags, noFlags, more, flag, onOff
    , noArgs, zeroOrMore, oneOf, require0, require1, require2, require3
    )
```

**New combinators:**

```elm
{-| Register a command as active in the CLI. -}
enabled : Command -> Maybe Command
enabled command =
    Just command


{-| Register a command as disabled.

The command's implementation is retained and remains statically referenced (so it is
not reported as dead code), but it is hidden from the CLI: it cannot be invoked and does
not appear in `--help` or the overview. Flip back to `enabled` to restore it.

-}
disabled : Command -> Maybe Command
disabled _ =
    Nothing
```

**Change `app` to take registrations and filter them** (signature change is safe —
`Terminal/Main.elm` is the only caller, confirmed by grep):

```elm
app : D.Doc -> D.Doc -> List (Maybe Command) -> Task Never ()
app intro outro registrations =
    let
        commands : List Command
        commands =
            List.filterMap identity registrations
    in
    Utils.envGetArgs
        |> Task.andThen
            (\argStrings ->
                ...  -- body unchanged; keeps using `commands`
            )
```

The rest of `app`'s body is unchanged — both the routing (`List.find ... commands`,
`exitWithUnknown ... (List.map toName commands)`) and overview
(`exitWithOverview intro outro commands`) now operate on the already-filtered list, so
disabled commands disappear from every code path automatically.

Note: `List.filterMap` resolves to core `List` (the file aliases
`import List.Extra as List`, but `filterMap` exists only in core, so it's unambiguous —
same pattern as the existing `List.concatMap` usage).

No change needed to `Terminal/Terminal/Internal.elm` — `Command`/`CommandData` are
untouched, so none of the nine command record literals need editing.

### 2. `compiler/src/Terminal/Main.elm`

**`app` registration list** (lines 46–59) becomes:

```elm
app : Task Never ()
app =
    Terminal.app intro
        outro
        [ Terminal.disabled repl
        , Terminal.enabled init
        , Terminal.enabled make
        , Terminal.enabled install
        , Terminal.enabled uninstall
        , Terminal.enabled bump
        , Terminal.enabled diff
        , Terminal.disabled test
        ]
```

(`format` removed from the list entirely.)

- `repl` definition (lines 151–205) and `interpreter` helper (208–215): **kept as-is**.
- `test` definition (lines 713–766), `int` (769–776), `parseInt` (779–781): **kept
  as-is**.
- Imports `Terminal.Repl as Repl` (line 27) and `Terminal.Test as Test` (line 32):
  **kept** (still used by the retained definitions).

## Code to remove (`format`)

- `Terminal/Main.elm`:
  - `format` registration in the list (was line 57) — omitted above.
  - `format : Terminal.Command` definition (lines 643–696) — delete.
  - `output : Terminal.Parser` helper (lines 699–706) — delete (format-only; `make`
    uses `Make.output`, a different parser from the `Make` module).
  - import `Terminal.Format as Format` (line 23) — delete.
- `Terminal/Format.elm` — see Open Question (default: keep on disk).

## Resulting CLI

Active commands: `init, make, install, uninstall, bump, diff`.
`repl` and `test` are defined, referenced, and disabled (invisible until re-enabled).
`format` is gone.

## Verification

1. Build: `cmake --build build --target full` (full rebuild to avoid stale `.mlir`).
2. Run elm-review (the project's inspection) and confirm **no** `NoUnused` reports for
   `Terminal.Repl`, `Terminal.Test`, `interpreter`, `int`, `parseInt`, or the `Repl`/
   `Test` imports.
3. `eco --help` / no-arg overview lists only `init, make, install, uninstall, bump,
   diff`.
4. `eco repl`, `eco test`, `eco format` all report unknown-command errors.
5. Re-enabling check (optional): flipping `disabled repl` → `enabled repl` restores it
   with no other edits.

## Open question

- **`Terminal/Format.elm`**: with the import removed, the module becomes orphaned.
  elm-review's `NoUnused.Modules` will then flag it. Options:
  - **(default in this plan)** Keep wiring removed but also **delete `Terminal/Format.elm`**
    to keep elm-review clean — since `format` is meant to be *completely removed*, full
    deletion is the consistent choice.
  - Keep the file and add an elm-review ignore — not recommended for a removed feature.

  Recommendation: **delete `Terminal/Format.elm`** as part of the removal. Confirm.
