// ============================================================================
// FPGA HFT Trading System - Feature Extractor
// Description: Converts raw order book data into normalized INT8 features
//              for the neural inference engine. Extracts 8 market
//              microstructure features in a single clock cycle.
//
// Features extracted:
//   [0] Price momentum    (mid_price - ema_mid) normalized
//   [1] Spread            (ask - bid) normalized
//   [2] Book imbalance    (bid_qty - ask_qty) / (bid_qty + ask_qty)
//   [3] Trade intensity   (recent trades / window) normalized
//   [4] Volatility        (ema of squared returns) normalized
//   [5] Bid depth         (total bid levels) normalized
//   [6] Ask depth         (total ask levels) normalized
//   [7] Mid-price return  (current - previous) signed
//
// Latency: 1 clock cycle
// ============================================================================

module feature_extractor
    import fixed_point_pkg::*;
#(
    parameter EMA_SHIFT = 4   // EMA smoothing for momentum/volatility
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Order Book Input
    input  top_of_book_t tob,
    input  logic         tob_valid,
    input  logic [7:0]   bid_depth,
    input  logic [7:0]   ask_depth,

    // Trade Event Input
    input  logic         trade_event,

    // Feature Output (8 × INT8)
    output logic signed [7:0] features [7:0],
    output logic              features_valid
);

    // ---- Internal State ----
    price_t     prev_mid;
    logic signed [31:0] ema_mid;      // EMA of mid-price
    logic signed [31:0] ema_vol;      // EMA of squared returns
    logic [15:0]        trade_count;  // Trades in current window
    logic [15:0]        trade_window; // Window counter
    logic               initialized;

    // ---- Normalization Helpers ----
    // Clamp signed 32-bit to INT8 range [-128, 127]
    function automatic logic signed [7:0] clamp_int8(input logic signed [31:0] val);
        if (val > 127)       return 8'sd127;
        else if (val < -128) return -8'sd128;
        else                 return val[7:0];
    endfunction

    // ---- Trade Counter (rolling window) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trade_count  <= '0;
            trade_window <= '0;
        end else if (enable) begin
            if (trade_window >= 16'd10000) begin  // Reset window (~15µs at 644MHz)
                trade_window <= '0;
                trade_count  <= '0;
            end else begin
                trade_window <= trade_window + 1;
                if (trade_event)
                    trade_count <= trade_count + 1;
            end
        end
    end

    // ---- Feature Computation (single cycle) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) features[i] <= '0;
            features_valid <= 1'b0;
            prev_mid       <= '0;
            ema_mid        <= '0;
            ema_vol        <= '0;
            initialized    <= 1'b0;
        end else if (enable && tob_valid && tob.valid) begin
            automatic logic signed [31:0] mid_s = $signed({1'b0, tob.mid_price});
            automatic logic signed [31:0] spread_s = $signed({1'b0, tob.best_ask}) -
                                                     $signed({1'b0, tob.best_bid});
            automatic logic signed [31:0] ret = mid_s - $signed({1'b0, prev_mid});
            automatic logic signed [31:0] momentum;
            automatic logic signed [31:0] imbalance_num;
            automatic logic signed [31:0] imbalance_den;

            if (!initialized) begin
                ema_mid     <= mid_s;
                prev_mid    <= tob.mid_price;
                initialized <= 1'b1;
                features_valid <= 1'b0;
            end else begin
                // Update EMAs
                ema_mid <= ema_mid + ((mid_s - ema_mid) >>> EMA_SHIFT);
                ema_vol <= ema_vol + (((ret * ret) - ema_vol) >>> EMA_SHIFT);

                // [0] Price momentum: (mid - ema_mid), normalized
                momentum = mid_s - ema_mid;
                features[0] <= clamp_int8(momentum);

                // [1] Spread: (ask - bid), normalized to small range
                features[1] <= clamp_int8(spread_s);

                // [2] Book imbalance: (bid_qty - ask_qty) / (bid_qty + ask_qty)
                // Approximation: (bid_qty - ask_qty) >> shift
                imbalance_num = $signed({1'b0, tob.bid_qty}) -
                                $signed({1'b0, tob.ask_qty});
                imbalance_den = $signed({1'b0, tob.bid_qty}) +
                                $signed({1'b0, tob.ask_qty});
                if (imbalance_den > 0)
                    features[2] <= clamp_int8((imbalance_num <<< 7) / imbalance_den);
                else
                    features[2] <= 8'sd0;

                // [3] Trade intensity: count normalized
                features[3] <= clamp_int8({16'b0, trade_count});

                // [4] Volatility: EMA of squared returns, normalized
                features[4] <= clamp_int8(ema_vol >>> 8);

                // [5] Bid depth
                features[5] <= clamp_int8({24'b0, bid_depth});

                // [6] Ask depth
                features[6] <= clamp_int8({24'b0, ask_depth});

                // [7] Mid-price return (signed)
                features[7] <= clamp_int8(ret);

                prev_mid       <= tob.mid_price;
                features_valid <= 1'b1;
            end
        end else begin
            features_valid <= 1'b0;
        end
    end

endmodule
