"""
Neural Network Reference Model (Python)
========================================
Golden model for validating the FPGA neural_inference.sv module.
Implements the exact same INT4/INT8 mixed-precision MLP architecture
with identical weight initialization, ReLU activation, and argmax output.

Usage:
    python verify/nn_reference.py

This produces expected outputs for known inputs that can be compared
against the SystemVerilog simulation results.
"""

import numpy as np


def int4_clamp(x):
    """Clamp to INT4 range [-8, 7]."""
    return np.clip(x, -8, 7).astype(np.int8)


def int8_clamp(x):
    """Clamp to INT8 range [-128, 127]."""
    return np.clip(x, -128, 127).astype(np.int16)


def relu_int8(x):
    """ReLU activation clamped to INT8."""
    return np.clip(np.maximum(0, x), 0, 127).astype(np.int16)


def init_weights():
    """Initialize weights identically to the SystemVerilog initial block."""
    INPUT_DIM = 8
    HIDDEN1_DIM = 16
    HIDDEN2_DIM = 16
    HIDDEN3_DIM = 8
    OUTPUT_DIM = 3

    # Layer 0: 8 x 16
    w0 = np.zeros((INPUT_DIM, HIDDEN1_DIM), dtype=np.int8)
    for i in range(INPUT_DIM):
        for j in range(HIDDEN1_DIM):
            if i == j:
                w0[i][j] = 2
            elif (i + j) % 3 == 0:
                w0[i][j] = 1
    b0 = np.zeros(HIDDEN1_DIM, dtype=np.int8)

    # Layer 1: 16 x 16
    w1 = np.zeros((HIDDEN1_DIM, HIDDEN2_DIM), dtype=np.int8)
    for i in range(HIDDEN1_DIM):
        for j in range(HIDDEN2_DIM):
            if (i + j) % 4 == 0:
                w1[i][j] = 2
            elif (i * j) % 5 == 0:
                w1[i][j] = -1
    b1 = np.zeros(HIDDEN2_DIM, dtype=np.int8)

    # Layer 2: 16 x 8
    w2 = np.zeros((HIDDEN2_DIM, HIDDEN3_DIM), dtype=np.int8)
    for i in range(HIDDEN2_DIM):
        for j in range(HIDDEN3_DIM):
            if (i + j) % 3 == 0:
                w2[i][j] = 1
            elif (i * j) % 4 == 0:
                w2[i][j] = -1
    b2 = np.zeros(HIDDEN3_DIM, dtype=np.int8)

    # Layer 3: 8 x 3
    w3 = np.zeros((HIDDEN3_DIM, OUTPUT_DIM), dtype=np.int8)
    for i in range(HIDDEN3_DIM):
        for j in range(OUTPUT_DIM):
            if i % OUTPUT_DIM == j:
                w3[i][j] = 2
    b3 = np.zeros(OUTPUT_DIM, dtype=np.int8)

    return (w0, b0), (w1, b1), (w2, b2), (w3, b3)


def forward(features, weights):
    """Forward pass through the 4-layer MLP. Matches RTL behavior exactly."""
    (w0, b0), (w1, b1), (w2, b2), (w3, b3) = weights

    x = features.astype(np.int16)

    # Layer 0
    z0 = x @ w0.astype(np.int16) + b0.astype(np.int16)
    a0 = relu_int8(z0)

    # Layer 1
    z1 = a0 @ w1.astype(np.int16) + b1.astype(np.int16)
    a1 = relu_int8(z1)

    # Layer 2
    z2 = a1 @ w2.astype(np.int16) + b2.astype(np.int16)
    a2 = relu_int8(z2)

    # Layer 3 (output logits, no ReLU)
    z3 = a2 @ w3.astype(np.int16) + b3.astype(np.int16)

    # Argmax
    prediction = np.argmax(z3)
    signal_map = {0: "BUY", 1: "SELL", 2: "HOLD"}

    return z3, prediction, signal_map[prediction]


def main():
    weights = init_weights()

    print("=" * 60)
    print("Neural Network Reference Model - Golden Verification")
    print("Architecture: Dense(8->16) -> Dense(16->16) -> Dense(16->8) -> Dense(8->3)")
    print("Quantization: INT4 weights, INT8 activations")
    print("=" * 60)

    # Test vectors (same inputs used in tb_smartnic.sv)
    test_vectors = [
        np.array([10, 5, 20, -10, 3, 8, 7, -2], dtype=np.int8),
        np.array([0, 0, 0, 0, 0, 0, 0, 0], dtype=np.int8),
        np.array([127, 127, 127, 127, 127, 127, 127, 127], dtype=np.int8),
        np.array([-128, -128, -128, -128, -128, -128, -128, -128], dtype=np.int8),
        np.array([50, -30, 15, -5, 100, 2, 3, -80], dtype=np.int8),
    ]

    print(f"\n{'Test':>5} | {'Input':>40} | {'Logits':>20} | {'Pred':>6} | {'Signal':>6}")
    print("-" * 90)

    for i, features in enumerate(test_vectors):
        logits, pred_idx, signal = forward(features, weights)
        print(f"{i:5d} | {str(features):>40} | {str(logits):>20} | {pred_idx:6d} | {signal:>6}")

    # Weight statistics
    print(f"\nWeight Statistics:")
    for i, ((w, b), name) in enumerate(zip(weights, ["L0 (8x16)", "L1 (16x16)", "L2 (16x8)", "L3 (8x3)"])):
        nonzero = np.count_nonzero(w)
        total = w.size
        print(f"  {name}: {nonzero}/{total} nonzero weights ({100*nonzero/total:.1f}% density)")

    print(f"\nTotal weights: {sum(w.size for w, b in weights)}")
    print(f"Total bytes (INT4): {sum(w.size for w, b in weights) // 2}")
    print("\nUse these logits to verify against SystemVerilog simulation output.")


if __name__ == "__main__":
    main()
