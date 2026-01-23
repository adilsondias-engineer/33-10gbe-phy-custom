--------------------------------------------------------------------------------
-- 10GBASE-R PCS (Physical Coding Sublayer)
--
-- Top-level PCS module integrating:
--   TX Path: XGMII -> 64B/66B Encoder -> Scrambler -> GTX
--   RX Path: GTX -> Block Lock -> Descrambler -> 64B/66B Decoder -> XGMII
--
-- Interfaces:
--   - XGMII: 64-bit data + 8-bit control @ 156.25 MHz (to/from MAC)
--   - GTX: 66-bit blocks (2-bit header + 64-bit payload) @ 156.25 MHz
--
-- Features:
--   - Full-duplex operation
--   - Self-synchronizing scrambler (no explicit sync required)
--   - Automatic block lock acquisition
--   - Error monitoring and reporting
--
-- Copyright (c) 2026, Adilson Dias - https://github.com/adilsondias-engineer/fpga-trading-systems                                             
--                    All rights reserved                                       
-- This source file may be used and distributed without restriction provided    
-- that this copyright statement is not removed from the file and that any      
-- derivative work contains the original copyright notice and the associated    
-- disclaimer.                                                                  
--                                                                              
-- Author: Adilson Dias - January 2026
-- Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900I)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pcs_10gbase_r is
    port (
        -- Clock and Reset
        clk             : in  std_logic;    -- 156.25 MHz (from GTX)
        reset           : in  std_logic;

        -- XGMII TX Interface (from MAC)
        xgmii_txd       : in  std_logic_vector(63 downto 0);
        xgmii_txc       : in  std_logic_vector(7 downto 0);

        -- XGMII RX Interface (to MAC)
        xgmii_rxd       : out std_logic_vector(63 downto 0);
        xgmii_rxc       : out std_logic_vector(7 downto 0);
        xgmii_rx_valid  : out std_logic;

        -- GTX TX Interface (to GTX transceiver)
        gtx_tx_data     : out std_logic_vector(63 downto 0);
        gtx_tx_header   : out std_logic_vector(1 downto 0);
        gtx_tx_valid    : out std_logic;

        -- GTX RX Interface (from GTX transceiver)
        gtx_rx_data     : in  std_logic_vector(63 downto 0);
        gtx_rx_header   : in  std_logic_vector(1 downto 0);
        gtx_rx_valid    : in  std_logic;
        gtx_rx_header_valid : in  std_logic;

        -- Gearbox Slip (to GTX)
        gtx_rx_slip     : out std_logic;

        -- Status
        pcs_block_lock  : out std_logic;
        pcs_rx_sync     : out std_logic;
        pcs_tx_error    : out std_logic;
        pcs_rx_error    : out std_logic;
        pcs_hi_ber      : out std_logic;   -- High BER indicator (too many decode errors)

        -- Debug
        debug_tx_enc_error  : out std_logic;
        debug_rx_dec_error  : out std_logic;
        debug_header_errors : out std_logic_vector(7 downto 0);
        debug_block_state   : out std_logic_vector(2 downto 0);

        -- Additional debug: block type tracking
        debug_ctrl_block_cnt : out std_logic_vector(15 downto 0);  -- Control blocks (hdr=10)
        debug_data_block_cnt : out std_logic_vector(15 downto 0);  -- Data blocks (hdr=01)
        debug_last_block_type: out std_logic_vector(7 downto 0);   -- Last ctrl block type field
        debug_hi_ber        : out std_logic;                       -- Hi-BER (lock to noise indicator)

        -- TX Debug: comprehensive signals for TX path debugging
        debug_tx_enc_header  : out std_logic_vector(1 downto 0);   -- Encoder output header (01=data, 10=ctrl)
        debug_tx_enc_type    : out std_logic_vector(7 downto 0);   -- Encoder block type field (0x1E=IDLE)
        debug_tx_scram_header: out std_logic_vector(1 downto 0);   -- Scrambler output header
        debug_tx_header_raw  : out std_logic_vector(1 downto 0);   -- Raw GTX TX header (before any processing)
        debug_tx_gtx_data_hi : out std_logic_vector(7 downto 0);   -- GTX TX data bits [63:56] (after bit_reverse)
        debug_tx_gtx_data_lo : out std_logic_vector(7 downto 0);   -- GTX TX data bits [7:0] (after bit_reverse)
        debug_tx_block_cnt   : out std_logic_vector(15 downto 0);  -- TX block counter (should increment)
        debug_tx_xgmii_ctrl  : out std_logic_vector(7 downto 0);   -- XGMII TX control input (0xFF=all ctrl)

        -- RX Debug: comprehensive signals for RX path debugging
        debug_rx_header_value : out std_logic_vector(1 downto 0);  -- Last tested RX header (00/01/10/11) - after processing
        debug_rx_header_raw   : out std_logic_vector(1 downto 0);  -- Raw GTX RX header bits (before any processing)
        debug_slip_count      : out std_logic_vector(15 downto 0); -- Total slip operations performed
        debug_rx_data_hi       : out std_logic_vector(7 downto 0);  -- RX data sample [63:56] (after reversal)
        debug_rx_data_lo       : out std_logic_vector(7 downto 0);  -- RX data sample [7:0] (after reversal)
        -- NEW: Raw GTX RX data (before any processing) - shows what switch actually sends
        debug_rx_data_raw_hi   : out std_logic_vector(7 downto 0);  -- Raw GTX RX data [63:56] (before reversal)
        debug_rx_data_raw_mid   : out std_logic_vector(7 downto 0);  -- Raw GTX RX data [31:24] (middle byte)
        debug_rx_data_raw_lo   : out std_logic_vector(7 downto 0);  -- Raw GTX RX data [7:0] (before reversal)
        -- NEW: Block type at different byte positions (to find where it actually is)
        debug_block_type_byte0 : out std_logic_vector(7 downto 0);  -- Block type at byte 0 [7:0]
        debug_block_type_byte7 : out std_logic_vector(7 downto 0);  -- Block type at byte 7 [63:56]
        -- Block Lock FSM internal counters
        debug_fsm_valid_cnt   : out std_logic_vector(6 downto 0);  -- FSM valid header count (0-64)
        debug_fsm_invalid_cnt : out std_logic_vector(5 downto 0);  -- FSM invalid header count (0-63)
        debug_fsm_window_cnt  : out std_logic_vector(6 downto 0);  -- FSM window position (0-64)
        -- Descrambler/Decoder status
        debug_descram_sync    : out std_logic;                      -- Descrambler sync status (1=synced)
        debug_descram_data_hi : out std_logic_vector(7 downto 0);   -- Descrambler output [63:56]
        debug_descram_data_lo : out std_logic_vector(7 downto 0);   -- Descrambler output [7:0]
        debug_decoder_error   : out std_logic;                      -- Decoder error flag
        debug_decoder_data_hi : out std_logic_vector(7 downto 0);   -- Decoder output [63:56]
        debug_decoder_data_lo : out std_logic_vector(7 downto 0)    -- Decoder output [7:0]
    );
end pcs_10gbase_r;

architecture rtl of pcs_10gbase_r is

    ----------------------------------------------------------------------------
    -- Bit Ordering Configuration
    --
    -- 7-Series GTX 64B/66B gearbox uses MSB-first internally:
    --   TX: TXDATA[63] serialized first on wire
    --   RX: First received bit placed in RXDATA[63]
    -- IEEE 802.3 scrambler/descrambler operates LSB-first (bit 0 first).
    -- bit_reverse() bridges this mismatch.
    --
    -- Hardware confirmed 2026-01-23:
    --   bit_reverse=true:  BT:1E, DED:0707, [OK] (correct idle decode)
    --   bit_reverse=false: BT:varies, DED:FEFE, [XK] (garbage decode)
    ----------------------------------------------------------------------------
    constant ENABLE_TX_BIT_REVERSE : boolean := true;   -- GTX MSB-first ↔ IEEE LSB-first
    constant ENABLE_RX_BIT_REVERSE : boolean := true;   -- GTX MSB-first ↔ IEEE LSB-first
    constant ENABLE_RX_HEADER_SWAP : boolean := false;  -- TEST: Disabled - header swap appears to invert headers incorrectly
    constant ENABLE_RX_BYTE_SWAP   : boolean := false;  -- TEST: Disabled - didn't help, trying header swap to FSM instead

    ----------------------------------------------------------------------------
    -- Bit Reversal Function
    -- GTX gearbox outputs data MSB-first (bit 63 received first)
    -- IEEE 802.3 scrambler operates LSB-first (bit 0 processed first)
    -- This function reverses the bit order to correct the mismatch
    ----------------------------------------------------------------------------
    function bit_reverse(data : std_logic_vector) return std_logic_vector is
        variable result : std_logic_vector(data'range);
        variable idx    : integer;
    begin
        for i in data'range loop
            idx := data'high - i + data'low;
            result(idx) := data(i);
        end loop;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- TX Path Signals
    ----------------------------------------------------------------------------
    -- Encoder output
    signal enc_data     : std_logic_vector(63 downto 0);
    signal enc_header   : std_logic_vector(1 downto 0);
    signal enc_valid    : std_logic;
    signal enc_error    : std_logic;

    -- Scrambler output
    signal scram_data   : std_logic_vector(63 downto 0);
    signal scram_header : std_logic_vector(1 downto 0);

    -- TX debug: block counter and GTX data (after bit_reverse)
    signal tx_block_cnt     : unsigned(15 downto 0) := (others => '0');
    signal gtx_tx_data_out  : std_logic_vector(63 downto 0);  -- After bit_reverse
    signal scram_valid  : std_logic;

    ----------------------------------------------------------------------------
    -- RX Path Signals
    ----------------------------------------------------------------------------
    -- Bit-reversed RX data (correcting GTX MSB-first to IEEE LSB-first)
    signal rx_data_byte_swapped : std_logic_vector(63 downto 0);  -- Byte-swapped GTX data (if enabled)
    signal rx_data_reversed   : std_logic_vector(63 downto 0);
    signal rx_header_reversed : std_logic_vector(1 downto 0);

    -- Block lock
    signal block_lock   : std_logic;
    signal slip_request : std_logic;
    signal header_errors: std_logic_vector(7 downto 0);
    signal block_state  : std_logic_vector(2 downto 0);
    signal rx_header_value : std_logic_vector(1 downto 0);  -- Last tested header from FSM
    signal fsm_valid_cnt   : std_logic_vector(6 downto 0);  -- FSM valid header count
    signal fsm_invalid_cnt : std_logic_vector(5 downto 0);  -- FSM invalid header count
    signal fsm_window_cnt  : std_logic_vector(6 downto 0);  -- FSM window position
    
    -- Slip counter (counts total slip operations)
    signal slip_count   : unsigned(15 downto 0) := (others => '0');

    -- Descrambler output
    signal descram_data : std_logic_vector(63 downto 0);
    signal descram_header: std_logic_vector(1 downto 0);
    signal descram_valid: std_logic;
    signal descram_sync : std_logic;

    -- Descrambler control signals (intermediate signals for port map)
    signal descram_reset    : std_logic;
    signal descram_valid_in : std_logic;

    -- Bit-reversed descrambler output (for decoder - compensates GTX bit reversal)
    signal descram_data_reversed : std_logic_vector(63 downto 0);

    -- Decoder output
    signal dec_rxd      : std_logic_vector(63 downto 0);
    signal dec_rxc      : std_logic_vector(7 downto 0);
    signal dec_valid    : std_logic;
    signal dec_error    : std_logic;

    -- Debug: block type tracking
    signal ctrl_block_cnt   : unsigned(15 downto 0) := (others => '0');
    signal data_block_cnt   : unsigned(15 downto 0) := (others => '0');
    signal last_block_type  : std_logic_vector(7 downto 0) := (others => '0');

    -- Hi-BER detection (detects lock-to-noise vs real link)
    -- Counts decode errors in a sliding window. With noise, error rate is ~100%.
    -- With real link, error rate should be < 10^-4.
    -- Window of 128 blocks, Hi-BER if > 8 errors (6.25% threshold)
    constant HI_BER_WINDOW      : integer := 128;
    constant HI_BER_THRESHOLD   : integer := 8;
    signal hi_ber_error_cnt     : unsigned(7 downto 0) := (others => '0');
    signal hi_ber_block_cnt     : unsigned(7 downto 0) := (others => '0');
    signal hi_ber_flag          : std_logic := '1';  -- Start high (assume no valid link)
    signal valid_idle_seen      : std_logic := '0';  -- Valid IDLE block received

    -- Valid 64B/66B control block types (IEEE 802.3 clause 49)
    -- Type field is in bits 7:0 of the descrambled payload
    constant BLOCK_TYPE_IDLE    : std_logic_vector(7 downto 0) := x"1E";  -- 8x IDLE
    constant BLOCK_TYPE_START0  : std_logic_vector(7 downto 0) := x"33";  -- START in lane 0
    constant BLOCK_TYPE_START4  : std_logic_vector(7 downto 0) := x"66";  -- START in lane 4
    constant BLOCK_TYPE_OS4     : std_logic_vector(7 downto 0) := x"55";  -- Ordered set + data
    constant BLOCK_TYPE_OS      : std_logic_vector(7 downto 0) := x"4B";  -- Ordered sets
    constant BLOCK_TYPE_TERM0   : std_logic_vector(7 downto 0) := x"87";  -- TERMINATE lane 0
    constant BLOCK_TYPE_TERM1   : std_logic_vector(7 downto 0) := x"99";  -- TERMINATE lane 1
    constant BLOCK_TYPE_TERM2   : std_logic_vector(7 downto 0) := x"AA";  -- TERMINATE lane 2
    constant BLOCK_TYPE_TERM3   : std_logic_vector(7 downto 0) := x"B4";  -- TERMINATE lane 3
    constant BLOCK_TYPE_TERM4   : std_logic_vector(7 downto 0) := x"CC";  -- TERMINATE lane 4
    constant BLOCK_TYPE_TERM5   : std_logic_vector(7 downto 0) := x"D2";  -- TERMINATE lane 5
    constant BLOCK_TYPE_TERM6   : std_logic_vector(7 downto 0) := x"E1";  -- TERMINATE lane 6
    constant BLOCK_TYPE_TERM7   : std_logic_vector(7 downto 0) := x"FF";  -- TERMINATE lane 7

    -- Component declarations
    component encoder_64b66b is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            xgmii_txd       : in  std_logic_vector(63 downto 0);
            xgmii_txc       : in  std_logic_vector(7 downto 0);
            tx_header       : out std_logic_vector(1 downto 0);
            tx_data         : out std_logic_vector(63 downto 0);
            tx_valid        : out std_logic;
            encode_error    : out std_logic
        );
    end component;

    component scrambler_tx is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            data_in         : in  std_logic_vector(63 downto 0);
            header_in       : in  std_logic_vector(1 downto 0);
            valid_in        : in  std_logic;
            data_out        : out std_logic_vector(63 downto 0);
            header_out      : out std_logic_vector(1 downto 0);
            valid_out       : out std_logic
        );
    end component;

    component block_lock_fsm is
        generic (
            LOCK_THRESHOLD      : integer := 64;
            UNLOCK_THRESHOLD    : integer := 16;
            WINDOW_SIZE         : integer := 64;
            SLIP_WAIT_CYCLES    : integer := 8
        );
        port (
            clk                 : in  std_logic;
            reset               : in  std_logic;
            rx_header           : in  std_logic_vector(1 downto 0);
            rx_header_valid     : in  std_logic;
            rx_datavalid        : in  std_logic;  -- New: for edge detection
            slip_request        : out std_logic;
            block_lock          : out std_logic;
            header_error_count  : out std_logic_vector(7 downto 0);
            state_debug         : out std_logic_vector(2 downto 0);
            debug_last_header   : out std_logic_vector(1 downto 0);  -- Last tested header (00/01/10/11)
            debug_valid_cnt     : out std_logic_vector(6 downto 0);   -- Valid header count in window
            debug_invalid_cnt   : out std_logic_vector(5 downto 0);  -- Invalid header count in window
            debug_window_cnt    : out std_logic_vector(6 downto 0)    -- Window position counter
        );
    end component;

    component descrambler_rx is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            data_in         : in  std_logic_vector(63 downto 0);
            header_in       : in  std_logic_vector(1 downto 0);
            valid_in        : in  std_logic;
            data_out        : out std_logic_vector(63 downto 0);
            header_out      : out std_logic_vector(1 downto 0);
            valid_out       : out std_logic;
            sync_status     : out std_logic
        );
    end component;

    component decoder_64b66b is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            rx_header       : in  std_logic_vector(1 downto 0);
            rx_data         : in  std_logic_vector(63 downto 0);
            rx_valid        : in  std_logic;
            xgmii_rxd       : out std_logic_vector(63 downto 0);
            xgmii_rxc       : out std_logic_vector(7 downto 0);
            rx_data_valid   : out std_logic;
            decode_error    : out std_logic
        );
    end component;

begin

    ----------------------------------------------------------------------------
    -- TX Path: XGMII -> Encoder -> Scrambler -> GTX
    ----------------------------------------------------------------------------

    -- 64B/66B Encoder
    encoder_inst : encoder_64b66b
        port map (
            clk             => clk,
            reset           => reset,
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,
            tx_header       => enc_header,
            tx_data         => enc_data,
            tx_valid        => enc_valid,
            encode_error    => enc_error
        );

    -- TX Scrambler
    scrambler_inst : scrambler_tx
        port map (
            clk             => clk,
            reset           => reset,
            data_in         => enc_data,
            header_in       => enc_header,
            valid_in        => enc_valid,
            data_out        => scram_data,
            header_out      => scram_header,
            valid_out       => scram_valid
        );

    -- TX outputs to GTX
    -- CRITICAL: TX bit reversal configuration
    -- IEEE 802.3 specifies LSB-first (bit 0 transmitted first)
    -- GTX TX gearbox transmits from MSB side (bit 63 first)
    -- DEBUG: Testing both configurations to find which works
    gtx_tx_data_out <= bit_reverse(scram_data) when ENABLE_TX_BIT_REVERSE else scram_data;
    gtx_tx_data     <= gtx_tx_data_out;
    gtx_tx_header   <= scram_header;
    gtx_tx_valid    <= scram_valid;

    ----------------------------------------------------------------------------
    -- TX Block Counter (for debug - verifies TX path is running)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                tx_block_cnt <= (others => '0');
            elsif scram_valid = '1' then
                tx_block_cnt <= tx_block_cnt + 1;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- RX Path: GTX -> Block Lock -> Descrambler -> Decoder -> XGMII
    ----------------------------------------------------------------------------

    ----------------------------------------------------------------------------
    -- RX Data Bit Reversal
    -- GTX gearbox outputs MSB-first (bit 63 first), but IEEE 802.3
    -- descrambler expects LSB-first (bit 0 first). Reversing RX data to match.
    -- This is the opposite of TX - RX needs reversal to convert GTX MSB-first
    -- back to IEEE LSB-first for the descrambler.
    --
    -- TEST 2026-01-22: Tried disabling reversal - no difference observed.
    -- RH field still shows mix of 00/11 (invalid) and 01/10 (valid) headers.
    -- Re-enabled reversal and now testing header bit swap.
    --
    -- TEST 2026-01-23: RDR shows only [63:56] varies, suggesting byte order issue.
    -- Try byte-swapping entire 64-bit word: swap bytes [7:0] <-> [63:56], [15:8] <-> [55:48], etc.
    ----------------------------------------------------------------------------
    -- Byte swap: swap entire 64-bit word byte-by-byte (LSB byte <-> MSB byte, etc.)
    rx_data_byte_swapped <= gtx_rx_data(7 downto 0) & gtx_rx_data(15 downto 8) & 
                            gtx_rx_data(23 downto 16) & gtx_rx_data(31 downto 24) &
                            gtx_rx_data(39 downto 32) & gtx_rx_data(47 downto 40) &
                            gtx_rx_data(55 downto 48) & gtx_rx_data(63 downto 56) when ENABLE_RX_BYTE_SWAP else gtx_rx_data;
    
    -- Apply bit reversal to byte-swapped (or original) data
    rx_data_reversed   <= bit_reverse(rx_data_byte_swapped) when ENABLE_RX_BIT_REVERSE else rx_data_byte_swapped;
    rx_header_reversed <= gtx_rx_header(0) & gtx_rx_header(1) when ENABLE_RX_HEADER_SWAP else gtx_rx_header;  -- TEST: Swap header bits

    -- Block Lock FSM (runs on raw GTX data to find alignment)
    -- TEST: Try using swapped headers for block lock FSM
    -- The switch might be sending headers in swapped bit order
    -- Note: "01" and "10" are NOT symmetric - swapping "01" gives "10" (data->control)
    -- This could cause the FSM to misinterpret headers from the switch
    block_lock_inst : block_lock_fsm
        generic map (
            LOCK_THRESHOLD      => 64,
            UNLOCK_THRESHOLD    => 16,
            WINDOW_SIZE         => 64,
            SLIP_WAIT_CYCLES    => 8   -- Wait 8 cycles after slip for gearbox settle
        )
        port map (
            clk                 => clk,
            reset               => reset,
            rx_header           => gtx_rx_header,  -- TEST: Try raw headers again - swap didn't consistently help
            rx_header_valid     => gtx_rx_header_valid,
            rx_datavalid        => gtx_rx_valid,  -- For edge detection (new block)
            slip_request        => slip_request,
            block_lock          => block_lock,
            header_error_count  => header_errors,
            state_debug         => block_state,
            debug_last_header   => rx_header_value,  -- Last tested header value
            debug_valid_cnt     => fsm_valid_cnt,    -- FSM valid header count
            debug_invalid_cnt   => fsm_invalid_cnt, -- FSM invalid header count
            debug_window_cnt    => fsm_window_cnt    -- FSM window position
        );

    -- Gearbox slip output
    gtx_rx_slip <= slip_request;
    
    -- Slip counter: count total slip operations
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                slip_count <= (others => '0');
            elsif slip_request = '1' then
                if slip_count < 65535 then
                    slip_count <= slip_count + 1;
                end if;
            end if;
        end if;
    end process;

    -- RX Descrambler (only process when block locked)
    -- Uses bit-reversed data to correct GTX MSB-first to IEEE LSB-first convention
    -- Intermediate signals for port map (VHDL requires static names)
    descram_reset    <= reset or not block_lock;
    descram_valid_in <= gtx_rx_valid and block_lock;

    descrambler_inst : descrambler_rx
        port map (
            clk             => clk,
            reset           => descram_reset,
            data_in         => rx_data_reversed,
            header_in       => rx_header_reversed,
            valid_in        => descram_valid_in,
            data_out        => descram_data,
            header_out      => descram_header,
            valid_out       => descram_valid,
            sync_status     => descram_sync
        );

    -- No byte swapping - descrambler output is in correct byte order
    -- The descrambler processes LSB-first and outputs in the same order
    -- Block type field is at bits [7:0] as per IEEE 802.3 specification
    descram_data_reversed <= descram_data;

    -- 64B/66B Decoder (receives bit-reversed data in correct format)
    decoder_inst : decoder_64b66b
        port map (
            clk             => clk,
            reset           => reset,
            rx_header       => descram_header,
            rx_data         => descram_data_reversed,  -- Use bit-reversed data
            rx_valid        => descram_valid,
            xgmii_rxd       => dec_rxd,
            xgmii_rxc       => dec_rxc,
            rx_data_valid   => dec_valid,
            decode_error    => dec_error
        );

    -- XGMII RX outputs
    xgmii_rxd       <= dec_rxd;
    xgmii_rxc       <= dec_rxc;
    xgmii_rx_valid  <= dec_valid and block_lock;

    ----------------------------------------------------------------------------
    -- Status Outputs
    ----------------------------------------------------------------------------
    pcs_block_lock <= block_lock;
    pcs_rx_sync    <= descram_sync;
    pcs_tx_error   <= enc_error;
    pcs_rx_error   <= dec_error;

    -- Debug outputs
    debug_tx_enc_error  <= enc_error;
    debug_rx_dec_error  <= dec_error;
    debug_header_errors <= header_errors;
    debug_block_state   <= block_state;

    ----------------------------------------------------------------------------
    -- Debug: Block Type Tracking
    -- Count control blocks (header="10") vs data blocks (header="01")
    -- Track last seen block type field from control blocks
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ctrl_block_cnt <= (others => '0');
                data_block_cnt <= (others => '0');
                last_block_type <= (others => '0');
            elsif descram_valid = '1' and block_lock = '1' then
                if descram_header = "10" then
                    -- Control block
                    -- Use bit-reversed data (same as decoder sees) for debug
                    ctrl_block_cnt <= ctrl_block_cnt + 1;
                    last_block_type <= descram_data_reversed(7 downto 0);  -- Block type in standard position [7:0]
                elsif descram_header = "01" then
                    -- Data block
                    data_block_cnt <= data_block_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    debug_ctrl_block_cnt <= std_logic_vector(ctrl_block_cnt);
    debug_data_block_cnt <= std_logic_vector(data_block_cnt);
    debug_last_block_type <= last_block_type;

    ----------------------------------------------------------------------------
    -- Hi-BER Detection (Link Quality Monitor)
    --
    -- Detects "lock to noise" by monitoring decode errors and block types.
    -- With real 10GBASE-R link: IDLE blocks (0x1E), error rate < 0.01%
    -- With noise: random garbage, error rate ~50-100%, no valid IDLE blocks
    --
    -- Logic:
    -- 1. Reset when block_lock is lost
    -- 2. Count blocks and decode errors in sliding window
    -- 3. If error rate > threshold OR no valid IDLE seen, set Hi-BER
    -- 4. Hi-BER clears when error rate drops AND valid IDLE seen
    ----------------------------------------------------------------------------
    process(clk)
        variable block_type : std_logic_vector(7 downto 0);
        variable is_valid_type : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' or block_lock = '0' then
                -- Reset when no block lock
                hi_ber_error_cnt <= (others => '0');
                hi_ber_block_cnt <= (others => '0');
                hi_ber_flag <= '1';  -- Assume bad link until proven otherwise
                valid_idle_seen <= '0';
            elsif descram_valid = '1' then
                -- Get block type from descrambled payload
                -- Block type is at bits [7:0] of the 64-bit payload (same as decoder uses)
                block_type := descram_data_reversed(7 downto 0);

                -- Check if this is a valid block type for control blocks
                is_valid_type := false;
                if descram_header = "10" then
                    -- Control block - check type field
                    if block_type = BLOCK_TYPE_IDLE or
                       block_type = BLOCK_TYPE_START0 or
                       block_type = BLOCK_TYPE_START4 or
                       block_type = BLOCK_TYPE_OS4 or
                       block_type = BLOCK_TYPE_OS or
                       block_type = BLOCK_TYPE_TERM0 or
                       block_type = BLOCK_TYPE_TERM1 or
                       block_type = BLOCK_TYPE_TERM2 or
                       block_type = BLOCK_TYPE_TERM3 or
                       block_type = BLOCK_TYPE_TERM4 or
                       block_type = BLOCK_TYPE_TERM5 or
                       block_type = BLOCK_TYPE_TERM6 or
                       block_type = BLOCK_TYPE_TERM7 then
                        is_valid_type := true;
                    end if;

                    -- Specifically track IDLE blocks (most common when link is up)
                    if block_type = BLOCK_TYPE_IDLE then
                        valid_idle_seen <= '1';
                    end if;
                elsif descram_header = "01" then
                    -- Data block - always valid if header is correct
                    is_valid_type := true;
                end if;

                -- Count errors (decode error OR invalid block type for control)
                if dec_error = '1' or (descram_header = "10" and not is_valid_type) then
                    if hi_ber_error_cnt < 255 then
                        hi_ber_error_cnt <= hi_ber_error_cnt + 1;
                    end if;
                end if;

                -- Count blocks in window
                if hi_ber_block_cnt < HI_BER_WINDOW - 1 then
                    hi_ber_block_cnt <= hi_ber_block_cnt + 1;
                else
                    -- End of window - evaluate and reset
                    -- Hi-BER if error rate too high OR no valid IDLE seen
                    if hi_ber_error_cnt >= HI_BER_THRESHOLD or valid_idle_seen = '0' then
                        hi_ber_flag <= '1';
                    else
                        hi_ber_flag <= '0';
                    end if;

                    -- Reset counters for next window
                    hi_ber_error_cnt <= (others => '0');
                    hi_ber_block_cnt <= (others => '0');
                    -- Note: valid_idle_seen persists - once seen, link is validated
                end if;
            end if;
        end if;
    end process;

    -- Hi-BER outputs
    pcs_hi_ber <= hi_ber_flag;
    debug_hi_ber <= hi_ber_flag;

    ----------------------------------------------------------------------------
    -- TX Debug Outputs
    -- Comprehensive signals for diagnosing TX path issues
    ----------------------------------------------------------------------------
    debug_tx_enc_header   <= enc_header;                          -- Encoder header (10=ctrl, 01=data)
    debug_tx_enc_type     <= enc_data(7 downto 0);                -- Block type field (0x1E=IDLE)
    debug_tx_scram_header <= scram_header;                        -- Scrambler output header
    debug_tx_header_raw   <= scram_header;                        -- Raw GTX TX header (same as scram_header, which drives gtx_tx_header)
    debug_tx_gtx_data_hi  <= gtx_tx_data_out(63 downto 56);       -- High byte of GTX data
    debug_tx_gtx_data_lo  <= gtx_tx_data_out(7 downto 0);         -- Low byte of GTX data
    debug_tx_block_cnt    <= std_logic_vector(tx_block_cnt);      -- TX block counter
    debug_tx_xgmii_ctrl   <= xgmii_txc;                           -- XGMII control (0xFF=all idle)

    -- RX Debug Outputs
    debug_rx_header_value <= rx_header_value;                     -- Last tested RX header (00/01/10/11) - after processing
    debug_rx_header_raw   <= gtx_rx_header;                      -- Raw GTX RX header bits (before any processing)
    debug_slip_count      <= std_logic_vector(slip_count);        -- Total slip operations
    debug_rx_data_hi      <= rx_data_reversed(63 downto 56);      -- RX data sample [63:56] (after reversal)
    debug_rx_data_lo      <= rx_data_reversed(7 downto 0);        -- RX data sample [7:0] (after reversal)
    -- NEW: Raw GTX RX data (before any processing) - shows what switch actually sends
    debug_rx_data_raw_hi  <= gtx_rx_data(63 downto 56);          -- Raw GTX RX data [63:56] (before reversal)
    debug_rx_data_raw_mid <= gtx_rx_data(31 downto 24);          -- Raw GTX RX data [31:24] (middle byte)
    debug_rx_data_raw_lo  <= gtx_rx_data(7 downto 0);            -- Raw GTX RX data [7:0] (before reversal)
    -- NEW: Block type at different byte positions (to find where it actually is)
    debug_block_type_byte0 <= descram_data_reversed(7 downto 0);   -- Block type at byte 0 [7:0]
    debug_block_type_byte7 <= descram_data_reversed(63 downto 56);  -- Block type at byte 7 [63:56]
    -- Block Lock FSM counters
    debug_fsm_valid_cnt   <= fsm_valid_cnt;                       -- FSM valid header count (0-64)
    debug_fsm_invalid_cnt <= fsm_invalid_cnt;                     -- FSM invalid header count (0-63)
    debug_fsm_window_cnt  <= fsm_window_cnt;                      -- FSM window position (0-64)
    -- Descrambler/Decoder status
    debug_descram_sync    <= descram_sync;                        -- Descrambler sync status (1=synced)
    debug_descram_data_hi <= descram_data(63 downto 56);          -- Descrambler output [63:56]
    debug_descram_data_lo <= descram_data(7 downto 0);            -- Descrambler output [7:0]
    debug_decoder_error   <= dec_error;                           -- Decoder error flag
    debug_decoder_data_hi <= dec_rxd(63 downto 56);               -- Decoder output [63:56]
    debug_decoder_data_lo <= dec_rxd(7 downto 0);                 -- Decoder output [7:0]

end rtl;
