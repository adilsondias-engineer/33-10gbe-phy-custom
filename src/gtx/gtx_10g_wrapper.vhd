--------------------------------------------------------------------------------
-- GTX 10GBASE-R Transceiver Wrapper
--
-- Configures Kintex-7 GTX transceiver for 10.3125 Gbps operation (10GBASE-R)
--
-- Key Parameters:
--   - Line rate: 10.3125 Gbps (64B/66B encoded)
--   - Reference clock: 156.25 MHz
--   - Internal data width: 32-bit @ 322.27 MHz (QPLL, GEARBOX_MODE="001")
--   - User interface: 64-bit @ 161.13 MHz (TXUSRCLK2/RXUSRCLK2)
--   - TXUSRCLK/RXUSRCLK: 322.27 MHz (internal gearbox rate)
--   - Single MMCM generates both clock frequencies from TXOUTCLK
--   - RX shares TX clocks (GTX elastic buffer handles CDR phase offset)
--   - TX gearbox: Internal counter with TXSTARTSEQ (per SLAC SURF reference)
--
-- Reset Sequence:
--   1. Assert gt_reset for minimum 500ns
--   2. Wait for QPLL lock (qpll_lock output)
--   3. Assert gt_tx_reset / gt_rx_reset
--   4. Wait for tx_resetdone / rx_resetdone
--   5. PHY ready when both resetdone signals high
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

entity gtx_10g_wrapper is
    generic (
        -- Simulation mode (faster reset for testbench)
        SIM_MODE            : boolean := false;
        -- GTX location (for multi-channel designs)
        GTX_CHANNEL         : integer := 0
    );
    port (
        -- Reference clock (156.25 MHz differential)
        refclk_p            : in  std_logic;
        refclk_n            : in  std_logic;

        -- Free-running clock for QPLL lock detection (~10-200 MHz)
        drp_clk             : in  std_logic;

        -- System reset (active high, async)
        sys_reset           : in  std_logic;

        -- Transceiver serial interface
        gtx_txp             : out std_logic;
        gtx_txn             : out std_logic;
        gtx_rxp             : in  std_logic;
        gtx_rxn             : in  std_logic;

        -- User TX interface (64-bit @ 161.13 MHz = TXUSRCLK2)
        tx_clk              : out std_logic;        -- 161.13 MHz (10.3125G / 64)
        tx_data             : in  std_logic_vector(63 downto 0);
        tx_header           : in  std_logic_vector(1 downto 0);  -- 64B/66B sync header
        tx_valid            : in  std_logic;        -- TX data valid (unused in GEARBOX_MODE="001", retained for interface compatibility)
        tx_sequence         : out std_logic_vector(6 downto 0);  -- Debug counter (0-32)

        -- User RX interface (64-bit @ 161.13 MHz = RXUSRCLK2)
        rx_clk              : out std_logic;        -- 161.13 MHz recovered from CDR
        rx_data             : out std_logic_vector(63 downto 0);
        rx_header           : out std_logic_vector(1 downto 0);  -- 64B/66B sync header
        rx_header_valid     : out std_logic;        -- Header valid strobe
        rx_datavalid        : out std_logic;        -- Data valid

        -- Gearbox slip control (for block alignment)
        rx_gearbox_slip     : in  std_logic;        -- Slip one bit for block alignment

        -- Status outputs
        qpll_lock           : out std_logic;
        qpll_refclk_lost    : out std_logic;        -- Reference clock lost indicator
        tx_resetdone        : out std_logic;
        rx_resetdone        : out std_logic;
        phy_ready           : out std_logic;        -- Both TX and RX ready

        -- Debug outputs for UART diagnostics
        debug_por_done      : out std_logic;        -- Power-on reset complete
        debug_qpll_reset    : out std_logic;        -- QPLL reset active
        debug_gtx_reset     : out std_logic;        -- GTX channel reset active
        debug_tx_userrdy    : out std_logic;        -- TX user ready
        debug_rx_userrdy    : out std_logic;        -- RX user ready
        debug_refclk_present: out std_logic;        -- IBUFDS_GTE2 ODIV2 heartbeat (~0.6 Hz)
        debug_rx_cdrlock    : out std_logic;        -- RX CDR lock status
        debug_rx_elecidle   : out std_logic;        -- RX electrical idle detected
        debug_rx_startofseq : out std_logic;        -- RXSTARTOFSEQ - indicates when gearbox sequence counter is at 0
        debug_tx_gearbox_ready : out std_logic     -- TXGEARBOXREADY - indicates when TX gearbox can accept data
    );
end gtx_10g_wrapper;

architecture rtl of gtx_10g_wrapper is

    -- Reference clock buffer output
    signal refclk_buf       : std_logic;
    signal refclk_div2      : std_logic;  -- ODIV2 output (78.125 MHz)
    signal refclk_div2_bufg : std_logic;  -- ODIV2 after BUFG (fabric-usable)

    -- ODIV2 heartbeat counter - verifies IBUFDS_GTE2 is outputting clock
    signal refclk_counter   : unsigned(26 downto 0) := (others => '0');  -- ~0.6s at 78.125 MHz
    signal refclk_heartbeat : std_logic := '0';

    -- QPLL signals
    signal qpll_outclk      : std_logic;
    signal qpll_outrefclk   : std_logic;
    signal qpll_lock_int    : std_logic;
    signal qpll_refclklost_int : std_logic;
    -- Note: qpll_reset is now generated by qpll_reset_pulse in the reset sequencer

    -- TX path signals
    signal tx_outclk        : std_logic;
    signal tx_usrclk        : std_logic;  -- 322.27 MHz (internal 32-bit rate)
    signal tx_usrclk2       : std_logic;  -- 161.13 MHz (external 64-bit rate)
    signal tx_resetdone_int : std_logic;
    signal txdata_int       : std_logic_vector(63 downto 0);  -- Port is always 64-bit
    signal txheader_int     : std_logic_vector(2 downto 0);
    signal txsequence_int   : std_logic_vector(6 downto 0);
    signal tx_startseq_int  : std_logic := '0';  -- TXSTARTSEQ pulse for mode "011"

    -- TX clock generation signals
    signal tx_outclk_bufg   : std_logic;  -- TXOUTCLK after BUFG (drives MMCM input)
    signal tx_mmcm_clkfb    : std_logic;
    signal tx_mmcm_clk0     : std_logic;  -- 322.27 MHz (unbuffered MMCM output)
    signal tx_mmcm_clk1     : std_logic;  -- 161.13 MHz (unbuffered MMCM output)
    signal tx_mmcm_locked   : std_logic;

    -- RX path signals
    signal rx_outclk        : std_logic;
    signal rx_usrclk        : std_logic;  -- 322.27 MHz (internal 32-bit rate)
    signal rx_usrclk2       : std_logic;  -- 161.13 MHz (external 64-bit rate)
    signal rx_resetdone_int : std_logic;
    signal rxdata_int       : std_logic_vector(63 downto 0);  -- GTX outputs 64-bit even with 32-bit width
    signal rxheader_int     : std_logic_vector(2 downto 0);
    signal rxheadervalid_int: std_ulogic;
    signal rxdatavalid_int  : std_ulogic;
    signal rxgearboxslip_int: std_logic;
    signal rxcdrlock_int    : std_ulogic;
    signal rxelecidle_int   : std_ulogic;

    -- RX uses same MMCM as TX (both from same QPLL, GTX elastic buffer handles phase)
    -- No separate RX MMCM needed - single MMCM constraint per clock region

    -- Power-on reset generator (auto-starts the reset sequence)
    -- Use 24-bit counter for ~80ms POR at 200MHz (ensures dominates any transients)
    signal por_counter      : unsigned(23 downto 0) := (others => '0');
    signal por_done         : std_logic := '0';
    signal reset_combined   : std_logic := '1';  -- Combined POR + external reset

    -- External reset synchronizer (to handle metastability from button)
    signal sys_reset_sync   : std_logic_vector(2 downto 0) := (others => '0');
    signal sys_reset_int    : std_logic := '0';

    -- Reset sequencer (500ns startup delay per AR43482)
    signal reset_counter    : unsigned(15 downto 0) := (others => '0');
    signal gt_reset_done    : std_logic := '0';
    signal qpll_reset_done  : std_logic := '0';
    signal init_wait_done   : std_logic := '0';
    signal qpll_reset_pulse : std_logic := '0';

    -- Constants for 500ns startup delay (assuming ~200MHz drp_clk = 5ns period)
    -- 500ns / 5ns = 100 cycles, add margin = 120 cycles
    constant STARTUP_WAIT_CYCLES : unsigned(7 downto 0) := to_unsigned(120, 8);
    signal startup_counter  : unsigned(7 downto 0) := (others => '0');

    -- GTX channel reset (must wait for QPLL lock before releasing)
    signal gtx_reset_int    : std_logic := '1';
    signal qpll_lock_sync   : std_logic_vector(2 downto 0) := (others => '0');

    -- User ready signals (delayed after reset release per UG476)
    signal tx_userrdy_int   : std_logic := '0';
    signal rx_userrdy_int   : std_logic := '0';
    signal userrdy_delay_cnt: unsigned(15 downto 0) := (others => '0');
    constant USERRDY_DELAY  : unsigned(15 downto 0) := to_unsigned(20000, 16);  -- 100us at 200MHz

    -- Gearbox debug counter
    signal tx_gearbox_seq   : unsigned(6 downto 0) := (others => '0');
    
    -- RXSTARTOFSEQ (indicates when gearbox sequence counter is at 0)
    signal rx_startofseq_int : std_logic;
    
    -- TXGEARBOXREADY (indicates when TX gearbox can accept data)
    signal tx_gearbox_ready_int : std_logic;
    
    -- Note: Debug signals are passed directly - debug reporter handles CDC

    -- Clock domain crossing for status
    signal tx_resetdone_sync: std_logic_vector(2 downto 0) := (others => '0');
    signal rx_resetdone_sync: std_logic_vector(2 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- Reference Clock Buffering
    -- IBUFDS_GTE2 connects DIRECTLY to dedicated GTX reference clock pins
    -- No IBUF stage - IBUFDS_GTE2 is the correct buffer for MGTREFCLK pins
    ----------------------------------------------------------------------------
    refclk_ibufds : IBUFDS_GTE2
        port map (
            O       => refclk_buf,
            ODIV2   => refclk_div2,  -- 78.125 MHz for fabric use
            CEB     => '0',
            I       => refclk_p,
            IB      => refclk_n
        );

    ----------------------------------------------------------------------------
    -- ODIV2 Heartbeat Counter
    -- Verifies that IBUFDS_GTE2 is receiving and outputting the reference clock
    -- 78.125 MHz / 2^27 = ~0.6 Hz blink rate
    -- Uses BUFG to route ODIV2 to fabric for counter
    ----------------------------------------------------------------------------
    refclk_div2_bufg_inst : BUFG
        port map (
            I => refclk_div2,
            O => refclk_div2_bufg
        );

    process(refclk_div2_bufg)
    begin
        if rising_edge(refclk_div2_bufg) then
            refclk_counter <= refclk_counter + 1;
            refclk_heartbeat <= refclk_counter(26);
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- External Reset Synchronizer
    -- Synchronizes the async button input to drp_clk domain
    -- Note: Button is ACTIVE-LOW (pressed = 0, released = 1)
    -- Invert the input so sys_reset_int = '1' when button is pressed
    ----------------------------------------------------------------------------
    process(drp_clk)
    begin
        if rising_edge(drp_clk) then
            sys_reset_sync <= sys_reset_sync(1 downto 0) & (not sys_reset);
            sys_reset_int <= sys_reset_sync(2);
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Power-On Reset Generator
    -- Generates a reset pulse after FPGA configuration to start the sequence
    -- Uses ~80ms delay (16M cycles at 200MHz) to ensure FPGA is fully configured
    ----------------------------------------------------------------------------
    process(drp_clk)
    begin
        if rising_edge(drp_clk) then
            if por_done = '0' then
                if por_counter < x"FFFFFF" then  -- ~80ms at 200MHz (16M cycles)
                    por_counter <= por_counter + 1;
                else
                    por_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Combined reset: active during POR or when synchronized external reset is asserted
    reset_combined <= (not por_done) or sys_reset_int;

    ----------------------------------------------------------------------------
    -- QPLL Reset Sequencer (per Xilinx AR43482)
    -- Must wait 500ns after FPGA configuration before asserting QPLL reset
    -- Uses reset_combined (POR + external reset) to auto-start after programming
    ----------------------------------------------------------------------------
    process(drp_clk)
    begin
        if rising_edge(drp_clk) then
            if reset_combined = '1' then
                startup_counter <= (others => '0');
                init_wait_done <= '0';
                qpll_reset_pulse <= '1';  -- Hold QPLL in reset during POR
                qpll_reset_done <= '0';
                -- CRITICAL: Reset all state when reset is asserted
                qpll_lock_sync <= (others => '0');  -- Clear lock synchronizer
                gtx_reset_int <= '1';               -- Hold GTX in reset
                tx_userrdy_int <= '0';              -- Deassert user ready
                rx_userrdy_int <= '0';
                userrdy_delay_cnt <= (others => '0');
            else
                -- Wait 500ns (120 cycles at 200MHz) after POR release
                if startup_counter < STARTUP_WAIT_CYCLES then
                    startup_counter <= startup_counter + 1;
                    init_wait_done <= '0';
                    qpll_reset_pulse <= '1';  -- Keep QPLL reset asserted during startup wait
                else
                    init_wait_done <= '1';
                    -- Release QPLL reset after startup delay
                    qpll_reset_pulse <= '0';
                    qpll_reset_done <= '1';
                end if;

                -- Synchronize QPLL lock to drp_clk domain
                qpll_lock_sync <= qpll_lock_sync(1 downto 0) & qpll_lock_int;

                -- GTX reset: release when QPLL is locked
                -- TXOUTCLK starts running after GTTXRESET deasserted (drives MMCM)
                -- UG476 sequence: QPLL lock -> deassert GTTXRESET -> TXOUTCLK runs ->
                --   MMCM locks -> assert TXUSERRDY -> TXRESETDONE
                if qpll_lock_sync(2) = '1' then
                    gtx_reset_int <= '0';  -- Release GTX reset (TXOUTCLK will start)
                else
                    gtx_reset_int <= '1';  -- Hold in reset until QPLL locked
                    userrdy_delay_cnt <= (others => '0');
                end if;

                -- User ready: assert after MMCM locks + delay
                -- MMCM needs TXOUTCLK (from GTX) to lock, so this naturally
                -- sequences after GTX reset release. Per UG476, TXUSERRDY gates
                -- the TX PCS — clocks must be stable before assertion.
                if gtx_reset_int = '0' and tx_mmcm_locked = '1' then
                    if userrdy_delay_cnt < USERRDY_DELAY then
                        userrdy_delay_cnt <= userrdy_delay_cnt + 1;
                        tx_userrdy_int <= '0';
                        rx_userrdy_int <= '0';
                    else
                        tx_userrdy_int <= '1';
                        rx_userrdy_int <= '1';
                    end if;
                else
                    tx_userrdy_int <= '0';
                    rx_userrdy_int <= '0';
                    userrdy_delay_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- QPLL (Quad PLL for 10.3125 Gbps)
    --
    -- QPLL_REFCLK_DIV = 1 (156.25 MHz / 1 = 156.25 MHz PFD)
    -- QPLL_FBDIV = 66 (156.25 MHz * 66 = 10.3125 GHz VCO)
    -- Line rate = 10.3125 Gbps
    --
    -- Reference clock: G7/G8 = MGTREFCLK0_117 on XC7K325T-FFG900 (AX7325B board)
    -- Using GTREFCLK1 with QPLLREFCLKSEL="010" (matching working Project 32)
    ----------------------------------------------------------------------------
    gtxe2_common_inst : GTXE2_COMMON
        generic map (
            -- Simulation
            SIM_RESET_SPEEDUP       => "TRUE",
            SIM_QPLLREFCLK_SEL      => "010",  -- GTREFCLK1 (matching working Project 32)
            SIM_VERSION             => "4.0",

            -- QPLL Configuration for 10.3125 Gbps (matched to Vivado IP exactly)
            -- VCO = 156.25 MHz * 66 = 10.3125 GHz
            QPLL_REFCLK_DIV         => 1,
            QPLL_FBDIV              => "0101000000",  -- Encoding for 66x feedback divider
            QPLL_FBDIV_RATIO        => '0',
            QPLL_CFG                => x"0680181",
            QPLL_CP                 => "0000011111",
            QPLL_LOCK_CFG           => x"21E8",
            QPLL_LPF                => "1111",
            QPLL_INIT_CFG           => x"000006",

            -- Additional QPLL attributes (matched to Vivado IP)
            QPLL_CLKOUT_CFG         => "0000",
            QPLL_COARSE_FREQ_OVRD   => "010000",
            QPLL_COARSE_FREQ_OVRD_EN => '0',
            QPLL_CP_MONITOR_EN      => '0',
            QPLL_DMONITOR_SEL       => '0',
            QPLL_FBDIV_MONITOR_EN   => '0',

            -- Bias settings
            BIAS_CFG                => x"0000040000001000",
            COMMON_CFG              => x"00000000"
        )
        port map (
            -- Reference clock: G7/G8 = MGTREFCLK0_117
            -- Using GTREFCLK1 port with QPLLREFCLKSEL="010" (matching working Project 32)
            GTGREFCLK           => '0',
            GTREFCLK0           => '0',                -- Tied to ground (matching P32)
            GTREFCLK1           => refclk_buf,         -- From IBUFDS_GTE2 (matching P32)
            GTNORTHREFCLK0      => '0',
            GTNORTHREFCLK1      => '0',
            GTSOUTHREFCLK0      => '0',
            GTSOUTHREFCLK1      => '0',
            QPLLREFCLKSEL       => "010",  -- Select GTREFCLK1 (matching working Project 32)

            -- QPLL outputs
            QPLLOUTCLK          => qpll_outclk,
            QPLLOUTREFCLK       => qpll_outrefclk,
            QPLLLOCK            => qpll_lock_int,
            QPLLLOCKDETCLK      => drp_clk,  -- Free-running clock per AR43482
            QPLLLOCKEN          => '1',
            QPLLOUTRESET        => '0',

            -- Reset and power down (use sequenced reset pulse)
            QPLLRESET           => qpll_reset_pulse,
            QPLLPD              => '0',

            -- DRP interface (unused - matching working Xilinx IP which ties DRPCLK to ground)
            DRPCLK              => '0',
            DRPEN               => '0',
            DRPWE               => '0',
            DRPADDR             => (others => '0'),
            DRPDI               => (others => '0'),
            DRPDO               => open,
            DRPRDY              => open,

            -- Status/Reserved
            REFCLKOUTMONITOR    => open,
            QPLLDMONITOR        => open,  -- Was missing!
            QPLLFBCLKLOST       => open,
            QPLLREFCLKLOST      => qpll_refclklost_int,
            QPLLRSVD1           => "0000000000000000",
            QPLLRSVD2           => "11111",
            BGBYPASSB           => '1',
            BGMONITORENB        => '1',
            BGPDB               => '1',
            BGRCALOVRD          => "11111",
            RCALENB             => '1',
            PMARSVD             => "00000000"
        );

    ----------------------------------------------------------------------------
    -- GTX Channel (GTXE2_CHANNEL)
    --
    -- TX: 64B/66B encoding enabled, 32-bit internal width
    -- RX: 64B/66B decoding enabled, 32-bit internal width, CDR
    ----------------------------------------------------------------------------
    gtxe2_channel_inst : GTXE2_CHANNEL
        generic map (
            -- Simulation
            SIM_RECEIVER_DETECT_PASS    => "TRUE",
            SIM_TX_EIDLE_DRIVE_LEVEL    => "X",
            SIM_RESET_SPEEDUP           => "TRUE",
            SIM_CPLLREFCLK_SEL          => "001",
            SIM_VERSION                 => "4.0",

            -- TX Configuration (64-bit external with 32-bit internal for 64B/66B gearbox)
            TX_DATA_WIDTH               => 64,
            TX_INT_DATAWIDTH            => 1,  -- 4-byte (32-bit) internal, required for 64-bit external
            TXGEARBOX_EN                => "TRUE",   -- Enable TX gearbox for 64B/66B
            GEARBOX_MODE                => "001",    -- 64B/66B mode, user-driven TXSEQUENCE counter (per Forencich reference)
            TXBUF_EN                    => "TRUE",   -- Enable TX elastic buffer
            TX_XCLK_SEL                 => "TXOUT",  -- Use TX output clock

            -- TX Driver
            TX_DRIVE_MODE               => "DIRECT",
            TX_MAINCURSOR_SEL           => '0',
            TX_MARGIN_FULL_0            => "1001110",
            TX_MARGIN_FULL_1            => "1001001",
            TX_MARGIN_FULL_2            => "1000101",
            TX_MARGIN_FULL_3            => "1000010",
            TX_MARGIN_FULL_4            => "1000000",
            TX_MARGIN_LOW_0             => "1000110",
            TX_MARGIN_LOW_1             => "1000100",
            TX_MARGIN_LOW_2             => "1000010",
            TX_MARGIN_LOW_3             => "1000000",
            TX_MARGIN_LOW_4             => "1000000",
            TX_PREDRIVER_MODE           => '0',
            TX_DEEMPH0                  => "00000",
            TX_DEEMPH1                  => "00000",

            -- RX Configuration (64-bit external with 32-bit internal for 64B/66B gearbox)
            RX_DATA_WIDTH               => 64,
            RX_INT_DATAWIDTH            => 1,  -- 4-byte (32-bit) internal, required for 64-bit external
            RXGEARBOX_EN                => "TRUE",   -- Enable RX gearbox for 64B/66B
            RXBUF_EN                    => "TRUE",   -- Enable RX elastic buffer
            RX_XCLK_SEL                 => "RXREC",  -- Use recovered clock from CDR

            -- RX CDR (matches Alinx vendor IP)
            RXCDR_CFG                   => x"0b000023ff10400020",
            RXCDR_LOCK_CFG              => "010101",
            RXCDR_HOLD_DURING_EIDLE     => '0',
            RXCDR_FR_RESET_ON_EIDLE     => '0',
            RXCDR_PH_RESET_ON_EIDLE     => '0',

            -- RX Equalizer
            RX_DFE_GAIN_CFG             => x"180E0F",
            RX_DFE_H2_CFG               => "000111100000",
            RX_DFE_H3_CFG               => "000001000000",
            RX_DFE_H4_CFG               => "00011110000",
            RX_DFE_H5_CFG               => "00011100000",
            RX_DFE_KL_CFG               => "0000011111110",
            RX_DFE_KL_CFG2              => x"3010D90C",
            RX_DFE_LPM_CFG              => x"0904",
            RX_DFE_LPM_HOLD_DURING_EIDLE=> '0',
            RX_DFE_UT_CFG               => "10001111000000000",
            RX_DFE_VP_CFG               => "00011111100000011",
            RX_DFE_XYD_CFG              => "0000000000000",
            RX_OS_CFG                   => "0000010000000",

            -- RX OOB Detection (disabled)
            RXOOB_CFG                   => "0000110",
            SATA_BURST_SEQ_LEN          => "1111",
            SATA_BURST_VAL              => "100",
            SATA_CPLL_CFG               => "VCO_3000MHZ",
            SATA_EIDLE_VAL              => "100",

            -- RX Comma Alignment (disabled for 64B/66B)
            ALIGN_COMMA_DOUBLE          => "FALSE",
            ALIGN_COMMA_ENABLE          => "0000000000",
            ALIGN_COMMA_WORD            => 1,
            ALIGN_MCOMMA_DET            => "FALSE",
            ALIGN_MCOMMA_VALUE          => "1010000011",
            ALIGN_PCOMMA_DET            => "FALSE",
            ALIGN_PCOMMA_VALUE          => "0101111100",
            DEC_MCOMMA_DETECT           => "FALSE",
            DEC_PCOMMA_DETECT           => "FALSE",
            DEC_VALID_COMMA_ONLY        => "FALSE",
            SHOW_REALIGN_COMMA          => "FALSE",
            RXSLIDE_AUTO_WAIT           => 7,
            RXSLIDE_MODE                => "PCS",  -- CRITICAL: Must be "PCS" for 64B/66B gearbox slip

            -- CPLL (not used, using QPLL)
            CPLL_CFG                    => x"BC07DC",
            CPLL_FBDIV                  => 4,
            CPLL_FBDIV_45               => 5,
            CPLL_INIT_CFG               => x"00001E",
            CPLL_LOCK_CFG               => x"01E8",
            CPLL_REFCLK_DIV             => 1,

            -- Clock recovery
            TXOUT_DIV                   => 1,
            RXOUT_DIV                   => 1,

            -- Other
            CHAN_BOND_MAX_SKEW          => 7,
            CHAN_BOND_SEQ_LEN           => 1,
            CHAN_BOND_SEQ_1_1           => "0000000000",
            CHAN_BOND_SEQ_1_2           => "0000000000",
            CHAN_BOND_SEQ_1_3           => "0000000000",
            CHAN_BOND_SEQ_1_4           => "0000000000",
            CHAN_BOND_SEQ_1_ENABLE      => "1111",
            CHAN_BOND_SEQ_2_1           => "0000000000",
            CHAN_BOND_SEQ_2_2           => "0000000000",
            CHAN_BOND_SEQ_2_3           => "0000000000",
            CHAN_BOND_SEQ_2_4           => "0000000000",
            CHAN_BOND_SEQ_2_ENABLE      => "1111",
            CHAN_BOND_SEQ_2_USE         => "FALSE",
            CLK_CORRECT_USE             => "FALSE",
            CLK_COR_KEEP_IDLE           => "FALSE",
            CLK_COR_MAX_LAT             => 9,
            CLK_COR_MIN_LAT             => 7,
            CLK_COR_PRECEDENCE          => "TRUE",
            CLK_COR_REPEAT_WAIT         => 0,
            CLK_COR_SEQ_1_1             => "0100000000",
            CLK_COR_SEQ_1_2             => "0000000000",
            CLK_COR_SEQ_1_3             => "0000000000",
            CLK_COR_SEQ_1_4             => "0000000000",
            CLK_COR_SEQ_1_ENABLE        => "1111",
            CLK_COR_SEQ_2_1             => "0100000000",
            CLK_COR_SEQ_2_2             => "0000000000",
            CLK_COR_SEQ_2_3             => "0000000000",
            CLK_COR_SEQ_2_4             => "0000000000",
            CLK_COR_SEQ_2_ENABLE        => "1111",
            CLK_COR_SEQ_2_USE           => "FALSE",
            CLK_COR_SEQ_LEN             => 1,
            ES_CONTROL                  => "000000",
            ES_ERRDET_EN                => "FALSE",
            ES_EYE_SCAN_EN              => "TRUE",
            ES_HORZ_OFFSET              => x"000",
            ES_PMA_CFG                  => "0000000000",
            ES_PRESCALE                 => "00000",
            ES_QUALIFIER                => x"00000000000000000000",
            ES_QUAL_MASK                => x"00000000000000000000",
            ES_SDATA_MASK               => x"00000000000000000000",
            ES_VERT_OFFSET              => "000000000",
            FTS_DESKEW_SEQ_ENABLE       => "1111",
            FTS_LANE_DESKEW_CFG         => "1111",
            FTS_LANE_DESKEW_EN          => "FALSE",
            OUTREFCLK_SEL_INV           => "11",
            PCS_PCIE_EN                 => "FALSE",
            PCS_RSVD_ATTR               => x"000000000000",
            PD_TRANS_TIME_FROM_P2       => x"03C",
            PD_TRANS_TIME_NONE_P2       => x"19",
            PD_TRANS_TIME_TO_P2         => x"64",
            PMA_RSV                     => x"00018480",
            PMA_RSV2                    => x"2050",
            PMA_RSV3                    => "00",
            PMA_RSV4                    => x"00000000",
            RXBUFRESET_TIME             => "00001",
            RXBUF_ADDR_MODE             => "FAST",
            RXBUF_EIDLE_HI_CNT          => "1000",
            RXBUF_EIDLE_LO_CNT          => "0000",
            RXBUF_RESET_ON_CB_CHANGE    => "TRUE",
            RXBUF_RESET_ON_COMMAALIGN   => "FALSE",
            RXBUF_RESET_ON_EIDLE        => "FALSE",
            RXBUF_RESET_ON_RATE_CHANGE  => "TRUE",
            RXBUF_THRESH_OVFLW          => 61,
            RXBUF_THRESH_OVRD           => "FALSE",
            RXBUF_THRESH_UNDFLW         => 4,
            RX_BIAS_CFG                 => "000000000100",
            RX_BUFFER_CFG               => "000000",
            RX_CLK25_DIV                => 7,
            RX_CLKMUX_PD                => '1',
            RX_CM_SEL                   => "11",
            RX_CM_TRIM                  => "010",
            RX_DDI_SEL                  => "000000",
            RX_DEBUG_CFG                => "000000000000",
            RX_DEFER_RESET_BUF_EN       => "TRUE",
            RX_DISPERR_SEQ_MATCH        => "TRUE",
            RX_SIG_VALID_DLY            => 10,
            RXCDRFREQRESET_TIME         => "00001",
            RXCDRPHRESET_TIME           => "00001",
            RXISCANRESET_TIME           => "00001",
            RXPCSRESET_TIME             => "00001",
            RXPHDLY_CFG                 => x"084020",
            RXPH_CFG                    => x"000000",
            RXPH_MONITOR_SEL            => "00000",
            RXPMARESET_TIME             => "00011",
            RXPRBS_ERR_LOOPBACK         => '0',
            TRANS_TIME_RATE             => x"0E",
            TST_RSV                     => x"00000000",
            TXBUF_RESET_ON_RATE_CHANGE  => "TRUE",
            TX_CLK25_DIV                => 7,
            TX_CLKMUX_PD                => '1',
            TX_LOOPBACK_DRIVE_HIZ       => "FALSE",
            TX_RXDETECT_CFG             => x"1832",
            TX_RXDETECT_REF             => "100",
            TXPCSRESET_TIME             => "00001",
            TXPHDLY_CFG                 => x"084020",
            TXPH_CFG                    => x"0780",
            TXPH_MONITOR_SEL            => "00000",
            TXPMARESET_TIME             => "00001",
            UCODEER_CLR                 => '0'
        )
        port map (
            -- QPLL Interface
            QPLLCLK                 => qpll_outclk,
            QPLLREFCLK              => qpll_outrefclk,

            -- TX Serial Output
            GTXTXP                  => gtx_txp,
            GTXTXN                  => gtx_txn,

            -- RX Serial Input
            GTXRXP                  => gtx_rxp,
            GTXRXN                  => gtx_rxn,

            -- TX User Clock
            TXOUTCLK                => tx_outclk,
            TXUSRCLK                => tx_usrclk,
            TXUSRCLK2               => tx_usrclk2,
            TXOUTCLKFABRIC          => open,
            TXOUTCLKPCS             => open,
            TXOUTCLKSEL             => "010",  -- TXPMA2USERCLK: 10312.5/32 = 322.27 MHz

            -- TX Data Path
            TXDATA                  => txdata_int,
            TXHEADER                => txheader_int,
            TXSEQUENCE              => txsequence_int,
            TXSTARTSEQ              => tx_startseq_int,  -- Unused in GEARBOX_MODE="001" (tied low)
            TXGEARBOXREADY          => tx_gearbox_ready_int,  -- Informational: pulses when gearbox latches data

            -- TX Control
            TXCHARISK               => (others => '0'),
            TX8B10BBYPASS           => (others => '0'),
            TXCHARDISPMODE          => (others => '0'),
            TXCHARDISPVAL           => (others => '0'),

            -- TX Reset (sequenced: wait for QPLL lock before releasing)
            TXRESETDONE             => tx_resetdone_int,
            GTTXRESET               => gtx_reset_int,
            TXUSERRDY               => tx_userrdy_int,
            TXPCSRESET              => '0',
            TXPMARESET              => '0',

            -- TX OOB signals
            TXCOMFINISH             => open,
            TXCOMINIT               => '0',
            TXCOMSAS                => '0',
            TXCOMWAKE               => '0',

            -- TX Polarity/Swing
            TXPOLARITY              => '0',
            TXDIFFCTRL              => "1000",
            TXPOSTCURSOR            => "00000",
            TXPRECURSOR             => "00000",
            TXINHIBIT               => '0',
            TXMAINCURSOR            => "0000000",

            -- TX Bypass/Loopback
            TXELECIDLE              => '0',
            TXDETECTRX              => '0',
            LOOPBACK                => "000",

            -- TX Power Down
            TXPD                    => "00",
            TXPISOPD                => '0',
            TXPDELECIDLEMODE        => '0',

            -- RX User Clock
            RXOUTCLK                => rx_outclk,
            RXUSRCLK                => rx_usrclk,
            RXUSRCLK2               => rx_usrclk2,
            RXOUTCLKFABRIC          => open,
            RXOUTCLKPCS             => open,
            RXOUTCLKSEL             => "010",  -- RXPMA2USERCLK: recovered 322.27 MHz from CDR
            RXDDIEN                 => '0',
            RXDLYBYPASS             => '1',

            -- RX Data Path
            RXDATA                  => rxdata_int,
            RXHEADER                => rxheader_int,
            RXHEADERVALID           => rxheadervalid_int,
            RXDATAVALID             => rxdatavalid_int,

            -- RX Gearbox
            RXGEARBOXSLIP           => rx_gearbox_slip,
            RXSTARTOFSEQ            => rx_startofseq_int,  -- Indicates when gearbox sequence counter is at 0

            -- RX Control
            RXCHARISCOMMA           => open,
            RXCHARISK               => open,
            RXDISPERR               => open,
            RXNOTINTABLE            => open,

            -- RX Reset
            RXRESETDONE             => rx_resetdone_int,
            GTRXRESET               => gtx_reset_int,
            RXUSERRDY               => rx_userrdy_int,
            RXPCSRESET              => '0',
            RXPMARESET              => '0',
            RXCDRRESET              => '0',
            RXCDRHOLD               => '0',
            RXCDRFREQRESET          => '0',
            RXDFEAGCHOLD            => '0',
            RXDFEAGCOVRDEN          => '0',
            RXDFECM1EN              => '0',
            RXDFELFHOLD             => '0',
            RXDFELFOVRDEN           => '1',
            RXDFELPMRESET           => '0',
            RXDFETAP2HOLD           => '0',
            RXDFETAP2OVRDEN         => '0',
            RXDFETAP3HOLD           => '0',
            RXDFETAP3OVRDEN         => '0',
            RXDFETAP4HOLD           => '0',
            RXDFETAP4OVRDEN         => '0',
            RXDFETAP5HOLD           => '0',
            RXDFETAP5OVRDEN         => '0',
            RXDFEUTHOLD             => '0',
            RXDFEUTOVRDEN           => '0',
            RXDFEVPHOLD             => '0',
            RXDFEVPOVRDEN           => '0',
            RXDFEVSEN               => '0',
            RXDFEXYDEN              => '1',
            RXLPMEN                 => '0',  -- DFE mode (not LPM)
            RXOSHOLD                => '0',
            RXOSOVRDEN              => '0',

            -- RX Alignment (not used for 64B/66B)
            RXCOMMADETEN            => '0',
            RXMCOMMAALIGNEN         => '0',
            RXPCOMMAALIGNEN         => '0',
            RXSLIDE                 => '0',
            RXBYTEISALIGNED         => open,
            RXBYTEREALIGN           => open,
            RXCOMMADET              => open,

            -- RX Status
            RXSTATUS                => open,
            RXVALID                 => open,
            RXCDRLOCK               => rxcdrlock_int,
            RXELECIDLE              => rxelecidle_int,
            RXRATEDONE              => open,

            -- RX Polarity
            RXPOLARITY              => '0',

            -- RX Power Down
            RXPD                    => "00",
            RXLPMHFHOLD             => '0',
            RXLPMHFOVRDEN           => '0',
            RXLPMLFHOLD             => '0',
            RXLPMLFKLOVRDEN         => '0',

            -- CPLL (not used)
            CPLLFBCLKLOST           => open,
            CPLLLOCK                => open,
            CPLLLOCKDETCLK          => '0',
            CPLLLOCKEN              => '1',
            CPLLPD                  => '1',  -- Power down CPLL (using QPLL)
            CPLLREFCLKLOST          => open,
            CPLLREFCLKSEL           => "001",
            CPLLRESET               => '0',
            GTGREFCLK               => '0',
            GTREFCLK0               => '0',
            GTREFCLK1               => '0',
            GTNORTHREFCLK0          => '0',
            GTNORTHREFCLK1          => '0',
            GTSOUTHREFCLK0          => '0',
            GTSOUTHREFCLK1          => '0',

            -- DRP Interface (unused for now)
            DRPCLK                  => '0',
            DRPEN                   => '0',
            DRPWE                   => '0',
            DRPADDR                 => (others => '0'),
            DRPDI                   => (others => '0'),
            DRPDO                   => open,
            DRPRDY                  => open,

            -- PRBS Generator/Checker
            TXPRBSSEL               => "000",
            TXPRBSFORCEERR          => '0',
            RXPRBSSEL               => "000",
            RXPRBSERR               => open,
            RXPRBSCNTRESET          => '0',

            -- Eye Scan (unused)
            EYESCANRESET            => '0',
            EYESCANDATAERROR        => open,
            EYESCANMODE             => '0',
            EYESCANTRIGGER          => '0',

            -- Reserved/Unused ports
            PCSRSVDIN               => (others => '0'),
            PCSRSVDIN2              => "00000",
            PCSRSVDOUT              => open,
            PMARSVDIN               => "00000",
            PMARSVDIN2              => "00000",
            TSTIN                   => (others => '1'),
            TSTOUT                  => open,

            -- TX Rate (not used - fixed rate)
            TXRATE                  => "000",
            TXRATEDONE              => open,

            -- TX Phase Align (not used)
            TXPHDLYTSTCLK           => '0',
            TXDLYHOLD               => '0',
            TXDLYOVRDEN             => '0',
            TXDLYSRESET             => '0',
            TXDLYSRESETDONE         => open,
            TXDLYUPDOWN             => '0',
            TXPHALIGN               => '0',
            TXPHALIGNDONE           => open,
            TXPHALIGNEN             => '0',
            TXPHDLYPD               => '0',
            TXPHDLYRESET            => '0',
            TXPHINIT                => '0',
            TXPHINITDONE            => open,
            TXPHOVRDEN              => '0',

            -- RX Rate (not used - fixed rate)
            RXRATE                  => "000",

            -- RX Phase Align (not used)
            RXPHDLYPD               => '0',
            RXPHDLYRESET            => '0',
            RXPHALIGN               => '0',
            RXPHALIGNDONE           => open,
            RXPHALIGNEN             => '0',
            RXPHOVRDEN              => '0',
            RXDLYSRESET             => '0',
            RXDLYSRESETDONE         => open,
            RXDLYEN                 => '0',
            RXDLYOVRDEN             => '0',

            -- Channel Bonding (not used)
            RXCHBONDEN              => '0',
            RXCHBONDMASTER          => '0',
            RXCHBONDSLAVE           => '0',
            RXCHBONDI               => (others => '0'),
            RXCHBONDO               => open,
            RXCHBONDLEVEL           => (others => '0'),
            RXCHANBONDSEQ           => open,
            RXCHANISALIGNED         => open,
            RXCHANREALIGN           => open,

            -- Misc/Reserved
            TXDIFFPD                => '0',
            GTRSVD                  => (others => '0'),
            GTRESETSEL              => '0',
            RESETOVRD               => '0',
            CLKRSVD                 => (others => '0'),
            DMONITOROUT             => open,
            RXMONITOROUT            => open,
            RXMONITORSEL            => "00",
            TXQPIBIASEN             => '0',
            TXQPISENN               => open,
            TXQPISENP               => open,
            TXQPISTRONGPDOWN        => '0',
            TXQPIWEAKPUP            => '0',
            RXQPIEN                 => '0',
            RXQPISENN               => open,
            RXQPISENP               => open,

            -- Required ports from Vivado primitive
            CFGRESET                => '0',
            RX8B10BEN               => '0',
            RXBUFRESET              => '0',
            RXCDROVRDEN             => '0',
            RXCDRRESETRSV           => '0',
            RXDFEXYDHOLD            => '0',
            RXDFEXYDOVRDEN          => '0',
            RXELECIDLEMODE          => "11",
            RXOOBRESET              => '0',
            RXSYSCLKSEL             => "11",  -- Use QPLL for RX (must match TX for 10G)
            SETERRSTATUS            => '0',
            TX8B10BEN               => '0',
            TXBUFDIFFCTRL           => "100",
            TXDEEMPH                => '0',
            TXDLYBYPASS             => '1',
            TXDLYEN                 => '0',
            TXMARGIN                => "000",
            TXPOSTCURSORINV         => '0',
            TXPRECURSORINV          => '0',
            TXSWING                 => '0',
            TXSYSCLKSEL             => "11"
        );

    ----------------------------------------------------------------------------
    -- TX Clock Generation (BUFG + MMCM)
    --
    -- TXOUTCLK = 322.27 MHz (PMA parallel clock = 10.3125G / 32)
    -- TXUSRCLK  = 322.27 MHz (internal 32-bit gearbox rate)
    -- TXUSRCLK2 = 161.13 MHz (external 64-bit fabric interface rate)
    --
    -- Architecture: TXOUTCLK -> BUFG -> MMCM -> BUFG x 2
    -- The intermediate BUFG decouples the GT-to-MMCM dedicated route requirement.
    -- Without it, the GT and MMCM must be in the same clock region (fails on
    -- XC7K325T where GT X0Y8 and available MMCMs are in different regions).
    -- With the BUFG, the MMCM input is a global clock and can be placed anywhere.
    --
    -- UG476 requirement: When TX_DATA_WIDTH = 2 * TX_INT_DATAWIDTH * 8,
    --   TXUSRCLK2 = TXUSRCLK / 2
    --
    -- MMCM parameters (per SLAC SURF PGP3 proven values):
    --   VCO = 322.27 * 3 = 966.8 MHz (within MMCM range 600-1200 MHz)
    --   CLKOUT0 = VCO / 3 = 322.27 MHz (TXUSRCLK)
    --   CLKOUT1 = VCO / 6 = 161.13 MHz (TXUSRCLK2)
    ----------------------------------------------------------------------------

    -- Buffer TXOUTCLK to global clock network (allows MMCM placement flexibility)
    tx_outclk_bufg_inst : BUFG
        port map (I => tx_outclk, O => tx_outclk_bufg);

    tx_mmcm_inst : MMCME2_BASE
        generic map (
            BANDWIDTH          => "OPTIMIZED",
            CLKIN1_PERIOD      => 3.103,      -- 322.27 MHz input
            DIVCLK_DIVIDE      => 1,
            CLKFBOUT_MULT_F    => 3.0,        -- VCO = 322.27 * 3 = 966.8 MHz
            CLKOUT0_DIVIDE_F   => 3.0,        -- 966.8 / 3 = 322.27 MHz
            CLKOUT1_DIVIDE     => 6           -- 966.8 / 6 = 161.13 MHz
        )
        port map (
            CLKIN1   => tx_outclk_bufg,       -- Driven from BUFG (not directly from GT)
            RST      => not qpll_lock_int,    -- Hold in reset until QPLL locked
            CLKFBOUT => tx_mmcm_clkfb,
            CLKFBIN  => tx_mmcm_clkfb,
            CLKOUT0  => tx_mmcm_clk0,         -- 322.27 MHz (unbuffered)
            CLKOUT1  => tx_mmcm_clk1,         -- 161.13 MHz (unbuffered)
            CLKOUT2  => open,
            CLKOUT3  => open,
            CLKOUT4  => open,
            CLKOUT5  => open,
            CLKOUT0B => open,
            CLKOUT1B => open,
            CLKOUT2B => open,
            CLKOUT3B => open,
            CLKFBOUTB => open,
            LOCKED   => tx_mmcm_locked,
            PWRDWN   => '0'
        );

    -- Buffer MMCM outputs (phase-aligned by construction)
    tx_usrclk_bufg : BUFG
        port map (I => tx_mmcm_clk0, O => tx_usrclk);   -- 322.27 MHz
    tx_usrclk2_bufg : BUFG
        port map (I => tx_mmcm_clk1, O => tx_usrclk2);  -- 161.13 MHz

    ----------------------------------------------------------------------------
    -- RX Clock Generation
    --
    -- Share TX MMCM clocks for RX path. Both TX and RX use same QPLL so
    -- TXOUTCLK and RXOUTCLK are the same frequency (322.27 MHz).
    -- The GTX internal elastic buffer (RXBUF) handles the phase difference
    -- between CDR-recovered clock and RXUSRCLK.
    --
    -- This avoids the placement constraint: each clock region only has one
    -- MMCM site, so the GT channel can only drive one MMCM.
    ----------------------------------------------------------------------------
    rx_usrclk  <= tx_usrclk;    -- 322.27 MHz (shared with TX)
    rx_usrclk2 <= tx_usrclk2;   -- 161.13 MHz (shared with TX)

    ----------------------------------------------------------------------------
    -- Output Clock Assignment
    ----------------------------------------------------------------------------
    tx_clk <= tx_usrclk2;
    rx_clk <= rx_usrclk2;

    ----------------------------------------------------------------------------
    -- TX Data Path - User-driven TXSEQUENCE mode (GEARBOX_MODE = "001")
    --
    -- Per Forencich verilog-ethernet reference and UG476:
    -- - TXSEQUENCE[6:0] counts 0 to 32 (33 values for 64B/66B)
    -- - The gearbox uses this counter to serialize 66-bit blocks
    -- - TXSTARTSEQ is unused in mode "001" (tied low)
    -- - Data and header must be stable on TXDATA/TXHEADER
    -- - TXGEARBOXREADY pulses when gearbox latches new data (informational)
    ----------------------------------------------------------------------------

    -- TXSEQUENCE counter: free-running 0 -> 32 -> 0 cycle
    -- Gearbox uses this to know which portion of the 66-bit block to serialize
    process(tx_usrclk2)
    begin
        if rising_edge(tx_usrclk2) then
            if reset_combined = '1' or tx_mmcm_locked = '0' then
                tx_gearbox_seq <= (others => '0');
            else
                if tx_gearbox_seq = 32 then
                    tx_gearbox_seq <= (others => '0');
                else
                    tx_gearbox_seq <= tx_gearbox_seq + 1;
                end if;
            end if;
        end if;
    end process;

    -- TX data/header presented continuously
    txdata_int <= tx_data;
    txheader_int <= '0' & tx_header;
    txsequence_int <= std_logic_vector(tx_gearbox_seq);  -- Drive gearbox counter
    tx_startseq_int <= '0';  -- Unused in GEARBOX_MODE="001"
    tx_sequence <= std_logic_vector(tx_gearbox_seq);  -- Debug visibility

    ----------------------------------------------------------------------------
    -- RX Data Path (64-bit native - direct from GTX)
    -- GTX provides 64-bit data with 64B/66B decoding when RXGEARBOX_EN is TRUE
    -- RXSTARTOFSEQ indicates when gearbox sequence counter is at 0 (block boundary)
    -- This can help with alignment debugging
    ----------------------------------------------------------------------------
    process(rx_usrclk2)
    begin
        if rising_edge(rx_usrclk2) then
            if reset_combined = '1' then
                rx_data <= (others => '0');
                rx_header <= "00";
                rx_header_valid <= '0';
                rx_datavalid <= '0';
            else
                -- Direct 64-bit data path from GTX
                rx_data <= rxdata_int;
                -- Extract 2-bit sync header (ignore MSB padding)
                rx_header <= rxheader_int(1 downto 0);
                -- Valid signals from GTX (single bit)
                rx_header_valid <= rxheadervalid_int;
                rx_datavalid <= rxdatavalid_int;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Status Synchronization and Output
    ----------------------------------------------------------------------------
    -- Note: qpll_reset is now handled by the sequencer above (qpll_reset_pulse)
    qpll_lock <= qpll_lock_int;
    qpll_refclk_lost <= qpll_refclklost_int;

    -- Synchronize reset done signals to drp_clk domain (always running)
    -- This avoids dependency on user clocks which may not be valid during reset
    process(drp_clk)
    begin
        if rising_edge(drp_clk) then
            tx_resetdone_sync <= tx_resetdone_sync(1 downto 0) & tx_resetdone_int;
            rx_resetdone_sync <= rx_resetdone_sync(1 downto 0) & rx_resetdone_int;
        end if;
    end process;
    
    -- Note: RXSTARTOFSEQ and TXGEARBOXREADY are passed directly to debug outputs
    -- The debug reporter (running on sys_clk) will handle CDC synchronization
    -- This matches how other GTX signals (rx_cdrlock, rx_elecidle) are handled

    tx_resetdone <= tx_resetdone_sync(2);
    rx_resetdone <= rx_resetdone_sync(2);
    phy_ready <= tx_resetdone_sync(2) and rx_resetdone_sync(2) and tx_mmcm_locked;

    -- Debug outputs for UART diagnostics
    debug_por_done    <= por_done;
    debug_qpll_reset  <= qpll_reset_pulse;
    debug_gtx_reset   <= gtx_reset_int;
    debug_tx_userrdy  <= tx_userrdy_int;
    debug_rx_userrdy  <= rx_userrdy_int;
    debug_refclk_present <= refclk_heartbeat;  -- Blinks if IBUFDS_GTE2 is outputting clock
    debug_rx_cdrlock  <= rxcdrlock_int;
    debug_rx_elecidle <= rxelecidle_int;
    debug_rx_startofseq <= rx_startofseq_int;  -- RXSTARTOFSEQ - debug reporter handles CDC
    debug_tx_gearbox_ready <= tx_gearbox_ready_int;  -- TXGEARBOXREADY - debug reporter handles CDC

end rtl;
