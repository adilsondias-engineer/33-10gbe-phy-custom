/*
 * GTX Debug Reporter
 *
 * Periodically sends GTX status over UART for debugging.
 * Format: "Q:X L:X T:X R:X BL:X HV:X DV:X CD:X EI:X ST:X TC:X PR:X HB:X TV:X TD:X TH:X TT:XX BC:XXXX RH:XX SC:XXXX RD:XXXX HE:XX BT:XX CC:XXXX DC:XXXX [OK]\r\n"
 *   Q  = QPLL lock (1=locked, 0=not)
 *   L  = REFCLK lost (1=lost, 0=present)
 *   T  = TX reset done (1=done, 0=in reset)
 *   R  = RX reset done (1=done, 0=in reset)
 *   BL = PCS block lock (1=locked, 0=searching)
 *   HV = RX header valid (from GTX gearbox)
 *   DV = RX data valid (from GTX, new block indicator)
 *   CD = CDR lock (info only - unreliable for 10GBASE-R, can show false positives!)
 *   EI = Electrical idle (info only - unreliable for 10GBASE-R, can show false positives!)
 *   ST = Block lock FSM state:
 *        0=INIT, 1=RESET, 2=WAIT_BLOCK, 3=TEST_SH
 *        4=VALID_SH, 5=INVALID/SLIP, 6=SLIP_WAIT, 7=LOCKED
 *   TC = TX clock heartbeat (should toggle every ~0.8s if tx_clk running)
 *   PR = PCS reset active (1=reset, 0=running - should be 0 for FSM)
 *   HB = High BER / Lock-to-noise (1=bad link/noise, 0=valid XGMII data seen)
 *        CRITICAL: HB:1 means "lock to noise", HB:0 means real link with valid IDLE blocks
 *   TV = TX valid (1=PCS scrambler producing data)
 *   TD = TX disable pin (0=TX on, 1=TX off)
 *   TH = TX encoder header (0-3, expect 2 for "10"=control/IDLE block)
 *   TT = TX encoder type field as hex (expect 1E for IDLE blocks)
 *   BC = TX block counter as 4-digit hex (should increment each 500ms report)
 *   RH = RX header value (00/01/10/11) - CRITICAL: shows actual header bits FSM is testing
 *        If always 00 or 11, headers are invalid (bit order issue?)
 *   SC = Slip count (total slip operations, 4 hex digits) - should increment if stuck at ST:2
 *   RD = RX data sample (hi byte + lo byte, 4 hex digits) - sample of RX data after reversal
 *   RDR = Raw GTX RX data (6 hex digits) - [63:56] [31:24] [7:0] - shows what switch actually sends (before any processing)
 *   HE = Header errors (invalid headers seen, 2 hex digits) - increments when headers are 00/11
 *   BT = Last block type decoded (2 hex digits, 1E=IDLE if valid link)
 *   BT0 = Block type at byte 0 [7:0] (2 hex) - to check if block type is at wrong position
 *   BT7 = Block type at byte 7 [63:56] (2 hex) - to check if block type is at wrong position
 *        Only valid when BL:1 - shows what block types are being decoded
 *   CC = Control block count (hdr=10, 4 hex digits) - increments when valid control blocks decoded
 *   DC = Data block count (hdr=01, 4 hex digits) - increments when valid data blocks decoded
 *   VC = FSM valid count (0-64, 2 hex) - Valid headers seen in current window (should reach 40+ for lock)
 *   IC = FSM invalid count (0-63, 2 hex) - Invalid headers in current window (should be low)
 *   WC = FSM window count (0-64, 2 hex) - Window position (resets when window completes)
 *   DS = Descrambler sync (0/1) - 1=descrambler synchronized (only valid when BL:1)
 *   DD = Descrambler data (4 hex) - Descrambler output sample [63:56] and [7:0]
 *   DE = Decoder error (0/1) - 1=decoder detected error
 *   DED = Decoder data (4 hex) - Decoder output sample [63:56] and [7:0]
 *
 * NOTE: CD and EI signals are unreliable for 10GBASE-R. The Xilinx axi_10g_ethernet
 * IP does not use them. The GTX CDR can lock to noise on floating SFP+ pins,
 * causing false CD:1 and EI:0 even with no cable. This is expected GTX behavior.
 *
 * Link Status:
 *   - [OK] = QPLL locked + block lock + NOT Hi-BER (valid XGMII data)
 *   - [XK] = Missing QPLL lock, block lock, OR Hi-BER (lock to noise)
 *
 * Expected lock sequence: ST cycles 1->2->3->4->(64 times)->7 (LOCKED)
 * If continuously seeing ST:5,6 = slipping due to invalid headers
 *
 * Copyright (c) 2026, Adilson Dias - https://github.com/adilsondias-engineer/fpga-trading-systems                                             
 *                    All rights reserved                                       
 * This source file may be used and distributed without restriction provided    
 * that this copyright statement is not removed from the file and that any      
 * derivative work contains the original copyright notice and the associated    
 * disclaimer.                                                                  
 *                                                                              
 * Author: Adilson Dias - January 2026
 * Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900I)
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gtx_debug_reporter #(
        parameter CLK_FREQ  = 200_000_000,
        parameter BAUD_RATE = 115200,
        parameter REPORT_MS = 500  // Report interval in milliseconds
    )(
        input  wire clk,
        input  wire rst,

        // Status inputs
        input  wire qpll_lock,
        input  wire qpll_refclk_lost,
        input  wire tx_resetdone,
        input  wire rx_resetdone,

        // Extended debug inputs
        input  wire debug_por_done,
        input  wire debug_qpll_reset,
        input  wire debug_gtx_reset,
        input  wire debug_tx_userrdy,
        input  wire debug_rx_userrdy,
        input  wire debug_refclk_present,  // IBUFDS_GTE2 ODIV2 heartbeat

        // PCS status
        input  wire pcs_block_lock,        // PCS 64B/66B block lock

        // RX debug signals (directly from GTX/PCS)
        input  wire rx_header_valid,       // GTX rx_header_valid
        input  wire rx_datavalid,          // GTX rx_datavalid
        input  wire [2:0] block_lock_state, // Block lock FSM state
        input  wire rx_cdrlock,            // GTX CDR lock
        input  wire rx_elecidle,           // GTX electrical idle
        input  wire rx_startofseq,         // RXSTARTOFSEQ - indicates when gearbox sequence counter is at 0
        input  wire tx_gearbox_ready,      // TXGEARBOXREADY - indicates when TX gearbox can accept data
        input  wire tx_clk_heartbeat,      // TX clock heartbeat (verifies PCS clock running)
        input  wire pcs_reset,             // PCS reset active (should be 0 for FSM to run)
        input  wire reset_int_dbg,         // reset_int component of pcs_reset
        input  wire gtx_ready_dbg,         // gtx_ready component of pcs_reset
        input  wire pcs_hi_ber,            // High BER (1=lock to noise, 0=valid XGMII data)

        // TX debug signals
        input  wire pcs_tx_valid,          // TX data valid from PCS (scrambler output)
        input  wire sfp_tx_disable,        // SFP+ TX_DISABLE pin value (0=TX on, 1=TX off)

        // NEW: Extended TX debug signals for TX path diagnosis
        input  wire [1:0] tx_enc_header,   // Encoder header (01=data, 10=ctrl/IDLE)
        input  wire [7:0] tx_enc_type,     // Encoder block type (0x1E=IDLE)
        input  wire [15:0] tx_block_cnt,   // TX block counter (should increment)

        // NEW: Extended RX debug signals for RX path diagnosis
        input  wire [1:0] rx_header_value, // Last tested RX header (00/01/10/11) - CRITICAL! (after processing)
        input  wire [1:0] rx_header_raw,   // Raw GTX RX header bits (before any processing) - for visual pattern analysis
        input  wire [15:0] slip_count,      // Total slip operations performed
        input  wire [7:0] rx_data_hi,       // RX data sample [63:56] (after reversal)
        input  wire [7:0] rx_data_lo,       // RX data sample [7:0] (after reversal)
        // NEW: Raw GTX RX data (before any processing) - shows what switch actually sends
        input  wire [7:0] rx_data_raw_hi,   // Raw GTX RX data [63:56] (before reversal)
        input  wire [7:0] rx_data_raw_mid,  // Raw GTX RX data [31:24] (middle byte)
        input  wire [7:0] rx_data_raw_lo,   // Raw GTX RX data [7:0] (before reversal)
        // NEW: Block type at different byte positions (to find where it actually is)
        input  wire [7:0] block_type_byte0, // Block type at byte 0 [7:0]
        input  wire [7:0] block_type_byte7, // Block type at byte 7 [63:56]
        input  wire [7:0] header_errors,    // Header error count (invalid headers seen)
        input  wire [7:0] last_block_type,  // Last decoded block type (0x1E=IDLE if valid)
        input  wire [15:0] ctrl_block_cnt,  // Control block count (hdr=10)
        input  wire [15:0] data_block_cnt,  // Data block count (hdr=01)
        // Block Lock FSM internal counters
        input  wire [6:0] fsm_valid_cnt,   // FSM valid header count (0-64) - shows lock progress
        input  wire [5:0] fsm_invalid_cnt, // FSM invalid header count (0-63) - shows error accumulation
        input  wire [6:0] fsm_window_cnt,   // FSM window position (0-64) - shows window progress
        // Descrambler/Decoder status
        input  wire descram_sync,           // Descrambler sync status (1=synced, 0=not synced)
        input  wire [7:0] descram_data_hi,  // Descrambler output [63:56]
        input  wire [7:0] descram_data_lo,  // Descrambler output [7:0]
        input  wire decoder_error,           // Decoder error flag (1=error detected)
        input  wire [7:0] decoder_data_hi,  // Decoder output [63:56]
        input  wire [7:0] decoder_data_lo,  // Decoder output [7:0]
        // TX header raw
        input  wire [1:0] tx_header_raw,     // Raw GTX TX header (before any processing)

        // UART output
        output wire uart_tx
    );

    // Report interval in clock cycles
    localparam REPORT_CYCLES = (CLK_FREQ / 1000) * REPORT_MS;

    // Message format with TX and RX debug:
    // "Q:X L:X T:X R:X BL:X HV:X DV:X CD:X EI:X ST:X TC:X PR:X HB:X TV:X TD:X TH:X THR:XX TT:XX BC:XXXX RH:XX RHR:XX SC:XXXX RD:XXXX RDR:XXXXXX HE:XX BT:XX BT0:XX BT7:XX CC:XXXX DC:XXXX VC:XX IC:XX WC:XX DS:X DD:XXXX DE:X DED:XXXX RS:X TR:X [OK]\r\n"
    // RS = RXSTARTOFSEQ (1=at block boundary, 0=not)
    // TR = TXGEARBOXREADY (1=ready, 0=not ready)
    // TH = TX encoder header (0-3, expect 2 for "10"=control)
    // TT = TX encoder type as hex (expect 1E for IDLE)
    // BC = TX block count lower 16 bits as hex (should increment)
    // RH = RX header value (00/01/10/11) - CRITICAL: shows what headers FSM is testing
    // SC = Slip count (total slips performed, 4 hex digits)
    // RD = RX data sample (hi byte + lo byte, 4 hex digits)
    // HE = Header errors (invalid headers seen, 2 hex digits)
    // BT = Last block type decoded (2 hex digits, 1E=IDLE if valid)
    // CC = Control block count (hdr=10, 4 hex digits)
    // DC = Data block count (hdr=01, 4 hex digits)
    localparam MSG_LEN = 242;  // Increased to accommodate RS and TR fields (ends at index 239=LF, 240-241=padding)

    // State machine
    localparam STATE_IDLE     = 2'd0;
    localparam STATE_BUILD    = 2'd1;
    localparam STATE_SEND     = 2'd2;
    localparam STATE_WAIT     = 2'd3;

    reg [1:0] state;
    reg [31:0] timer;
    reg [7:0] char_idx;  // Increased from [6:0] to [7:0] to support MSG_LEN=148 (needs 0-145)
    reg [7:0] tx_data;
    reg tx_start;
    wire tx_busy;

    // Status sampling (reduce metastability)
    reg qpll_lock_s, qpll_lost_s, tx_done_s, rx_done_s, blk_lock_s;
    reg qpll_lock_ss, qpll_lost_ss, tx_done_ss, rx_done_ss, blk_lock_ss;
    reg hdr_valid_s, data_valid_s, cdr_lock_s, elec_idle_s, tx_hb_s, pcs_rst_s, hi_ber_s;
    reg hdr_valid_ss, data_valid_ss, cdr_lock_ss, elec_idle_ss, tx_hb_ss, pcs_rst_ss, hi_ber_ss;
    reg rx_startofseq_s, rx_startofseq_ss;  // RXSTARTOFSEQ sampling
    reg tx_gearbox_ready_s, tx_gearbox_ready_ss;  // TXGEARBOXREADY sampling
    reg tx_valid_s, tx_disable_s;
    reg tx_valid_ss, tx_disable_ss;
    reg [2:0] blk_state_s, blk_state_ss;
    // NEW: TX debug sampling registers
    reg [1:0] tx_enc_hdr_s, tx_enc_hdr_ss;
    reg [7:0] tx_enc_type_s, tx_enc_type_ss;
    reg [15:0] tx_blk_cnt_s, tx_blk_cnt_ss;
    // NEW: RX debug sampling registers
    reg [1:0] rx_hdr_val_s, rx_hdr_val_ss;
    reg [1:0] rx_hdr_raw_s, rx_hdr_raw_ss;
    reg [15:0] slip_cnt_s, slip_cnt_ss;
    reg [7:0] rx_data_hi_s, rx_data_hi_ss;
    reg [7:0] rx_data_lo_s, rx_data_lo_ss;
    // NEW: Raw GTX RX data registers
    reg [7:0] rx_data_raw_hi_s, rx_data_raw_hi_ss;
    reg [7:0] rx_data_raw_mid_s, rx_data_raw_mid_ss;
    reg [7:0] rx_data_raw_lo_s, rx_data_raw_lo_ss;
    // NEW: Block type at different positions
    reg [7:0] block_type_byte0_s, block_type_byte0_ss;
    reg [7:0] block_type_byte7_s, block_type_byte7_ss;
    reg [7:0] hdr_err_s, hdr_err_ss;
    reg [7:0] last_blk_type_s, last_blk_type_ss;
    reg [15:0] ctrl_blk_cnt_s, ctrl_blk_cnt_ss;
    reg [15:0] data_blk_cnt_s, data_blk_cnt_ss;
    // Block Lock FSM counters
    reg [6:0] fsm_valid_cnt_s, fsm_valid_cnt_ss;
    reg [5:0] fsm_invalid_cnt_s, fsm_invalid_cnt_ss;
    reg [6:0] fsm_window_cnt_s, fsm_window_cnt_ss;
    // Descrambler/Decoder status
    reg descram_sync_s, descram_sync_ss;
    reg [7:0] descram_data_hi_s, descram_data_hi_ss;
    reg [7:0] descram_data_lo_s, descram_data_lo_ss;
    reg decoder_error_s, decoder_error_ss;
    reg [7:0] decoder_data_hi_s, decoder_data_hi_ss;
    reg [7:0] decoder_data_lo_s, decoder_data_lo_ss;
    // TX header raw
    reg [1:0] tx_hdr_raw_s, tx_hdr_raw_ss;

    // Message buffer
    reg [7:0] msg [0:MSG_LEN-1];

    // UART TX instantiation
    uart_tx_simple #(
                       .CLK_FREQ(CLK_FREQ),
                       .BAUD_RATE(BAUD_RATE)
                   ) uart_inst (
                       .clk(clk),
                       .rst(rst),
                       .tx_data(tx_data),
                       .tx_start(tx_start),
                       .tx_busy(tx_busy),
                       .tx(uart_tx)
                   );

    // Sample status inputs
    always @(posedge clk) begin
        // First stage
        qpll_lock_s <= qpll_lock;
        qpll_lost_s <= qpll_refclk_lost;
        tx_done_s   <= tx_resetdone;
        rx_done_s   <= rx_resetdone;
        blk_lock_s  <= pcs_block_lock;
        hdr_valid_s <= rx_header_valid;
        data_valid_s <= rx_datavalid;
        cdr_lock_s  <= rx_cdrlock;
        elec_idle_s <= rx_elecidle;
        rx_startofseq_s <= rx_startofseq;
        tx_gearbox_ready_s <= tx_gearbox_ready;
        blk_state_s <= block_lock_state;
        tx_hb_s     <= tx_clk_heartbeat;
        pcs_rst_s   <= pcs_reset;
        hi_ber_s    <= pcs_hi_ber;
        tx_valid_s  <= pcs_tx_valid;
        tx_disable_s <= sfp_tx_disable;
        // NEW: TX debug signals
        tx_enc_hdr_s  <= tx_enc_header;
        tx_enc_type_s <= tx_enc_type;
        tx_blk_cnt_s  <= tx_block_cnt;
        tx_hdr_raw_s  <= tx_header_raw;
        // NEW: RX debug signals
        rx_hdr_val_s  <= rx_header_value;
        rx_hdr_raw_s  <= rx_header_raw;
        slip_cnt_s    <= slip_count;
        // Block Lock FSM counters
        fsm_valid_cnt_s   <= fsm_valid_cnt;
        fsm_invalid_cnt_s <= fsm_invalid_cnt;
        fsm_window_cnt_s  <= fsm_window_cnt;
        // Descrambler/Decoder status
        descram_sync_s    <= descram_sync;
        descram_data_hi_s <= descram_data_hi;
        descram_data_lo_s <= descram_data_lo;
        decoder_error_s   <= decoder_error;
        decoder_data_hi_s <= decoder_data_hi;
        decoder_data_lo_s <= decoder_data_lo;
        rx_data_hi_s  <= rx_data_hi;
        rx_data_lo_s  <= rx_data_lo;
        // NEW: Raw GTX RX data
        rx_data_raw_hi_s  <= rx_data_raw_hi;
        rx_data_raw_mid_s <= rx_data_raw_mid;
        rx_data_raw_lo_s  <= rx_data_raw_lo;
        // NEW: Block type at different positions
        block_type_byte0_s <= block_type_byte0;
        block_type_byte7_s <= block_type_byte7;
        hdr_err_s     <= header_errors;
        last_blk_type_s <= last_block_type;
        ctrl_blk_cnt_s  <= ctrl_block_cnt;
        data_blk_cnt_s  <= data_block_cnt;

        // Second stage
        qpll_lock_ss <= qpll_lock_s;
        qpll_lost_ss <= qpll_lost_s;
        tx_done_ss   <= tx_done_s;
        rx_done_ss   <= rx_done_s;
        blk_lock_ss  <= blk_lock_s;
        hdr_valid_ss <= hdr_valid_s;
        data_valid_ss <= data_valid_s;
        cdr_lock_ss <= cdr_lock_s;
        elec_idle_ss <= elec_idle_s;
        rx_startofseq_ss <= rx_startofseq_s;
        tx_gearbox_ready_ss <= tx_gearbox_ready_s;
        blk_state_ss <= blk_state_s;
        tx_hb_ss    <= tx_hb_s;
        pcs_rst_ss  <= pcs_rst_s;
        hi_ber_ss   <= hi_ber_s;
        tx_valid_ss <= tx_valid_s;
        tx_disable_ss <= tx_disable_s;
        // NEW: TX debug signals second stage
        tx_enc_hdr_ss  <= tx_enc_hdr_s;
        tx_enc_type_ss <= tx_enc_type_s;
        tx_blk_cnt_ss  <= tx_blk_cnt_s;
        tx_hdr_raw_ss  <= tx_hdr_raw_s;
        // NEW: RX debug signals second stage
        rx_hdr_val_ss  <= rx_hdr_val_s;
        rx_hdr_raw_ss  <= rx_hdr_raw_s;
        slip_cnt_ss    <= slip_cnt_s;
        rx_data_hi_ss  <= rx_data_hi_s;
        rx_data_lo_ss  <= rx_data_lo_s;
        // NEW: Raw GTX RX data second stage
        rx_data_raw_hi_ss  <= rx_data_raw_hi_s;
        rx_data_raw_mid_ss <= rx_data_raw_mid_s;
        rx_data_raw_lo_ss  <= rx_data_raw_lo_s;
        // NEW: Block type at different positions second stage
        block_type_byte0_ss <= block_type_byte0_s;
        block_type_byte7_ss <= block_type_byte7_s;
        hdr_err_ss     <= hdr_err_s;
        last_blk_type_ss <= last_blk_type_s;
        ctrl_blk_cnt_ss  <= ctrl_blk_cnt_s;
        data_blk_cnt_ss  <= data_blk_cnt_s;
        // Block Lock FSM counters second stage
        fsm_valid_cnt_ss   <= fsm_valid_cnt_s;
        fsm_invalid_cnt_ss <= fsm_invalid_cnt_s;
        fsm_window_cnt_ss  <= fsm_window_cnt_s;
        // Descrambler/Decoder status second stage
        descram_sync_ss    <= descram_sync_s;
        descram_data_hi_ss <= descram_data_hi_s;
        descram_data_lo_ss <= descram_data_lo_s;
        decoder_error_ss   <= decoder_error_s;
        decoder_data_hi_ss <= decoder_data_hi_s;
        decoder_data_lo_ss <= decoder_data_lo_s;
    end

    // Hex digit conversion function
    function [7:0] hex_digit;
        input [3:0] val;
        begin
            if (val < 10)
                hex_digit = "0" + val;
            else
                hex_digit = "A" + (val - 10);
        end
    endfunction

    // Main state machine
    always @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            timer <= 32'd0;
            char_idx <= 7'd0;
            tx_start <= 1'b0;
            tx_data <= 8'd0;
        end
        else begin
            tx_start <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (timer >= REPORT_CYCLES - 1) begin
                        timer <= 32'd0;
                        state <= STATE_BUILD;
                    end
                    else begin
                        timer <= timer + 1;
                    end
                end

                STATE_BUILD: begin
                    // Build message: "Q:X L:X T:X R:X BL:X HV:X DV:X CD:X EI:X ST:X TC:X PR:X HB:X [OK]\r\n"
                    msg[0]  <= "Q";
                    msg[1]  <= ":";
                    msg[2]  <= qpll_lock_ss ? "1" : "0";
                    msg[3]  <= " ";
                    msg[4]  <= "L";
                    msg[5]  <= ":";
                    msg[6]  <= qpll_lost_ss ? "1" : "0";
                    msg[7]  <= " ";
                    msg[8]  <= "T";
                    msg[9]  <= ":";
                    msg[10] <= tx_done_ss ? "1" : "0";
                    msg[11] <= " ";
                    msg[12] <= "R";
                    msg[13] <= ":";
                    msg[14] <= rx_done_ss ? "1" : "0";
                    msg[15] <= " ";
                    msg[16] <= "B";
                    msg[17] <= "L";
                    msg[18] <= ":";
                    msg[19] <= blk_lock_ss ? "1" : "0";
                    msg[20] <= " ";
                    msg[21] <= "H";
                    msg[22] <= "V";
                    msg[23] <= ":";
                    msg[24] <= hdr_valid_ss ? "1" : "0";
                    msg[25] <= " ";
                    msg[26] <= "D";
                    msg[27] <= "V";
                    msg[28] <= ":";
                    msg[29] <= data_valid_ss ? "1" : "0";
                    msg[30] <= " ";
                    msg[31] <= "C";
                    msg[32] <= "D";
                    msg[33] <= ":";
                    msg[34] <= cdr_lock_ss ? "1" : "0";
                    msg[35] <= " ";
                    msg[36] <= "E";
                    msg[37] <= "I";
                    msg[38] <= ":";
                    msg[39] <= elec_idle_ss ? "1" : "0";
                    msg[40] <= " ";
                    msg[41] <= "S";
                    msg[42] <= "T";
                    msg[43] <= ":";
                    msg[44] <= "0" + blk_state_ss;  // 0-7
                    msg[45] <= " ";
                    msg[46] <= "T";
                    msg[47] <= "C";
                    msg[48] <= ":";
                    msg[49] <= tx_hb_ss ? "1" : "0";  // TX clock heartbeat (should toggle)
                    msg[50] <= " ";
                    msg[51] <= "P";
                    msg[52] <= "R";
                    msg[53] <= ":";
                    msg[54] <= pcs_rst_ss ? "1" : "0";  // PCS reset (should be 0 for FSM to run)
                    msg[55] <= " ";
                    msg[56] <= "H";
                    msg[57] <= "B";
                    msg[58] <= ":";
                    msg[59] <= hi_ber_ss ? "1" : "0";  // Hi-BER (1=noise/no link, 0=valid data)
                    msg[60] <= " ";
                    msg[61] <= "T";
                    msg[62] <= "V";
                    msg[63] <= ":";
                    msg[64] <= tx_valid_ss ? "1" : "0";  // TX Valid (1=PCS producing data)
                    msg[65] <= " ";
                    msg[66] <= "T";
                    msg[67] <= "D";
                    msg[68] <= ":";
                    msg[69] <= tx_disable_ss ? "1" : "0";  // TX Disable pin (0=TX on, 1=TX off)
                    msg[70] <= " ";
                    // NEW: TX debug fields
                    msg[71] <= "T";
                    msg[72] <= "H";
                    msg[73] <= ":";
                    msg[74] <= "0" + tx_enc_hdr_ss;  // TX encoder header (expect 2 for "10"=ctrl)
                    msg[75] <= " ";
                    msg[76] <= "T";
                    msg[77] <= "H";
                    msg[78] <= "R";
                    msg[79] <= ":";
                    msg[80] <= "0" + tx_hdr_raw_ss[1];  // TX header raw bit 1
                    msg[81] <= "0" + tx_hdr_raw_ss[0];  // TX header raw bit 0
                    msg[82] <= " ";
                    msg[83] <= "T";
                    msg[84] <= "T";
                    msg[85] <= ":";
                    msg[86] <= hex_digit(tx_enc_type_ss[7:4]);  // TX type high nibble
                    msg[87] <= hex_digit(tx_enc_type_ss[3:0]);  // TX type low nibble (expect 1E)
                    msg[88] <= " ";
                    msg[89] <= "B";
                    msg[90] <= "C";
                    msg[91] <= ":";
                    msg[92] <= hex_digit(tx_blk_cnt_ss[15:12]); // Block count nibble 3
                    msg[93] <= hex_digit(tx_blk_cnt_ss[11:8]);  // Block count nibble 2
                    msg[94] <= hex_digit(tx_blk_cnt_ss[7:4]);   // Block count nibble 1
                    msg[95] <= hex_digit(tx_blk_cnt_ss[3:0]);   // Block count nibble 0
                    msg[96] <= " ";
                    // NEW: RX debug fields
                    msg[97] <= "R";
                    msg[98] <= "H";
                    msg[99] <= ":";
                    msg[100] <= "0" + rx_hdr_val_ss[1];  // RX header bit 1 (processed)
                    msg[101] <= "0" + rx_hdr_val_ss[0];  // RX header bit 0 (processed) (00/01/10/11)
                    msg[102] <= " ";
                    msg[103] <= "R";
                    msg[104] <= "H";
                    msg[105] <= "R";
                    msg[106] <= ":";
                    msg[107] <= "0" + rx_hdr_raw_ss[1];  // Raw RX header bit 1
                    msg[108] <= "0" + rx_hdr_raw_ss[0];  // Raw RX header bit 0 (00/01/10/11)
                    msg[109] <= " ";
                    msg[110] <= "S";
                    msg[111] <= "C";
                    msg[112] <= ":";
                    msg[113] <= hex_digit(slip_cnt_ss[15:12]);  // Slip count nibble 3
                    msg[114] <= hex_digit(slip_cnt_ss[11:8]);  // Slip count nibble 2
                    msg[115] <= hex_digit(slip_cnt_ss[7:4]);   // Slip count nibble 1
                    msg[116] <= hex_digit(slip_cnt_ss[3:0]);   // Slip count nibble 0
                    msg[117] <= " ";
                    msg[118] <= "R";
                    msg[119] <= "D";
                    msg[120] <= ":";
                    msg[121] <= hex_digit(rx_data_hi_ss[7:4]);  // RX data hi byte high nibble
                    msg[122] <= hex_digit(rx_data_hi_ss[3:0]);  // RX data hi byte low nibble
                    msg[123] <= hex_digit(rx_data_lo_ss[7:4]);  // RX data lo byte high nibble
                    msg[124] <= hex_digit(rx_data_lo_ss[3:0]);  // RX data lo byte low nibble
                    msg[125] <= " ";
                    // NEW: Raw GTX RX data (before any processing) - shows what switch actually sends
                    msg[126] <= "R";
                    msg[127] <= "D";
                    msg[128] <= "R";
                    msg[129] <= ":";
                    msg[130] <= hex_digit(rx_data_raw_hi_ss[7:4]);  // Raw RX data [63:56] high nibble
                    msg[131] <= hex_digit(rx_data_raw_hi_ss[3:0]);  // Raw RX data [63:56] low nibble
                    msg[132] <= hex_digit(rx_data_raw_mid_ss[7:4]); // Raw RX data [31:24] high nibble
                    msg[133] <= hex_digit(rx_data_raw_mid_ss[3:0]); // Raw RX data [31:24] low nibble
                    msg[134] <= hex_digit(rx_data_raw_lo_ss[7:4]);  // Raw RX data [7:0] high nibble
                    msg[135] <= hex_digit(rx_data_raw_lo_ss[3:0]);  // Raw RX data [7:0] low nibble
                    msg[136] <= " ";
                    msg[137] <= "H";
                    msg[138] <= "E";
                    msg[139] <= ":";
                    msg[140] <= hex_digit(hdr_err_ss[7:4]);     // Header errors high nibble
                    msg[141] <= hex_digit(hdr_err_ss[3:0]);     // Header errors low nibble
                    msg[142] <= " ";
                    msg[143] <= "B";
                    msg[144] <= "T";
                    msg[145] <= ":";
                    msg[146] <= hex_digit(last_blk_type_ss[7:4]); // Last block type high nibble
                    msg[147] <= hex_digit(last_blk_type_ss[3:0]); // Last block type low nibble
                    msg[148] <= " ";
                    // NEW: Block type at different byte positions
                    msg[149] <= "B";
                    msg[150] <= "T";
                    msg[151] <= "0";
                    msg[152] <= ":";
                    msg[153] <= hex_digit(block_type_byte0_ss[7:4]); // Block type at byte 0 [7:0] high nibble
                    msg[154] <= hex_digit(block_type_byte0_ss[3:0]); // Block type at byte 0 [7:0] low nibble
                    msg[155] <= " ";
                    msg[156] <= "B";
                    msg[157] <= "T";
                    msg[158] <= "7";
                    msg[159] <= ":";
                    msg[160] <= hex_digit(block_type_byte7_ss[7:4]); // Block type at byte 7 [63:56] high nibble
                    msg[161] <= hex_digit(block_type_byte7_ss[3:0]); // Block type at byte 7 [63:56] low nibble
                    msg[162] <= " ";
                    msg[163] <= "C";
                    msg[164] <= "C";
                    msg[165] <= ":";
                    msg[166] <= hex_digit(ctrl_blk_cnt_ss[15:12]); // Ctrl block count nibble 3
                    msg[167] <= hex_digit(ctrl_blk_cnt_ss[11:8]);  // Ctrl block count nibble 2
                    msg[168] <= hex_digit(ctrl_blk_cnt_ss[7:4]);   // Ctrl block count nibble 1
                    msg[169] <= hex_digit(ctrl_blk_cnt_ss[3:0]);   // Ctrl block count nibble 0
                    msg[170] <= " ";
                    msg[171] <= "D";
                    msg[172] <= "C";
                    msg[173] <= ":";
                    msg[174] <= hex_digit(data_blk_cnt_ss[15:12]); // Data block count nibble 3
                    msg[175] <= hex_digit(data_blk_cnt_ss[11:8]);  // Data block count nibble 2
                    msg[176] <= hex_digit(data_blk_cnt_ss[7:4]);   // Data block count nibble 1
                    msg[177] <= hex_digit(data_blk_cnt_ss[3:0]);   // Data block count nibble 0
                    msg[178] <= " ";
                    // NEW: Block Lock FSM counters
                    msg[179] <= "V";
                    msg[180] <= "C";
                    msg[181] <= ":";
                    msg[182] <= hex_digit({1'b0, fsm_valid_cnt_ss[6:4]});  // Valid count high nibble (0-64)
                    msg[183] <= hex_digit(fsm_valid_cnt_ss[3:0]);         // Valid count low nibble
                    msg[184] <= " ";
                    msg[185] <= "I";
                    msg[186] <= "C";
                    msg[187] <= ":";
                    msg[188] <= hex_digit({2'b0, fsm_invalid_cnt_ss[5:4]}); // Invalid count high nibble (0-63)
                    msg[189] <= hex_digit(fsm_invalid_cnt_ss[3:0]);         // Invalid count low nibble
                    msg[190] <= " ";
                    msg[191] <= "W";
                    msg[192] <= "C";
                    msg[193] <= ":";
                    msg[194] <= hex_digit({1'b0, fsm_window_cnt_ss[6:4]});  // Window count high nibble (0-64)
                    msg[195] <= hex_digit(fsm_window_cnt_ss[3:0]);         // Window count low nibble
                    msg[196] <= " ";
                    // NEW: Descrambler/Decoder status
                    msg[197] <= "D";
                    msg[198] <= "S";
                    msg[199] <= ":";
                    msg[200] <= descram_sync_ss ? "1" : "0";  // Descrambler sync status
                    msg[201] <= " ";
                    msg[202] <= "D";
                    msg[203] <= "D";
                    msg[204] <= ":";
                    msg[205] <= hex_digit(descram_data_hi_ss[7:4]);  // Descrambler data hi high nibble
                    msg[206] <= hex_digit(descram_data_hi_ss[3:0]);  // Descrambler data hi low nibble
                    msg[207] <= hex_digit(descram_data_lo_ss[7:4]);  // Descrambler data lo high nibble
                    msg[208] <= hex_digit(descram_data_lo_ss[3:0]);  // Descrambler data lo low nibble
                    msg[209] <= " ";
                    msg[210] <= "D";
                    msg[211] <= "E";
                    msg[212] <= ":";
                    msg[213] <= decoder_error_ss ? "1" : "0";  // Decoder error flag
                    msg[214] <= " ";
                    msg[215] <= "D";
                    msg[216] <= "E";
                    msg[217] <= "D";
                    msg[218] <= ":";
                    msg[219] <= hex_digit(decoder_data_hi_ss[7:4]);  // Decoder data hi high nibble
                    msg[220] <= hex_digit(decoder_data_hi_ss[3:0]);  // Decoder data hi low nibble
                    msg[221] <= hex_digit(decoder_data_lo_ss[7:4]);  // Decoder data lo high nibble
                    msg[222] <= hex_digit(decoder_data_lo_ss[3:0]);  // Decoder data lo low nibble
                    msg[223] <= " ";
                    // NEW: RXSTARTOFSEQ and TXGEARBOXREADY
                    msg[224] <= "R";
                    msg[225] <= "S";
                    msg[226] <= ":";
                    msg[227] <= rx_startofseq_ss ? "1" : "0";  // RXSTARTOFSEQ - at block boundary
                    msg[228] <= " ";
                    msg[229] <= "T";
                    msg[230] <= "R";
                    msg[231] <= ":";
                    msg[232] <= tx_gearbox_ready_ss ? "1" : "0";  // TXGEARBOXREADY - gearbox ready
                    msg[233] <= " ";
                    msg[234] <= "[";
                    // [OK] requires: QPLL lock + block lock + NOT Hi-BER (valid XGMII data)
                    msg[235] <= (qpll_lock_ss && blk_lock_ss && !hi_ber_ss) ? "O" : "X";
                    msg[236] <= "K";
                    msg[237] <= "]";
                    msg[238] <= 8'h0D;  // CR
                    msg[239] <= 8'h0A;  // LF
                    msg[240] <= 8'h00;  // null (not sent)
                    msg[241] <= 8'h00;  // padding

                    char_idx <= 8'd0;
                    state <= STATE_SEND;
                end

                STATE_SEND: begin
                    if (!tx_busy && !tx_start) begin
                        // Send characters 0-239 (message + CR + LF), stop before null bytes at 240-241
                        if (char_idx <= 239) begin  // Stop after LF (0x0A at index 239), padding at 240-241
                            tx_data <= msg[char_idx];
                            tx_start <= 1'b1;
                            char_idx <= char_idx + 1;
                            state <= STATE_WAIT;
                        end
                        else begin
                            state <= STATE_IDLE;
                        end
                    end
                end

                STATE_WAIT: begin
                    // Wait for current character to start transmitting
                    if (tx_busy) begin
                        state <= STATE_SEND;
                    end
                end

                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

endmodule

`resetall
