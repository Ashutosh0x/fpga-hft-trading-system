// ============================================================================
// FPGA HFT Trading System - Avellaneda-Stoikov Optimal Market Maker
// Description: Implements the Avellaneda-Stoikov (2008) stochastic control
//              market-making model in hardware. Computes reservation price
//              and optimal bid-ask spread using fixed-point arithmetic.
//
// Reference:   Avellaneda, M. & Stoikov, S. (2008) "High-frequency trading
//              in a limit order book" Quantitative Finance, 8(3), 217-224.
//
// Formulas:
//   Reservation price: r = s - q * γ * σ² * (T - t)
//   Optimal spread:    δ = γ * σ² * (T - t) + (2/γ) * ln(1 + γ/κ)
//   Bid price:         p_bid = r - δ/2
//   Ask price:         p_ask = r + δ/2
//
// Where:
//   s = mid price, q = inventory, γ = risk aversion,
//   σ = volatility, T-t = time remaining, κ = order book liquidity
//
// Implementation: All math in Q16.16 fixed-point. Logarithm via lookup table.
//                 3-stage pipeline for deterministic latency.
// Latency:        ~4.7ns (3 clock cycles at 644 MHz)
// ============================================================================

module avellaneda_stoikov
    import fixed_point_pkg::*;
#(
    parameter fp_t  GAMMA_DEFAULT    = 32'sh00010000, // γ = 1.0 (Q16.16)
    parameter fp_t  KAPPA_DEFAULT    = 32'sh000A0000, // κ = 10.0 (Q16.16)
    parameter       POSITION_LIMIT   = 32'd1000,
    parameter       VOL_EMA_SHIFT    = 6,             // Volatility EMA smoothing
    parameter       DEFAULT_QTY      = 32'd100
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Top-of-Book Input
    input  top_of_book_t tob,
    input  logic         tob_valid,

    // Parameters (from CPU via config registers)
    input  fp_t         gamma,          // Risk aversion coefficient
    input  fp_t         kappa,          // Order book liquidity parameter
    input  fp_t         time_remaining, // T - t (session time fraction, Q16.16)

    // Fill Report Input
    input  logic        fill_valid,
    input  side_t       fill_side,
    input  qty_t        fill_qty,

    // Order Output
    output order_out_t  bid_order,
    output order_out_t  ask_order,
    output logic        orders_valid,

    // Status & Diagnostics
    output logic signed [31:0] current_position,
    output fp_t                reservation_price,
    output fp_t                optimal_spread,
    output fp_t                realized_volatility,
    output logic               quoting_active
);

    // ---- Internal State ----
    logic signed [31:0] position;
    assign current_position = position;

    // ---- Volatility Estimation (EMA of squared returns) ----
    fp_t prev_mid;
    fp_t vol_sq;        // σ² estimate (EMA of squared returns)
    logic vol_initialized;

    // ---- Pipeline Registers ----
    // Stage 1: Compute σ², q*γ*σ²*(T-t)
    logic   s1_valid;
    fp_t    s1_mid;
    fp_t    s1_inventory_penalty;  // q * γ * σ² * (T-t)
    fp_t    s1_vol_spread_term;    // γ * σ² * (T-t)

    // Stage 2: Compute reservation price and spread
    logic   s2_valid;
    fp_t    s2_reservation;        // r = s - inventory_penalty
    fp_t    s2_spread;             // δ = vol_term + log_term

    // Stage 3: Compute bid/ask and output
    fp_t    prev_bid, prev_ask;

    // ---- Logarithm Lookup Table ----
    // ln(1 + γ/κ) approximation using lookup table
    // For γ/κ in range [0, 2], ln(1+x) ≈ x - x²/2 + x³/3 (Taylor)
    // Or use piecewise linear LUT for speed
    //
    // LUT: 256 entries covering x = 0.0 to 4.0 (step = 4/256 = 0.015625)
    // Value stored as Q16.16

    fp_t ln_lut [0:255];

    // Initialize LUT (synthesizable initial block)
    initial begin
        // ln(1 + x) for x = i * (4.0/256)
        // Pre-computed values in Q16.16
        ln_lut[0]   = 32'sh00000000; // ln(1.0)   = 0.000
        ln_lut[1]   = 32'sh00000FE0; // ln(1.016) ≈ 0.0155
        ln_lut[2]   = 32'sh00001FA0; // ln(1.031) ≈ 0.0308
        ln_lut[4]   = 32'sh00003F00; // ln(1.063) ≈ 0.0608
        ln_lut[8]   = 32'sh00007C00; // ln(1.125) ≈ 0.1178
        ln_lut[16]  = 32'sh0000F400; // ln(1.250) ≈ 0.2231
        ln_lut[32]  = 32'sh0001D800; // ln(1.500) ≈ 0.4055
        ln_lut[64]  = 32'sh00034800; // ln(2.000) ≈ 0.6931
        ln_lut[128] = 32'sh00049C00; // ln(3.000) ≈ 1.0986
        ln_lut[192] = 32'sh00056400; // ln(4.000) ≈ 1.3863
        ln_lut[255] = 32'sh00060800; // ln(5.000) ≈ 1.6094
        // Remaining entries interpolated by hardware
        for (int i = 0; i < 256; i++) begin
            if (ln_lut[i] == 0 && i > 0) begin
                // Linear interpolation approximation: ln(1+x) ≈ x for small x
                // Use Taylor: ln(1+x) ≈ x - x²/2
                int x_fp = (i * 32'sh00040000) >> 8; // x in Q16.16
                int x_sq = (x_fp * x_fp) >> 16;
                ln_lut[i] = x_fp - (x_sq >> 1);
            end
        end
    end

    // ---- LUT Lookup Function ----
    function automatic fp_t lookup_ln(input fp_t x);
        // x is Q16.16, map to LUT index [0,255]
        // LUT covers [0, 4.0], so index = x * 256 / 4 = x * 64
        logic [31:0] idx;
        if (x <= 0) return 0;
        idx = (x * 64) >> 16;  // Convert Q16.16 to integer index
        if (idx > 255) idx = 255;
        return ln_lut[idx[7:0]];
    endfunction

    // ---- Position Update ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            position <= '0;
        end else if (enable && fill_valid) begin
            if (fill_side == SIDE_BID)
                position <= position + $signed({1'b0, fill_qty});
            else
                position <= position - $signed({1'b0, fill_qty});
        end
    end

    // ---- Realized Volatility Estimation (EMA of squared returns) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mid        <= '0;
            vol_sq          <= 32'sh00010000; // Default σ² = 1.0
            vol_initialized <= 1'b0;
        end else if (enable && tob_valid && tob.valid) begin
            if (!vol_initialized) begin
                prev_mid        <= tob.mid_price;
                vol_initialized <= 1'b1;
            end else begin
                // Return = current_mid - prev_mid
                fp_t ret = $signed(tob.mid_price) - $signed(prev_mid);
                fp_t ret_sq = fp_mul(ret, ret);
                // EMA update: vol_sq += (ret_sq - vol_sq) >> VOL_EMA_SHIFT
                vol_sq   <= vol_sq + ((ret_sq - vol_sq) >>> VOL_EMA_SHIFT);
                prev_mid <= tob.mid_price;
            end
        end
    end

    assign realized_volatility = vol_sq;

    // ==================================================================
    // PIPELINE STAGE 1: Inventory penalty & volatility spread term
    // ==================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid            <= 1'b0;
            s1_mid              <= '0;
            s1_inventory_penalty <= '0;
            s1_vol_spread_term  <= '0;
        end else if (enable && tob_valid && tob.valid) begin
            // inventory_penalty = q * γ * σ² * (T-t)
            fp_t gamma_vol = fp_mul(gamma, vol_sq);        // γ * σ²
            fp_t time_adj  = fp_mul(gamma_vol, time_remaining); // γ*σ²*(T-t)

            s1_inventory_penalty <= fp_mul({{16{position[31]}}, position[15:0], 16'b0} >>> 16,
                                           time_adj);
            s1_vol_spread_term   <= time_adj;
            s1_mid               <= {tob.mid_price[15:0], 16'b0}; // Convert to Q16.16
            s1_valid             <= 1'b1;
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // ==================================================================
    // PIPELINE STAGE 2: Reservation price & optimal spread
    // ==================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid       <= 1'b0;
            s2_reservation <= '0;
            s2_spread      <= '0;
        end else if (enable && s1_valid) begin
            // Reservation price: r = s - q * γ * σ² * (T-t)
            s2_reservation <= s1_mid - s1_inventory_penalty;

            // Optimal spread: δ = γ*σ²*(T-t) + (2/γ) * ln(1 + γ/κ)
            fp_t gamma_over_kappa = fp_div(gamma, kappa);
            fp_t ln_term = lookup_ln(gamma_over_kappa);
            fp_t two_over_gamma = fp_div(32'sh00020000, gamma); // 2.0 / γ
            fp_t log_component = fp_mul(two_over_gamma, ln_term);

            s2_spread <= s1_vol_spread_term + log_component;
            s2_valid  <= 1'b1;
        end else begin
            s2_valid <= 1'b0;
        end
    end

    assign reservation_price = s2_reservation;
    assign optimal_spread    = s2_spread;

    // ==================================================================
    // PIPELINE STAGE 3: Generate bid/ask quotes
    // ==================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bid_order      <= '0;
            ask_order      <= '0;
            orders_valid   <= 1'b0;
            prev_bid       <= '0;
            prev_ask       <= '0;
            quoting_active <= 1'b0;
        end else if (enable && s2_valid) begin
            fp_t half_spread = s2_spread >>> 1;  // δ/2
            fp_t my_bid = s2_reservation - half_spread;
            fp_t my_ask = s2_reservation + half_spread;
            logic pos_ok;

            // Convert from Q16.16 back to integer price (ticks)
            price_t bid_price = my_bid[31:16]; // Integer part
            price_t ask_price = my_ask[31:16];

            // Position safety check
            pos_ok = ($signed(position) > -$signed(POSITION_LIMIT)) &&
                     ($signed(position) < $signed(POSITION_LIMIT));

            if (pos_ok && bid_price > 0 && ask_price > bid_price) begin
                // Only re-quote if prices changed
                if (bid_price != prev_bid[31:16] || ask_price != prev_ask[31:16]) begin
                    bid_order.valid     <= 1'b1;
                    bid_order.signal    <= SIGNAL_BUY;
                    bid_order.side      <= SIDE_BID;
                    bid_order.price     <= bid_price;
                    bid_order.quantity  <= DEFAULT_QTY;
                    bid_order.order_id  <= '0;
                    bid_order.symbol_id <= 16'h0001;

                    ask_order.valid     <= 1'b1;
                    ask_order.signal    <= SIGNAL_SELL;
                    ask_order.side      <= SIDE_ASK;
                    ask_order.price     <= ask_price;
                    ask_order.quantity  <= DEFAULT_QTY;
                    ask_order.order_id  <= '0;
                    ask_order.symbol_id <= 16'h0001;

                    orders_valid   <= 1'b1;
                    prev_bid       <= my_bid;
                    prev_ask       <= my_ask;
                    quoting_active <= 1'b1;
                end else begin
                    orders_valid <= 1'b0;
                end
            end else begin
                // Position limit or invalid spread — cancel
                bid_order.valid  <= 1'b1;
                bid_order.signal <= SIGNAL_CANCEL;
                ask_order.valid  <= 1'b1;
                ask_order.signal <= SIGNAL_CANCEL;
                orders_valid     <= 1'b1;
                quoting_active   <= 1'b0;
            end
        end else begin
            orders_valid <= 1'b0;
        end
    end

endmodule
