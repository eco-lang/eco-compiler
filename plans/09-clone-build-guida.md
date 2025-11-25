# Plan: Clone and Build Guida Compiler

**Related PLAN.md Section**: §2.1.1 Audit Guida I/O Implementation

## Objective

Clone the Guida repository, document build steps, and verify it compiles and runs successfully.

## Background

From PLAN.md §2.1.1:
> Clone and build Guida compiler
> Document all native I/O operations currently implemented

Guida is an Elm port of the Elm compiler. It's the starting point for ECO's compiler work.

## Tasks

### 1. Locate Guida Repository

Search for Guida compiler repository:
- GitHub search for "guida elm compiler"
- Check if it's under a specific organization
- Likely URL patterns: github.com/*/guida or gitlab.com/*/guida

**Note**: If the repository is private or requires access, document this and ask the user for the URL.

### 2. Clone the Repository

```bash
# Create a directory for guida alongside eco-runtime
cd /home/rupert/sc/gitlab
git clone <guida-repo-url> guida
cd guida
```

### 3. Analyze Build System

Examine the repository to understand:
- What build system is used (likely npm/node based since Elm compiles to JS)
- What dependencies are required
- Build instructions in README or similar

Look for:
- `package.json` - Node.js dependencies
- `elm.json` - Elm package configuration
- `Makefile` or build scripts
- `README.md` - Build instructions

### 4. Install Dependencies

Based on build system analysis:

For Node.js/npm:
```bash
npm install
```

For Elm:
```bash
elm make
```

### 5. Build the Compiler

Execute the build:
```bash
# Likely something like:
npm run build
# or
elm make src/Main.elm --output=guida.js
```

### 6. Test Basic Functionality

Run the compiler on a simple Elm file:

Create `test.elm`:
```elm
module Test exposing (main)

main =
    "Hello, World!"
```

Run:
```bash
node guida.js make test.elm
```

### 7. Document Build Process

Create `design_docs/guida_build_notes.md`:

```markdown
# Guida Compiler Build Notes

## Repository
- URL: <repo-url>
- Commit: <commit-hash>
- Date cloned: <date>

## Prerequisites
- Node.js version: X.X
- npm version: X.X
- Other dependencies: ...

## Build Steps

1. Clone: `git clone <url>`
2. Install deps: `npm install`
3. Build: `npm run build`

## Running the Compiler

```bash
node guida.js make <elm-file>
```

## Directory Structure

- `src/` - Elm source code
- `runtime/` - JavaScript runtime (I/O operations are here)
- ...

## Known Issues

- ...

## Notes

- ...
```

### 8. Identify Runtime/I/O Location

Find where the I/O operations are implemented:
- Look for `runtime/` directory
- Look for files handling HTTP, file system, etc.
- Look for native/kernel JavaScript code

Document the file paths for task #10 (List All Guida I/O Operations).

## Success Criteria

1. Guida repository cloned successfully
2. All dependencies installed
3. Compiler builds without errors
4. Can compile a simple Elm program
5. Build documentation created at `design_docs/guida_build_notes.md`
6. I/O runtime location identified for follow-up task

## Files to Create

- **Create**: `design_docs/guida_build_notes.md`

## Potential Issues

1. **Private repository** - May need user to provide access/URL
2. **Node.js version mismatch** - May need specific Node version
3. **Elm version issues** - May need specific Elm compiler version to bootstrap
4. **Missing documentation** - Build process may not be well documented

## Recovery Steps

If build fails:
1. Check GitHub issues for similar problems
2. Try different Node.js versions
3. Document the error and ask user for guidance

## Estimated Complexity

Medium - may encounter build issues that need troubleshooting.
