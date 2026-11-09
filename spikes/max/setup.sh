#!/bin/sh
# Makes spikes/max/.venv with MAX 26.7 (the C API headers and libmax.so ship in the wheel) and
# downloads MNIST into spikes/max/mnist/data, checked against torchvision's MD5s.
set -eu
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
    uv venv -q .venv --python 3.11
    uv pip install -q --python .venv/bin/python "max==26.7.*"
fi
mkdir -p mnist/data
cd mnist/data
for f in train-images-idx3-ubyte train-labels-idx1-ubyte t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
    [ -f "$f" ] && continue
    curl -sSfL --retry 2 -o "$f.gz" "https://ossci-datasets.s3.amazonaws.com/mnist/$f.gz"
done
if ls ./*.gz >/dev/null 2>&1; then
    md5sum -c ../mnist.md5
    gunzip -f ./*.gz
fi
echo "setup done: . spikes/max/env.sh, then make -C spikes/max"
