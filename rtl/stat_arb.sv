// ============================================================================
// FPGA HFT Trading System - Statistical Arbitrage Engine
// Description: Pair trading strategy implemented in hardware. Monitors spread
//              between two correlated instruments, computes z-score using
//              hardware EMA, and generates mean-reversion trade signals.
// Latency:     ~20-40ns (3-4 clock cycles at 644 MHz)
// ============================================================================

module stat_arb
    import fixed_point_pkg::*;
#(
    parameter ENTRY_THRESHOLD = 32'sd131072, // 2.0 in Q16.16 (2 * 65536)
    parameter EXIT_THRESHOLD  = 32'sd32768,  // 0.5 in Q16.16
    parameter EMA_SHIFT       = 5,           // EMA alpha = 1/32
    parameter DEFAULT_QTY     = 32'd50
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Price inputs for instruments A and B
    input  price_t      price_a,
    input  logic        price_a_valid,
    input  price_t      price_b,
    input  logic        price_b_valid,

    // Pre-computed regression parameters (loaded from CPU via config bus)
    input  fp_t         beta,    // Hedge ratio (Q16.16)
    input  fp_t         alpha,   // Intercept (Q16.16)

    // Trade signal output
    output order_out_t  order_a,
    output order_out_t  order_b,
    output logic        signals_valid,

    // Status
    output fp_t         current_spread,
    output fp_t         current_zscore,
    output logic [1:0]  position_state  // 0=FLAT, 1=LONG_SPREAD, 2=SHORT_SPREAD
);

    // ---- Position State ----
    typedef enum logic [1:0] {
        POS_FLAT         = 2'd0,
        POS_LONG_SPREAD  = 2'd1,  // Long A, Short B (bought spread)
        POS_SHORT_SPREAD = 2'd2   // Short A, Long B (sold spread)
    } pos_state_t;

    pos_state_t pos;

    // ---- Pipeline Registers ----
    // Stage 1: Compute spread
    logic       s1_valid;
    fp_t        s1_spread;

    // Stage 2: EMA of spread and variance
    logic       s2_valid;
    fp_t        s2_spread;

    // Stage 3: Z-score and signal
    logic       s3_valid;

    // ---- EMA Instances ----
    logic signed [31:0] ema_mean_out;
    logic               ema_mean_valid;
    logic signed [31:0] ema_var_out;
    logic               ema_var_valid;

    // Spread deviation squared
    logic signed [31:0] spread_dev_sq;
    logic               dev_sq_valid;

    // ---- Both prices ready ----
    logic both_valid;
    price_t latched_a, latched_b;
    logic a_ready, b_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_ready  <= 1'b0;
            b_ready  <= 1'b0;
            latched_a <= '0;
            latched_b <= '0;
        end else if (enable) begin
            if (price_a_valid) begin
                latched_a <= price_a;
                a_ready   <= 1'b1;
            end
            if (price_b_valid) begin
                latched_b <= price_b;
                b_ready   <= 1'b1;
            end
            if (a_ready && b_ready) begin
                a_ready <= 1'b0;
                b_ready <= 1'b0;
            end
        end
    end

    assign both_valid = a_ready && b_ready;

    // ---- Stage 1: Compute Spread ----
    // spread = price_A - beta * price_B - alpha
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s1_spread <= '0;
        end else if (enable && both_valid) begin
            automatic fp_t price_a_fp = {latched_a[15:0], 16'b0}; // Convert to Q16.16
            automatic fp_t price_b_fp = {latched_b[15:0], 16'b0};
            automatic fp_t beta_b     = fp_mul(beta, price_b_fp);

            s1_spread <= price_a_fp - beta_b - alpha;
            s1_valid  <= 1'b1;
        end else begin
            s1_valid <= 1'b0;
        end
    end

    assign current_spread = s1_spread;

    // ---- EMA of Spread Mean ----
    ema_calculator #(
        .ALPHA_SHIFT(EMA_SHIFT),
        .DATA_WIDTH(32)
    ) u_ema_mean (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .data_in    (s1_spread),
        .data_valid (s1_valid),
        .ema_out    (ema_mean_out),
        .ema_valid  (ema_mean_valid),
        .ema_reset  (1'b0),
        .ema_reset_val('0)
    );

    // ---- Compute (spread - mean)^2 for variance EMA ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spread_dev_sq <= '0;
            dev_sq_valid  <= 1'b0;
        end else if (enable && ema_mean_valid) begin
            automatic logic signed [31:0] dev = s1_spread - ema_mean_out;
            // Approximate square: use fp_mul
            spread_dev_sq <= fp_mul(dev, dev);
            dev_sq_valid  <= 1'b1;
        end else begin
            dev_sq_valid <= 1'b0;
        end
    end

    // ---- EMA of Variance ----
    ema_calculator #(
        .ALPHA_SHIFT(EMA_SHIFT),
        .DATA_WIDTH(32)
    ) u_ema_var (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .data_in    (spread_dev_sq),
        .data_valid (dev_sq_valid),
        .ema_out    (ema_var_out),
        .ema_valid  (ema_var_valid),
        .ema_reset  (1'b0),
        .ema_reset_val('0)
    );

    // ---- Stage 3: Z-Score & Signal Generation ----
    // z = (spread - mean) / std_dev
    // Approximation: compare (spread - mean)^2 vs threshold^2 * variance
    // This avoids square root entirely!
    // |z| > T  <=>  (spread - mean)^2 > T^2 * variance

    fp_t entry_thresh_sq;
    fp_t exit_thresh_sq;

    assign entry_thresh_sq = fp_mul(ENTRY_THRESHOLD, ENTRY_THRESHOLD);
    assign exit_thresh_sq  = fp_mul(EXIT_THRESHOLD, EXIT_THRESHOLD);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            order_a       <= '0;
            order_b       <= '0;
            signals_valid <= 1'b0;
            pos           <= POS_FLAT;
            current_zscore <= '0;
        end else if (enable && ema_var_valid) begin
            automatic logic signed [31:0] dev = s1_spread - ema_mean_out;
            automatic fp_t dev_sq_now = fp_mul(dev, dev);
            automatic fp_t entry_boundary = fp_mul(entry_thresh_sq, ema_var_out);
            automatic fp_t exit_boundary  = fp_mul(exit_thresh_sq, ema_var_out);

            // Approximate z-score for output (dev / sqrt(var) ≈ dev >> half_var_shift)
            if (ema_var_out != 0)
                current_zscore <= fp_div(dev, ema_var_out); // Approximate
            else
                current_zscore <= '0;

            signals_valid <= 1'b0;  // Default

            case (pos)
                POS_FLAT: begin
                    if (dev_sq_now > entry_boundary && dev > 0) begin
                        // Spread too high → SELL A, BUY B
                        order_a.valid    <= 1'b1;
                        order_a.signal   <= SIGNAL_SELL;
                        order_a.side     <= SIDE_ASK;
                        order_a.price    <= latched_a;
                        order_a.quantity <= DEFAULT_QTY;
                        order_a.order_id <= '0;
                        order_a.symbol_id <= 16'h0001;

                        order_b.valid    <= 1'b1;
                        order_b.signal   <= SIGNAL_BUY;
                        order_b.side     <= SIDE_BID;
                        order_b.price    <= latched_b;
                        order_b.quantity <= DEFAULT_QTY;
                        order_b.order_id <= '0;
                        order_b.symbol_id <= 16'h0002;

                        signals_valid <= 1'b1;
                        pos <= POS_SHORT_SPREAD;

                    end else if (dev_sq_now > entry_boundary && dev < 0) begin
                        // Spread too low → BUY A, SELL B
                        order_a.valid    <= 1'b1;
                        order_a.signal   <= SIGNAL_BUY;
                        order_a.side     <= SIDE_BID;
                        order_a.price    <= latched_a;
                        order_a.quantity <= DEFAULT_QTY;
                        order_a.order_id <= '0;
                        order_a.symbol_id <= 16'h0001;

                        order_b.valid    <= 1'b1;
                        order_b.signal   <= SIGNAL_SELL;
                        order_b.side     <= SIDE_ASK;
                        order_b.price    <= latched_b;
                        order_b.quantity <= DEFAULT_QTY;
                        order_b.order_id <= '0;
                        order_b.symbol_id <= 16'h0002;

                        signals_valid <= 1'b1;
                        pos <= POS_LONG_SPREAD;
                    end
                end

                POS_LONG_SPREAD, POS_SHORT_SPREAD: begin
                    if (dev_sq_now < exit_boundary) begin
                        // Mean reversion achieved → CLOSE position
                        // Reverse the entry trades
                        order_a.valid    <= 1'b1;
                        order_a.signal   <= (pos == POS_LONG_SPREAD) ? SIGNAL_SELL : SIGNAL_BUY;
                        order_a.side     <= (pos == POS_LONG_SPREAD) ? SIDE_ASK : SIDE_BID;
                        order_a.price    <= latched_a;
                        order_a.quantity <= DEFAULT_QTY;
                        order_a.order_id <= '0;
                        order_a.symbol_id <= 16'h0001;

                        order_b.valid    <= 1'b1;
                        order_b.signal   <= (pos == POS_LONG_SPREAD) ? SIGNAL_BUY : SIGNAL_SELL;
                        order_b.side     <= (pos == POS_LONG_SPREAD) ? SIDE_BID : SIDE_ASK;
                        order_b.price    <= latched_b;
                        order_b.quantity <= DEFAULT_QTY;
                        order_b.order_id <= '0;
                        order_b.symbol_id <= 16'h0002;

                        signals_valid <= 1'b1;
                        pos <= POS_FLAT;
                    end
                end

                default: pos <= POS_FLAT;
            endcase
        end else begin
            signals_valid <= 1'b0;
        end
    end

    assign position_state = pos;

endmodule
