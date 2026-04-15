Bootstrap Stage 7 crashes because we get a pointer from heap old gen into the nursery.
                                                                                                                     
  Creating a pointer from older to younger objects should not be possible, because Elm is immutable. The pointed to
  object must exist first, so must be older. When an object is promoted to old gen, everything it points to must
  be older, and therefore also promoted.

  It seems we could have a mutation bug where such a pointer does get created.
  Or we have an age divergence bug where somehow the age of the parent is incremented but not the child.

  Look into this bug.

  TIPS:
  Instrument eco_store_field (and friends) to see if fields are being mutated on non-fresh objects.
  Assert “no promoted-parent + sub-threshold child” during GC
  Assert “no old→nursery pointers after minor GC”

  Either trace the code analytically or add debug log statements into the code to reveal its working state, or use
  linux debugging/profiling tools, whatever is most appropriate to gather evidence for how the code is executing
  and how this bug arises. Use your evidence to inform your reasoning and hypothesis about the root cause.

  Avoid speculating about the cause. When you do not know something for sure, make another round of analysis with
  more detailed tracing until the cause is absolutely solidly understood, exposed and confirmed with a bullet proof
  chain of evidence and solid reasoning. This is a hard bug to pin down, so try hard to do so.

  If you need to make changes to C++ code, its ok to build Stage 7 immediately after without re-generating the
  MLIR.
  Only changes to Elm code require the MLIR to be regenerated.

  Create a detailed report including full trace evidence from your thorough investigation of the issue.
