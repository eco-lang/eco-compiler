# JavaScript output

Eco keeps the stock Elm compiler's JavaScript and HTML generator for two reasons. The compiler is an Elm program, so before any native binary of it exists it has to run as JavaScript. And JavaScript output is the established behavior of Elm programs, against which the native path is checked. A build that asks for a `.js` or `.html` file, or names no output at all, takes the erased path: the front end, then Elm's own optimizer, which drops types, then this generator. The generator walks the optimized program from its entry points and writes every reachable definition once, inside a single JavaScript function, together with the kernel JavaScript of the libraries the program uses. It sits behind a small interface and reads only the erased program, so the typed, specialized program that feeds MLIR never reaches it.

## Same driver, different program

The JavaScript generator and the MLIR generator are two back ends of one build driver. They share project loading, caching, the discovery of entry points and error reporting. They do not share the program they read. The MLIR generator reads the monomorphic graph that the whole-program steps produce. The JavaScript generator reads the erased graph: one record of every global definition, as stock Elm's optimizer builds it. Nothing typed crosses to the JavaScript side, and nothing about heap layouts, calling conventions or boxing belongs there.

The interface makes that split a matter of types rather than convention. It has one kind of back end, and its graph is the erased one:

```elm
type alias CodeGen =
    { -- Generate a complete program from the optimized global graph
      generate :
        { sourceMaps : SourceMaps
        , leadingLines : Int
        , mode : Mode.Mode
        , graph : Opt.GlobalGraph
        , mains : Mains
        }
        -> Output
    ...
    }
```

From `compiler/src/Compiler/Generate/CodeGen.elm`. The interface takes the erased `Opt` graph and the list of entry points. The cut part holds two entry points for the interactive loop. Because the graph's type is fixed in the record, a JavaScript back end cannot be handed typed data by accident. Its result is text. The MLIR generator has no such interface: the build streams it through the generator's own writer (`Compiler.Generate.MLIR.Backend`), and the test harnesses call the generator's functions directly.

The adapter that puts the stock generator behind the interface is a few lines long. The build driver wraps it in three drivers, one per mode, that load the cached erased objects, assemble the graph and the entry points, and read module sources when source maps are wanted. Both targets share the rest of the build driver instead of each carrying a fork of it.

## Choosing JavaScript

The file name decides the back end, once for the whole build. A name ending in `.js` or `.html` selects this generator. A name ending in `.mlir` selects MLIR, and any other name selects a native output whose kind the extension decides. With no output name, the build writes `index.html` when the project has one entry point and `elm.js` when it has several, which is what `elm make` does.

The generator runs in one of three modes, and the options for debugging, for production optimization and for source maps choose them. These options have no meaning on the native side and affect only this generator, because they are inherited Elm behavior. Development mode writes readable code. Debug mode is development mode carrying the program's type information, which the Elm debugger needs to display values. Production mode counts how often each record field name occurs in the whole graph and gives the most frequent fields the shortest names, which shrinks the output.

## From erased graph to file

The generator turns the graph into a file in four steps, in the order they run.

1. It walks the graph from each entry point and emits every reachable definition once, dependencies before the definitions that use them, in a fixed sorted order, inside one immediately invoked function. Code that no entry point reaches is never written.
2. It lowers each definition, expression by expression, into a small syntax tree for JavaScript. Decision trees from pattern matching become chains of `if` and `switch`, tail calls become loops, and a reference to one of the library functions written directly in JavaScript, a kernel function, becomes a plain global name of the form `_Module_function` (`_Eco_Module_function` for an `Eco.Kernel` module).
3. It prints the tree as text. The printer records the source position of each piece, so a version 3 source map can be built when one is asked for.
4. It assembles the file. The file opens with the helpers that make curried calls of two to nine arguments cheap, then the kernel JavaScript of the libraries the program uses, then the exported entry points. It closes with a small block inherited from Guida that represents tuples of more than three elements and teaches the terminal debug printer to show them. Eco's front end rejects such tuples, so no program Eco accepts needs that block.

Identifiers are chosen to be legal JavaScript and free of collisions, and production mode uses short generated names.

Kernel names keep the two families apart. An `Elm.Kernel` module's values keep stock Elm's `_Module_name`, so output for programs on Elm's libraries is unchanged. An `Eco.Kernel` module is keyed in the program graph by its whole module name and its values are named `_Eco_Module_name`, because eco/kernel shares homes with Elm's libraries (`File`, `Http`, `Process`) and both `File` kernels define `_File_size`; with flat names one kernel replaced the other and the program failed at load (SD-16). An Eco kernel file spells its own values `_Module_name` in its JavaScript text, so the generator rewrites each `_Module_` identifier in an Eco kernel's text whose `Module` is an Eco kernel of the program. A kernel import `Eco.Kernel.Module` with no such Eco kernel names the Elm kernel `Module` (eco/kernel's files import elm/core's `Scheduler` and `Utils` that way). The JavaScript-hosted compiler builds and runs with these names: its Eco kernel calls and the kernel files' definitions are renamed together.

For HTML output the JavaScript is placed in a page that starts the program on one element and shows an initialization error if startup fails.

## Why Eco keeps the stock generator

Three needs keep it, and a fourth reason keeps it on the erased program.

The self-compilation chain needs it. The first stage uses stock Elm to build the compiler as JavaScript. The next stages use that JavaScript compiler, through this generator, to build the compiler again, until the JavaScript output stops changing. Only after that does a stage emit the MLIR that becomes the first native compiler. Without this generator there is no path from stock Elm to a native Eco. The fixed point also puts a requirement on the native compiler: when it generates JavaScript, the text it prints for a number, such as a float literal, has to match what the JavaScript-hosted compiler prints, or the output is not identical.

Browser projects need it. The default page, the single JavaScript file and the debug, production and source map options are stock Elm behavior, so Eco can replace `elm make` for a browser project. The curried-call helpers, the single wrapping function and the shortening of field names are the stock design too, left unchanged so that Eco's output stays interchangeable with Elm's.

The native path needs a reference. The native runtime's rules for effects and ports are stated as parity with the JavaScript runtime: the native side matches JavaScript, not the other way round. The MLIR equivalence check compiles every whole-program test with the JavaScript-hosted compiler and with the native compiler and compares the MLIR, and the benchmarks compare Eco's JavaScript output with its native output.

The generator reads the erased program because that is stock Elm's design. Stock Elm drops types after type checking because JavaScript does not need them, and the typed optimizer exists only for the native path. A JavaScript build runs only the erased path and writes none of the typed artifacts, as [compiler.md](compiler.md) explains. Leaving the generator on the erased program frees the typed representation to be shaped entirely for native code.

Two other designs come up and are turned down. Dropping JavaScript output for native code alone would break the self-compilation chain and browser use together. Feeding the generator from the typed or specialized program would tie it to data that exists to serve native code, and the two interface kinds keep it off that data.

## Changing the generator

A change fits when it keeps the generator a faithful Elm back end over the erased program and puts each concern in the part that already owns it: lowering in the expression code, behavior that differs by mode in the mode type, output wrapping beside the HTML page.

### Examples of changes that fit the theory
- A change to how one construct is lowered, such as a literal or an operator, belongs in the expression lowering and, if the text changes, the printer. Float literal formatting is an example.
- Behavior that depends on the mode goes into the mode type and is read by the generator, as the debugger's type information and field shortening are.
- A runtime helper goes beside the curried-call helpers at the head of the file. These sit beside the generated code and do not change code generation. The closing Guida block is not a model to follow, since it supports syntax Eco rejects.
- Another output wrapper sits beside the HTML page and gets its own branch where the build chooses the output.
- A further back end implements one of the two interface kinds and adds an output kind, as the MLIR generator does.

### Examples of changes that would break the theory
- Making the generator read typed or specialized data to improve its output ties it to the native path's representation, which is free to change for native reasons. If both back ends would benefit, put the improvement in the optimizer that builds the erased program.
- Changing what a program does, such as evaluation order, in the JavaScript emitter alone makes the reference disagree with the native path. Change the shared front end or optimizer so every back end inherits it.
- Giving Elm and Eco kernel modules the same JavaScript names or graph keys again lets a kernel of one family replace the other's when a program uses both (SD-16). Keep the `Eco` prefix in both.
- Bringing heap layouts, calling conventions or boxing into the JavaScript generator imports decisions that have no meaning there and that change with the native back end. Keep them in global optimization and MLIR generation.
- Copying a native behavior into JavaScript to make the two agree reverses the direction of parity, since the parity rules make native match JavaScript. Check those rules first, and fix the native side if it is the one that differs.

## References

Parent: [compiler.md](compiler.md).

Code:

- `compiler/src/Compiler/Generate/CodeGen.elm`: the `CodeGen` interface and the text `Output`.
- `compiler/src/Compiler/Generate/CodeGen/JavaScript.elm`: the adapter to the stock generator.
- `compiler/src/Compiler/Generate/JavaScript.elm`: the graph walk, the helpers, kernel chunks, the closing `EXTRA GUIDA CORE` block (`_Utils_TupleN` and its `_Debug_toAnsiString` wrapper), REPL output and source maps.
- `compiler/src/Compiler/Generate/JavaScript/Expression.elm`: lowering of each expression.
- `compiler/src/Compiler/Generate/JavaScript/Name.elm`: identifier choice, including `fromKernel` (Elm kernel modules, `_Module_name`) and `fromEcoKernel` (Eco kernel modules, `_Eco_Module_name`).
- `compiler/src/Compiler/Generate/JavaScript/Builder.elm`, `SourceMap.elm`, `Functions.elm`: printing, source maps, and the `F2`..`F9` and `A2`..`A9` helpers.
- `compiler/src/Compiler/Generate/Mode.elm`: `Dev (Maybe Types)` and `Prod ShortFieldNames`.
- `compiler/src/Compiler/Generate/Html.elm`: the HTML page (`sandwich`). It tells the source map that two lines precede the JavaScript (`leadingLines`) but writes more than two, so source-map line numbers for HTML output are likely off by the difference.
- `compiler/src/Builder/Generate.elm`: `javascriptBackend` and the `debug`, `dev` and `prod` drivers.
- `compiler/src/Terminal/Make.elm`: output selection (`parseOutput`, `handleArtifacts`) and the `--output`, `--debug`, `--optimize` and `--sourcemaps` options. `compiler/src/API/Make.elm`: the HTML path for the JSON entry point.
- `compiler/review/src/EnforceBoundaries.elm`: the layer rule that keeps generation downstream of earlier phases.

Documents:

- `docs/bootstrap.md`, `docs/options.md`, `design_docs/distribution.md`: the self-compilation chain and the output kinds.
- The header of `CodeGen.elm` describes a third interface kind, `TypedCodeGen`, and a binary `Output`; neither exists in the code.

Invariants (`design_docs/invariants.csv`): PORT_005 and PORT_007 (port and effect parity with the JavaScript runtime), LIVE_001.
