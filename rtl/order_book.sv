// ============================================================================
// FPGA HFT Trading System - Order Book Reconstruction Engine (Stage 2)
// Description: Maintains a sorted order book from parsed market data messages.
//              Uses on-chip BRAM arrays for price levels and hash table for
//              order ID mapping. Outputs top-of-book on every update.
// Latency:     ~10-20ns (1-2 clock cycles at 644 MHz)
// ============================================================================

module order_book
    import fixed_point_pkg::*;
#(
    parameter MAX_LEVELS = 16,      // Max price levels per side
    parameter MAX_ORDERS = 1024,    // Max tracked orders (hash table size)
    parameter HASH_BITS  = 10       // log2(MAX_ORDERS)
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Input from Market Data Parser
    input  parsed_msg_t msg_in,
    input  logic        msg_valid,

    // Top-of-Book Output
    output top_of_book_t tob,
    output logic         tob_valid,

    // Book statistics
    output logic [7:0]  bid_depth,
    output logic [7:0]  ask_depth
);

    // ---- Bid/Ask Price Level Arrays (sorted, on-chip BRAM) ----
    price_t     bid_prices  [MAX_LEVELS-1:0];
    qty_t       bid_qtys    [MAX_LEVELS-1:0];
    logic [7:0] bid_counts  [MAX_LEVELS-1:0];
    logic       bid_valid   [MAX_LEVELS-1:0];

    price_t     ask_prices  [MAX_LEVELS-1:0];
    qty_t       ask_qtys    [MAX_LEVELS-1:0];
    logic [7:0] ask_counts  [MAX_LEVELS-1:0];
    logic       ask_valid   [MAX_LEVELS-1:0];

    // ---- Order Hash Table (order_id -> {price, qty, side}) ----
    typedef struct packed {
        logic       valid;
        order_id_t  order_id;
        price_t     price;
        qty_t       quantity;
        side_t      side;
    } order_entry_t;

    order_entry_t order_table [MAX_ORDERS-1:0];

    // ---- Internal Signals ----
    logic [HASH_BITS-1:0] hash_idx;
    logic book_changed;
    logic [7:0] r_bid_depth, r_ask_depth;

    // ---- Simple Hash Function (XOR-fold) ----
    function automatic logic [HASH_BITS-1:0] hash_order_id(input order_id_t oid);
        return oid[HASH_BITS-1:0] ^ oid[2*HASH_BITS-1:HASH_BITS] ^
               oid[3*HASH_BITS-1:2*HASH_BITS];
    endfunction

    // ---- Find Price Level Index ----
    function automatic logic [3:0] find_bid_level(input price_t price);
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (bid_valid[i] && bid_prices[i] == price) return i[3:0];
        end
        return 4'hF; // Not found
    endfunction

    function automatic logic [3:0] find_ask_level(input price_t price);
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (ask_valid[i] && ask_prices[i] == price) return i[3:0];
        end
        return 4'hF; // Not found
    endfunction

    // ---- Find Empty Slot ----
    function automatic logic [3:0] find_empty_bid();
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (!bid_valid[i]) return i[3:0];
        end
        return 4'hF;
    endfunction

    function automatic logic [3:0] find_empty_ask();
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (!ask_valid[i]) return i[3:0];
        end
        return 4'hF;
    endfunction

    // ---- Main Processing Logic ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_LEVELS; i++) begin
                bid_valid[i]  <= 1'b0;
                bid_prices[i] <= '0;
                bid_qtys[i]   <= '0;
                bid_counts[i] <= '0;
                ask_valid[i]  <= 1'b0;
                ask_prices[i] <= '0;
                ask_qtys[i]   <= '0;
                ask_counts[i] <= '0;
            end
            for (int i = 0; i < MAX_ORDERS; i++) begin
                order_table[i].valid <= 1'b0;
            end
            book_changed <= 1'b0;
        end else if (enable && msg_valid && msg_in.valid) begin
            hash_idx <= hash_order_id(msg_in.order_id);
            book_changed <= 1'b0;

            case (msg_in.msg_type)
                // ---- ADD ORDER ----
                MSG_ADD: begin
                    // Store in hash table
                    order_table[hash_order_id(msg_in.order_id)].valid    <= 1'b1;
                    order_table[hash_order_id(msg_in.order_id)].order_id <= msg_in.order_id;
                    order_table[hash_order_id(msg_in.order_id)].price    <= msg_in.price;
                    order_table[hash_order_id(msg_in.order_id)].quantity <= msg_in.quantity;
                    order_table[hash_order_id(msg_in.order_id)].side     <= msg_in.side;

                    if (msg_in.side == SIDE_BID) begin
                        logic [3:0] lvl = find_bid_level(msg_in.price);
                        if (lvl != 4'hF) begin
                            // Level exists — add quantity
                            bid_qtys[lvl]   <= bid_qtys[lvl] + msg_in.quantity;
                            bid_counts[lvl] <= bid_counts[lvl] + 1;
                        end else begin
                            // New level
                            logic [3:0] empty = find_empty_bid();
                            if (empty != 4'hF) begin
                                bid_valid[empty]  <= 1'b1;
                                bid_prices[empty] <= msg_in.price;
                                bid_qtys[empty]   <= msg_in.quantity;
                                bid_counts[empty] <= 8'd1;
                            end
                        end
                    end else begin
                        logic [3:0] lvl = find_ask_level(msg_in.price);
                        if (lvl != 4'hF) begin
                            ask_qtys[lvl]   <= ask_qtys[lvl] + msg_in.quantity;
                            ask_counts[lvl] <= ask_counts[lvl] + 1;
                        end else begin
                            logic [3:0] empty = find_empty_ask();
                            if (empty != 4'hF) begin
                                ask_valid[empty]  <= 1'b1;
                                ask_prices[empty] <= msg_in.price;
                                ask_qtys[empty]   <= msg_in.quantity;
                                ask_counts[empty] <= 8'd1;
                            end
                        end
                    end
                    book_changed <= 1'b1;
                end

                // ---- DELETE ORDER ----
                MSG_DELETE: begin
                    logic [HASH_BITS-1:0] h = hash_order_id(msg_in.order_id);
                    if (order_table[h].valid && order_table[h].order_id == msg_in.order_id) begin
                        if (order_table[h].side == SIDE_BID) begin
                            logic [3:0] lvl = find_bid_level(order_table[h].price);
                            if (lvl != 4'hF) begin
                                if (bid_qtys[lvl] <= order_table[h].quantity) begin
                                    bid_valid[lvl] <= 1'b0;
                                    bid_qtys[lvl]  <= '0;
                                end else begin
                                    bid_qtys[lvl]   <= bid_qtys[lvl] - order_table[h].quantity;
                                    bid_counts[lvl] <= bid_counts[lvl] - 1;
                                end
                            end
                        end else begin
                            logic [3:0] lvl = find_ask_level(order_table[h].price);
                            if (lvl != 4'hF) begin
                                if (ask_qtys[lvl] <= order_table[h].quantity) begin
                                    ask_valid[lvl] <= 1'b0;
                                    ask_qtys[lvl]  <= '0;
                                end else begin
                                    ask_qtys[lvl]   <= ask_qtys[lvl] - order_table[h].quantity;
                                    ask_counts[lvl] <= ask_counts[lvl] - 1;
                                end
                            end
                        end
                        order_table[h].valid <= 1'b0;
                    end
                    book_changed <= 1'b1;
                end

                // ---- EXECUTE / TRADE ----
                MSG_EXECUTE, MSG_TRADE: begin
                    logic [HASH_BITS-1:0] h = hash_order_id(msg_in.order_id);
                    if (order_table[h].valid) begin
                        if (order_table[h].side == SIDE_BID) begin
                            logic [3:0] lvl = find_bid_level(order_table[h].price);
                            if (lvl != 4'hF) begin
                                if (bid_qtys[lvl] <= msg_in.quantity) begin
                                    bid_valid[lvl] <= 1'b0;
                                    bid_qtys[lvl]  <= '0;
                                end else begin
                                    bid_qtys[lvl] <= bid_qtys[lvl] - msg_in.quantity;
                                end
                            end
                        end else begin
                            logic [3:0] lvl = find_ask_level(order_table[h].price);
                            if (lvl != 4'hF) begin
                                if (ask_qtys[lvl] <= msg_in.quantity) begin
                                    ask_valid[lvl] <= 1'b0;
                                    ask_qtys[lvl]  <= '0;
                                end else begin
                                    ask_qtys[lvl] <= ask_qtys[lvl] - msg_in.quantity;
                                end
                            end
                        end
                        // Update remaining qty in order table
                        if (order_table[h].quantity <= msg_in.quantity)
                            order_table[h].valid <= 1'b0;
                        else
                            order_table[h].quantity <= order_table[h].quantity - msg_in.quantity;
                    end
                    book_changed <= 1'b1;
                end

                default: ;
            endcase
        end else begin
            book_changed <= 1'b0;
        end
    end

    // ---- Best Bid/Ask Computation (Combinational) ----
    price_t c_best_bid, c_best_ask;
    qty_t   c_bid_qty, c_ask_qty;
    logic   c_bid_found, c_ask_found;

    always_comb begin
        c_best_bid = '0;
        c_best_ask = '1;  // Max value (will find minimum)
        c_bid_qty  = '0;
        c_ask_qty  = '0;
        c_bid_found = 1'b0;
        c_ask_found = 1'b0;
        r_bid_depth = '0;
        r_ask_depth = '0;

        // Find best (highest) bid
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (bid_valid[i]) begin
                r_bid_depth = r_bid_depth + 1;
                if (bid_prices[i] > c_best_bid || !c_bid_found) begin
                    c_best_bid  = bid_prices[i];
                    c_bid_qty   = bid_qtys[i];
                    c_bid_found = 1'b1;
                end
            end
        end

        // Find best (lowest) ask
        for (int i = 0; i < MAX_LEVELS; i++) begin
            if (ask_valid[i]) begin
                r_ask_depth = r_ask_depth + 1;
                if (ask_prices[i] < c_best_ask || !c_ask_found) begin
                    c_best_ask  = ask_prices[i];
                    c_ask_qty   = ask_qtys[i];
                    c_ask_found = 1'b1;
                end
            end
        end
    end

    // ---- Top-of-Book Output Register ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tob       <= '0;
            tob_valid <= 1'b0;
            bid_depth <= '0;
            ask_depth <= '0;
        end else if (enable && book_changed) begin
            tob.valid     <= c_bid_found && c_ask_found;
            tob.best_bid  <= c_best_bid;
            tob.bid_qty   <= c_bid_qty;
            tob.best_ask  <= c_best_ask;
            tob.ask_qty   <= c_ask_qty;
            tob.mid_price <= (c_best_bid + c_best_ask) >> 1;  // Bit-shift divide by 2
            tob_valid     <= c_bid_found && c_ask_found;
            bid_depth     <= r_bid_depth;
            ask_depth     <= r_ask_depth;
        end else begin
            tob_valid <= 1'b0;
        end
    end

endmodule
