// ============================================================================
// FPGA HFT Trading System - Top Level Integration
// Description: Connects the full tick-to-trade pipeline:
//              Network RX → Parser → Order Book → Strategy → Risk → Order TX
//              Total pipeline latency target: < 100 nanoseconds
// Target FPGA: AMD Alveo UL3524 (Virtex UltraScale+ @ 644 MHz)
// ============================================================================

module trading_system_top
    import fixed_point_pkg::*;
#(
    // ---- Order Book Parameters ----
    parameter OB_MAX_LEVELS     = 16,
    parameter OB_MAX_ORDERS     = 1024,

    // ---- Market Maker Parameters ----
    parameter MM_SPREAD_TARGET  = 32'd2,
    parameter MM_POSITION_LIMIT = 32'd1000,
    parameter MM_SKEW_SHIFT     = 4,

    // ---- Risk Parameters ----
    parameter RISK_MAX_POSITION = 32'd1000,
    parameter RISK_MAX_NOTIONAL = 32'd10000000,
    parameter RISK_MAX_RATE     = 32'd1000,
    parameter RISK_PRICE_BAND   = 32'd100
)(
    // ---- Clock & Reset ----
    input  logic        clk,            // 644 MHz system clock
    input  logic        rst_n,          // Active-low async reset
    input  logic        enable,         // Global enable

    // ---- Network RX (AXI-Stream from PHY/MAC) ----
    input  logic [63:0] rx_tdata,
    input  logic        rx_tvalid,
    output logic        rx_tready,
    input  logic        rx_tlast,
    input  logic [7:0]  rx_tkeep,

    // ---- Network TX (AXI-Stream to PHY/MAC) ----
    output logic [63:0] tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast,
    output logic [7:0]  tx_tkeep,

    // ---- Control Interface (from CPU via PCIe/AXI-Lite) ----
    input  logic        kill_switch,     // Emergency stop
    input  logic [1:0]  strategy_select, // 0=MM, 1=StatArb, 2=Both

    // ---- Status & Diagnostics ----
    output logic signed [31:0] position_out,
    output logic [31:0]        reject_count_out,
    output logic [63:0]        orders_sent_out,
    output logic [63:0]        last_order_id_out,
    output logic               quoting_active_out,
    output logic [7:0]         bid_depth_out,
    output logic [7:0]         ask_depth_out,

    // ---- LED Indicators ----
    output logic [3:0]  led_status
);

    // ====================================================================
    //  INTERNAL SIGNALS
    // ====================================================================

    // ---- Free-Running Timestamp Counter ----
    logic [63:0] timestamp_counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            timestamp_counter <= '0;
        else
            timestamp_counter <= timestamp_counter + 1;
    end

    // ---- Stage 1: Parser Outputs ----
    parsed_msg_t    parsed_msg;
    logic           parsed_valid;

    // ---- Stage 2: Order Book Outputs ----
    top_of_book_t   tob;
    logic           tob_valid;
    logic [7:0]     bid_depth, ask_depth;

    // ---- Stage 3: Strategy Outputs ----
    order_out_t     mm_bid_order, mm_ask_order;
    logic           mm_orders_valid;
    logic signed [31:0] mm_position;
    logic           mm_quoting;

    // ---- Strategy Mux Output ----
    order_out_t     strategy_order;
    logic           strategy_valid;

    // ---- Stage 4: Risk Manager Outputs ----
    order_out_t     risk_order;
    logic           risk_approved;
    risk_status_t   risk_status;
    logic [31:0]    reject_count;
    logic [31:0]    order_count_window;

    // ---- Stage 5: Order Generator Outputs ----
    logic [63:0]    orders_sent;
    logic [63:0]    last_oid;

    // ====================================================================
    //  STAGE 1: MARKET DATA PARSER
    // ====================================================================
    market_data_parser u_parser (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (enable),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tkeep   (rx_tkeep),
        .parsed_msg     (parsed_msg),
        .parsed_valid   (parsed_valid)
    );

    // ====================================================================
    //  STAGE 2: ORDER BOOK RECONSTRUCTION
    // ====================================================================
    order_book #(
        .MAX_LEVELS     (OB_MAX_LEVELS),
        .MAX_ORDERS     (OB_MAX_ORDERS)
    ) u_order_book (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (enable),
        .msg_in         (parsed_msg),
        .msg_valid      (parsed_valid),
        .tob            (tob),
        .tob_valid      (tob_valid),
        .bid_depth      (bid_depth),
        .ask_depth      (ask_depth)
    );

    // ====================================================================
    //  STAGE 3: STRATEGY ENGINES
    // ====================================================================

    // ---- 3a: Market Maker ----
    market_maker #(
        .SPREAD_TARGET    (MM_SPREAD_TARGET),
        .POSITION_LIMIT   (MM_POSITION_LIMIT),
        .SKEW_SHIFT       (MM_SKEW_SHIFT)
    ) u_market_maker (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && (strategy_select == 2'd0 || strategy_select == 2'd2)),
        .tob              (tob),
        .tob_valid        (tob_valid),
        .fill_valid       (1'b0),       // TODO: connect fill reports
        .fill_side        (SIDE_BID),
        .fill_qty         (32'd0),
        .bid_order        (mm_bid_order),
        .ask_order        (mm_ask_order),
        .orders_valid     (mm_orders_valid),
        .current_position (mm_position),
        .quoting_active   (mm_quoting)
    );

    // ---- Strategy Output Mux ----
    // Priority: bid order first, then ask order (round-robin in production)
    always_comb begin
        strategy_order = '0;
        strategy_valid = 1'b0;

        if (mm_orders_valid) begin
            // Send bid order (ask follows next cycle in production)
            strategy_order = mm_bid_order;
            strategy_valid = 1'b1;
        end
    end

    // ====================================================================
    //  STAGE 4: RISK MANAGER
    // ====================================================================
    risk_manager #(
        .MAX_POSITION       (RISK_MAX_POSITION),
        .MAX_NOTIONAL       (RISK_MAX_NOTIONAL),
        .MAX_ORDERS_PER_SEC (RISK_MAX_RATE),
        .PRICE_BAND_TICKS   (RISK_PRICE_BAND)
    ) u_risk_manager (
        .clk                (clk),
        .rst_n              (rst_n),
        .enable             (enable),
        .order_in           (strategy_order),
        .order_valid        (strategy_valid),
        .current_position   (mm_position),
        .reference_price    (tob.mid_price),
        .kill_switch        (kill_switch),
        .order_out          (risk_order),
        .order_approved     (risk_approved),
        .risk_status        (risk_status),
        .reject_count       (reject_count),
        .order_count_window (order_count_window)
    );

    // ====================================================================
    //  STAGE 5: ORDER GENERATOR & TRANSMITTER
    // ====================================================================
    order_generator u_order_gen (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .order_in         (risk_order),
        .order_valid      (risk_approved),
        .timestamp        (timestamp_counter),
        .m_axis_tdata     (tx_tdata),
        .m_axis_tvalid    (tx_tvalid),
        .m_axis_tready    (tx_tready),
        .m_axis_tlast     (tx_tlast),
        .m_axis_tkeep     (tx_tkeep),
        .orders_sent_count(orders_sent),
        .last_order_id    (last_oid)
    );

    // ====================================================================
    //  STATUS OUTPUTS
    // ====================================================================
    assign position_out      = mm_position;
    assign reject_count_out  = reject_count;
    assign orders_sent_out   = orders_sent;
    assign last_order_id_out = last_oid;
    assign quoting_active_out = mm_quoting;
    assign bid_depth_out     = bid_depth;
    assign ask_depth_out     = ask_depth;

    // ---- LED Indicators ----
    assign led_status[0] = enable;                          // System enabled
    assign led_status[1] = mm_quoting;                      // Actively quoting
    assign led_status[2] = risk_status.circuit_breaker;     // Circuit breaker active
    assign led_status[3] = |reject_count[3:0];              // Recent rejections

endmodule
