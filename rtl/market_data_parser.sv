// ============================================================================
// FPGA HFT Trading System - Market Data Parser (Stage 1)
// Description: Parses binary market data messages (ITCH-like protocol) from
//              raw byte stream. Single-cycle output once message is assembled.
//              Pipelined FSM: IDLE -> HEADER -> PAYLOAD -> OUTPUT
// Latency:     ~5-15ns (1-3 clock cycles at 644 MHz)
// ============================================================================

module market_data_parser
    import fixed_point_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,          // Active-low reset
    input  logic        enable,

    // AXI-Stream Input (from network PHY/MAC)
    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [7:0]  s_axis_tkeep,

    // Parsed Message Output
    output parsed_msg_t parsed_msg,
    output logic        parsed_valid
);

    // ---- FSM States ----
    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_WORD0    = 3'd1,     // Bytes 0-7:  msg_type(1) + order_id(7 of 8)
        ST_WORD1    = 3'd2,     // Bytes 8-15: order_id(1) + symbol_id(2) + side(1) + price(4)
        ST_WORD2    = 3'd3,     // Bytes 16-23: quantity(4) + timestamp(4 of 8)
        ST_WORD3    = 3'd4,     // Bytes 24-27: timestamp(4) + padding(4)
        ST_OUTPUT   = 3'd5
    } state_t;

    state_t state, state_next;

    // ---- Internal Registers ----
    logic [7:0]     r_msg_type;
    order_id_t      r_order_id;
    symbol_id_t     r_symbol_id;
    side_t          r_side;
    price_t         r_price;
    qty_t           r_quantity;
    logic [63:0]    r_timestamp;

    // ---- State Machine ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (enable) begin
            state <= state_next;
        end
    end

    // ---- Next State Logic ----
    always_comb begin
        state_next = state;
        case (state)
            ST_IDLE:    if (s_axis_tvalid) state_next = ST_WORD0;
            ST_WORD0:   if (s_axis_tvalid) state_next = ST_WORD1;
            ST_WORD1:   if (s_axis_tvalid) state_next = ST_WORD2;
            ST_WORD2:   if (s_axis_tvalid) state_next = ST_WORD3;
            ST_WORD3:   state_next = ST_OUTPUT;
            ST_OUTPUT:  state_next = ST_IDLE;
            default:    state_next = ST_IDLE;
        endcase
    end

    // ---- Data Capture (Big-Endian Network Byte Order) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_msg_type  <= '0;
            r_order_id  <= '0;
            r_symbol_id <= '0;
            r_side      <= '0;
            r_price     <= '0;
            r_quantity  <= '0;
            r_timestamp <= '0;
        end else if (enable && s_axis_tvalid) begin
            case (state)
                ST_IDLE: begin
                    // Word 0: [msg_type(8)][order_id(56 of 64)]
                    r_msg_type         <= s_axis_tdata[63:56];
                    r_order_id[63:8]   <= s_axis_tdata[55:0];
                end
                ST_WORD0: begin
                    // Word 1: [order_id(8)][symbol_id(16)][side(8)][price(32)]
                    r_order_id[7:0]    <= s_axis_tdata[63:56];
                    r_symbol_id        <= s_axis_tdata[55:40];
                    r_side             <= s_axis_tdata[39:32];
                    r_price            <= s_axis_tdata[31:0];
                end
                ST_WORD1: begin
                    // Word 2: [quantity(32)][timestamp(32 of 64)]
                    r_quantity         <= s_axis_tdata[63:32];
                    r_timestamp[63:32] <= s_axis_tdata[31:0];
                end
                ST_WORD2: begin
                    // Word 3: [timestamp(32)][padding(32)]
                    r_timestamp[31:0]  <= s_axis_tdata[63:32];
                end
                default: ;
            endcase
        end
    end

    // ---- Output Assignment ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parsed_msg  <= '0;
            parsed_valid <= 1'b0;
        end else if (enable) begin
            if (state == ST_WORD3) begin
                parsed_msg.valid     <= 1'b1;
                parsed_msg.msg_type  <= r_msg_type;
                parsed_msg.order_id  <= r_order_id;
                parsed_msg.symbol_id <= r_symbol_id;
                parsed_msg.side      <= r_side;
                parsed_msg.price     <= r_price;
                parsed_msg.quantity   <= r_quantity;
                parsed_msg.timestamp <= r_timestamp;
                parsed_valid         <= 1'b1;
            end else begin
                parsed_valid         <= 1'b0;
                parsed_msg.valid     <= 1'b0;
            end
        end
    end

    // ---- Backpressure ----
    assign s_axis_tready = enable && (state != ST_OUTPUT);

endmodule
