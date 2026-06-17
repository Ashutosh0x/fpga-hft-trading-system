// ============================================================================
// Sparse Neural Network Inference Engine with 2:4 Structured Sparsity
// ============================================================================
// Inspired by NVIDIA Ampere/Hopper Sparse Tensor Cores (2020-2026)
//
// Implements 2:4 structured sparsity: in every group of 4 weights, exactly
// 2 are zero. This halves the number of multiply-accumulate operations
// per layer, reducing DSP usage and power while maintaining throughput.
//
// Each weight group stores:
//   - 2 nonzero INT4 weight values
//   - 2-bit index mask indicating which 2 of 4 positions are nonzero
//
// Compared to dense neural_inference.sv:
//   - 50% fewer multiplications per layer
//   - 50% less weight storage (268 bytes -> 134 bytes + index metadata)
//   - Same 4-cycle pipeline latency
//   - Requires sparsity-aware training (not implemented; uses heuristic init)
//
// IMPORTANT: Weights use heuristic initialization with a synthetic 2:4 pattern.
// No training has been performed. This demonstrates hardware feasibility only.
// ============================================================================

module sparse_neural_inference
    import fixed_point_pkg::*;
#(
    parameter INPUT_DIM   = 8,
    parameter HIDDEN1_DIM = 16,
    parameter HIDDEN2_DIM = 16,
    parameter HIDDEN3_DIM = 8,
    parameter OUTPUT_DIM  = 3
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Feature input (from feature_extractor)
    input  logic signed [7:0] features [INPUT_DIM],
    input  logic        features_valid,

    // Prediction output
    output logic [1:0]  prediction,     // 0=BUY, 1=SELL, 2=HOLD
    output logic signed [15:0] confidence,
    output logic        prediction_valid,

    // Sparsity statistics (for monitoring)
    output logic [31:0] total_macs,        // Total MACs performed
    output logic [31:0] skipped_macs       // MACs skipped due to sparsity
);

    // ========================================================================
    // 2:4 Sparsity Data Structures
    // ========================================================================
    // For a group of 4 weights, we store:
    //   - 2 nonzero values (INT4, 4 bits each = 8 bits)
    //   - 2-bit index mask (which 2 of 4 positions are nonzero)
    //   Total: 10 bits per group of 4 weights (vs 16 bits dense)
    //
    // Index encoding (2 bits select from 6 possible 2:4 patterns):
    //   00 -> positions [0,1] nonzero  (mask = 4'b0011)
    //   01 -> positions [0,2] nonzero  (mask = 4'b0101)
    //   10 -> positions [1,2] nonzero  (mask = 4'b0110)
    //   11 -> positions [0,3] nonzero  (mask = 4'b1001)
    // (Simplified encoding; full 2:4 has C(4,2)=6 patterns)

    // Sparse weight storage
    typedef struct packed {
        logic signed [3:0] val0;     // First nonzero weight (INT4)
        logic signed [3:0] val1;     // Second nonzero weight (INT4)
        logic [1:0]        idx;      // Index pattern selector
    } sparse_weight_t;                // 10 bits total

    // ========================================================================
    // Weight Storage (2:4 sparse format)
    // ========================================================================
    // Layer 0: INPUT_DIM x HIDDEN1_DIM = 8 x 16
    // Groups of 4 along input dim: 2 groups per output neuron
    // Total groups: 2 * 16 = 32
    sparse_weight_t l0_weights [2][HIDDEN1_DIM];    // [group][output]
    logic signed [7:0] l0_bias [HIDDEN1_DIM];

    // Layer 1: HIDDEN1_DIM x HIDDEN2_DIM = 16 x 16
    // Groups: 4 * 16 = 64
    sparse_weight_t l1_weights [4][HIDDEN2_DIM];
    logic signed [7:0] l1_bias [HIDDEN2_DIM];

    // Layer 2: HIDDEN2_DIM x HIDDEN3_DIM = 16 x 8
    // Groups: 4 * 8 = 32
    sparse_weight_t l2_weights [4][HIDDEN3_DIM];
    logic signed [7:0] l2_bias [HIDDEN3_DIM];

    // Layer 3: HIDDEN3_DIM x OUTPUT_DIM = 8 x 3
    // Groups: 2 * 3 = 6
    sparse_weight_t l3_weights [2][OUTPUT_DIM];
    logic signed [7:0] l3_bias [OUTPUT_DIM];

    // ========================================================================
    // Index Pattern Decoder
    // ========================================================================
    // Converts 2-bit index to actual input positions
    function automatic logic [3:0] decode_mask(input logic [1:0] idx);
        case (idx)
            2'b00: return 4'b0011;  // positions 0,1
            2'b01: return 4'b0101;  // positions 0,2
            2'b10: return 4'b0110;  // positions 1,2
            2'b11: return 4'b1001;  // positions 0,3
        endcase
    endfunction

    // Returns the two active input indices for a given pattern
    function automatic logic [1:0] get_idx0(input logic [1:0] pattern);
        case (pattern)
            2'b00: return 2'd0;
            2'b01: return 2'd0;
            2'b10: return 2'd1;
            2'b11: return 2'd0;
        endcase
    endfunction

    function automatic logic [1:0] get_idx1(input logic [1:0] pattern);
        case (pattern)
            2'b00: return 2'd1;
            2'b01: return 2'd2;
            2'b10: return 2'd2;
            2'b11: return 2'd3;
        endcase
    endfunction

    // ========================================================================
    // Sparse MAC Unit (2 multiplies instead of 4 per group)
    // ========================================================================
    function automatic logic signed [15:0] sparse_mac_group(
        input logic signed [7:0] inputs [4],
        input sparse_weight_t    sw
    );
        logic [1:0] i0 = get_idx0(sw.idx);
        logic [1:0] i1 = get_idx1(sw.idx);
        // Only 2 multiplies instead of 4 -- 50% compute savings
        return (inputs[i0] * sw.val0) + (inputs[i1] * sw.val1);
    endfunction

    // ========================================================================
    // Pipeline Registers
    // ========================================================================
    // Stage 0: Layer 0 (input -> hidden1)
    logic signed [7:0] s0_out [HIDDEN1_DIM];
    logic s0_valid;

    // Stage 1: Layer 1 (hidden1 -> hidden2)
    logic signed [7:0] s1_out [HIDDEN2_DIM];
    logic s1_valid;

    // Stage 2: Layer 2 (hidden2 -> hidden3)
    logic signed [7:0] s2_out [HIDDEN3_DIM];
    logic s2_valid;

    // Stage 3: Layer 3 (hidden3 -> output) + argmax
    logic signed [15:0] s3_logits [OUTPUT_DIM];
    logic s3_valid;

    // ========================================================================
    // Sparsity Statistics Counter
    // ========================================================================
    logic [31:0] mac_count;
    logic [31:0] skip_count;

    assign total_macs   = mac_count;
    assign skipped_macs = skip_count;

    // ========================================================================
    // Pipeline Stage 0: Layer 0 (8 -> 16) with 2:4 sparsity
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            mac_count <= '0;
            skip_count <= '0;
        end else if (enable && features_valid) begin
            for (int j = 0; j < HIDDEN1_DIM; j++) begin
                logic signed [15:0] acc = l0_bias[j];
                // 2 groups of 4 inputs = 8 inputs
                // Each group: 2 MACs (not 4) -- 50% savings
                for (int g = 0; g < 2; g++) begin
                    logic signed [7:0] grp_in [4];
                    for (int k = 0; k < 4; k++)
                        grp_in[k] = features[g*4 + k];
                    acc = acc + sparse_mac_group(grp_in, l0_weights[g][j]);
                end
                // ReLU
                s0_out[j] <= (acc > 0) ? ((acc > 127) ? 8'd127 : acc[7:0]) : 8'd0;
            end
            s0_valid <= 1'b1;
            mac_count <= mac_count + (2 * HIDDEN1_DIM * 2);  // 2 MACs per group
            skip_count <= skip_count + (2 * HIDDEN1_DIM * 2); // 2 skipped per group
        end else begin
            s0_valid <= 1'b0;
        end
    end

    // ========================================================================
    // Pipeline Stage 1: Layer 1 (16 -> 16) with 2:4 sparsity
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else if (enable && s0_valid) begin
            for (int j = 0; j < HIDDEN2_DIM; j++) begin
                logic signed [15:0] acc = l1_bias[j];
                for (int g = 0; g < 4; g++) begin
                    logic signed [7:0] grp_in [4];
                    for (int k = 0; k < 4; k++)
                        grp_in[k] = s0_out[g*4 + k];
                    acc = acc + sparse_mac_group(grp_in, l1_weights[g][j]);
                end
                s1_out[j] <= (acc > 0) ? ((acc > 127) ? 8'd127 : acc[7:0]) : 8'd0;
            end
            s1_valid <= 1'b1;
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // ========================================================================
    // Pipeline Stage 2: Layer 2 (16 -> 8) with 2:4 sparsity
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else if (enable && s1_valid) begin
            for (int j = 0; j < HIDDEN3_DIM; j++) begin
                logic signed [15:0] acc = l2_bias[j];
                for (int g = 0; g < 4; g++) begin
                    logic signed [7:0] grp_in [4];
                    for (int k = 0; k < 4; k++)
                        grp_in[k] = s1_out[g*4 + k];
                    acc = acc + sparse_mac_group(grp_in, l2_weights[g][j]);
                end
                s2_out[j] <= (acc > 0) ? ((acc > 127) ? 8'd127 : acc[7:0]) : 8'd0;
            end
            s2_valid <= 1'b1;
        end else begin
            s2_valid <= 1'b0;
        end
    end

    // ========================================================================
    // Pipeline Stage 3: Layer 3 (8 -> 3) + Argmax
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            prediction <= 2'd2;  // HOLD
            confidence <= '0;
            prediction_valid <= 1'b0;
        end else if (enable && s2_valid) begin
            // Compute logits
            for (int j = 0; j < OUTPUT_DIM; j++) begin
                logic signed [15:0] acc = l3_bias[j];
                for (int g = 0; g < 2; g++) begin
                    logic signed [7:0] grp_in [4];
                    for (int k = 0; k < 4; k++)
                        grp_in[k] = s2_out[g*4 + k];
                    acc = acc + sparse_mac_group(grp_in, l3_weights[g][j]);
                end
                s3_logits[j] <= acc;
            end

            // Argmax over 3 logits
            if (s3_logits[0] >= s3_logits[1] && s3_logits[0] >= s3_logits[2]) begin
                prediction <= 2'd0;  // BUY
                confidence <= s3_logits[0];
            end else if (s3_logits[1] >= s3_logits[2]) begin
                prediction <= 2'd1;  // SELL
                confidence <= s3_logits[1];
            end else begin
                prediction <= 2'd2;  // HOLD
                confidence <= s3_logits[2];
            end
            prediction_valid <= 1'b1;
        end else begin
            prediction_valid <= 1'b0;
        end
    end

    // ========================================================================
    // Weight Initialization (2:4 sparse heuristic pattern)
    // ========================================================================
    initial begin
        // Layer 0: 2 groups x 16 outputs
        for (int j = 0; j < HIDDEN1_DIM; j++) begin
            for (int g = 0; g < 2; g++) begin
                l0_weights[g][j].val0 = (g == 0 && j < 8) ? 4'sd2 : 4'sd1;
                l0_weights[g][j].val1 = ((g + j) % 3 == 0) ? 4'sd1 : 4'sd0;
                l0_weights[g][j].idx  = g[1:0];
            end
            l0_bias[j] = 8'sd0;
        end

        // Layer 1: 4 groups x 16 outputs
        for (int j = 0; j < HIDDEN2_DIM; j++) begin
            for (int g = 0; g < 4; g++) begin
                l1_weights[g][j].val0 = ((g + j) % 4 == 0) ? 4'sd2 : 4'sd1;
                l1_weights[g][j].val1 = ((g * j) % 5 == 0) ? -4'sd1 : 4'sd0;
                l1_weights[g][j].idx  = g[1:0];
            end
            l1_bias[j] = 8'sd0;
        end

        // Layer 2: 4 groups x 8 outputs
        for (int j = 0; j < HIDDEN3_DIM; j++) begin
            for (int g = 0; g < 4; g++) begin
                l2_weights[g][j].val0 = ((g + j) % 3 == 0) ? 4'sd1 : 4'sd0;
                l2_weights[g][j].val1 = ((g * j) % 4 == 0) ? -4'sd1 : 4'sd0;
                l2_weights[g][j].idx  = g[1:0];
            end
            l2_bias[j] = 8'sd0;
        end

        // Layer 3: 2 groups x 3 outputs
        for (int j = 0; j < OUTPUT_DIM; j++) begin
            for (int g = 0; g < 2; g++) begin
                l3_weights[g][j].val0 = (j == g) ? 4'sd2 : 4'sd1;
                l3_weights[g][j].val1 = 4'sd0;
                l3_weights[g][j].idx  = 2'b00;
            end
            l3_bias[j] = 8'sd0;
        end
    end

endmodule
