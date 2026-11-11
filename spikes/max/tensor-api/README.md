# The tensor API's example programs and counterexamples

The contract the package `eco-lab/tensor` (`../tensor`) was written to, and the evidence for the
typing claims in `plans/nabla-api-in-elm.md`. It began as a type-only stub of every public
signature; that stub became the package's `src/`, and this directory keeps the programs:

- `examples/`: programs that must compile against the package: `MnistNet` (AdamW, per-step rate),
  `Gpt` (96 shared encoder blocks, seeds through the signature, `vmap2`), `Cnn`, `LoraTune` (frozen
  base), `Calculus` (`hessianVector`, `jacobian`, `whileLoop`, `cond`), `Extras` (a custom optimizer,
  `mapElems`, `vmapWith`, QLoRA parameters, `stack`). `examples/All.elm` imports them all.
- `bad/`: programs that must **not** compile, each with the error eco gave (`bad/*.txt`, recorded
  against the stub).
- `scripts/gen_axis.py`: a copy of the package's witness generator.

`make check-api` (from `spikes/max`) checks both.
