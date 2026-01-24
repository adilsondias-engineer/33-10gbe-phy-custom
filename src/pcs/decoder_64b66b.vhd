--------------------------------------------------------------------------------
-- 64B/66B Decoder for 10GBASE-R PCS
--
-- Converts 66-bit encoded blocks back to XGMII 64-bit data + 8-bit control.
--
-- Block Types Decoded:
--   Data block (01):     D0-D7 (all data)
--   Control block (10):  Based on type field, extract data/control mix
--
-- Control Character Decoding:
--   7-bit encoded -> 8-bit XGMII control character
--
-- Error Handling:
--   - Invalid sync header (00, 11) -> output error characters
--   - Unknown block type -> output error characters
--   - Invalid control codes -> output error characters
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

entity decoder_64b66b is
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Input (from descrambler)
        rx_header       : in  std_logic_vector(1 downto 0);
        rx_data         : in  std_logic_vector(63 downto 0);
        rx_valid        : in  std_logic;

        -- XGMII RX interface (to MAC)
        xgmii_rxd       : out std_logic_vector(63 downto 0);
        xgmii_rxc       : out std_logic_vector(7 downto 0);

        -- Status
        rx_data_valid   : out std_logic;
        decode_error    : out std_logic
    );
end decoder_64b66b;

architecture rtl of decoder_64b66b is

    -- XGMII control characters
    constant XGMII_IDLE     : std_logic_vector(7 downto 0) := x"07";
    constant XGMII_START    : std_logic_vector(7 downto 0) := x"FB";
    constant XGMII_TERM     : std_logic_vector(7 downto 0) := x"FD";
    constant XGMII_ERROR    : std_logic_vector(7 downto 0) := x"FE";
    constant XGMII_SEQ      : std_logic_vector(7 downto 0) := x"9C";
    constant XGMII_SIG      : std_logic_vector(7 downto 0) := x"5C";

    -- 64B/66B sync headers
    constant SYNC_DATA      : std_logic_vector(1 downto 0) := "01";
    constant SYNC_CTRL      : std_logic_vector(1 downto 0) := "10";

    -- Block type field values
    constant BTYPE_C8       : std_logic_vector(7 downto 0) := x"1E";
    constant BTYPE_S0       : std_logic_vector(7 downto 0) := x"78";
    constant BTYPE_S4       : std_logic_vector(7 downto 0) := x"33";
    constant BTYPE_T0       : std_logic_vector(7 downto 0) := x"87";
    constant BTYPE_T1       : std_logic_vector(7 downto 0) := x"99";
    constant BTYPE_T2       : std_logic_vector(7 downto 0) := x"AA";
    constant BTYPE_T3       : std_logic_vector(7 downto 0) := x"B4";
    constant BTYPE_T4       : std_logic_vector(7 downto 0) := x"CC";
    constant BTYPE_T5       : std_logic_vector(7 downto 0) := x"D2";
    constant BTYPE_T6       : std_logic_vector(7 downto 0) := x"E1";
    constant BTYPE_T7       : std_logic_vector(7 downto 0) := x"FF";

    -- Encoded control character values (7-bit)
    constant ENC_IDLE       : std_logic_vector(6 downto 0) := "0000000";
    constant ENC_ERROR      : std_logic_vector(6 downto 0) := "0011110";
    constant ENC_LPI        : std_logic_vector(6 downto 0) := "0000110";

    -- Output registers
    signal rxd_reg          : std_logic_vector(63 downto 0);
    signal rxc_reg          : std_logic_vector(7 downto 0);
    signal valid_reg        : std_logic;
    signal error_reg        : std_logic;

    -- Block type field
    signal block_type       : std_logic_vector(7 downto 0);

    -- Helper function: decode 7-bit control to 8-bit XGMII
    function decode_ctrl(enc_char : std_logic_vector(6 downto 0))
        return std_logic_vector is
    begin
        case enc_char is
            when ENC_IDLE   => return XGMII_IDLE;
            when ENC_ERROR  => return XGMII_ERROR;
            when ENC_LPI    => return XGMII_IDLE;  -- Treat LPI as idle
            when "0101101"  => return XGMII_SEQ;   -- /Q/
            when "0110011"  => return XGMII_SIG;   -- /Fsig/
            when others     => return XGMII_ERROR; -- Unknown -> error
        end case;
    end function;

begin

    -- Extract block type field
    block_type <= rx_data(7 downto 0);

    ----------------------------------------------------------------------------
    -- Main Decoding Process
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                rxd_reg <= (others => '0');
                rxc_reg <= (others => '0');
                valid_reg <= '0';
                error_reg <= '0';
            elsif rx_valid = '1' then
                valid_reg <= '1';
                error_reg <= '0';

                case rx_header is
                    when SYNC_DATA =>
                        --------------------------------------------------------
                        -- Data Block: All 8 bytes are data
                        --------------------------------------------------------
                        rxd_reg <= rx_data;
                        rxc_reg <= "00000000";

                    when SYNC_CTRL =>
                        --------------------------------------------------------
                        -- Control Block: Decode based on type field
                        --------------------------------------------------------
                        case block_type is
                            when BTYPE_C8 =>
                                -- All control: C0-C7
                                rxd_reg(7 downto 0)   <= decode_ctrl(rx_data(14 downto 8));
                                rxd_reg(15 downto 8)  <= decode_ctrl(rx_data(21 downto 15));
                                rxd_reg(23 downto 16) <= decode_ctrl(rx_data(28 downto 22));
                                rxd_reg(31 downto 24) <= decode_ctrl(rx_data(35 downto 29));
                                rxd_reg(39 downto 32) <= decode_ctrl(rx_data(42 downto 36));
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(49 downto 43));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(56 downto 50));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(63 downto 57));
                                rxc_reg <= "11111111";

                            when BTYPE_S0 =>
                                -- Start in lane 0: S,D1-D7
                                rxd_reg(7 downto 0)   <= XGMII_START;
                                rxd_reg(15 downto 8)  <= rx_data(15 downto 8);
                                rxd_reg(23 downto 16) <= rx_data(23 downto 16);
                                rxd_reg(31 downto 24) <= rx_data(31 downto 24);
                                rxd_reg(39 downto 32) <= rx_data(39 downto 32);
                                rxd_reg(47 downto 40) <= rx_data(47 downto 40);
                                rxd_reg(55 downto 48) <= rx_data(55 downto 48);
                                rxd_reg(63 downto 56) <= rx_data(63 downto 56);
                                rxc_reg <= "00000001";  -- Only lane 0 is control

                            when BTYPE_S4 =>
                                -- Start in lane 4: C0-C3,S,D5-D7
                                rxd_reg(7 downto 0)   <= decode_ctrl(rx_data(14 downto 8));
                                rxd_reg(15 downto 8)  <= decode_ctrl(rx_data(21 downto 15));
                                rxd_reg(23 downto 16) <= decode_ctrl(rx_data(28 downto 22));
                                rxd_reg(31 downto 24) <= decode_ctrl(rx_data(35 downto 29));
                                rxd_reg(39 downto 32) <= XGMII_START;
                                rxd_reg(47 downto 40) <= rx_data(43 downto 36);
                                rxd_reg(55 downto 48) <= rx_data(51 downto 44);
                                rxd_reg(63 downto 56) <= rx_data(59 downto 52);
                                rxc_reg <= "00011111";  -- Lanes 0-4 are control

                            when BTYPE_T0 =>
                                -- Terminate lane 0: T,C1-C7
                                rxd_reg(7 downto 0)   <= XGMII_TERM;
                                rxd_reg(15 downto 8)  <= decode_ctrl(rx_data(14 downto 8));
                                rxd_reg(23 downto 16) <= decode_ctrl(rx_data(21 downto 15));
                                rxd_reg(31 downto 24) <= decode_ctrl(rx_data(28 downto 22));
                                rxd_reg(39 downto 32) <= decode_ctrl(rx_data(35 downto 29));
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(42 downto 36));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(49 downto 43));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(56 downto 50));
                                rxc_reg <= "11111111";

                            when BTYPE_T1 =>
                                -- D0,T,C2-C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= XGMII_TERM;
                                rxd_reg(23 downto 16) <= decode_ctrl(rx_data(22 downto 16));
                                rxd_reg(31 downto 24) <= decode_ctrl(rx_data(29 downto 23));
                                rxd_reg(39 downto 32) <= decode_ctrl(rx_data(36 downto 30));
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(43 downto 37));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(50 downto 44));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(57 downto 51));
                                rxc_reg <= "11111110";

                            when BTYPE_T2 =>
                                -- D0D1,T,C3-C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= XGMII_TERM;
                                rxd_reg(31 downto 24) <= decode_ctrl(rx_data(30 downto 24));
                                rxd_reg(39 downto 32) <= decode_ctrl(rx_data(37 downto 31));
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(44 downto 38));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(51 downto 45));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(58 downto 52));
                                rxc_reg <= "11111100";

                            when BTYPE_T3 =>
                                -- D0D1D2,T,C4-C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= rx_data(31 downto 24);
                                rxd_reg(31 downto 24) <= XGMII_TERM;
                                rxd_reg(39 downto 32) <= decode_ctrl(rx_data(38 downto 32));
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(45 downto 39));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(52 downto 46));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(59 downto 53));
                                rxc_reg <= "11111000";

                            when BTYPE_T4 =>
                                -- D0D1D2D3,T,C5-C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= rx_data(31 downto 24);
                                rxd_reg(31 downto 24) <= rx_data(39 downto 32);
                                rxd_reg(39 downto 32) <= XGMII_TERM;
                                rxd_reg(47 downto 40) <= decode_ctrl(rx_data(46 downto 40));
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(53 downto 47));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(60 downto 54));
                                rxc_reg <= "11110000";

                            when BTYPE_T5 =>
                                -- D0D1D2D3D4,T,C6C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= rx_data(31 downto 24);
                                rxd_reg(31 downto 24) <= rx_data(39 downto 32);
                                rxd_reg(39 downto 32) <= rx_data(47 downto 40);
                                rxd_reg(47 downto 40) <= XGMII_TERM;
                                rxd_reg(55 downto 48) <= decode_ctrl(rx_data(54 downto 48));
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(61 downto 55));
                                rxc_reg <= "11100000";

                            when BTYPE_T6 =>
                                -- D0D1D2D3D4D5,T,C7
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= rx_data(31 downto 24);
                                rxd_reg(31 downto 24) <= rx_data(39 downto 32);
                                rxd_reg(39 downto 32) <= rx_data(47 downto 40);
                                rxd_reg(47 downto 40) <= rx_data(55 downto 48);
                                rxd_reg(55 downto 48) <= XGMII_TERM;
                                rxd_reg(63 downto 56) <= decode_ctrl(rx_data(62 downto 56));
                                rxc_reg <= "11000000";

                            when BTYPE_T7 =>
                                -- D0D1D2D3D4D5D6,T
                                rxd_reg(7 downto 0)   <= rx_data(15 downto 8);
                                rxd_reg(15 downto 8)  <= rx_data(23 downto 16);
                                rxd_reg(23 downto 16) <= rx_data(31 downto 24);
                                rxd_reg(31 downto 24) <= rx_data(39 downto 32);
                                rxd_reg(39 downto 32) <= rx_data(47 downto 40);
                                rxd_reg(47 downto 40) <= rx_data(55 downto 48);
                                rxd_reg(55 downto 48) <= rx_data(63 downto 56);
                                rxd_reg(63 downto 56) <= XGMII_TERM;
                                rxc_reg <= "10000000";

                            when others =>
                                -- Unknown block type - output errors
                                rxd_reg <= XGMII_ERROR & XGMII_ERROR & XGMII_ERROR & XGMII_ERROR &
                                          XGMII_ERROR & XGMII_ERROR & XGMII_ERROR & XGMII_ERROR;
                                rxc_reg <= "11111111";
                                error_reg <= '1';
                        end case;

                    when others =>
                        --------------------------------------------------------
                        -- Invalid sync header (00 or 11) - output errors
                        --------------------------------------------------------
                        rxd_reg <= XGMII_ERROR & XGMII_ERROR & XGMII_ERROR & XGMII_ERROR &
                                  XGMII_ERROR & XGMII_ERROR & XGMII_ERROR & XGMII_ERROR;
                        rxc_reg <= "11111111";
                        error_reg <= '1';
                end case;
            else
                valid_reg <= '0';
            end if;
        end if;
    end process;

    -- Output assignments
    xgmii_rxd <= rxd_reg;
    xgmii_rxc <= rxc_reg;
    rx_data_valid <= valid_reg;
    decode_error <= error_reg;

end rtl;
