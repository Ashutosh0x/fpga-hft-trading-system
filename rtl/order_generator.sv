// ============================================================================
// FPGA HFT Trading System - Order Generator & Transmitter (Stage 5)
// Description: Constructs raw binary order messages from order_out_t signals
//              and outputs them as Ethernet-ready frames via AXI-Stream.
//              Assigns sequential order IDs and timestamps.
// Latency:     ~5-10ns (1-2 clock cycles at 644 MHz)
// ============================================================================

module order_generator
    import fixed_point_pkg::*;
#(
    parameter SYMBOL_ID_DEFAULT = 16'h0001
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Order Input (from risk manager)
    input  order_out_t  order_in,
    input  logic        order_valid,

    // Free-running timestamp counter
    input  logic [63:0] timestamp,

    // AXI-Stream Output (to network TX PHY/MAC)
    output logic [63:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [7:0]  m_axis_tkeep,

    // Diagnostics
    output logic [63:0] orders_sent_count,
    output logic [63:0] last_order_id
);

    // ---- FSM States ----
    typedef enum logic [2:0] {
        TX_IDLE   = 3'd0,
        TX_WORD0  = 3'd1,
        TX_WORD1  = 3'd2,
        TX_WORD2  = 3'd3,
        TX_WORD3  = 3'd4,
        TX_DONE   = 3'd5
    } tx_state_t;

    tx_state_t tx_state;

    // ---- Order ID Counter ----
    logic [63:0] next_order_id;

    // ---- Latched Order ----
    order_out_t latched_order;
    logic [63:0] latched_ts;
    logic [63:0] latched_oid;

    // ---- Order Message Format (same as parser, 4 x 64-bit words) ----
    // Word 0: [msg_type(8)][order_id(56)]
    // Word 1: [order_id(8)][symbol_id(16)][side(8)][price(32)]
    // Word 2: [quantity(32)][timestamp(32)]
    // Word 3: [timestamp(32)][padding(32)]

    // Convert signal to message type
    function automatic logic [7:0] signal_to_msg_type(input trade_signal_t sig);
        case (sig)
            SIGNAL_BUY:      return 8'h4E;  // 'N' - New Order
            SIGNAL_SELL:     return 8'h4E;  // 'N' - New Order
            SIGNAL_CANCEL:   return 8'h58;  // 'X' - Cancel Order
            SIGNAL_REPLACE:  return 8'h55;  // 'U' - Replace Order
            SIGNAL_KILL_ALL: return 8'h4B;  // 'K' - Kill All
            default:         return 8'h00;
        endcase
    endfunction

    // ---- TX State Machine ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state         <= TX_IDLE;
            next_order_id    <= 64'd1;
            latched_order    <= '0;
            latched_ts       <= '0;
            latched_oid      <= '0;
            m_axis_tdata     <= '0;
            m_axis_tvalid    <= 1'b0;
            m_axis_tlast     <= 1'b0;
            m_axis_tkeep     <= '0;
            orders_sent_count <= '0;
            last_order_id    <= '0;
        end else if (enable) begin
            case (tx_state)
                TX_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;

                    if (order_valid && order_in.valid) begin
                        // Latch the order
                        latched_order <= order_in;
                        latched_ts    <= timestamp;
                        latched_oid   <= next_order_id;
                        next_order_id <= next_order_id + 1;
                        tx_state      <= TX_WORD0;
                    end
                end

                TX_WORD0: begin
                    // Word 0: [msg_type(8)][order_id(56 MSBs)]
                    m_axis_tdata  <= {signal_to_msg_type(latched_order.signal),
                                     latched_oid[63:8]};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tkeep  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;

                    if (m_axis_tready)
                        tx_state <= TX_WORD1;
                end

                TX_WORD1: begin
                    // Word 1: [order_id(8 LSBs)][symbol_id(16)][side(8)][price(32)]
                    m_axis_tdata  <= {latched_oid[7:0],
                                     (latched_order.symbol_id == '0) ?
                                         SYMBOL_ID_DEFAULT : latched_order.symbol_id,
                                     latched_order.side,
                                     latched_order.price};
                    m_axis_tvalid <= 1'b1;

                    if (m_axis_tready)
                        tx_state <= TX_WORD2;
                end

                TX_WORD2: begin
                    // Word 2: [quantity(32)][timestamp_hi(32)]
                    m_axis_tdata  <= {latched_order.quantity, latched_ts[63:32]};
                    m_axis_tvalid <= 1'b1;

                    if (m_axis_tready)
                        tx_state <= TX_WORD3;
                end

                TX_WORD3: begin
                    // Word 3: [timestamp_lo(32)][padding(32)]
                    m_axis_tdata  <= {latched_ts[31:0], 32'h00000000};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= 1'b1;  // End of frame
                    m_axis_tkeep  <= 8'hF0; // Only upper 4 bytes valid

                    if (m_axis_tready)
                        tx_state <= TX_DONE;
                end

                TX_DONE: begin
                    m_axis_tvalid     <= 1'b0;
                    m_axis_tlast      <= 1'b0;
                    orders_sent_count <= orders_sent_count + 1;
                    last_order_id     <= latched_oid;
                    tx_state          <= TX_IDLE;
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule
