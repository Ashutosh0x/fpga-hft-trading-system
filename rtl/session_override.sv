// ============================================================================
// FPGA HFT Trading System - Dynamic Session Override Controller
// Description: Monitors latency to multiple exchange sessions in real-time
//              and dynamically switches to the best-performing session
//              in a single clock cycle. Based on Exegy's April 2026
//              breakthrough that achieved 71% execution-stack latency reduction.
//
// Architecture:
//   Session 0 ──┐
//   Session 1 ──┼──▶ Latency Monitor ──▶ Scorer ──▶ Hot-Swap MUX ──▶ Best
//   Session 2 ──┤
//   Session 3 ──┘
//
// Latency: 1 cycle for session switch, continuous monitoring
// ============================================================================

module session_override
    import fixed_point_pkg::*;
#(
    parameter NUM_SESSIONS     = 4,
    parameter PROBE_INTERVAL   = 32'd64400,    // ~100µs at 644MHz
    parameter SWITCH_THRESHOLD = 32'd10,       // Switch if p99 > threshold (ns)
    parameter HYSTERESIS       = 32'd3         // Must be better by this much
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Session TX ports (one per session)
    input  logic [63:0] session_tx_data  [NUM_SESSIONS-1:0],
    input  logic        session_tx_valid [NUM_SESSIONS-1:0],

    // Session RX ports (responses)
    input  logic [63:0] session_rx_data  [NUM_SESSIONS-1:0],
    input  logic        session_rx_valid [NUM_SESSIONS-1:0],

    // Latency measurement inputs (from timestamping hardware)
    input  logic [31:0] session_latency  [NUM_SESSIONS-1:0],  // Latest RTT in cycles
    input  logic        latency_valid    [NUM_SESSIONS-1:0],

    // Active session output
    output logic [63:0] active_tx_data,
    output logic        active_tx_valid,
    output logic [1:0]  active_session_id,

    // Status
    output logic [31:0] session_scores   [NUM_SESSIONS-1:0],
    output logic [31:0] switch_count,
    output logic        override_active
);

    // ---- Per-Session Latency Statistics ----
    logic [31:0] lat_min    [NUM_SESSIONS-1:0];
    logic [31:0] lat_max    [NUM_SESSIONS-1:0];
    logic [31:0] lat_ema    [NUM_SESSIONS-1:0];   // EMA of latency
    logic [31:0] lat_p99    [NUM_SESSIONS-1:0];   // Approximate p99
    logic [15:0] lat_count  [NUM_SESSIONS-1:0];   // Samples in window

    // ---- Scoring ----
    logic [31:0] scores [NUM_SESSIONS-1:0];
    logic [1:0]  best_session;
    logic [1:0]  current_session;
    logic [31:0] probe_timer;
    logic [31:0] r_switch_count;

    assign active_session_id = current_session;
    assign switch_count      = r_switch_count;
    assign override_active   = 1'b1;

    // ---- Latency Tracking (EMA + approximate p99) ----
    genvar g;
    generate
        for (g = 0; g < NUM_SESSIONS; g++) begin : lat_track
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    lat_min[g]   <= '1;  // Max initial
                    lat_max[g]   <= '0;
                    lat_ema[g]   <= 32'd50;  // Default 50 cycles
                    lat_p99[g]   <= 32'd100;
                    lat_count[g] <= '0;
                end else if (enable && latency_valid[g]) begin
                    // Update min/max
                    if (session_latency[g] < lat_min[g])
                        lat_min[g] <= session_latency[g];
                    if (session_latency[g] > lat_max[g])
                        lat_max[g] <= session_latency[g];

                    // EMA update: ema += (sample - ema) >> 4
                    lat_ema[g] <= lat_ema[g] +
                                  (($signed(session_latency[g]) - $signed(lat_ema[g])) >>> 4);

                    // Approximate p99: track max with decay
                    // p99 = max(sample, p99 - 1) — slowly decays old maxima
                    if (session_latency[g] > lat_p99[g])
                        lat_p99[g] <= session_latency[g];
                    else if (lat_p99[g] > lat_ema[g])
                        lat_p99[g] <= lat_p99[g] - 1;

                    lat_count[g] <= lat_count[g] + 1;
                end
            end

            // Score = weighted combination (lower is better)
            // score = 2 * p99 + ema (prioritize tail latency)
            assign scores[g] = (lat_p99[g] << 1) + lat_ema[g];
            assign session_scores[g] = scores[g];
        end
    endgenerate

    // ---- Find Best Session (combinational) ----
    always_comb begin
        best_session = 2'd0;
        for (int i = 1; i < NUM_SESSIONS; i++) begin
            if (scores[i] < scores[best_session])
                best_session = i[1:0];
        end
    end

    // ---- Session Switch Logic ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_session <= 2'd0;
            r_switch_count  <= '0;
            probe_timer     <= '0;
        end else if (enable) begin
            probe_timer <= probe_timer + 1;

            if (probe_timer >= PROBE_INTERVAL) begin
                probe_timer <= '0;

                // Switch if best session is significantly better (hysteresis)
                if (best_session != current_session &&
                    scores[best_session] + HYSTERESIS < scores[current_session]) begin
                    current_session <= best_session;
                    r_switch_count  <= r_switch_count + 1;

                    // Reset stats for old session
                    lat_min[current_session] <= '1;
                    lat_max[current_session] <= '0;
                end
            end
        end
    end

    // ---- Hot-Swap Output MUX (1-cycle switch) ----
    always_comb begin
        active_tx_data  = session_tx_data[current_session];
        active_tx_valid = session_tx_valid[current_session];
    end

endmodule
