// ============================================================================
// FPGA HFT Trading System - Latency Arbiter (Cross-Exchange Arbitrage)
// Description: Monitors the same instrument across two exchanges in parallel.
//              Detects price discrepancies and fires simultaneous arbitrage
//              orders on both exchanges via dual independent TX pipelines.
// Latency:     ~3.1ns (2 clock cycles at 644 MHz)
// ============================================================================

module latency_arbiter
    import fixed_point_pkg::*;
#(
    parameter price_t COST_THRESHOLD = 32'd2,  // Min profit (ticks) after costs
    parameter qty_t   MAX_ARB_QTY    = 32'd100,
    parameter         POSITION_LIMIT = 32'd500,
    parameter         COOLDOWN_CYCLES = 32'd100 // Min cycles between arb trades
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Exchange 1 Top-of-Book (co-located, fastest feed)
    input  top_of_book_t exch1_tob,
    input  logic         exch1_valid,

    // Exchange 2 Top-of-Book
    input  top_of_book_t exch2_tob,
    input  logic         exch2_valid,

    // Orders for Exchange 1
    output order_out_t  exch1_order,
    output logic        exch1_order_valid,

    // Orders for Exchange 2
    output order_out_t  exch2_order,
    output logic        exch2_order_valid,

    // Diagnostics
    output logic signed [31:0] net_position,
    output logic [31:0]        arb_opportunities,
    output logic [31:0]        arb_executions,
    output fp_t                estimated_pnl
);

    // ---- State ----
    logic signed [31:0] position;
    logic [31:0]        cooldown_counter;
    logic [31:0]        r_arb_opps, r_arb_execs;
    fp_t                r_pnl;
    logic               cooldown_active;

    assign net_position      = position;
    assign arb_opportunities = r_arb_opps;
    assign arb_executions    = r_arb_execs;
    assign estimated_pnl     = r_pnl;
    assign cooldown_active   = (cooldown_counter > 0);

    // ---- Latched TOBs ----
    top_of_book_t lat_e1, lat_e2;
    logic e1_ready, e2_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_e1   <= '0;
            lat_e2   <= '0;
            e1_ready <= 1'b0;
            e2_ready <= 1'b0;
        end else if (enable) begin
            if (exch1_valid) begin lat_e1 <= exch1_tob; e1_ready <= 1'b1; end
            if (exch2_valid) begin lat_e2 <= exch2_tob; e2_ready <= 1'b1; end
        end
    end

    // ---- Cooldown Timer ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cooldown_counter <= '0;
        else if (cooldown_counter > 0)
            cooldown_counter <= cooldown_counter - 1;
    end

    // ---- Arbitrage Detection & Execution ----
    // Pipeline Stage 1: Compare prices (combinational)
    logic arb_buy_e2_sell_e1;   // Buy on Exch2, Sell on Exch1
    logic arb_buy_e1_sell_e2;   // Buy on Exch1, Sell on Exch2
    price_t profit_1to2, profit_2to1;
    qty_t   arb_qty;

    always_comb begin
        arb_buy_e2_sell_e1 = 1'b0;
        arb_buy_e1_sell_e2 = 1'b0;
        profit_1to2 = '0;
        profit_2to1 = '0;
        arb_qty     = '0;

        if (e1_ready && e2_ready && lat_e1.valid && lat_e2.valid) begin
            // Opportunity 1: Exch1 bid > Exch2 ask + costs
            if (lat_e1.best_bid > lat_e2.best_ask + COST_THRESHOLD) begin
                arb_buy_e2_sell_e1 = 1'b1;
                profit_1to2 = lat_e1.best_bid - lat_e2.best_ask - COST_THRESHOLD;
                arb_qty = (lat_e1.bid_qty < lat_e2.ask_qty) ? lat_e1.bid_qty : lat_e2.ask_qty;
                if (arb_qty > MAX_ARB_QTY) arb_qty = MAX_ARB_QTY;
            end

            // Opportunity 2: Exch2 bid > Exch1 ask + costs
            if (lat_e2.best_bid > lat_e1.best_ask + COST_THRESHOLD) begin
                arb_buy_e1_sell_e2 = 1'b1;
                profit_2to1 = lat_e2.best_bid - lat_e1.best_ask - COST_THRESHOLD;
                arb_qty = (lat_e2.bid_qty < lat_e1.ask_qty) ? lat_e2.bid_qty : lat_e1.ask_qty;
                if (arb_qty > MAX_ARB_QTY) arb_qty = MAX_ARB_QTY;
            end
        end
    end

    // Pipeline Stage 2: Generate orders
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exch1_order       <= '0;
            exch2_order       <= '0;
            exch1_order_valid <= 1'b0;
            exch2_order_valid <= 1'b0;
            position          <= '0;
            r_arb_opps        <= '0;
            r_arb_execs       <= '0;
            r_pnl             <= '0;
        end else if (enable) begin
            exch1_order_valid <= 1'b0;
            exch2_order_valid <= 1'b0;

            if (arb_buy_e2_sell_e1 && !cooldown_active &&
                position > -$signed(POSITION_LIMIT) &&
                position < $signed(POSITION_LIMIT)) begin

                r_arb_opps <= r_arb_opps + 1;

                // SELL on Exchange 1
                exch1_order.valid     <= 1'b1;
                exch1_order.signal    <= SIGNAL_SELL;
                exch1_order.side      <= SIDE_ASK;
                exch1_order.price     <= lat_e1.best_bid;
                exch1_order.quantity  <= arb_qty;
                exch1_order.order_id  <= '0;
                exch1_order.symbol_id <= 16'h0001;
                exch1_order_valid     <= 1'b1;

                // BUY on Exchange 2
                exch2_order.valid     <= 1'b1;
                exch2_order.signal    <= SIGNAL_BUY;
                exch2_order.side      <= SIDE_BID;
                exch2_order.price     <= lat_e2.best_ask;
                exch2_order.quantity  <= arb_qty;
                exch2_order.order_id  <= '0;
                exch2_order.symbol_id <= 16'h0001;
                exch2_order_valid     <= 1'b1;

                // Update state
                r_arb_execs      <= r_arb_execs + 1;
                r_pnl            <= r_pnl + {profit_1to2[15:0], 16'b0};
                cooldown_counter <= COOLDOWN_CYCLES;
                e1_ready         <= 1'b0;
                e2_ready         <= 1'b0;

            end else if (arb_buy_e1_sell_e2 && !cooldown_active &&
                         position > -$signed(POSITION_LIMIT) &&
                         position < $signed(POSITION_LIMIT)) begin

                r_arb_opps <= r_arb_opps + 1;

                // BUY on Exchange 1
                exch1_order.valid     <= 1'b1;
                exch1_order.signal    <= SIGNAL_BUY;
                exch1_order.side      <= SIDE_BID;
                exch1_order.price     <= lat_e1.best_ask;
                exch1_order.quantity  <= arb_qty;
                exch1_order.order_id  <= '0;
                exch1_order.symbol_id <= 16'h0001;
                exch1_order_valid     <= 1'b1;

                // SELL on Exchange 2
                exch2_order.valid     <= 1'b1;
                exch2_order.signal    <= SIGNAL_SELL;
                exch2_order.side      <= SIDE_ASK;
                exch2_order.price     <= lat_e2.best_bid;
                exch2_order.quantity  <= arb_qty;
                exch2_order.order_id  <= '0;
                exch2_order.symbol_id <= 16'h0001;
                exch2_order_valid     <= 1'b1;

                r_arb_execs      <= r_arb_execs + 1;
                r_pnl            <= r_pnl + {profit_2to1[15:0], 16'b0};
                cooldown_counter <= COOLDOWN_CYCLES;
                e1_ready         <= 1'b0;
                e2_ready         <= 1'b0;
            end
        end
    end

endmodule
