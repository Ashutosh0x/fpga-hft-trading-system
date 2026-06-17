// ============================================================================
// FPGA HFT Trading System - Full-Stack SmartNIC (Problem #7)
// Description: The ENTIRE trading stack in a single FPGA. No CPU in the
//              critical path. Wire-to-wire execution: packet in → order out.
//              CPU only used for async parameter updates via PCIe.
//
// THIS IS FRONTIER: Nobody ships a true "serverless" trading system.
//
// Pipeline:
//   10GbE RX → Speculative Parser → Order Book → Feature Extractor →
//   Deterministic AI (Neural Net) → Avellaneda-Stoikov Strategy →
//   Risk Manager → Order Generator → Session Override → 10GbE TX
//
// Total Latency Target: < 50ns wire-to-wire (with AI!)
// ============================================================================

module smartnic_top
    import fixed_point_pkg::*;
#(
    // Book parameters
    parameter OB_MAX_LEVELS     = 16,
    parameter OB_MAX_ORDERS     = 1024,
    // Strategy parameters
    parameter MM_POSITION_LIMIT = 32'd1000,
    // Risk parameters
    parameter RISK_MAX_POSITION = 32'd1000,
    parameter RISK_MAX_NOTIONAL = 32'd10000000,
    parameter RISK_MAX_RATE     = 32'd1000,
    parameter RISK_PRICE_BAND   = 32'd100,
    // AI parameters
    parameter AI_PIPELINE_DEPTH = 12
)(
    // ---- Clock & Reset ----
    input  logic        clk,            // 644 MHz
    input  logic        rst_n,
    input  logic        enable,

    // ---- 10GbE Network RX (AXI-Stream) ----
    input  logic [63:0] rx_tdata,
    input  logic        rx_tvalid,
    output logic        rx_tready,
    input  logic        rx_tlast,
    input  logic [7:0]  rx_tkeep,

    // ---- 10GbE Network TX (AXI-Stream) ----
    output logic [63:0] tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast,
    output logic [7:0]  tx_tkeep,

    // ---- PCIe Config Bus (async, non-critical) ----
    input  logic        kill_switch,
    input  logic [1:0]  strategy_select,  // 0=MM, 1=AS, 2=AI+AS, 3=AI+MM
    input  fp_t         cfg_gamma,
    input  fp_t         cfg_kappa,
    input  fp_t         cfg_time_remaining,

    // ---- Weight Loading (from CPU) ----
    input  logic        wt_load_en,
    input  logic [1:0]  wt_layer,
    input  logic [7:0]  wt_row,
    input  logic [7:0]  wt_col,
    input  logic signed [3:0] wt_value,
    input  logic signed [7:0] wt_bias,

    // ---- Status LEDs ----
    output logic [7:0]  led_status,

    // ---- Diagnostics (readable via PCIe) ----
    output logic signed [31:0] diag_position,
    output logic [31:0]        diag_rejects,
    output logic [63:0]        diag_orders_sent,
    output logic [63:0]        diag_messages_parsed,
    output logic [63:0]        diag_parse_errors,
    output logic [7:0]         diag_bid_depth,
    output logic [7:0]         diag_ask_depth,
    output logic [31:0]        diag_ai_pipeline_depth,
    output logic               diag_ai_active,
    output logic               diag_quoting
);

    // ====================================================================
    //  FREE-RUNNING TIMESTAMP
    // ====================================================================
    logic [63:0] timestamp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) timestamp <= '0;
        else        timestamp <= timestamp + 1;
    end

    // ====================================================================
    //  STAGE 1: SPECULATIVE PARALLEL PARSER
    // ====================================================================
    parsed_msg_t parsed_msg;
    logic        parsed_valid;
    logic [63:0] msg_count;
    logic [63:0] parse_errors;

    speculative_parser u_parser (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (enable),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tkeep   (rx_tkeep),
        .parsed_msg     (parsed_msg),
        .parsed_valid   (parsed_valid),
        .msg_count      (msg_count),
        .parse_errors   (parse_errors)
    );

    // ====================================================================
    //  STAGE 2: ORDER BOOK
    // ====================================================================
    top_of_book_t tob;
    logic         tob_valid;
    logic [7:0]   bid_depth, ask_depth;

    order_book #(
        .MAX_LEVELS(OB_MAX_LEVELS),
        .MAX_ORDERS(OB_MAX_ORDERS)
    ) u_book (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .msg_in     (parsed_msg),
        .msg_valid  (parsed_valid),
        .tob        (tob),
        .tob_valid  (tob_valid),
        .bid_depth  (bid_depth),
        .ask_depth  (ask_depth)
    );

    // ====================================================================
    //  STAGE 3: DETERMINISTIC AI PIPELINE (Feature Extract + Neural Net)
    // ====================================================================
    trade_signal_t     ai_prediction;
    logic signed [7:0] ai_confidence;
    logic              ai_valid;
    logic [31:0]       ai_depth;

    deterministic_ai_pipeline #(
        .TOTAL_PIPELINE_DEPTH(AI_PIPELINE_DEPTH)
    ) u_ai (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && (strategy_select >= 2'd2)),
        .tob              (tob),
        .tob_valid        (tob_valid),
        .bid_depth        (bid_depth),
        .ask_depth        (ask_depth),
        .prediction       (ai_prediction),
        .confidence       (ai_confidence),
        .prediction_valid (ai_valid),
        .pipeline_depth   (ai_depth),
        .jitter_alert     ()
    );

    // ====================================================================
    //  STAGE 4: AVELLANEDA-STOIKOV STRATEGY
    // ====================================================================
    order_out_t as_bid, as_ask;
    logic       as_valid;
    logic signed [31:0] as_position;
    fp_t        as_reservation, as_spread, as_vol;
    logic       as_quoting;

    avellaneda_stoikov u_as (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && (strategy_select != 2'd0)),
        .tob              (tob),
        .tob_valid        (tob_valid),
        .gamma            (cfg_gamma),
        .kappa            (cfg_kappa),
        .time_remaining   (cfg_time_remaining),
        .fill_valid       (1'b0),
        .fill_side        (SIDE_BID),
        .fill_qty         (32'd0),
        .bid_order        (as_bid),
        .ask_order        (as_ask),
        .orders_valid     (as_valid),
        .current_position (as_position),
        .reservation_price(as_reservation),
        .optimal_spread   (as_spread),
        .realized_volatility(as_vol),
        .quoting_active   (as_quoting)
    );

    // ====================================================================
    //  STAGE 4b: MARKET MAKER (alternative strategy)
    // ====================================================================
    order_out_t mm_bid, mm_ask;
    logic       mm_valid;
    logic signed [31:0] mm_position;
    logic       mm_quoting;

    market_maker #(
        .POSITION_LIMIT(MM_POSITION_LIMIT)
    ) u_mm (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && (strategy_select == 2'd0 || strategy_select == 2'd3)),
        .tob              (tob),
        .tob_valid        (tob_valid),
        .fill_valid       (1'b0),
        .fill_side        (SIDE_BID),
        .fill_qty         (32'd0),
        .bid_order        (mm_bid),
        .ask_order        (mm_ask),
        .orders_valid     (mm_valid),
        .current_position (mm_position),
        .quoting_active   (mm_quoting)
    );

    // ====================================================================
    //  STRATEGY MUX + AI OVERRIDE
    // ====================================================================
    order_out_t strat_order;
    logic       strat_valid;
    logic signed [31:0] active_position;

    always_comb begin
        strat_order     = '0;
        strat_valid     = 1'b0;
        active_position = '0;

        case (strategy_select)
            2'd0: begin  // Pure Market Maker
                if (mm_valid) begin strat_order = mm_bid; strat_valid = 1'b1; end
                active_position = mm_position;
            end
            2'd1: begin  // Pure Avellaneda-Stoikov
                if (as_valid) begin strat_order = as_bid; strat_valid = 1'b1; end
                active_position = as_position;
            end
            2'd2: begin  // AI + Avellaneda-Stoikov
                if (as_valid && ai_valid) begin
                    // AI can OVERRIDE: if AI says HOLD, don't send order
                    if (ai_prediction != SIGNAL_NONE) begin
                        strat_order = as_bid;
                        strat_valid = 1'b1;
                    end
                end
                active_position = as_position;
            end
            2'd3: begin  // AI + Market Maker
                if (mm_valid && ai_valid) begin
                    if (ai_prediction != SIGNAL_NONE) begin
                        strat_order = mm_bid;
                        strat_valid = 1'b1;
                    end
                end
                active_position = mm_position;
            end
        endcase
    end

    // ====================================================================
    //  STAGE 5: RISK MANAGER
    // ====================================================================
    order_out_t  risk_order;
    logic        risk_approved;
    risk_status_t risk_status;
    logic [31:0] reject_count;

    risk_manager #(
        .MAX_POSITION      (RISK_MAX_POSITION),
        .MAX_NOTIONAL      (RISK_MAX_NOTIONAL),
        .MAX_ORDERS_PER_SEC(RISK_MAX_RATE),
        .PRICE_BAND_TICKS  (RISK_PRICE_BAND)
    ) u_risk (
        .clk                (clk),
        .rst_n              (rst_n),
        .enable             (enable),
        .order_in           (strat_order),
        .order_valid        (strat_valid),
        .current_position   (active_position),
        .reference_price    (tob.mid_price),
        .kill_switch        (kill_switch),
        .order_out          (risk_order),
        .order_approved     (risk_approved),
        .risk_status        (risk_status),
        .reject_count       (reject_count),
        .order_count_window ()
    );

    // ====================================================================
    //  STAGE 6: ORDER GENERATOR → TX
    // ====================================================================
    logic [63:0] orders_sent;
    logic [63:0] last_oid;

    order_generator u_ordergen (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .order_in         (risk_order),
        .order_valid      (risk_approved),
        .timestamp        (timestamp),
        .m_axis_tdata     (tx_tdata),
        .m_axis_tvalid    (tx_tvalid),
        .m_axis_tready    (tx_tready),
        .m_axis_tlast     (tx_tlast),
        .m_axis_tkeep     (tx_tkeep),
        .orders_sent_count(orders_sent),
        .last_order_id    (last_oid)
    );

    // ====================================================================
    //  DIAGNOSTICS
    // ====================================================================
    assign diag_position         = active_position;
    assign diag_rejects          = reject_count;
    assign diag_orders_sent      = orders_sent;
    assign diag_messages_parsed  = msg_count;
    assign diag_parse_errors     = parse_errors;
    assign diag_bid_depth        = bid_depth;
    assign diag_ask_depth        = ask_depth;
    assign diag_ai_pipeline_depth = ai_depth;
    assign diag_ai_active        = ai_valid;
    assign diag_quoting          = as_quoting || mm_quoting;

    // ---- LED Status ----
    assign led_status[0] = enable;
    assign led_status[1] = as_quoting || mm_quoting;
    assign led_status[2] = ai_valid;
    assign led_status[3] = risk_status.circuit_breaker;
    assign led_status[4] = |reject_count[3:0];
    assign led_status[5] = tob_valid;
    assign led_status[6] = parsed_valid;
    assign led_status[7] = kill_switch;

endmodule
