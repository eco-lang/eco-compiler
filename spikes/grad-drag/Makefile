# Dragging through gradients (plans/grad-drag-spike.md): evg's declarative dragging with solvers that
# use exact derivatives from eco-lab/tensor, run in the browser by Tensor.Eval. Stock Elm 0.19.1.
#
#   make            build/main.js (open index.html)
#   make page       build/grad-drag.html: one self-contained file
#   make test       the spike's tests (elm-test-rs)
#   make bench      the tentacle's two solvers, the cannon and training, timed under Node
#   make format     elm-format the spike's own Elm (not vendor/)
#   make smoke CHROME=/path/to/headless_shell  real drags on build/grad-drag.html in headless Chromium

REPO      ?= $(abspath $(CURDIR)/../..)
TOOLCHAIN ?= $(REPO)/build/toolchain/bin
ELM       := PATH=$(TOOLCHAIN):$$PATH elm
SOURCES   := $(wildcard src/*.elm) $(shell find vendor/evg/src ../max/tensor/src -name '*.elm')

all: build/main.js

build/main.js: $(SOURCES) elm.json
	mkdir -p build
	$(ELM) make src/Main.elm --optimize --output=$@

build/grad-drag.html: build/main.js index.html scripts/page.py
	python3 -I scripts/page.py index.html build/main.js $@

page: build/grad-drag.html

test:
	PATH=$(TOOLCHAIN):$$PATH $(TOOLCHAIN)/elm-test-rs

build/bench.js: $(SOURCES) bench/Bench.elm bench/elm.json
	mkdir -p build
	cd bench && $(ELM) make Bench.elm --optimize --output=../build/bench.js

bench: build/bench.js
	node bench/bench.js build/bench.js

CHROME ?= $(HOME)/.cache/ms-playwright/chromium_headless_shell-1148/chrome-linux/headless_shell
smoke: build/grad-drag.html
	node scripts/smoke.js $(CHROME) file://$(CURDIR)/build/grad-drag.html build/smoke

format:
	$(TOOLCHAIN)/elm-format --yes src tests bench/Bench.elm

clean:
	rm -rf build elm-stuff bench/elm-stuff

.PHONY: all page test bench smoke format clean
