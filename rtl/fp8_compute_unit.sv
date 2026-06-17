// ============================================================================
// FP8 (E4M3) Compute Unit for Neural Network Inference
// ============================================================================
// Inspired by NVIDIA Blackwell/Hopper FP8 Tensor Core architecture (2023-2026)
//
// Implements E4M3 floating-point format:
//   - 1 sign bit
//   - 4 exponent bits (bias = 7)
//   - 3 mantissa bits (implicit leading 1)
//   - Range: +/- 448, smallest subnormal: 2^-9
//   - Higher dynamic range than INT4/INT8 for neural network weights
//
// This module provides FP8 multiply-accumulate (MAC) operations that can
// replace INT4/INT8 arithmetic in the neural inference pipeline for
// applications where dynamic range matters more than absolute precision.
//
// IMPORTANT: This is an experimental compute unit. No trained FP8 model
// has been deployed. Hardware feasibility demonstration only.
// ============================================================================

module fp8_compute_unit
    import fixed_point_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // FP8 vector dot product: result = sum(a[i] * b[i]) for i in [0, VEC_LEN)
    input  logic [7:0]  vec_a [8],       // 8 FP8 E4M3 values
    input  logic [7:0]  vec_b [8],       // 8 FP8 E4M3 weights
    input  logic        vec_valid,

    // Result in INT16 (accumulated, de-scaled)
    output logic signed [15:0] result,
    output logic        result_valid,

    // Overflow/underflow flags
    output logic        overflow_flag,
    output logic        underflow_flag
);

    // ========================================================================
    // FP8 E4M3 Format
    // ========================================================================
    // Bit layout: [7] sign | [6:3] exponent | [2:0] mantissa
    // Exponent bias: 7
    // Special values:
    //   exp=0, man=0  -> zero
    //   exp=0, man!=0 -> subnormal
    //   exp=15        -> NaN (no infinity in E4M3)

    localparam EXP_BIAS = 7;

    typedef struct packed {
        logic        sign;
        logic [3:0]  exp;
        logic [2:0]  man;
    } fp8_t;

    // ========================================================================
    // FP8 Multiply (combinational)
    // ========================================================================
    // Returns result as {sign, exponent(5bit), mantissa(6bit)} intermediate
    function automatic logic signed [15:0] fp8_multiply(
        input logic [7:0] a_raw,
        input logic [7:0] b_raw
    );
        automatic fp8_t a = fp8_t'(a_raw);
        automatic fp8_t b = fp8_t'(b_raw);
        logic        res_sign;
        logic [4:0]  res_exp;
        logic [7:0]  man_product;
        logic signed [15:0] result;

        // Handle zero
        if ((a.exp == 0 && a.man == 0) || (b.exp == 0 && b.man == 0))
            return 16'sd0;

        // Sign
        res_sign = a.sign ^ b.sign;

        // Mantissa multiply: (1.man_a) * (1.man_b)
        // 4-bit * 4-bit = 8-bit product
        man_product = {1'b1, a.man} * {1'b1, b.man};

        // Exponent add (remove double bias)
        res_exp = a.exp + b.exp - EXP_BIAS;

        // Normalize: if product >= 2.0, shift right and increment exponent
        if (man_product[7]) begin
            man_product = man_product >> 1;
            res_exp = res_exp + 1;
        end

        // Convert to fixed-point INT16
        // Scale: value = (-1)^sign * 2^(exp-bias) * (1.mantissa)
        if (res_exp > 5'd22)  // Overflow
            result = res_sign ? -16'sd32767 : 16'sd32767;
        else if (res_exp < 5'd1)  // Underflow
            result = 16'sd0;
        else
            result = res_sign ? -(man_product[6:0]) : (man_product[6:0]);

        return result;
    endfunction

    // ========================================================================
    // Pipeline Stage 1: Compute 8 FP8 multiplications
    // ========================================================================
    logic signed [15:0] products [8];
    logic s1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            overflow_flag <= 1'b0;
            underflow_flag <= 1'b0;
        end else if (enable && vec_valid) begin
            for (int i = 0; i < 8; i++) begin
                products[i] <= fp8_multiply(vec_a[i], vec_b[i]);
            end
            s1_valid <= 1'b1;
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // ========================================================================
    // Pipeline Stage 2: Reduction tree (accumulate 8 products)
    // ========================================================================
    // Adder tree: 8 -> 4 -> 2 -> 1
    logic signed [15:0] sum_stage1 [4];
    logic signed [15:0] sum_stage2 [2];
    logic signed [15:0] final_sum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 16'sd0;
            result_valid <= 1'b0;
        end else if (enable && s1_valid) begin
            // Level 1: 8 -> 4
            for (int i = 0; i < 4; i++)
                sum_stage1[i] = products[2*i] + products[2*i + 1];

            // Level 2: 4 -> 2
            sum_stage2[0] = sum_stage1[0] + sum_stage1[1];
            sum_stage2[1] = sum_stage1[2] + sum_stage1[3];

            // Level 3: 2 -> 1
            result <= sum_stage2[0] + sum_stage2[1];
            result_valid <= 1'b1;

            // Overflow detection
            overflow_flag <= (sum_stage2[0] + sum_stage2[1] > 16'sd32000);
            underflow_flag <= (sum_stage2[0] + sum_stage2[1] < -16'sd32000);
        end else begin
            result_valid <= 1'b0;
        end
    end

    // ========================================================================
    // FP8 Weight Conversion Utilities
    // ========================================================================
    // Convert INT4 weight to FP8 E4M3 format
    function automatic logic [7:0] int4_to_fp8(input logic signed [3:0] val);
        logic [7:0] fp8_val;
        if (val == 0)
            return 8'h00;  // Zero

        fp8_val[7] = val[3];  // Sign bit

        // Magnitude to FP8
        case (val[3] ? -val : val)
            4'd1: fp8_val[6:0] = {4'd7, 3'b000};   // 1.0 * 2^0
            4'd2: fp8_val[6:0] = {4'd8, 3'b000};   // 1.0 * 2^1
            4'd3: fp8_val[6:0] = {4'd8, 3'b100};   // 1.5 * 2^1
            4'd4: fp8_val[6:0] = {4'd9, 3'b000};   // 1.0 * 2^2
            4'd5: fp8_val[6:0] = {4'd9, 3'b010};   // 1.25 * 2^2
            4'd6: fp8_val[6:0] = {4'd9, 3'b100};   // 1.5 * 2^2
            4'd7: fp8_val[6:0] = {4'd9, 3'b110};   // 1.75 * 2^2
            default: fp8_val[6:0] = {4'd7, 3'b000};
        endcase

        return fp8_val;
    endfunction

endmodule
