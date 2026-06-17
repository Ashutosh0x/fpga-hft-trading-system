// ============================================================================
// FPGA HFT Trading System - EMA Calculator (Hardware)
// Description: Exponential Moving Average using bit-shift multiplication
//              instead of floating-point division. Fully pipelined.
//              EMA[t] = EMA[t-1] + (x[t] - EMA[t-1]) >> ALPHA_SHIFT
// Latency:     1 clock cycle
// ============================================================================

module ema_calculator
    import fixed_point_pkg::*;
#(
    parameter ALPHA_SHIFT = 4,  // Smoothing: alpha = 1/2^ALPHA_SHIFT = 1/16
    parameter DATA_WIDTH  = 32
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       enable,

    input  logic signed [DATA_WIDTH-1:0] data_in,
    input  logic                       data_valid,

    output logic signed [DATA_WIDTH-1:0] ema_out,
    output logic                       ema_valid,

    // Reset EMA to a specific value
    input  logic                       ema_reset,
    input  logic signed [DATA_WIDTH-1:0] ema_reset_val
);

    logic signed [DATA_WIDTH-1:0] ema_reg;
    logic initialized;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ema_reg     <= '0;
            ema_valid   <= 1'b0;
            initialized <= 1'b0;
        end else if (ema_reset) begin
            ema_reg     <= ema_reset_val;
            initialized <= 1'b1;
            ema_valid   <= 1'b0;
        end else if (enable && data_valid) begin
            if (!initialized) begin
                // First sample — initialize EMA to input value
                ema_reg     <= data_in;
                initialized <= 1'b1;
            end else begin
                // EMA update: ema = ema + (x - ema) >> ALPHA_SHIFT
                logic signed [DATA_WIDTH-1:0] diff;
                logic signed [DATA_WIDTH-1:0] update;
                diff   = data_in - ema_reg;
                update = diff >>> ALPHA_SHIFT;  // Arithmetic right shift
                ema_reg <= ema_reg + update;
            end
            ema_valid <= 1'b1;
        end else begin
            ema_valid <= 1'b0;
        end
    end

    assign ema_out = ema_reg;

endmodule
