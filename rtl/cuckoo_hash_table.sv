// ============================================================================
// FPGA HFT Trading System - Cuckoo Hash Table
// Description: O(1) worst-case lookup hash table for order ID → order entry
//              mapping. Uses two hash functions and two tables. On collision,
//              displaces existing entry ("cuckoo" eviction). Guarantees
//              constant-time lookup critical for deterministic HFT latency.
//
// Reference:   Pagh & Rodler (2004) "Cuckoo Hashing"
//              Adapted for FPGA with dual-port BRAM and XOR hash functions.
//
// Performance: Lookup = 1 cycle, Insert = 1-3 cycles (amortized)
// ============================================================================

module cuckoo_hash_table
    import fixed_point_pkg::*;
#(
    parameter TABLE_SIZE  = 2048,          // Per table (total = 2 * TABLE_SIZE)
    parameter ADDR_BITS   = 11,            // log2(TABLE_SIZE)
    parameter MAX_EVICT   = 8             // Max cuckoo evictions before rehash
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Lookup Interface ----
    input  order_id_t   lookup_key,
    input  logic        lookup_valid,
    output logic        lookup_hit,
    output price_t      lookup_price,
    output qty_t        lookup_qty,
    output side_t       lookup_side,
    output logic        lookup_done,

    // ---- Insert Interface ----
    input  order_id_t   insert_key,
    input  price_t      insert_price,
    input  qty_t        insert_qty,
    input  side_t       insert_side,
    input  logic        insert_valid,
    output logic        insert_done,
    output logic        insert_fail,    // Table full / too many evictions

    // ---- Delete Interface ----
    input  order_id_t   delete_key,
    input  logic        delete_valid,
    output logic        delete_done,
    output logic        delete_hit,

    // ---- Update Quantity (for partial fills) ----
    input  order_id_t   update_key,
    input  qty_t        update_new_qty,
    input  logic        update_valid,
    output logic        update_done,

    // ---- Status ----
    output logic [31:0] entry_count,
    output logic        table_full
);

    // ---- Entry Structure ----
    typedef struct packed {
        logic       valid;
        order_id_t  key;       // 64-bit order ID
        price_t     price;     // 32-bit
        qty_t       qty;       // 32-bit
        side_t      side;      // 8-bit
    } entry_t;

    // ---- Dual Tables (BRAM) ----
    (* ram_style = "block" *)
    entry_t table_a [TABLE_SIZE-1:0];
    (* ram_style = "block" *)
    entry_t table_b [TABLE_SIZE-1:0];

    // ---- Hash Functions (two independent hashes) ----
    // Hash A: XOR-fold with golden ratio mixing
    function automatic logic [ADDR_BITS-1:0] hash_a(input order_id_t key);
        logic [63:0] mixed;
        mixed = key ^ (key >> 17) ^ (key >> 34);
        mixed = mixed * 64'h9E3779B97F4A7C15;  // Golden ratio constant
        return mixed[ADDR_BITS-1:0];
    endfunction

    // Hash B: Different mixing with Fibonacci hashing
    function automatic logic [ADDR_BITS-1:0] hash_b(input order_id_t key);
        logic [63:0] mixed;
        mixed = key ^ (key >> 13) ^ (key >> 29) ^ (key >> 47);
        mixed = mixed * 64'hC4CEB9FE1A85EC53;  // Different constant
        return mixed[ADDR_BITS-1:0];
    endfunction

    // ---- State Machine ----
    typedef enum logic [3:0] {
        IDLE          = 4'd0,
        LOOKUP_READ   = 4'd1,
        LOOKUP_CHECK  = 4'd2,
        INSERT_CHECK  = 4'd3,
        INSERT_WRITE  = 4'd4,
        INSERT_EVICT  = 4'd5,
        DELETE_READ   = 4'd6,
        DELETE_WRITE  = 4'd7,
        UPDATE_READ   = 4'd8,
        UPDATE_WRITE  = 4'd9
    } state_t;

    state_t state;

    // ---- Working Registers ----
    logic [ADDR_BITS-1:0] addr_a, addr_b;
    entry_t               read_a, read_b;
    entry_t               evict_entry;
    logic [3:0]           evict_count;
    logic [31:0]          r_entry_count;
    order_id_t            work_key;

    assign entry_count = r_entry_count;
    assign table_full  = (r_entry_count >= (TABLE_SIZE * 2 - 64));

    // ---- Main State Machine ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            lookup_hit     <= 1'b0;
            lookup_done    <= 1'b0;
            insert_done    <= 1'b0;
            insert_fail    <= 1'b0;
            delete_done    <= 1'b0;
            delete_hit     <= 1'b0;
            update_done    <= 1'b0;
            r_entry_count  <= '0;
            evict_count    <= '0;

            for (int i = 0; i < TABLE_SIZE; i++) begin
                table_a[i].valid <= 1'b0;
                table_b[i].valid <= 1'b0;
            end
        end else begin
            // Clear single-cycle outputs
            lookup_done <= 1'b0;
            insert_done <= 1'b0;
            insert_fail <= 1'b0;
            delete_done <= 1'b0;
            update_done <= 1'b0;

            case (state)
                IDLE: begin
                    if (lookup_valid) begin
                        addr_a   <= hash_a(lookup_key);
                        addr_b   <= hash_b(lookup_key);
                        work_key <= lookup_key;
                        state    <= LOOKUP_READ;
                    end else if (insert_valid) begin
                        addr_a <= hash_a(insert_key);
                        addr_b <= hash_b(insert_key);
                        evict_entry.valid <= 1'b1;
                        evict_entry.key   <= insert_key;
                        evict_entry.price <= insert_price;
                        evict_entry.qty   <= insert_qty;
                        evict_entry.side  <= insert_side;
                        evict_count       <= '0;
                        state             <= INSERT_CHECK;
                    end else if (delete_valid) begin
                        addr_a   <= hash_a(delete_key);
                        addr_b   <= hash_b(delete_key);
                        work_key <= delete_key;
                        state    <= DELETE_READ;
                    end else if (update_valid) begin
                        addr_a   <= hash_a(update_key);
                        addr_b   <= hash_b(update_key);
                        work_key <= update_key;
                        state    <= UPDATE_READ;
                    end
                end

                // ---- LOOKUP ----
                LOOKUP_READ: begin
                    read_a <= table_a[addr_a];
                    read_b <= table_b[addr_b];
                    state  <= LOOKUP_CHECK;
                end

                LOOKUP_CHECK: begin
                    if (read_a.valid && read_a.key == work_key) begin
                        lookup_hit   <= 1'b1;
                        lookup_price <= read_a.price;
                        lookup_qty   <= read_a.qty;
                        lookup_side  <= read_a.side;
                    end else if (read_b.valid && read_b.key == work_key) begin
                        lookup_hit   <= 1'b1;
                        lookup_price <= read_b.price;
                        lookup_qty   <= read_b.qty;
                        lookup_side  <= read_b.side;
                    end else begin
                        lookup_hit <= 1'b0;
                    end
                    lookup_done <= 1'b1;
                    state       <= IDLE;
                end

                // ---- INSERT (with cuckoo eviction) ----
                INSERT_CHECK: begin
                    read_a <= table_a[addr_a];
                    read_b <= table_b[addr_b];
                    state  <= INSERT_WRITE;
                end

                INSERT_WRITE: begin
                    if (!read_a.valid) begin
                        // Slot A empty — insert here
                        table_a[addr_a] <= evict_entry;
                        insert_done     <= 1'b1;
                        r_entry_count   <= r_entry_count + 1;
                        state           <= IDLE;
                    end else if (!read_b.valid) begin
                        // Slot B empty — insert here
                        table_b[addr_b] <= evict_entry;
                        insert_done     <= 1'b1;
                        r_entry_count   <= r_entry_count + 1;
                        state           <= IDLE;
                    end else if (evict_count < MAX_EVICT) begin
                        // Both full — evict from table A, insert our entry
                        table_a[addr_a] <= evict_entry;
                        evict_entry     <= read_a;  // Displaced entry
                        // Compute new hash for displaced entry
                        addr_a <= hash_a(read_a.key);
                        addr_b <= hash_b(read_a.key);
                        evict_count <= evict_count + 1;
                        state <= INSERT_CHECK;  // Try again with displaced entry
                    end else begin
                        // Too many evictions — insert failed
                        insert_fail <= 1'b1;
                        insert_done <= 1'b1;
                        state       <= IDLE;
                    end
                end

                // ---- DELETE ----
                DELETE_READ: begin
                    read_a <= table_a[addr_a];
                    read_b <= table_b[addr_b];
                    state  <= DELETE_WRITE;
                end

                DELETE_WRITE: begin
                    if (read_a.valid && read_a.key == work_key) begin
                        table_a[addr_a].valid <= 1'b0;
                        delete_hit      <= 1'b1;
                        r_entry_count   <= r_entry_count - 1;
                    end else if (read_b.valid && read_b.key == work_key) begin
                        table_b[addr_b].valid <= 1'b0;
                        delete_hit      <= 1'b1;
                        r_entry_count   <= r_entry_count - 1;
                    end else begin
                        delete_hit <= 1'b0;
                    end
                    delete_done <= 1'b1;
                    state       <= IDLE;
                end

                // ---- UPDATE ----
                UPDATE_READ: begin
                    read_a <= table_a[addr_a];
                    read_b <= table_b[addr_b];
                    state  <= UPDATE_WRITE;
                end

                UPDATE_WRITE: begin
                    if (read_a.valid && read_a.key == work_key) begin
                        table_a[addr_a].qty <= update_new_qty;
                    end else if (read_b.valid && read_b.key == work_key) begin
                        table_b[addr_b].qty <= update_new_qty;
                    end
                    update_done <= 1'b1;
                    state       <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
