// ============================================================================
// FPGA HFT Trading System - Risk Manager (Stage 4)
// Description: Pre-trade risk checks in a single clock cycle. Validates
//              position limits, notional limits, order rate, price bands,
//              and circuit breaker status before allowing order transmission.
// Latency:     ~2-5ns (1 clock cycle — combinational checks + registered out)
// ============================================================================

module risk_manager
    import fixed_point_pkg::*;
#(
    parameter MAX_POSITION       = 32'd1000,     // Max absolute position
    parameter MAX_NOTIONAL       = 32'd10000000, // Max order notional (price * qty)
    parameter MAX_ORDERS_PER_SEC = 32'd1000,     // Rate limit
    parameter PRICE_BAND_TICKS   = 32'd100,      // Max deviation from reference
    parameter RATE_WINDOW_CYCLES = 32'd644000000 // 1 second at 644 MHz
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Order Input (from strategy engine)
    input  order_out_t  order_in,
    input  logic        order_valid,

    // Current state
    input  logic signed [31:0] current_position,
    input  price_t             reference_price,   // Last traded or mid price

    // Kill switch (emergency stop)
    input  logic        kill_switch,

    // Approved Order Output
    output order_out_t  order_out,
    output logic        order_approved,

    // Risk Status
    output risk_status_t risk_status,

    // Diagnostics
    output logic [31:0] reject_count,
    output logic [31:0] order_count_window
);

    // ---- Order Rate Counter ----
    logic [31:0] rate_counter;
    logic [31:0] rate_timer;

    // ---- Rate Limiting Timer ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_counter <= '0;
            rate_timer   <= '0;
        end else if (enable) begin
            if (rate_timer >= RATE_WINDOW_CYCLES) begin
                // Reset window
                rate_timer   <= '0;
                rate_counter <= '0;
            end else begin
                rate_timer <= rate_timer + 1;
                if (order_valid && order_in.valid)
                    rate_counter <= rate_counter + 1;
            end
        end
    end

    assign order_count_window = rate_counter;

    // ---- Combinational Risk Checks ----
    logic c_position_ok;
    logic c_notional_ok;
    logic c_rate_ok;
    logic c_price_ok;
    logic c_all_ok;

    logic [63:0] c_notional;
    logic signed [31:0] c_new_position;
    logic [31:0] c_price_diff;

    always_comb begin
        // Default
        c_position_ok = 1'b0;
        c_notional_ok = 1'b0;
        c_rate_ok     = 1'b0;
        c_price_ok    = 1'b0;
        c_notional    = '0;
        c_new_position = current_position;
        c_price_diff   = '0;

        if (order_valid && order_in.valid) begin
            // 1. Position Limit Check
            if (order_in.side == SIDE_BID)
                c_new_position = current_position + $signed({1'b0, order_in.quantity});
            else
                c_new_position = current_position - $signed({1'b0, order_in.quantity});

            c_position_ok = (c_new_position > -$signed(MAX_POSITION)) &&
                            (c_new_position < $signed(MAX_POSITION));

            // 2. Notional Limit Check
            c_notional = {32'b0, order_in.price} * {32'b0, order_in.quantity};
            c_notional_ok = (c_notional <= {32'b0, MAX_NOTIONAL});

            // 3. Order Rate Limit Check
            c_rate_ok = (rate_counter < MAX_ORDERS_PER_SEC);

            // 4. Price Band Check
            if (order_in.price >= reference_price)
                c_price_diff = order_in.price - reference_price;
            else
                c_price_diff = reference_price - order_in.price;

            c_price_ok = (c_price_diff <= PRICE_BAND_TICKS);
        end

        // All checks pass (and no kill switch)
        c_all_ok = c_position_ok && c_notional_ok && c_rate_ok && c_price_ok && !kill_switch;
    end

    // ---- Registered Output ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            order_out      <= '0;
            order_approved <= 1'b0;
            risk_status    <= '0;
            reject_count   <= '0;
        end else if (enable) begin
            if (kill_switch) begin
                // Kill switch: emit KILL_ALL signal
                order_out.valid     <= 1'b1;
                order_out.signal    <= SIGNAL_KILL_ALL;
                order_out.side      <= '0;
                order_out.price     <= '0;
                order_out.quantity  <= '0;
                order_out.order_id  <= '0;
                order_out.symbol_id <= '0;
                order_approved      <= 1'b1;

                risk_status.approved        <= 1'b0;
                risk_status.position_breach <= 1'b0;
                risk_status.notional_breach <= 1'b0;
                risk_status.rate_breach     <= 1'b0;
                risk_status.circuit_breaker <= 1'b1;
            end else if (order_valid && order_in.valid) begin
                if (c_all_ok) begin
                    // APPROVED — pass through order
                    order_out      <= order_in;
                    order_approved <= 1'b1;

                    risk_status.approved        <= 1'b1;
                    risk_status.position_breach <= 1'b0;
                    risk_status.notional_breach <= 1'b0;
                    risk_status.rate_breach     <= 1'b0;
                    risk_status.circuit_breaker <= 1'b0;
                end else begin
                    // REJECTED — block order
                    order_out      <= '0;
                    order_approved <= 1'b0;
                    reject_count   <= reject_count + 1;

                    risk_status.approved        <= 1'b0;
                    risk_status.position_breach <= !c_position_ok;
                    risk_status.notional_breach <= !c_notional_ok;
                    risk_status.rate_breach     <= !c_rate_ok;
                    risk_status.circuit_breaker <= 1'b0;
                end
            end else begin
                order_approved <= 1'b0;
                order_out.valid <= 1'b0;
            end
        end
    end

endmodule
