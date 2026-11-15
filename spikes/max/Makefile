# Builds the MAX spikes against the eco dev build tree (cmake --preset build) and the MAX venv that
# setup.sh makes. Source env.sh first: the binaries need its variables at run time.
#
#   make            everything below
#   make run-capi   hand-written mo text through the C API
#   make run-bytes  an eco .so and libmax in one process, zero-copy Bytes ports
#   make run-mnist  train and evaluate an MNIST model (MODEL=sgd|adamw|stack|cnn|lora, FORMAT=bytecode|generic,
#                   TRACE=steps, RELOAD=true: save, reload and re-evaluate)
#   make check-bytecode  the MNIST graphs' Elm-written bytecode against their generic text
#   make run-churn  the eco-only repro of the MNIST run's memory growth (MODE=hold|both|...)
#   make check-ops  every tensor operation and gradient on MAX against NumPy (opcheck/)
#   make check-ops-eval  the same checks run by Tensor.Eval, the package's evaluator (no MAX)
#   make check-api  the API's example programs compile, its counterexamples do not (tensor-api/)
#   make check-tensor  the tensor package's own tests (elm-test-rs, tensor/tests/)
#   make docs-tensor  the tensor package's docs.json
#   make snapshot-graphs OUT=dir / compare-graphs BASE=dir  every model graph and host block, without MAX
#   make check-tensor-native  the E2E suite eco-tensor, tensor-e2e/ (native code, 64-bit Int)
#
# Elm programs are compiled with the Stage 1 compiler and lowered to a .so with eco-boot-native, as
# test/embed/run-node-addon-tests.sh does; the .so then links the host's libstdc++, like libmax.so.

REPO      ?= $(abspath $(CURDIR)/../..)
ECO_BUILD ?= $(REPO)/build
BOOT      := $(ECO_BUILD)/runtime/src/codegen/eco-boot-native
# index.js otherwise loads guida.js from the `build/` preset's tree, not ECO_BUILD's.
STAGE1    := GUIDA_JS_PATH=$(ECO_BUILD)/compiler/build-xhr/bin/guida.js \
             node --stack-size=500000 $(REPO)/compiler/bin/index.js
MAX_VENV  ?= $(CURDIR)/.venv
MAX_SITE  := $(firstword $(wildcard $(MAX_VENV)/lib/python3*/site-packages))
MAX_LIB   := $(MAX_SITE)/modular/lib
CXX       ?= g++
CXXFLAGS  := -std=c++20 -O2 -Wall -Wextra -I$(REPO)/runtime/include -I$(MAX_SITE)/max/include
B         := $(CURDIR)/build
# The typed tensor package, whose Max.Session is the Elm side of the MAX host every model app links,
# and the MLIR package it writes its graphs with (the compiler's, compiler/mlir).
MLIR_PKG   := $(REPO)/compiler/mlir
LOCAL_PKGS := --local-package eco-lab/tensor=$(CURDIR)/tensor --local-package the-sett/elm-mlir=$(MLIR_PKG)
TENSOR_SRC := $(shell find $(CURDIR)/tensor/src $(MLIR_PKG)/src -name '*.elm')
# The package's generic MAX host (protocol 2 of Max.Session); each *_bridge is it linked with one app.
MAX_HOST   := tensor/host/max_host.cpp

all: $(B)/spike $(B)/tensor_host $(B)/bytes_host $(B)/max_bridge $(B)/churn_host

check-venv:
	@test -n "$(MAX_SITE)" || { echo "no MAX venv at $(MAX_VENV): run ./setup.sh"; exit 1; }

# An Elm program in project directory $(1), module $(2), as $(B)/$(3).so
define elm_so
	mkdir -p $(B)
	cd $(1) && { ulimit -s unlimited 2>/dev/null || true; } && $(STAGE1) make src/$(2).elm --output=$(B)/$(3).mlir $(LOCAL_PKGS)
	$(BOOT) $(B)/$(3).mlir -o $(B)/$(3).so > $(B)/$(3).lower.log 2>&1 || { tail -20 $(B)/$(3).lower.log; exit 1; }
endef

$(B)/spike: capi/spike.cpp | check-venv
	mkdir -p $(B)
	$(CXX) $(CXXFLAGS) $< -L$(MAX_LIB) -lmax -Wl,-rpath,$(MAX_LIB) -o $@

$(B)/tensor_service.so: embed/json/src/TensorService.elm
	$(call elm_so,embed/json,TensorService,tensor_service)

$(B)/tensor_host: embed/json/tensor_host.cpp $(B)/tensor_service.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/tensor_service.so -L$(MAX_LIB) -lmax -lm -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/tensor_bytes.so: embed/bytes/src/TensorBytes.elm
	$(call elm_so,embed/bytes,TensorBytes,tensor_bytes)

$(B)/bytes_host: embed/bytes/bytes_host.cpp $(B)/tensor_bytes.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/tensor_bytes.so -L$(MAX_LIB) -lmax -lm -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/mnist.so: $(wildcard mnist/src/*.elm) $(TENSOR_SRC)
	$(call elm_so,mnist,Mnist,mnist)

# The generic host, linked with the MNIST model.
$(B)/max_bridge: $(MAX_HOST) $(B)/mnist.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/mnist.so -L$(MAX_LIB) -lmax -lm -pthread -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/charlm.so: $(wildcard models/charlm/src/*.elm) $(TENSOR_SRC)
	$(call elm_so,models/charlm,CharLm,charlm)

# The same generic host, linked with the char model.
$(B)/charlm_bridge: $(MAX_HOST) $(B)/charlm.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/charlm.so -L$(MAX_LIB) -lmax -lm -pthread -Wl,-rpath,$(B):$(MAX_LIB) -o $@

# The corpus: the repo's theory documents, concatenated.
work/charlm/corpus.txt:
	mkdir -p work/charlm
	cat $$(find $(REPO)/design_docs/theory -name '*.md' | sort) > $@

LAYERS ?= 2
SHARED ?= false
STEPS ?= 1000
run-charlm: $(B)/charlm_bridge work/charlm/corpus.txt
	$(B)/charlm_bridge $(CURDIR)/work/charlm '{"corpus": "$(CURDIR)/work/charlm/corpus.txt", "layers": $(LAYERS), "shared": $(SHARED), "steps": $(STEPS), "trace": $(TRACE)}'

# Round 2's end-to-end API checks on synthetic models (plans/tensor-api-round2.md, A2): CHECK=cache,
# import, block or int64; check-apicheck runs all four and the block's NumPy reference.
CHECK ?= cache
APICHECK_SRC := $(wildcard models/apicheck/src/*.elm)

$(B)/apicheck.so: $(APICHECK_SRC) $(TENSOR_SRC)
	$(call elm_so,models/apicheck,ApiCheck,apicheck)

# The same generic host, linked with the API checks.
$(B)/apicheck_bridge: $(MAX_HOST) $(B)/apicheck.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/apicheck.so -L$(MAX_LIB) -lmax -lm -pthread -Wl,-rpath,$(B):$(MAX_LIB) -o $@

work/apicheck/synthetic.safetensors: models/apicheck/make_checkpoint.py | check-venv
	mkdir -p work/apicheck/block
	$(MAX_VENV)/bin/python -I $< $(CURDIR)/work/apicheck

run-apicheck: $(B)/apicheck_bridge work/apicheck/synthetic.safetensors
	$(B)/apicheck_bridge $(CURDIR)/work/apicheck '{"check": "$(CHECK)", "dir": "$(CURDIR)/work/apicheck"}'

check-apicheck: $(B)/apicheck_bridge work/apicheck/synthetic.safetensors
	@for c in cache import block int64; do \
	  $(B)/apicheck_bridge $(CURDIR)/work/apicheck '{"check": "'$$c'", "dir": "$(CURDIR)/work/apicheck"}' > work/apicheck/$$c.log 2>&1; \
	  grep -h -E '"(PASS|FAIL)|HOST residents' work/apicheck/$$c.log | sed 's/^\[[^]]*\] //'; \
	  if grep -q '"FAIL' work/apicheck/$$c.log || ! grep -q '"PASS' work/apicheck/$$c.log; then echo "apicheck $$c failed (work/apicheck/$$c.log)"; exit 1; fi; \
	done
	@grep -q 'HOST residents: 11 buffers' work/apicheck/import.log || { echo "import: raw buffers left resident"; exit 1; }
	$(MAX_VENV)/bin/python -I models/apicheck/ref_block.py $(CURDIR)/work/apicheck

$(B)/churn.so: memgrowth/src/Churn.elm
	$(call elm_so,memgrowth,Churn,churn)

$(B)/churn_host: memgrowth/churn_host.cpp $(B)/churn.so
	$(CXX) $(CXXFLAGS) $< $(B)/churn.so -lm -Wl,-rpath,$(B) -o $@

run-capi: $(B)/spike
	cd capi && $(B)/spike models/mlp_rmo.mlir --compile-twice
	cd capi && $(B)/spike models/sym_mlp.mlir --k 64 --n 17

run-json: $(B)/tensor_host
	cd capi && $(B)/tensor_host models/sym_mlp.mlir

run-bytes: $(B)/bytes_host
	cd capi && $(B)/bytes_host models/sym_mlp.mlir

# FORMAT: bytecode (MLIR bytecode written with the-sett/elm-mlir) or generic (the same ops as
# MLIR generic text). Graphs land in work/<FORMAT>/graph-<id>.mlir[bc]. TRACE=n logs the first n
# step losses of epoch 1.
FORMAT ?= bytecode
TRACE ?= 0
MODEL ?= sgd
RELOAD ?= false
run-mnist: $(B)/max_bridge
	mkdir -p work/$(FORMAT) work/checkpoints
	$(B)/max_bridge $(CURDIR)/work/$(FORMAT) '{"dataDir": "$(CURDIR)/mnist/data", "format": "$(FORMAT)", "trace": $(TRACE), "variant": "$(MODEL)", "checkpoints": "$(CURDIR)/work/checkpoints", "reload": $(RELOAD)}'

# The bytecode checked with eco's own LLVM (the commit MAX pins): each graph's bytecode and generic
# text, from runs with FORMAT=bytecode and FORMAT=generic, must read back as the same IR.
MLIR_OPT ?= /opt/llvm-mlir/bin/mlir-opt
check-bytecode:
	@for g in 1 2; do \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic work/bytecode/graph-$$g.mlirbc > work/graph-$$g.from-bc.mlir && \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic work/generic/graph-$$g.mlir > work/graph-$$g.from-text.mlir && \
	  cmp work/graph-$$g.from-bc.mlir work/graph-$$g.from-text.mlir && \
	  echo "graph $$g: bytecode and generic text read back identical ($$(wc -l < work/graph-$$g.from-bc.mlir) lines)" || exit 1; \
	done

MODE ?= hold
run-churn: $(B)/churn_host
	ECO_GC_PHASE_PROFILE=1 $(B)/churn_host '{"mode":"$(MODE)","steps":3000}'

run-mnist-ref:
	$(MAX_VENV)/bin/python -I mnist/ref/numpy_ref.py mnist/data

clean:
	rm -rf $(B) work

# Elm programs run under node for the checks (their graphs are the bytes the native build writes).
ELM_JS = cd $(1) && $(STAGE1) make $(2) --output=$(3) $(LOCAL_PKGS)

FAMILIES ?=
check-ops: | check-venv
	mkdir -p work
	$(call ELM_JS,opcheck,src/OpCheck.elm,$(CURDIR)/work/opcheck.js)
	node opcheck/emit.js $(CURDIR)/work/opcheck.js $(CURDIR)/work/opcheck
	$(MAX_VENV)/bin/python -I opcheck/ref.py $(CURDIR)/work/opcheck/manifest.json $(FAMILIES)

# Every op-check family run by Tensor.Eval, the package's pure-Elm evaluator, against the same NumPy
# references and tolerances as check-ops (plans/tensor-eval-in-elm.md, E2.2): ref.py draws the
# inputs, eval.js runs OpCheck under Node with them as flags, ref.py checks the results. No MAX.
check-ops-eval: | check-venv
	mkdir -p work
	$(call ELM_JS,opcheck,src/OpCheck.elm,$(CURDIR)/work/opcheck.js)
	node opcheck/emit.js $(CURDIR)/work/opcheck.js $(CURDIR)/work/opcheck
	$(MAX_VENV)/bin/python -I opcheck/ref.py --dump-inputs $(CURDIR)/work/opcheck/manifest.json $(CURDIR)/work/opcheck/inputs.json
	node --stack-size=65500 opcheck/eval.js $(CURDIR)/work/opcheck.js $(CURDIR)/work/opcheck/inputs.json $(CURDIR)/work/opcheck/results.json
	$(MAX_VENV)/bin/python -I opcheck/ref.py --results $(CURDIR)/work/opcheck/results.json $(CURDIR)/work/opcheck/manifest.json $(FAMILIES)

# Every op-check family's bytecode and generic text read back as the same IR (eco's mlir-opt).
check-opcheck-bytecode:
	@for f in work/opcheck/*.mlir; do \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic $$f > $$f.from-text && \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic $${f}bc > $$f.from-bc && \
	  cmp -s $$f.from-text $$f.from-bc || { echo "differ: $$f"; exit 1; }; \
	done; echo "op-check: bytecode and generic text read back identical ($$(ls work/opcheck/*.mlir | wc -l) graphs)"

# Every op-check family written for GPU 0 (round 2, A3; no GPU needed): bytecode and generic text read
# back as the same IR, and every op's operands and results placed as MAX's own API places them
# (work/inventory/g16_gpu.txt). A family a GPU cannot run is listed as refused.
check-gpu-ir:
	@for f in work/opcheck/gpu/*.mlir; do \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic $$f > $$f.from-text && \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic $${f}bc > $$f.from-bc && \
	  cmp -s $$f.from-text $$f.from-bc || { echo "differ: $$f"; exit 1; }; \
	done; echo "gpu: bytecode and generic text read back identical ($$(ls work/opcheck/gpu/*.mlir | wc -l) graphs)"
	@for f in work/opcheck/gpu/*.refused; do [ -e "$$f" ] && echo "gpu: refused $$(basename $$f .refused): $$(head -1 $$f)"; done; true
	$(MAX_VENV)/bin/python -I capi/scripts/inventory/compare_gpu_ir.py work/inventory/g16_gpu.txt work/opcheck/gpu/*.mlir

# Every bad/X.elm must be refused with the error recorded in bad/X.txt: its first `-- TITLE --` line
# and the line of the message after it.
# BLESS=1 rewrites the bad/*.txt files from the compiler's current errors instead.
check-api:
	$(call ELM_JS,tensor-api,examples/All.elm,/dev/null)
	@cd tensor-api && for f in bad/*.elm; do \
	  t=$${f%.elm}.txt; \
	  if $(STAGE1) make $$f --output=/dev/null $(LOCAL_PKGS) > /tmp/check-api.out 2>&1; then echo "compiled, but must not: $$f"; exit 1; fi; \
	  if [ -n "$(BLESS)" ]; then cp /tmp/check-api.out $$t; fi; \
	  got=$$(sed -n '/^-- /,$$p' /tmp/check-api.out | grep -v '^$$' | head -2); want=$$(sed -n '/^-- /,$$p' $$t | grep -v '^$$' | head -2); \
	  if [ "$$got" != "$$want" ]; then echo "$$f: refused with the wrong error"; echo "  want: $$want"; echo "  got:  $$got"; exit 1; fi; \
	done; echo "tensor-api: the examples compile; every program in bad/ is refused with its recorded error ($$(ls bad/*.elm | wc -l))"

# Every graph and block of host bytes the spike's models make, written without MAX (snapshot/), plus
# the op-check families: OUT=dir. compare-graphs BASE=dir writes them again and compares every file
# of BASE (files that are new since, such as a new op-check family, are listed, not compared).
snapshot-graphs:
	@test -n "$(OUT)" || { echo "usage: make snapshot-graphs OUT=dir"; exit 1; }
	rm -rf $(OUT)
	mkdir -p $(OUT)/opcheck work
	$(call ELM_JS,opcheck,src/OpCheck.elm,$(CURDIR)/work/opcheck.js)
	node opcheck/emit.js $(CURDIR)/work/opcheck.js $(abspath $(OUT))/opcheck > /dev/null
	rm -f $(OUT)/opcheck/manifest.json
	$(call ELM_JS,snapshot,src/Snapshot.elm,$(CURDIR)/work/snapshot.js)
	node --stack-size=65500 snapshot/emit.js $(CURDIR)/work/snapshot.js $(abspath $(OUT))/models
	@echo "snapshot: $$(find $(OUT) -type f | wc -l) files in $(OUT)"

compare-graphs:
	@test -n "$(BASE)" || { echo "usage: make compare-graphs BASE=dir"; exit 1; }
	$(MAKE) --no-print-directory snapshot-graphs OUT=work/graphs-now
	@cd $(BASE) && find . -type f | sort | while read f; do \
	  cmp -s "$$f" "$(CURDIR)/work/graphs-now/$$f" || echo "differs: $$f"; \
	done > $(CURDIR)/work/graphs-diff.txt; \
	cd $(CURDIR)/work/graphs-now && find . -type f | sort | while read f; do [ -e "$(abspath $(BASE))/$$f" ] || echo "new: $$f"; done > $(CURDIR)/work/graphs-new.txt; \
	cd $(CURDIR); \
	if [ -s work/graphs-new.txt ]; then echo "not in $(BASE) (new): $$(wc -l < work/graphs-new.txt) files (work/graphs-new.txt)"; fi; \
	if [ -s work/graphs-diff.txt ]; then head -50 work/graphs-diff.txt; echo "graphs differ from $(BASE) (work/graphs-diff.txt)"; exit 1; fi; \
	echo "graphs identical to $(BASE): $$(cd $(BASE) && find . -type f | wc -l) files"

# The E2E suite eco-tensor: the programs in tensor-e2e/, registered with the repo's E2E runner
# (test/CMakeLists.txt; 64-bit Int, native code; plans/tensor-eval-in-elm.md). The runner recompiles
# a test only when its .elm is newer than its cached .mlir, so its caches go first.
check-tensor-native:
	rm -rf $(ECO_BUILD)/test/eco-tensor/eco-stuff $(ECO_BUILD)/test/eco-tensor/elm-stuff
	cd $(REPO) && TEST_FILTER=eco-tensor cmake --build $(ECO_BUILD) --target check 2>&1 | tee /tmp/test_output.txt
	@grep -qE '^Tests run: +[1-9]' /tmp/test_output.txt && grep -qE '^Tests failed: +0$$' /tmp/test_output.txt \
	  && echo "eco-tensor E2E: $$(grep -E '^Tests passed' /tmp/test_output.txt)"

ELM_TEST_RS ?= $(ECO_BUILD)/toolchain/bin/elm-test-rs
# Stock Elm cannot resolve the-sett/elm-mlir until it is published, so the tests run from an
# application over the package's sources and the MLIR package's (tensor-tests.elm.json).
check-tensor:
	mkdir -p $(B)/tensor-test && cp tensor-tests.elm.json $(B)/tensor-test/elm.json
	ln -sfn ../../tensor/tests $(B)/tensor-test/tests
	cd $(B)/tensor-test && PATH=$(ECO_BUILD)/toolchain/bin:$$PATH $(ELM_TEST_RS) --fuzz 20

# The tensor package's docs.json, with stock Elm. Until the-sett/elm-mlir is published, stock Elm
# cannot resolve it as a dependency, so the docs are built from a copy of the package without that
# dependency, whose src holds the MLIR package's modules too; they are not exposed, so they do not
# appear in the docs.
docs-tensor:
	rm -rf $(B)/tensor-docs && mkdir -p $(B)/tensor-docs/src
	cp -r tensor/src/. $(MLIR_PKG)/src/. $(B)/tensor-docs/src/
	cp tensor/README.md $(B)/tensor-docs/
	python3 -c 'import json,sys; j=json.load(open("tensor/elm.json")); del j["dependencies"]["the-sett/elm-mlir"]; json.dump(j, open(sys.argv[1], "w"), indent=4)' $(B)/tensor-docs/elm.json
	cd $(B)/tensor-docs && PATH=$(ECO_BUILD)/toolchain/bin:$$PATH elm make --docs=$(CURDIR)/tensor/docs.json

.PHONY: all check-venv run-capi run-json run-bytes run-mnist check-bytecode run-churn run-mnist-ref clean \
	check-ops check-opcheck-bytecode check-api check-tensor run-apicheck check-apicheck check-gpu-ir \
	snapshot-graphs compare-graphs check-tensor-native check-ops-eval docs-tensor
