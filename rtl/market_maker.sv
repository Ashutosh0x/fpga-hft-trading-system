// ============================================================================
// FPGA HFT Trading System - Market Making Strategy Engine (Stage 3)
// Description: Implements hardware market-making with weighted mid-price,
//              inventory skew, and quote generation. 2-stage pipeline.
// Latency:     ~10-30ns (2 clock cycles at 644 MHz)
// ============================================================================

module market_maker
    import fixed_point_pkg::*;
#(
    parameter SPREAD_TARGET    = 32'd2,         // Target spread in ticks
    parameter POSITION_LIMIT   = 32'd1000,      // Max abs position
    parameter MIN_QUOTE_CHANGE = 32'd1,         // Min change to re-quote
    parameter SKEW_SHIFT       = 4              // Skew = position >> SKEW_SHIFT
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Top-of-Book Input (from order_book)
    input  top_of_book_t tob,
    input  logic         tob_valid,

    // Fill Report Input (updates position)
    input  logic        fill_valid,
    input  side_t       fill_side,
    input  qty_t        fill_qty,

    // Order Output
    output order_out_t  bid_order,
    output order_out_t  ask_order,
    output logic        orders_valid,

    // Status
    output logic signed [31:0] current_position,
    output logic               quoting_active
);

    // ---- Pipeline Registers ----
    // Stage 1: Compute weighted mid + skew
    logic        s1_valid;
    price_t      s1_wmid;
    logic signed [31:0] s1_skew;
    price_t      s1_best_bid, s1_best_ask;

    // Stage 2: Generate quotes
    price_t      s2_my_bid, s2_my_ask;
    price_t      prev_my_bid, prev_my_ask;

    // ---- Position Tracking ----
    logic signed [31:0] position;

    assign current_position = position;

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

    // ---- Pipeline Stage 1: Weighted Mid-Price & Skew ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid    <= 1'b0;
            s1_wmid     <= '0;
            s1_skew     <= '0;
            s1_best_bid <= '0;
            s1_best_ask <= '0;
        end else if (enable && tob_valid && tob.valid) begin
            // Weighted mid-price:
            // wmid = (best_bid * ask_qty + best_ask * bid_qty) / (bid_qty + ask_qty)
            // Use 64-bit intermediate to avoid overflow
            automatic logic [63:0] numerator;
            automatic logic [31:0] denominator;

            numerator   = ({32'b0, tob.best_bid} * {32'b0, tob.ask_qty}) +
                          ({32'b0, tob.best_ask} * {32'b0, tob.bid_qty});
            denominator = tob.bid_qty + tob.ask_qty;

            if (denominator != 0)
                s1_wmid <= numerator / {32'b0, denominator};
            else
                s1_wmid <= tob.mid_price;  // Fallback to simple mid

            // Inventory skew (arithmetic right shift = divide by 2^SKEW_SHIFT)
            s1_skew <= position >>> SKEW_SHIFT;

            s1_best_bid <= tob.best_bid;
            s1_best_ask <= tob.best_ask;
            s1_valid    <= 1'b1;
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // ---- Pipeline Stage 2: Quote Generation ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bid_order    <= '0;
            ask_order    <= '0;
            orders_valid <= 1'b0;
            prev_my_bid  <= '0;
            prev_my_ask  <= '0;
            quoting_active <= 1'b0;
        end else if (enable && s1_valid) begin
            // Compute my quote prices
            automatic price_t half_spread = SPREAD_TARGET >> 1;
            automatic price_t my_bid_price;
            automatic price_t my_ask_price;
            automatic logic   pos_ok;

            // my_bid = wmid - half_spread - skew
            // my_ask = wmid + half_spread - skew
            if (s1_skew >= 0) begin
                my_bid_price = s1_wmid - half_spread - s1_skew[31:0];
                my_ask_price = s1_wmid + half_spread - s1_skew[31:0];
            end else begin
                my_bid_price = s1_wmid - half_spread + (-s1_skew[31:0]);
                my_ask_price = s1_wmid + half_spread + (-s1_skew[31:0]);
            end

            // Position limit check
            pos_ok = ($signed(position) > -$signed(POSITION_LIMIT)) &&
                     ($signed(position) < $signed(POSITION_LIMIT));

            // Only emit if quote changed by more than MIN_QUOTE_CHANGE
            if (pos_ok) begin
                automatic logic bid_changed, ask_changed;
                bid_changed = (my_bid_price > prev_my_bid + MIN_QUOTE_CHANGE) ||
                              (my_bid_price + MIN_QUOTE_CHANGE < prev_my_bid) ||
                              (prev_my_bid == 0);
                ask_changed = (my_ask_price > prev_my_ask + MIN_QUOTE_CHANGE) ||
                              (my_ask_price + MIN_QUOTE_CHANGE < prev_my_ask) ||
                              (prev_my_ask == 0);

                if (bid_changed || ask_changed) begin
                    // Bid order
                    bid_order.valid     <= 1'b1;
                    bid_order.signal    <= SIGNAL_BUY;
                    bid_order.side      <= SIDE_BID;
                    bid_order.price     <= my_bid_price;
                    bid_order.quantity  <= 32'd100;  // Default lot size
                    bid_order.order_id  <= '0;       // Assigned by order generator
                    bid_order.symbol_id <= '0;

                    // Ask order
                    ask_order.valid     <= 1'b1;
                    ask_order.signal    <= SIGNAL_SELL;
                    ask_order.side      <= SIDE_ASK;
                    ask_order.price     <= my_ask_price;
                    ask_order.quantity  <= 32'd100;
                    ask_order.order_id  <= '0;
                    ask_order.symbol_id <= '0;

                    orders_valid   <= 1'b1;
                    prev_my_bid    <= my_bid_price;
                    prev_my_ask    <= my_ask_price;
                    quoting_active <= 1'b1;
                end else begin
                    orders_valid <= 1'b0;
                end
            end else begin
                // Position limit breached — cancel all quotes
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
