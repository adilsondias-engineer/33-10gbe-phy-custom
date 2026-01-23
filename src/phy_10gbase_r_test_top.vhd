--------------------------------------------------------------------------------
-- 10GBASE-R PHY Test Top Level (Standalone Hardware Test)
--
-- This wrapper removes the XGMII interface for standalone PHY testing.
-- It generates IDLE patterns on TX and monitors link status on RX.
--
-- Only uses pins that are explicitly constrained:
--   - SFP+ reference clock
--   - SFP+ transceiver lanes
--   - SFP+ TX disable
--   - Reset button
--   - Status LEDs
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

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity phy_10gbase_r_test_top is
    port (
        -- System Clock (200 MHz differential) - free-running for GTX control
        sys_clk_p       : in  std_logic;
        sys_clk_n       : in  std_logic;

        -- Reference Clock (156.25 MHz differential)
        refclk_p        : in  std_logic;
        refclk_n        : in  std_logic;

        -- System Reset (active LOW on AX7325B - directly from button)
        phy_reset       : in  std_logic;

        -- SFP+ Serial Interface
        sfp_txp         : out std_logic;
        sfp_txn         : out std_logic;
        sfp_rxp         : in  std_logic;
        sfp_rxn         : in  std_logic;

        -- SFP+ Control
        sfp_tx_disable  : out std_logic;

        -- Debug LEDs (directly active high)
        debug_led       : out std_logic_vector(3 downto 0);

        -- UART Debug Output (directly active)
        uart_tx         : out std_logic
    );
end phy_10gbase_r_test_top;

architecture rtl of phy_10gbase_r_test_top is

    -- System clock (free-running 200 MHz)
    signal sys_clk          : std_logic;

    -- Internal clocks
    signal tx_clk           : std_logic;
    signal rx_clk           : std_logic;
    signal clk_156          : std_logic;

    -- GTX signals
    signal gtx_tx_data      : std_logic_vector(63 downto 0);
    signal gtx_tx_header    : std_logic_vector(1 downto 0);
    signal gtx_tx_sequence  : std_logic_vector(6 downto 0);
    signal gtx_rx_data      : std_logic_vector(63 downto 0);
    signal gtx_rx_header    : std_logic_vector(1 downto 0);
    signal gtx_rx_header_valid : std_logic;
    signal gtx_rx_datavalid : std_logic;
    signal gtx_rx_slip      : std_logic;

    -- GTX status
    signal qpll_lock_int    : std_logic;
    signal qpll_refclk_lost_int : std_logic;
    signal tx_resetdone     : std_logic;
    signal rx_resetdone     : std_logic;
    signal gtx_ready        : std_logic;

    -- GTX debug signals
    signal debug_por_done   : std_logic;
    signal debug_qpll_reset : std_logic;
    signal debug_gtx_reset  : std_logic;
    signal debug_tx_userrdy : std_logic;
    signal debug_rx_userrdy : std_logic;
    signal debug_refclk_present : std_logic;
    signal debug_rx_cdrlock : std_logic;
    signal debug_rx_elecidle : std_logic;
    signal debug_rx_startofseq : std_logic;  -- RXSTARTOFSEQ - indicates when gearbox sequence counter is at 0
    signal debug_tx_gearbox_ready : std_logic;  -- TXGEARBOXREADY - indicates when TX gearbox can accept data

    -- PCS status
    signal pcs_block_lock   : std_logic;
    signal pcs_rx_sync      : std_logic;
    signal pcs_tx_error     : std_logic;
    signal pcs_rx_error     : std_logic;
    signal pcs_hi_ber       : std_logic;  -- High BER (lock-to-noise indicator)
    signal pcs_block_state  : std_logic_vector(2 downto 0);

    -- XGMII internal signals (directly loopback IDLE patterns)
    signal xgmii_txd        : std_logic_vector(63 downto 0);
    signal xgmii_txc        : std_logic_vector(7 downto 0);
    signal xgmii_rxd        : std_logic_vector(63 downto 0);
    signal xgmii_rxc        : std_logic_vector(7 downto 0);
    signal xgmii_rx_valid   : std_logic;

    -- Reset synchronization
    signal reset_sync       : std_logic_vector(2 downto 0) := (others => '1');
    signal reset_int        : std_logic;

    -- Heartbeat counter for sys_clk verification (200 MHz / 2^27 = ~1.5 Hz)
    signal sys_clk_counter  : unsigned(27 downto 0) := (others => '0');
    signal sys_clk_heartbeat: std_logic := '0';

    -- Heartbeat counter for tx_clk verification (156.25 MHz / 2^27 = ~1.2 Hz)
    signal tx_clk_counter   : unsigned(27 downto 0) := (others => '0');
    signal tx_clk_heartbeat : std_logic := '0';

    -- TX debug signals
    signal pcs_tx_valid     : std_logic;  -- TX data valid from PCS (scrambler output)
    signal sfp_tx_disable_int : std_logic;  -- Internal copy for debug visibility

    -- NEW: Extended TX debug signals from PCS
    signal debug_tx_enc_header  : std_logic_vector(1 downto 0);
    signal debug_tx_enc_type    : std_logic_vector(7 downto 0);
    signal debug_tx_scram_header: std_logic_vector(1 downto 0);
    signal debug_tx_header_raw  : std_logic_vector(1 downto 0);
    signal debug_tx_gtx_data_hi : std_logic_vector(7 downto 0);
    signal debug_tx_gtx_data_lo : std_logic_vector(7 downto 0);
    signal debug_tx_block_cnt   : std_logic_vector(15 downto 0);
    signal debug_tx_xgmii_ctrl  : std_logic_vector(7 downto 0);
    
    -- NEW: Extended RX debug signals from PCS
    signal debug_rx_header_value : std_logic_vector(1 downto 0);
    signal debug_rx_header_raw   : std_logic_vector(1 downto 0);
    signal debug_slip_count      : std_logic_vector(15 downto 0);
    signal debug_rx_data_hi       : std_logic_vector(7 downto 0);
    signal debug_rx_data_lo       : std_logic_vector(7 downto 0);
    -- NEW: Raw GTX RX data (before any processing)
    signal debug_rx_data_raw_hi   : std_logic_vector(7 downto 0);
    signal debug_rx_data_raw_mid  : std_logic_vector(7 downto 0);
    signal debug_rx_data_raw_lo   : std_logic_vector(7 downto 0);
    -- NEW: Block type at different byte positions
    signal debug_block_type_byte0 : std_logic_vector(7 downto 0);
    signal debug_block_type_byte7 : std_logic_vector(7 downto 0);
    signal debug_header_errors    : std_logic_vector(7 downto 0);
    signal debug_last_block_type  : std_logic_vector(7 downto 0);
    signal debug_ctrl_block_cnt   : std_logic_vector(15 downto 0);
    signal debug_data_block_cnt   : std_logic_vector(15 downto 0);
    -- Block Lock FSM counters
    signal debug_fsm_valid_cnt    : std_logic_vector(6 downto 0);
    signal debug_fsm_invalid_cnt  : std_logic_vector(5 downto 0);
    signal debug_fsm_window_cnt   : std_logic_vector(6 downto 0);
    -- Descrambler/Decoder status
    signal debug_descram_sync     : std_logic;
    signal debug_descram_data_hi  : std_logic_vector(7 downto 0);
    signal debug_descram_data_lo  : std_logic_vector(7 downto 0);
    signal debug_decoder_error    : std_logic;
    signal debug_decoder_data_hi   : std_logic_vector(7 downto 0);
    signal debug_decoder_data_lo   : std_logic_vector(7 downto 0);

    -- PCS reset signal for debug
    signal pcs_reset        : std_logic;

    -- IDLE pattern constants (IEEE 802.3 IDLE = 0x07)
    constant XGMII_IDLE_DATA : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_CTRL : std_logic_vector(7 downto 0) := "11111111";

    -- Note: Using entity instantiation (no component declarations needed)

begin

    ----------------------------------------------------------------------------
    -- System Clock Buffer (200 MHz free-running)
    -- Direct IBUFDS - no Clock Wizard needed for GTX drp_clk
    ----------------------------------------------------------------------------
    sys_clk_ibuf : IBUFDS
        generic map (
            DIFF_TERM    => FALSE,
            IBUF_LOW_PWR => FALSE,
            IOSTANDARD   => "DIFF_SSTL15"
        )
        port map (
            I  => sys_clk_p,
            IB => sys_clk_n,
            O  => sys_clk
        );

    ----------------------------------------------------------------------------
    -- Heartbeat Counter (sys_clk domain) - verifies 200 MHz clock is running
    -- 200 MHz / 2^27 = ~1.5 Hz blink rate
    ----------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            sys_clk_counter <= sys_clk_counter + 1;
            sys_clk_heartbeat <= sys_clk_counter(27);
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Heartbeat Counter (tx_clk domain) - verifies 156.25 MHz PCS clock running
    -- 156.25 MHz / 2^27 = ~1.2 Hz blink rate
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            tx_clk_counter <= tx_clk_counter + 1;
            tx_clk_heartbeat <= tx_clk_counter(27);
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Reset Synchronization
    -- Note: AX7325B reset button is active-LOW (pressed = 0, released = 1)
    -- Polarity inverted: phy_reset = '0' means reset active
    ----------------------------------------------------------------------------
    process(tx_clk, phy_reset)
    begin
        if phy_reset = '0' then  -- Active-low reset button
            reset_sync <= (others => '1');
        elsif rising_edge(tx_clk) then
            reset_sync <= reset_sync(1 downto 0) & '0';
        end if;
    end process;
    reset_int <= reset_sync(2);

    ----------------------------------------------------------------------------
    -- GTX Transceiver (entity instantiation)
    ----------------------------------------------------------------------------
    gtx_inst : entity work.gtx_10g_wrapper
        generic map (
            SIM_MODE        => false,
            GTX_CHANNEL     => 0
        )
        port map (
            refclk_p        => refclk_p,
            refclk_n        => refclk_n,
            drp_clk         => sys_clk,  -- 200 MHz free-running clock
            sys_reset       => phy_reset,
            gtx_txp         => sfp_txp,
            gtx_txn         => sfp_txn,
            gtx_rxp         => sfp_rxp,
            gtx_rxn         => sfp_rxn,
            tx_clk          => tx_clk,
            tx_data         => gtx_tx_data,
            tx_header       => gtx_tx_header,
            tx_valid        => pcs_tx_valid,  -- CRITICAL: Pass valid signal for TXSTARTSEQ control
            tx_sequence     => gtx_tx_sequence,
            rx_clk          => rx_clk,
            rx_data         => gtx_rx_data,
            rx_header       => gtx_rx_header,
            rx_header_valid => gtx_rx_header_valid,
            rx_datavalid    => gtx_rx_datavalid,
            rx_gearbox_slip => gtx_rx_slip,
            qpll_lock       => qpll_lock_int,
            qpll_refclk_lost => qpll_refclk_lost_int,
            tx_resetdone    => tx_resetdone,
            rx_resetdone    => rx_resetdone,
            phy_ready       => gtx_ready,
            debug_por_done  => debug_por_done,
            debug_qpll_reset => debug_qpll_reset,
            debug_gtx_reset => debug_gtx_reset,
            debug_tx_userrdy => debug_tx_userrdy,
            debug_rx_userrdy => debug_rx_userrdy,
            debug_refclk_present => debug_refclk_present,
            debug_rx_cdrlock => debug_rx_cdrlock,
            debug_rx_elecidle => debug_rx_elecidle,
            debug_rx_startofseq => debug_rx_startofseq,
            debug_tx_gearbox_ready => debug_tx_gearbox_ready
        );

    clk_156 <= tx_clk;

    -- PCS reset = reset_int OR not gtx_ready (for debug visibility)
    pcs_reset <= reset_int or not gtx_ready;

    ----------------------------------------------------------------------------
    -- PCS Layer
    ----------------------------------------------------------------------------
    pcs_inst :  entity work.pcs_10gbase_r
        port map (
            clk             => clk_156,
            reset           => pcs_reset,
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,
            xgmii_rxd       => xgmii_rxd,
            xgmii_rxc       => xgmii_rxc,
            xgmii_rx_valid  => xgmii_rx_valid,
            gtx_tx_data     => gtx_tx_data,
            gtx_tx_header   => gtx_tx_header,
            gtx_tx_valid    => pcs_tx_valid,
            gtx_rx_data     => gtx_rx_data,
            gtx_rx_header   => gtx_rx_header,
            gtx_rx_valid    => gtx_rx_datavalid,
            gtx_rx_header_valid => gtx_rx_header_valid,
            gtx_rx_slip     => gtx_rx_slip,
            pcs_block_lock  => pcs_block_lock,
            pcs_rx_sync     => pcs_rx_sync,
            pcs_tx_error    => pcs_tx_error,
            pcs_rx_error    => pcs_rx_error,
            pcs_hi_ber      => pcs_hi_ber,
            debug_tx_enc_error  => open,
            debug_rx_dec_error  => open,
            debug_header_errors => debug_header_errors,
            debug_block_state   => pcs_block_state,
            debug_ctrl_block_cnt => debug_ctrl_block_cnt,
            debug_data_block_cnt => debug_data_block_cnt,
            debug_last_block_type => debug_last_block_type,
            debug_hi_ber        => open,
            -- NEW: TX debug outputs
            debug_tx_enc_header  => debug_tx_enc_header,
            debug_tx_enc_type    => debug_tx_enc_type,
            debug_tx_scram_header => debug_tx_scram_header,
            debug_tx_gtx_data_hi => debug_tx_gtx_data_hi,
            debug_tx_gtx_data_lo => debug_tx_gtx_data_lo,
            debug_tx_block_cnt   => debug_tx_block_cnt,
            debug_tx_xgmii_ctrl  => debug_tx_xgmii_ctrl,
            debug_tx_header_raw  => debug_tx_header_raw,
            -- NEW: RX debug outputs
            debug_rx_header_value => debug_rx_header_value,
            debug_rx_header_raw   => debug_rx_header_raw,
            debug_slip_count      => debug_slip_count,
            debug_rx_data_hi       => debug_rx_data_hi,
            debug_rx_data_lo       => debug_rx_data_lo,
            debug_rx_data_raw_hi   => debug_rx_data_raw_hi,
            debug_rx_data_raw_mid  => debug_rx_data_raw_mid,
            debug_rx_data_raw_lo   => debug_rx_data_raw_lo,
            debug_block_type_byte0 => debug_block_type_byte0,
            debug_block_type_byte7 => debug_block_type_byte7,
            -- Block Lock FSM counters
            debug_fsm_valid_cnt   => debug_fsm_valid_cnt,
            debug_fsm_invalid_cnt => debug_fsm_invalid_cnt,
            debug_fsm_window_cnt  => debug_fsm_window_cnt,
            -- Descrambler/Decoder status
            debug_descram_sync    => debug_descram_sync,
            debug_descram_data_hi => debug_descram_data_hi,
            debug_descram_data_lo => debug_descram_data_lo,
            debug_decoder_error   => debug_decoder_error,
            debug_decoder_data_hi => debug_decoder_data_hi,
            debug_decoder_data_lo => debug_decoder_data_lo
        );

    ----------------------------------------------------------------------------
    -- IDLE Pattern Generator (TX)
    -- Continuously transmit IDLE patterns to test the link
    ----------------------------------------------------------------------------
    xgmii_txd <= XGMII_IDLE_DATA;
    xgmii_txc <= XGMII_IDLE_CTRL;

    ----------------------------------------------------------------------------
    -- Output Assignments
    ----------------------------------------------------------------------------

    -- SFP+ control: TX_DISABLE is active-high (high = TX off, low = TX on)
    -- Force to '0' to always enable optical TX (eliminates button polarity uncertainty)
    -- If this doesn't work, try '1' to test opposite polarity
    sfp_tx_disable_int <= '0';
    sfp_tx_disable <= sfp_tx_disable_int;

    -- Debug LEDs show PHY status (diagnostic mode)
    debug_led(0) <= qpll_lock_int;          -- LED0: QPLL locked
    debug_led(1) <= gtx_ready;              -- LED1: GTX ready (TX+RX reset done)
    debug_led(2) <= debug_refclk_present;   -- LED2: IBUFDS_GTE2 ODIV2 heartbeat (~0.6 Hz if clock present)
    debug_led(3) <= sys_clk_heartbeat;      -- LED3: sys_clk heartbeat (~1.5 Hz blink)

    ----------------------------------------------------------------------------
    -- UART Debug Reporter
    -- Sends status every 500ms including PCS block lock status
    --
    -- IMPORTANT: Signal Reliability (see SIGNAL_EXPECTATIONS.md)
    --   RELIABLE signals: Q, L, T, R, TC, PR, TV, TD, TH, TT, BC, HB
    --   UNRELIABLE signals: CD, EI, DV, HV, BL, ST (can show false positives with no module)
    --
    -- Key Indicator: HB (Hi-BER)
    --   HB:1 = No valid link (even if BL:1 ST:7 - that's locking to noise)
    --   HB:0 = Valid link (only if BL:1 ST:7)
    --
    -- Expected with NO SFP+ module:
    --   HB:1 [XK] = Correct (no link, may lock to noise)
    -- Expected with SFP+ module + cable + switch:
    --   HB:0 BL:1 ST:7 [OK] = Valid link established
    ----------------------------------------------------------------------------
    uart_debug_inst : entity work.gtx_debug_reporter
        generic map (
            CLK_FREQ    => 200_000_000,
            BAUD_RATE   => 115200,
            REPORT_MS   => 500
        )
        port map (
            clk              => sys_clk,
            rst              => '0',  -- No reset for debug module
            qpll_lock        => qpll_lock_int,
            qpll_refclk_lost => qpll_refclk_lost_int,
            tx_resetdone     => tx_resetdone,
            rx_resetdone     => rx_resetdone,
            debug_por_done   => debug_por_done,
            debug_qpll_reset => debug_qpll_reset,
            debug_gtx_reset  => debug_gtx_reset,
            debug_tx_userrdy => debug_tx_userrdy,
            debug_rx_userrdy => debug_rx_userrdy,
            debug_refclk_present => debug_refclk_present,
            pcs_block_lock   => pcs_block_lock,
            rx_header_valid  => gtx_rx_header_valid,
            rx_datavalid     => gtx_rx_datavalid,
            block_lock_state => pcs_block_state,
            rx_cdrlock       => debug_rx_cdrlock,
            rx_elecidle      => debug_rx_elecidle,
            tx_clk_heartbeat => tx_clk_heartbeat,
            pcs_reset        => pcs_reset,
            reset_int_dbg    => reset_int,
            gtx_ready_dbg    => gtx_ready,
            pcs_hi_ber       => pcs_hi_ber,
            pcs_tx_valid     => pcs_tx_valid,
            sfp_tx_disable   => sfp_tx_disable_int,
            -- NEW: Extended TX debug signals
            tx_enc_header    => debug_tx_enc_header,
            tx_enc_type      => debug_tx_enc_type,
            tx_block_cnt     => debug_tx_block_cnt,
            tx_header_raw    => debug_tx_header_raw,
            -- NEW: Extended RX debug signals
            rx_header_value  => debug_rx_header_value,
            rx_header_raw    => debug_rx_header_raw,
            slip_count       => debug_slip_count,
            rx_data_hi       => debug_rx_data_hi,
            rx_data_lo       => debug_rx_data_lo,
            rx_data_raw_hi   => debug_rx_data_raw_hi,
            rx_data_raw_mid  => debug_rx_data_raw_mid,
            rx_data_raw_lo   => debug_rx_data_raw_lo,
            block_type_byte0 => debug_block_type_byte0,
            block_type_byte7 => debug_block_type_byte7,
            header_errors    => debug_header_errors,
            last_block_type  => debug_last_block_type,
            ctrl_block_cnt   => debug_ctrl_block_cnt,
            data_block_cnt   => debug_data_block_cnt,
            -- NEW: Block Lock FSM counters
            fsm_valid_cnt    => debug_fsm_valid_cnt,
            fsm_invalid_cnt  => debug_fsm_invalid_cnt,
            fsm_window_cnt   => debug_fsm_window_cnt,
            -- NEW: Descrambler/Decoder status
            descram_sync     => debug_descram_sync,
            descram_data_hi  => debug_descram_data_hi,
            descram_data_lo  => debug_descram_data_lo,
            decoder_error    => debug_decoder_error,
            decoder_data_hi  => debug_decoder_data_hi,
            decoder_data_lo  => debug_decoder_data_lo,
            rx_startofseq    => debug_rx_startofseq,
            tx_gearbox_ready => debug_tx_gearbox_ready,
            uart_tx          => uart_tx
        );

end rtl;
