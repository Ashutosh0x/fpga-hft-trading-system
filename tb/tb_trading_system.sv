// ============================================================================
// FPGA HFT Trading System - Top-Level Testbench
// Description: Comprehensive testbench that feeds market data messages through
//              the full pipeline and verifies order generation. Measures
//              tick-to-trade latency in clock cycles.
// ============================================================================

`timescale 1ns / 1ps

module tb_trading_system;

    import fixed_point_pkg::*;

    // ---- Clock & Reset ----
    logic        clk;
    logic        rst_n;
    logic        enable;

    // ---- Network RX ----
    logic [63:0] rx_tdata;
    logic        rx_tvalid;
    logic        rx_tready;
    logic        rx_tlast;
    logic [7:0]  rx_tkeep;

    // ---- Network TX ----
    logic [63:0] tx_tdata;
    logic        tx_tvalid;
    logic        tx_tready;
    logic        tx_tlast;
    logic [7:0]  tx_tkeep;

    // ---- Control ----
    logic        kill_switch;
    logic [1:0]  strategy_select;

    // ---- Status ----
    logic signed [31:0] position_out;
    logic [31:0]        reject_count_out;
    logic [63:0]        orders_sent_out;
    logic [63:0]        last_order_id_out;
    logic               quoting_active_out;
    logic [7:0]         bid_depth_out;
    logic [7:0]         ask_depth_out;
    logic [3:0]         led_status;

    // ---- Clock Generation (644 MHz → ~1.553ns period) ----
    parameter CLK_PERIOD = 1.553;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- DUT Instantiation ----
    trading_system_top #(
        .OB_MAX_LEVELS     (16),
        .OB_MAX_ORDERS     (1024),
        .MM_SPREAD_TARGET  (32'd2),
        .MM_POSITION_LIMIT (32'd1000),
        .RISK_MAX_POSITION (32'd1000),
        .RISK_MAX_NOTIONAL (32'd10000000),
        .RISK_MAX_RATE     (32'd1000),
        .RISK_PRICE_BAND   (32'd100)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .enable             (enable),
        .rx_tdata           (rx_tdata),
        .rx_tvalid          (rx_tvalid),
        .rx_tready          (rx_tready),
        .rx_tlast           (rx_tlast),
        .rx_tkeep           (rx_tkeep),
        .tx_tdata           (tx_tdata),
        .tx_tvalid          (tx_tvalid),
        .tx_tready          (tx_tready),
        .tx_tlast           (tx_tlast),
        .tx_tkeep           (tx_tkeep),
        .kill_switch        (kill_switch),
        .strategy_select    (strategy_select),
        .position_out       (position_out),
        .reject_count_out   (reject_count_out),
        .orders_sent_out    (orders_sent_out),
        .last_order_id_out  (last_order_id_out),
        .quoting_active_out (quoting_active_out),
        .bid_depth_out      (bid_depth_out),
        .ask_depth_out      (ask_depth_out),
        .led_status         (led_status)
    );

    // ---- TX always ready ----
    assign tx_tready = 1'b1;

    // ---- Latency Measurement ----
    time rx_start_time;
    time tx_end_time;
    integer latency_cycles;

    // ---- Helper Task: Send a 4-word market data message ----
    task automatic send_market_msg(
        input logic [7:0]  msg_type,
        input logic [63:0] order_id,
        input logic [15:0] symbol_id,
        input logic [7:0]  side,
        input logic [31:0] price,
        input logic [31:0] quantity,
        input logic [63:0] timestamp
    );
        // Word 0: [msg_type(8)][order_id(56 MSBs)]
        @(posedge clk);
        rx_tdata  <= {msg_type, order_id[63:8]};
        rx_tvalid <= 1'b1;
        rx_tkeep  <= 8'hFF;
        rx_tlast  <= 1'b0;

        @(posedge clk);
        while (!rx_tready) @(posedge clk);

        // Word 1: [order_id(8 LSBs)][symbol_id(16)][side(8)][price(32)]
        rx_tdata <= {order_id[7:0], symbol_id, side, price};

        @(posedge clk);
        while (!rx_tready) @(posedge clk);

        // Word 2: [quantity(32)][timestamp_hi(32)]
        rx_tdata <= {quantity, timestamp[63:32]};

        @(posedge clk);
        while (!rx_tready) @(posedge clk);

        // Word 3: [timestamp_lo(32)][padding(32)]
        rx_tdata  <= {timestamp[31:0], 32'h0};
        rx_tlast  <= 1'b1;

        @(posedge clk);
        while (!rx_tready) @(posedge clk);

        rx_tvalid <= 1'b0;
        rx_tlast  <= 1'b0;
    endtask

    // ---- Main Test Sequence ----
    initial begin
        $display("============================================================");
        $display("  FPGA HFT Trading System — Full Pipeline Testbench");
        $display("  Target: AMD Alveo UL3524 @ 644 MHz");
        $display("  Clock Period: %.3f ns", CLK_PERIOD);
        $display("============================================================");

        // ---- Initialize ----
        rst_n           = 1'b0;
        enable          = 1'b0;
        rx_tdata        = '0;
        rx_tvalid       = 1'b0;
        rx_tlast        = 1'b0;
        rx_tkeep        = '0;
        kill_switch     = 1'b0;
        strategy_select = 2'd0;  // Market Maker mode

        // ---- Reset ----
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5)  @(posedge clk);
        enable = 1'b1;
        repeat (5)  @(posedge clk);

        $display("\n[%0t] === TEST 1: Build Order Book (Add Bids & Asks) ===", $time);

        // Add BID orders (building bid side)
        send_market_msg(MSG_ADD, 64'd1001, 16'h0001, SIDE_BID, 32'd10000, 32'd100, 64'd1);
        $display("[%0t] Sent ADD BID: price=10000, qty=100, oid=1001", $time);

        send_market_msg(MSG_ADD, 64'd1002, 16'h0001, SIDE_BID, 32'd9999, 32'd200, 64'd2);
        $display("[%0t] Sent ADD BID: price=9999,  qty=200, oid=1002", $time);

        send_market_msg(MSG_ADD, 64'd1003, 16'h0001, SIDE_BID, 32'd9998, 32'd150, 64'd3);
        $display("[%0t] Sent ADD BID: price=9998,  qty=150, oid=1003", $time);

        // Add ASK orders (building ask side)
        send_market_msg(MSG_ADD, 64'd2001, 16'h0001, SIDE_ASK, 32'd10002, 32'd100, 64'd4);
        $display("[%0t] Sent ADD ASK: price=10002, qty=100, oid=2001", $time);

        send_market_msg(MSG_ADD, 64'd2002, 16'h0001, SIDE_ASK, 32'd10003, 32'd250, 64'd5);
        $display("[%0t] Sent ADD ASK: price=10003, qty=250, oid=2002", $time);

        send_market_msg(MSG_ADD, 64'd2003, 16'h0001, SIDE_ASK, 32'd10004, 32'd300, 64'd6);
        $display("[%0t] Sent ADD ASK: price=10004, qty=300, oid=2003", $time);

        // Wait for pipeline to process
        repeat (20) @(posedge clk);

        $display("\n[%0t] Book State: bid_depth=%0d, ask_depth=%0d", $time, bid_depth_out, ask_depth_out);
        $display("[%0t] Quoting Active: %b", $time, quoting_active_out);
        $display("[%0t] Position: %0d", $time, position_out);

        // ---- TEST 2: Measure Tick-to-Trade Latency ----
        $display("\n[%0t] === TEST 2: Tick-to-Trade Latency Measurement ===", $time);

        rx_start_time = $time;

        // Send a new order that should trigger a quote update
        send_market_msg(MSG_ADD, 64'd3001, 16'h0001, SIDE_BID, 32'd10001, 32'd500, 64'd7);
        $display("[%0t] Sent ADD BID: price=10001, qty=500 (new best bid)", $time);

        // Wait for TX output
        fork
            begin
                @(posedge tx_tvalid);
                tx_end_time = $time;
                latency_cycles = (tx_end_time - rx_start_time) / CLK_PERIOD;
                $display("[%0t] *** TX ORDER DETECTED ***", $time);
                $display("[%0t] Tick-to-Trade Latency: %0t ns (%0d clock cycles)",
                         $time, tx_end_time - rx_start_time, latency_cycles);
            end
            begin
                repeat (100) @(posedge clk);
                $display("[%0t] WARNING: No TX output within 100 cycles", $time);
            end
        join_any
        disable fork;

        // ---- TEST 3: Delete Order & Book Update ----
        $display("\n[%0t] === TEST 3: Delete Order ===", $time);
        send_market_msg(MSG_DELETE, 64'd1001, 16'h0001, SIDE_BID, 32'd0, 32'd0, 64'd8);
        $display("[%0t] Sent DELETE: oid=1001", $time);

        repeat (20) @(posedge clk);
        $display("[%0t] Book State: bid_depth=%0d, ask_depth=%0d", $time, bid_depth_out, ask_depth_out);

        // ---- TEST 4: Trade Execution ----
        $display("\n[%0t] === TEST 4: Trade Execution ===", $time);
        send_market_msg(MSG_TRADE, 64'd2001, 16'h0001, SIDE_ASK, 32'd10002, 32'd50, 64'd9);
        $display("[%0t] Sent TRADE: oid=2001, qty=50 (partial fill)", $time);

        repeat (20) @(posedge clk);

        // ---- TEST 5: Kill Switch ----
        $display("\n[%0t] === TEST 5: Kill Switch ===", $time);
        kill_switch = 1'b1;
        repeat (5) @(posedge clk);

        $display("[%0t] Kill switch activated", $time);
        $display("[%0t] Circuit breaker LED: %b", $time, led_status[2]);

        kill_switch = 1'b0;
        repeat (10) @(posedge clk);

        // ---- Summary ----
        $display("\n============================================================");
        $display("  TEST SUMMARY");
        $display("============================================================");
        $display("  Orders Sent:     %0d", orders_sent_out);
        $display("  Last Order ID:   %0d", last_order_id_out);
        $display("  Rejects:         %0d", reject_count_out);
        $display("  Final Position:  %0d", position_out);
        $display("  LED Status:      %04b", led_status);
        $display("============================================================");

        repeat (20) @(posedge clk);
        $finish;
    end

    // ---- TX Monitor ----
    always @(posedge clk) begin
        if (tx_tvalid && tx_tready) begin
            $display("[%0t] TX OUT: data=0x%016h last=%b", $time, tx_tdata, tx_tlast);
        end
    end

    // ---- Waveform Dump ----
    initial begin
        $dumpfile("trading_system_tb.vcd");
        $dumpvars(0, tb_trading_system);
    end

endmodule
