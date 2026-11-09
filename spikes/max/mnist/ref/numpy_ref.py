# The Elm program's exact training run in NumPy: same LCG, same init order, same shuffles,
# hand-written gradients. If the losses match, Elm's autodiff is right.
import sys, numpy as np
d = sys.argv[1]
def idx(name, off): return np.frombuffer(open(f"{d}/{name}", "rb").read()[off:], dtype=np.uint8)
xtr = idx("train-images-idx3-ubyte", 16).reshape(60000, 784); ytr = idx("train-labels-idx1-ubyte", 8)
xte = idx("t10k-images-idx3-ubyte", 16).reshape(10000, 784); yte = idx("t10k-labels-idx1-ubyte", 8)
M = 4294967296
def nxt(s): return (1664525 * s + 1013904223) % M
def uniform(fan_in, count, seed):
    b = np.float32(np.sqrt(6 / fan_in)); vals = []
    for _ in range(count):
        seed = nxt(seed); vals.append((2 * (seed / M) - 1) * b)
    return np.array(vals[::-1], dtype=np.float32), seed   # Elm prepends, so the list is reversed
def shuffle(seed, n):
    a = list(range(n))
    for i in range(n - 1, 0, -1):
        seed = nxt(seed); j = seed % (i + 1); a[i], a[j] = a[j], a[i]
    return a, seed
w1, s = uniform(784, 784 * 128, 42); w1 = w1.reshape(784, 128); b1 = np.zeros(128, np.float32)
w2, _ = uniform(128, 1280, s); w2 = w2.reshape(128, 10); b2 = np.zeros(10, np.float32)
def fwd(x8):
    x = x8.astype(np.float32) * np.float32(1 / 255); z1 = x @ w1 + b1; h = np.maximum(z1, 0)
    return x, z1, h, h @ w2 + b2
def acc():
    return int((fwd(xte)[3].argmax(1) == yte).sum())
print("epoch 0: untrained, test accuracy", acc() / 100)
seed = 7; lr = np.float32(0.1)
for e in range(1, 6):
    order, seed = shuffle(seed, 600); total = 0.0
    for bi in order:
        x8 = xtr[bi * 100:(bi + 1) * 100]; y = ytr[bi * 100:(bi + 1) * 100]
        x, z1, h, logits = fwd(x8)
        oh = np.eye(10, dtype=np.float32)[y]
        lse = logits - logits.max(1, keepdims=True); lsm = lse - np.log(np.exp(lse).sum(1, keepdims=True))
        total += float(-(oh * lsm).sum() / 100)
        g = (np.exp(lsm) - oh) / np.float32(100)
        gw2 = h.T @ g; gb2 = g.sum(0); gh = g @ w2.T; gz = gh * (z1 > 0)
        gw1 = x.T @ gz; gb1 = gz.sum(0)
        w1 -= lr * gw1; b1 -= lr * gb1; w2 -= lr * gw2; b2 -= lr * gb2
    print(f"epoch {e}: mean train loss {total / 600:.4f}, test accuracy {acc() / 100}%")
