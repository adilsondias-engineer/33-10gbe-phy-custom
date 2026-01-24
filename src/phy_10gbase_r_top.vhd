--------------------------------------------------------------------------------
-- 10GBASE-R PHY Top Level
--
-- Complete 10 Gigabit Ethernet PHY with:
--   - GTX transceiver for 10.3125 Gbps serial interface
--   - PCS layer with 64B/66B encoding and scrambling
--   - XGMII interface for MAC connection
--
-- Architecture:
--   ┌────────────────────────────────────────────────────────────┐
--   │                    PHY_10GBASE_R_TOP                       │
--   │  ┌──────────┐    ┌──────────┐    ┌──────────┐             │
--   │  │   XGMII  │◄──►│   PCS    │◄──►│   GTX    │◄──► SFP+    │
--   │  │Interface │    │ 64B/66B  │    │ 10.3Gbps │             │
--   │  └──────────┘    └──────────┘    └──────────┘             │
--   └────────────────────────────────────────────────────────────┘
--
-- Clocking:
--   - refclk: 156.25 MHz differential (from SFP+ module or board)
--   - xgmii_clk: 156.25 MHz (generated, output to MAC)
--
-- Reset Sequence:
--   1. Assert phy_reset
--   2. Wait for qpll_lock
--   3. Wait for tx_resetdone and rx_resetdone
--   4. Wait for block_lock
--   5. phy_ready goes high
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

entity phy_10gbase_r_top is
    generic (
        -- Simulation mode (faster reset)
        SIM_MODE        : boolean := false
    );
    port (
        -- Reference Clock (156.25 MHz differential)
        refclk_p        : in  std_logic;
        refclk_n        : in  std_logic;

        -- System Reset (active high, asynchronous)
        phy_reset       : in  std_logic;

        -- SFP+ Serial Interface
        sfp_txp         : out std_logic;
        sfp_txn         : out std_logic;
        sfp_rxp         : in  std_logic;
        sfp_rxn         : in  std_logic;

        -- SFP+ Control
        sfp_tx_disable  : out std_logic;    -- Active high to disable TX

        -- XGMII TX Interface (from MAC)
        xgmii_clk       : out std_logic;    -- 156.25 MHz to MAC
        xgmii_txd       : in  std_logic_vector(63 downto 0);
        xgmii_txc       : in  std_logic_vector(7 downto 0);

        -- XGMII RX Interface (to MAC)
        xgmii_rxd       : out std_logic_vector(63 downto 0);
        xgmii_rxc       : out std_logic_vector(7 downto 0);
        xgmii_rx_valid  : out std_logic;

        -- Status
        phy_ready       : out std_logic;    -- PHY fully operational
        qpll_lock       : out std_logic;    -- QPLL locked
        block_lock      : out std_logic;    -- 64B/66B block lock
        rx_sync         : out std_logic;    -- Descrambler synchronized

        -- Error Status
        tx_error        : out std_logic;
        rx_error        : out std_logic;

        -- Debug (active high LEDs suggested)
        debug_led       : out std_logic_vector(3 downto 0)
    );
end phy_10gbase_r_top;

architecture rtl of phy_10gbase_r_top is

    -- Internal clocks
    signal tx_clk           : std_logic;
    signal rx_clk           : std_logic;
    signal clk_156          : std_logic;    -- Common 156.25 MHz clock

    -- GTX signals
    signal gtx_tx_data      : std_logic_vector(63 downto 0);
    signal gtx_tx_header    : std_logic_vector(1 downto 0);
    signal gtx_tx_valid     : std_logic;  -- TX data valid for TXSTARTSEQ control
    signal gtx_tx_sequence   : std_logic_vector(6 downto 0);
    signal gtx_rx_data      : std_logic_vector(63 downto 0);
    signal gtx_rx_header    : std_logic_vector(1 downto 0);
    signal gtx_rx_header_valid : std_logic;
    signal gtx_rx_datavalid : std_logic;
    signal gtx_rx_slip      : std_logic;

    -- GTX status
    signal qpll_lock_int    : std_logic;
    signal tx_resetdone     : std_logic;
    signal rx_resetdone     : std_logic;
    signal gtx_ready        : std_logic;

    -- PCS status
    signal pcs_block_lock   : std_logic;
    signal pcs_rx_sync      : std_logic;
    signal pcs_tx_error     : std_logic;
    signal pcs_rx_error     : std_logic;

    -- Debug signals
    signal debug_tx_enc_error  : std_logic;
    signal debug_rx_dec_error  : std_logic;
    signal debug_header_errors : std_logic_vector(7 downto 0);
    signal debug_block_state   : std_logic_vector(2 downto 0);

    -- Reset synchronization
    signal reset_sync       : std_logic_vector(2 downto 0) := (others => '1');
    signal reset_int        : std_logic;

    -- Component: GTX Wrapper
    component gtx_10g_wrapper is
        generic (
            SIM_MODE            : boolean := false;
            GTX_CHANNEL         : integer := 0
        );
        port (
            refclk_p            : in  std_logic;
            refclk_n            : in  std_logic;
            sys_reset           : in  std_logic;
            gtx_txp             : out std_logic;
            gtx_txn             : out std_logic;
            gtx_rxp             : in  std_logic;
            gtx_rxn             : in  std_logic;
            tx_clk              : out std_logic;
            tx_data             : in  std_logic_vector(63 downto 0);
            tx_header           : in  std_logic_vector(1 downto 0);
            tx_valid            : in  std_logic;        -- TX data valid (pulse TXSTARTSEQ when valid)
            tx_sequence         : out std_logic_vector(6 downto 0);
            rx_clk              : out std_logic;
            rx_data             : out std_logic_vector(63 downto 0);
            rx_header           : out std_logic_vector(1 downto 0);
            rx_header_valid     : out std_logic;
            rx_datavalid        : out std_logic;
            rx_gearbox_slip     : in  std_logic;
            qpll_lock           : out std_logic;
            tx_resetdone        : out std_logic;
            rx_resetdone        : out std_logic;
            phy_ready           : out std_logic
        );
    end component;

    -- Component: PCS
    component pcs_10gbase_r is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            xgmii_txd       : in  std_logic_vector(63 downto 0);
            xgmii_txc       : in  std_logic_vector(7 downto 0);
            xgmii_rxd       : out std_logic_vector(63 downto 0);
            xgmii_rxc       : out std_logic_vector(7 downto 0);
            xgmii_rx_valid  : out std_logic;
            gtx_tx_data     : out std_logic_vector(63 downto 0);
            gtx_tx_header   : out std_logic_vector(1 downto 0);
            gtx_tx_valid    : out std_logic;
            gtx_rx_data     : in  std_logic_vector(63 downto 0);
            gtx_rx_header   : in  std_logic_vector(1 downto 0);
            gtx_rx_valid    : in  std_logic;
            gtx_rx_header_valid : in  std_logic;
            gtx_rx_slip     : out std_logic;
            pcs_block_lock  : out std_logic;
            pcs_rx_sync     : out std_logic;
            pcs_tx_error    : out std_logic;
            pcs_rx_error    : out std_logic;
            debug_tx_enc_error  : out std_logic;
            debug_rx_dec_error  : out std_logic;
            debug_header_errors : out std_logic_vector(7 downto 0);
            debug_block_state   : out std_logic_vector(2 downto 0)
        );
    end component;

begin

    ----------------------------------------------------------------------------
    -- Reset Synchronization
    ----------------------------------------------------------------------------
    process(tx_clk, phy_reset)
    begin
        if phy_reset = '1' then
            reset_sync <= (others => '1');
        elsif rising_edge(tx_clk) then
            reset_sync <= reset_sync(1 downto 0) & '0';
        end if;
    end process;
    reset_int <= reset_sync(2);

    ----------------------------------------------------------------------------
    -- GTX Transceiver
    ----------------------------------------------------------------------------
    gtx_inst : gtx_10g_wrapper
        generic map (
            SIM_MODE        => SIM_MODE,
            GTX_CHANNEL     => 0
        )
        port map (
            refclk_p        => refclk_p,
            refclk_n        => refclk_n,
            sys_reset       => phy_reset,
            gtx_txp         => sfp_txp,
            gtx_txn         => sfp_txn,
            gtx_rxp         => sfp_rxp,
            gtx_rxn         => sfp_rxn,
            tx_clk          => tx_clk,
            tx_data         => gtx_tx_data,
            tx_header       => gtx_tx_header,
            tx_valid        => gtx_tx_valid,  -- CRITICAL: Pass valid signal for TXSTARTSEQ control
            tx_sequence     => gtx_tx_sequence,
            rx_clk          => rx_clk,
            rx_data         => gtx_rx_data,
            rx_header       => gtx_rx_header,
            rx_header_valid => gtx_rx_header_valid,
            rx_datavalid    => gtx_rx_datavalid,
            rx_gearbox_slip => gtx_rx_slip,
            qpll_lock       => qpll_lock_int,
            tx_resetdone    => tx_resetdone,
            rx_resetdone    => rx_resetdone,
            phy_ready       => gtx_ready
        );

    -- Use TX clock as common clock (TX and RX clocks are same frequency)
    clk_156 <= tx_clk;

    ----------------------------------------------------------------------------
    -- PCS Layer
    ----------------------------------------------------------------------------
    pcs_inst : pcs_10gbase_r
        port map (
            clk             => clk_156,
            reset           => reset_int or not gtx_ready,
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,
            xgmii_rxd       => xgmii_rxd,
            xgmii_rxc       => xgmii_rxc,
            xgmii_rx_valid  => xgmii_rx_valid,
            gtx_tx_data     => gtx_tx_data,
            gtx_tx_header   => gtx_tx_header,
            gtx_tx_valid    => gtx_tx_valid,  -- Pass to GTX wrapper for TXSTARTSEQ control
            gtx_rx_data     => gtx_rx_data,
            gtx_rx_header   => gtx_rx_header,
            gtx_rx_valid    => gtx_rx_datavalid,
            gtx_rx_header_valid => gtx_rx_header_valid,
            gtx_rx_slip     => gtx_rx_slip,
            pcs_block_lock  => pcs_block_lock,
            pcs_rx_sync     => pcs_rx_sync,
            pcs_tx_error    => pcs_tx_error,
            pcs_rx_error    => pcs_rx_error,
            debug_tx_enc_error  => debug_tx_enc_error,
            debug_rx_dec_error  => debug_rx_dec_error,
            debug_header_errors => debug_header_errors,
            debug_block_state   => debug_block_state
        );

    ----------------------------------------------------------------------------
    -- Output Assignments
    ----------------------------------------------------------------------------

    -- Clock output to MAC
    xgmii_clk <= clk_156;

    -- SFP+ control
    sfp_tx_disable <= phy_reset;  -- Disable TX during reset

    -- Status outputs
    qpll_lock <= qpll_lock_int;
    block_lock <= pcs_block_lock;
    rx_sync <= pcs_rx_sync;
    phy_ready <= gtx_ready and pcs_block_lock;

    -- Error outputs
    tx_error <= pcs_tx_error;
    rx_error <= pcs_rx_error;

    -- Debug LEDs
    debug_led(0) <= qpll_lock_int;      -- QPLL locked
    debug_led(1) <= gtx_ready;          -- GTX ready
    debug_led(2) <= pcs_block_lock;     -- Block lock
    debug_led(3) <= pcs_rx_sync;        -- RX synchronized

end rtl;
