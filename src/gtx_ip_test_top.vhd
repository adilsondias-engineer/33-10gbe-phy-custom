--------------------------------------------------------------------------------
-- Minimal GTX IP Test Top
-- Uses the pre-generated GTX IP directly to verify reference clock path
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Author: Adilson Dias
-- GitHub: https://github.com/adilsondias-engineer/fpga-trading-systems
-- Date: January 2026
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity gtx_ip_test_top is
    port (
        -- System clock (200 MHz differential)
        sys_clk_p       : in  std_logic;
        sys_clk_n       : in  std_logic;

        -- SFP+ reference clock (156.25 MHz differential)
        refclk_p        : in  std_logic;
        refclk_n        : in  std_logic;

        -- SFP+ serial interface
        sfp_txp         : out std_logic;
        sfp_txn         : out std_logic;
        sfp_rxp         : in  std_logic;
        sfp_rxn         : in  std_logic;

        -- SFP+ control
        sfp_tx_disable  : out std_logic;

        -- Reset button
        phy_reset       : in  std_logic;

        -- Debug LEDs
        debug_led       : out std_logic_vector(3 downto 0)
    );
end gtx_ip_test_top;

architecture rtl of gtx_ip_test_top is

    -- System clock
    signal sys_clk          : std_logic;

    -- GTX IP signals
    signal gt0_txusrclk     : std_logic;
    signal gt0_txusrclk2    : std_logic;
    signal gt0_rxusrclk     : std_logic;
    signal gt0_rxusrclk2    : std_logic;
    signal gt0_tx_fsm_reset_done : std_logic;
    signal gt0_rx_fsm_reset_done : std_logic;

    -- TX data (send IDLE pattern)
    signal gt0_txdata       : std_logic_vector(31 downto 0);
    signal gt0_txheader     : std_logic_vector(1 downto 0);

    -- RX data
    signal gt0_rxdata       : std_logic_vector(31 downto 0);
    signal gt0_rxheader     : std_logic_vector(1 downto 0);
    signal gt0_rxheadervalid: std_logic;
    signal gt0_rxdatavalid  : std_logic;

    -- Heartbeat counter
    signal heartbeat_cnt    : unsigned(27 downto 0) := (others => '0');

    -- Component declaration for GTX IP support module
    component gtx_10gbase_r_support is
        generic (
            EXAMPLE_SIM_GTRESET_SPEEDUP : string := "TRUE";
            STABLE_CLOCK_PERIOD         : integer := 6
        );
        port (
            SOFT_RESET_TX_IN                : in  std_logic;
            SOFT_RESET_RX_IN                : in  std_logic;
            DONT_RESET_ON_DATA_ERROR_IN     : in  std_logic;
            Q2_CLK1_GTREFCLK_PAD_N_IN       : in  std_logic;
            Q2_CLK1_GTREFCLK_PAD_P_IN       : in  std_logic;
            GT0_TX_FSM_RESET_DONE_OUT       : out std_logic;
            GT0_RX_FSM_RESET_DONE_OUT       : out std_logic;
            GT0_DATA_VALID_IN               : in  std_logic;
            GT0_TXUSRCLK_OUT                : out std_logic;
            GT0_TXUSRCLK2_OUT               : out std_logic;
            GT0_RXUSRCLK_OUT                : out std_logic;
            GT0_RXUSRCLK2_OUT               : out std_logic;
            gt0_drpaddr_in                  : in  std_logic_vector(8 downto 0);
            gt0_drpdi_in                    : in  std_logic_vector(15 downto 0);
            gt0_drpdo_out                   : out std_logic_vector(15 downto 0);
            gt0_drpen_in                    : in  std_logic;
            gt0_drprdy_out                  : out std_logic;
            gt0_drpwe_in                    : in  std_logic;
            gt0_dmonitorout_out             : out std_logic_vector(7 downto 0);
            gt0_rxrate_in                   : in  std_logic_vector(2 downto 0);
            gt0_eyescanreset_in             : in  std_logic;
            gt0_rxuserrdy_in                : in  std_logic;
            gt0_eyescandataerror_out        : out std_logic;
            gt0_eyescantrigger_in           : in  std_logic;
            gt0_rxcdrhold_in                : in  std_logic;
            gt0_rxdata_out                  : out std_logic_vector(31 downto 0);
            gt0_gtxrxp_in                   : in  std_logic;
            gt0_gtxrxn_in                   : in  std_logic;
            gt0_rxbufreset_in               : in  std_logic;
            gt0_rxbufstatus_out             : out std_logic_vector(2 downto 0);
            gt0_rxdfelpmreset_in            : in  std_logic;
            gt0_rxmonitorout_out            : out std_logic_vector(6 downto 0);
            gt0_rxmonitorsel_in             : in  std_logic_vector(1 downto 0);
            gt0_rxratedone_out              : out std_logic;
            gt0_rxoutclkfabric_out          : out std_logic;
            gt0_rxdatavalid_out             : out std_logic;
            gt0_rxheader_out                : out std_logic_vector(1 downto 0);
            gt0_rxheadervalid_out           : out std_logic;
            gt0_rxgearboxslip_in            : in  std_logic;
            gt0_gtrxreset_in                : in  std_logic;
            gt0_rxpcsreset_in               : in  std_logic;
            gt0_rxpmareset_in               : in  std_logic;
            gt0_rxlpmen_in                  : in  std_logic;
            gt0_rxpolarity_in               : in  std_logic;
            gt0_rxresetdone_out             : out std_logic;
            gt0_txdata_in                   : in  std_logic_vector(31 downto 0);
            gt0_gtxtxn_out                  : out std_logic;
            gt0_gtxtxp_out                  : out std_logic;
            gt0_txbufstatus_out             : out std_logic_vector(1 downto 0);
            gt0_txheader_in                 : in  std_logic_vector(1 downto 0);
            gt0_txsequence_in               : in  std_logic_vector(6 downto 0);
            gt0_gttxreset_in                : in  std_logic;
            gt0_txpcsreset_in               : in  std_logic;
            gt0_txpmareset_in               : in  std_logic;
            gt0_txpolarity_in               : in  std_logic;
            gt0_txresetdone_out             : out std_logic;
            GT0_QPLLLOCK_OUT                : out std_logic;
            GT0_QPLLREFCLKLOST_OUT          : out std_logic;
            GT0_QPLLOUTCLK_OUT              : out std_logic;
            GT0_QPLLOUTREFCLK_OUT           : out std_logic;
            sysclk_in                       : in  std_logic
        );
    end component;

    signal qpll_lock        : std_logic;
    signal qpll_refclklost  : std_logic;
    signal tx_resetdone     : std_logic;
    signal rx_resetdone     : std_logic;

begin

    -- System clock buffer
    sys_clk_ibufds : IBUFDS
        generic map (
            DIFF_TERM => FALSE,
            IBUF_LOW_PWR => FALSE
        )
        port map (
            I  => sys_clk_p,
            IB => sys_clk_n,
            O  => sys_clk
        );

    -- Heartbeat on sys_clk (200 MHz / 2^28 = ~0.75 Hz)
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            heartbeat_cnt <= heartbeat_cnt + 1;
        end if;
    end process;

    -- Instantiate GTX IP
    gtx_ip_inst : gtx_10gbase_r_support
        generic map (
            EXAMPLE_SIM_GTRESET_SPEEDUP => "TRUE",
            STABLE_CLOCK_PERIOD         => 5  -- 200 MHz = 5ns
        )
        port map (
            SOFT_RESET_TX_IN            => phy_reset,
            SOFT_RESET_RX_IN            => phy_reset,
            DONT_RESET_ON_DATA_ERROR_IN => '1',
            Q2_CLK1_GTREFCLK_PAD_N_IN   => refclk_n,
            Q2_CLK1_GTREFCLK_PAD_P_IN   => refclk_p,
            GT0_TX_FSM_RESET_DONE_OUT   => gt0_tx_fsm_reset_done,
            GT0_RX_FSM_RESET_DONE_OUT   => gt0_rx_fsm_reset_done,
            GT0_DATA_VALID_IN           => '1',
            GT0_TXUSRCLK_OUT            => gt0_txusrclk,
            GT0_TXUSRCLK2_OUT           => gt0_txusrclk2,
            GT0_RXUSRCLK_OUT            => gt0_rxusrclk,
            GT0_RXUSRCLK2_OUT           => gt0_rxusrclk2,
            -- DRP (unused)
            gt0_drpaddr_in              => (others => '0'),
            gt0_drpdi_in                => (others => '0'),
            gt0_drpdo_out               => open,
            gt0_drpen_in                => '0',
            gt0_drprdy_out              => open,
            gt0_drpwe_in                => '0',
            gt0_dmonitorout_out         => open,
            gt0_rxrate_in               => "000",
            gt0_eyescanreset_in         => '0',
            gt0_rxuserrdy_in            => '1',
            gt0_eyescandataerror_out    => open,
            gt0_eyescantrigger_in       => '0',
            gt0_rxcdrhold_in            => '0',
            -- RX data
            gt0_rxdata_out              => gt0_rxdata,
            gt0_gtxrxp_in               => sfp_rxp,
            gt0_gtxrxn_in               => sfp_rxn,
            gt0_rxbufreset_in           => '0',
            gt0_rxbufstatus_out         => open,
            gt0_rxdfelpmreset_in        => '0',
            gt0_rxmonitorout_out        => open,
            gt0_rxmonitorsel_in         => "00",
            gt0_rxratedone_out          => open,
            gt0_rxoutclkfabric_out      => open,
            gt0_rxdatavalid_out         => gt0_rxdatavalid,
            gt0_rxheader_out            => gt0_rxheader,
            gt0_rxheadervalid_out       => gt0_rxheadervalid,
            gt0_rxgearboxslip_in        => '0',
            gt0_gtrxreset_in            => '0',
            gt0_rxpcsreset_in           => '0',
            gt0_rxpmareset_in           => '0',
            gt0_rxlpmen_in              => '0',
            gt0_rxpolarity_in           => '0',
            gt0_rxresetdone_out         => rx_resetdone,
            -- TX data (IDLE pattern)
            gt0_txdata_in               => x"07070707",  -- IDLE
            gt0_gtxtxn_out              => sfp_txn,
            gt0_gtxtxp_out              => sfp_txp,
            gt0_txbufstatus_out         => open,
            gt0_txheader_in             => "01",  -- Data block
            gt0_txsequence_in           => "0000000",
            gt0_gttxreset_in            => '0',
            gt0_txpcsreset_in           => '0',
            gt0_txpmareset_in           => '0',
            gt0_txpolarity_in           => '0',
            gt0_txresetdone_out         => tx_resetdone,
            -- QPLL status
            GT0_QPLLLOCK_OUT            => qpll_lock,
            GT0_QPLLREFCLKLOST_OUT      => qpll_refclklost,
            GT0_QPLLOUTCLK_OUT          => open,
            GT0_QPLLOUTREFCLK_OUT       => open,
            sysclk_in                   => sys_clk
        );

    -- SFP+ TX enable
    sfp_tx_disable <= phy_reset;

    -- Debug LEDs
    debug_led(0) <= qpll_lock;              -- LED0: QPLL locked
    debug_led(1) <= gt0_tx_fsm_reset_done and gt0_rx_fsm_reset_done;  -- LED1: GTX ready
    debug_led(2) <= qpll_refclklost;        -- LED2: REFCLK LOST
    debug_led(3) <= heartbeat_cnt(27);      -- LED3: sys_clk heartbeat

end rtl;
