// ============================================================================
// FPGA HFT Trading System - Fixed Point Arithmetic Package
// Description: Defines fixed-point types and arithmetic operations used
//              throughout the trading pipeline. Avoids floating-point to
//              maintain deterministic, single-cycle execution.
// ============================================================================

package fixed_point_pkg;

    // ---- Fixed-Point Configuration ----
    // Q16.16 format: 16 integer bits, 16 fractional bits = 32-bit total
    // Range: -32768.0 to +32767.99998 with precision of ~0.0000153
    parameter INT_BITS  = 16;
    parameter FRAC_BITS = 16;
    parameter FP_WIDTH  = INT_BITS + FRAC_BITS;  // 32

    typedef logic signed [FP_WIDTH-1:0] fp_t;

    // ---- Price/Quantity Types ----
    // Prices stored as integers (in ticks/cents)
    typedef logic [31:0] price_t;
    typedef logic [31:0] qty_t;
    typedef logic [63:0] order_id_t;
    typedef logic [7:0]  side_t;
    typedef logic [15:0] symbol_id_t;

    // ---- Side Constants ----
    parameter side_t SIDE_BID = 8'h42;  // 'B'
    parameter side_t SIDE_ASK = 8'h53;  // 'S'

    // ---- Message Types (ITCH-like) ----
    parameter logic [7:0] MSG_ADD       = 8'h41;  // 'A' - Add Order
    parameter logic [7:0] MSG_DELETE    = 8'h44;  // 'D' - Delete Order
    parameter logic [7:0] MSG_REPLACE   = 8'h55;  // 'U' - Replace Order
    parameter logic [7:0] MSG_EXECUTE   = 8'h45;  // 'E' - Order Executed
    parameter logic [7:0] MSG_TRADE     = 8'h50;  // 'P' - Trade (non-cross)

    // ---- Trade Signal Types ----
    typedef enum logic [2:0] {
        SIGNAL_NONE     = 3'd0,
        SIGNAL_BUY      = 3'd1,
        SIGNAL_SELL     = 3'd2,
        SIGNAL_CANCEL   = 3'd3,
        SIGNAL_REPLACE  = 3'd4,
        SIGNAL_KILL_ALL = 3'd5
    } trade_signal_t;

    // ---- Parsed Message Structure ----
    typedef struct packed {
        logic           valid;
        logic [7:0]     msg_type;
        order_id_t      order_id;
        symbol_id_t     symbol_id;
        side_t          side;
        price_t         price;
        qty_t           quantity;
        logic [63:0]    timestamp;
    } parsed_msg_t;

    // ---- Order Book Entry ----
    typedef struct packed {
        logic       valid;
        price_t     price;
        qty_t       total_qty;
        logic [7:0] order_count;
    } book_level_t;

    // ---- Top of Book ----
    typedef struct packed {
        logic       valid;
        price_t     best_bid;
        qty_t       bid_qty;
        price_t     best_ask;
        qty_t       ask_qty;
        price_t     mid_price;
    } top_of_book_t;

    // ---- Order Output ----
    typedef struct packed {
        logic           valid;
        trade_signal_t  signal;
        side_t          side;
        price_t         price;
        qty_t           quantity;
        order_id_t      order_id;
        symbol_id_t     symbol_id;
    } order_out_t;

    // ---- Risk Status ----
    typedef struct packed {
        logic   approved;
        logic   position_breach;
        logic   notional_breach;
        logic   rate_breach;
        logic   circuit_breaker;
    } risk_status_t;

    // ---- Fixed-Point Helper Functions ----

    // Convert integer to fixed-point
    function automatic fp_t int_to_fp(input logic signed [INT_BITS-1:0] val);
        return fp_t'(val) <<< FRAC_BITS;
    endfunction

    // Fixed-point multiply (returns Q16.16 from two Q16.16 inputs)
    function automatic fp_t fp_mul(input fp_t a, input fp_t b);
        logic signed [2*FP_WIDTH-1:0] product;
        product = a * b;
        return product[FP_WIDTH+FRAC_BITS-1 : FRAC_BITS];
    endfunction

    // Fixed-point divide (a / b) using shift-based approximation
    function automatic fp_t fp_div(input fp_t a, input fp_t b);
        logic signed [2*FP_WIDTH-1:0] numerator;
        numerator = fp_t'(a) <<< FRAC_BITS;
        return numerator / b;
    endfunction

    // Absolute value
    function automatic fp_t fp_abs(input fp_t val);
        return (val < 0) ? -val : val;
    endfunction

endpackage
