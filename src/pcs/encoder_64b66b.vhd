--------------------------------------------------------------------------------
-- 64B/66B Encoder for 10GBASE-R PCS
--
-- Converts XGMII 64-bit data + 8-bit control into 66-bit encoded blocks.
--
-- 64B/66B Encoding:
--   - 2-bit sync header: "01" = data block, "10" = control block
--   - 64-bit payload follows header
--   - Self-synchronizing (unique sync header pattern)
--
-- Block Types (IEEE 802.3 Clause 49):
--   Data block (D):     01 + D0-D7 (all 8 lanes are data)
--   Control blocks (C): 10 + type field + control/data mix
--
-- Control Block Types:
--   0x1E: C0-C7 (all control, idle)
--   0x2D: C0-C3 + D4-D7 (start after idle)
--   0x33: D0-D3 + C4-C7 (terminate)
--   0x66: D0 + C1-C7 (ordered set)
--   0x55: D0-D3 + C4 + D5-D7 (ordered set variant)
--   0x78: S + D1-D7 (start in lane 0)
--   0x87: T + C1-C7 (terminate in lane 0)
--   etc.
--
-- XGMII Special Characters (TXC = 1):
--   0x07 = Idle (/I/)
--   0xFB = Start (/S/)
--   0xFD = Terminate (/T/)
--   0xFE = Error (/E/)
--   0x9C = Sequence ordered set (/Q/)
--   0x5C = Signal ordered set (/Fsig/)
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

entity encoder_64b66b is
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- XGMII TX interface (directly from MAC)
        xgmii_txd       : in  std_logic_vector(63 downto 0);  -- Data lanes 0-7
        xgmii_txc       : in  std_logic_vector(7 downto 0);   -- Control (1=control, 0=data)

        -- Encoded 66-bit block output
        tx_header       : out std_logic_vector(1 downto 0);   -- Sync header
        tx_data         : out std_logic_vector(63 downto 0);  -- Encoded payload

        -- Status
        tx_valid        : out std_logic;                       -- Valid block output
        encode_error    : out std_logic                        -- Encoding error (invalid XGMII)
    );
end encoder_64b66b;

architecture rtl of encoder_64b66b is

    -- XGMII control characters
    constant XGMII_IDLE     : std_logic_vector(7 downto 0) := x"07";
    constant XGMII_START    : std_logic_vector(7 downto 0) := x"FB";
    constant XGMII_TERM     : std_logic_vector(7 downto 0) := x"FD";
    constant XGMII_ERROR    : std_logic_vector(7 downto 0) := x"FE";
    constant XGMII_SEQ      : std_logic_vector(7 downto 0) := x"9C";  -- /Q/ ordered set
    constant XGMII_SIG      : std_logic_vector(7 downto 0) := x"5C";  -- Signal ordered set

    -- 64B/66B sync headers
    constant SYNC_DATA      : std_logic_vector(1 downto 0) := "01";
    constant SYNC_CTRL      : std_logic_vector(1 downto 0) := "10";

    -- 64B/66B block type field (8 bits, positioned at payload[7:0])
    constant BTYPE_C8       : std_logic_vector(7 downto 0) := x"1E";  -- All control (C0-C7)
    constant BTYPE_S0       : std_logic_vector(7 downto 0) := x"78";  -- Start lane 0 (S,D1-D7)
    constant BTYPE_S4       : std_logic_vector(7 downto 0) := x"33";  -- Start lane 4 (C0-C3,S,D5-D7) -- Actually O-code
    constant BTYPE_T0       : std_logic_vector(7 downto 0) := x"87";  -- Terminate lane 0 (T,C1-C7)
    constant BTYPE_T1       : std_logic_vector(7 downto 0) := x"99";  -- Terminate lane 1 (D0,T,C2-C7)
    constant BTYPE_T2       : std_logic_vector(7 downto 0) := x"AA";  -- Terminate lane 2
    constant BTYPE_T3       : std_logic_vector(7 downto 0) := x"B4";  -- Terminate lane 3
    constant BTYPE_T4       : std_logic_vector(7 downto 0) := x"CC";  -- Terminate lane 4
    constant BTYPE_T5       : std_logic_vector(7 downto 0) := x"D2";  -- Terminate lane 5
    constant BTYPE_T6       : std_logic_vector(7 downto 0) := x"E1";  -- Terminate lane 6
    constant BTYPE_T7       : std_logic_vector(7 downto 0) := x"FF";  -- Terminate lane 7 (D0-D6,T)

    -- Encoded control character (7-bit representation)
    constant ENC_IDLE       : std_logic_vector(6 downto 0) := "0000000";  -- /I/ idle
    constant ENC_ERROR      : std_logic_vector(6 downto 0) := "0011110";  -- /E/ error
    constant ENC_LPI        : std_logic_vector(6 downto 0) := "0000110";  -- Low power idle

    -- Extract individual bytes from XGMII
    signal txd0, txd1, txd2, txd3 : std_logic_vector(7 downto 0);
    signal txd4, txd5, txd6, txd7 : std_logic_vector(7 downto 0);
    signal txc0, txc1, txc2, txc3 : std_logic;
    signal txc4, txc5, txc6, txc7 : std_logic;

    -- Encoded output registers
    signal header_reg       : std_logic_vector(1 downto 0);
    signal data_reg         : std_logic_vector(63 downto 0);
    signal valid_reg        : std_logic;
    signal error_reg        : std_logic;

    -- Helper function: encode XGMII control character to 7-bit
    function encode_ctrl(xgmii_char : std_logic_vector(7 downto 0))
        return std_logic_vector is
    begin
        case xgmii_char is
            when XGMII_IDLE  => return ENC_IDLE;
            when XGMII_ERROR => return ENC_ERROR;
            when XGMII_SEQ   => return "0101101";  -- /Q/
            when XGMII_SIG   => return "0110011";  -- /Fsig/
            when others      => return ENC_ERROR;  -- Unknown -> error
        end case;
    end function;

begin

    -- Extract bytes and control bits
    txd0 <= xgmii_txd(7 downto 0);
    txd1 <= xgmii_txd(15 downto 8);
    txd2 <= xgmii_txd(23 downto 16);
    txd3 <= xgmii_txd(31 downto 24);
    txd4 <= xgmii_txd(39 downto 32);
    txd5 <= xgmii_txd(47 downto 40);
    txd6 <= xgmii_txd(55 downto 48);
    txd7 <= xgmii_txd(63 downto 56);

    txc0 <= xgmii_txc(0);
    txc1 <= xgmii_txc(1);
    txc2 <= xgmii_txc(2);
    txc3 <= xgmii_txc(3);
    txc4 <= xgmii_txc(4);
    txc5 <= xgmii_txc(5);
    txc6 <= xgmii_txc(6);
    txc7 <= xgmii_txc(7);

    ----------------------------------------------------------------------------
    -- Main Encoding Process
    ----------------------------------------------------------------------------
    process(clk)
        variable start_lane : integer range 0 to 7;
        variable term_lane  : integer range 0 to 7;
        variable has_start  : boolean;
        variable has_term   : boolean;
        variable all_data   : boolean;
        variable all_ctrl   : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                header_reg <= SYNC_CTRL;
                data_reg <= (others => '0');
                valid_reg <= '0';
                error_reg <= '0';
            else
                valid_reg <= '1';
                error_reg <= '0';

                -- Determine block type
                all_data := (xgmii_txc = "00000000");
                all_ctrl := (xgmii_txc = "11111111");

                -- Check for start character
                has_start := false;
                start_lane := 0;
                if txc0 = '1' and txd0 = XGMII_START then
                    has_start := true;
                    start_lane := 0;
                elsif txc4 = '1' and txd4 = XGMII_START then
                    has_start := true;
                    start_lane := 4;
                end if;

                -- Check for terminate character
                has_term := false;
                term_lane := 0;
                for i in 0 to 7 loop
                    if xgmii_txc(i) = '1' then
                        case i is
                            when 0 => if txd0 = XGMII_TERM then has_term := true; term_lane := 0; end if;
                            when 1 => if txd1 = XGMII_TERM then has_term := true; term_lane := 1; end if;
                            when 2 => if txd2 = XGMII_TERM then has_term := true; term_lane := 2; end if;
                            when 3 => if txd3 = XGMII_TERM then has_term := true; term_lane := 3; end if;
                            when 4 => if txd4 = XGMII_TERM then has_term := true; term_lane := 4; end if;
                            when 5 => if txd5 = XGMII_TERM then has_term := true; term_lane := 5; end if;
                            when 6 => if txd6 = XGMII_TERM then has_term := true; term_lane := 6; end if;
                            when 7 => if txd7 = XGMII_TERM then has_term := true; term_lane := 7; end if;
                            when others => null;
                        end case;
                    end if;
                end loop;

                -- Encode based on block type
                -- Priority: data > start > terminate > all_ctrl
                -- (terminate must be checked before all_ctrl since terminate
                --  frames with trailing idles have all control bits set)
                if all_data then
                    ------------------------------------------------------------
                    -- All Data Block: 01 + D0D1D2D3D4D5D6D7
                    ------------------------------------------------------------
                    header_reg <= SYNC_DATA;
                    data_reg <= xgmii_txd;

                elsif has_start and start_lane = 0 then
                    ------------------------------------------------------------
                    -- Start in Lane 0: 10 + 0x78 + D1D2D3D4D5D6D7
                    -- TXC = 1000_0000 (start) or 0000_0001 (start in lane 0)
                    ------------------------------------------------------------
                    header_reg <= SYNC_CTRL;
                    data_reg(7 downto 0) <= BTYPE_S0;
                    data_reg(15 downto 8)  <= txd1;
                    data_reg(23 downto 16) <= txd2;
                    data_reg(31 downto 24) <= txd3;
                    data_reg(39 downto 32) <= txd4;
                    data_reg(47 downto 40) <= txd5;
                    data_reg(55 downto 48) <= txd6;
                    data_reg(63 downto 56) <= txd7;

                elsif has_start and start_lane = 4 then
                    ------------------------------------------------------------
                    -- Start in Lane 4: 10 + 0x33 + C0C1C2C3 + D5D6D7
                    -- Actually this is ordered set, simplified here
                    ------------------------------------------------------------
                    header_reg <= SYNC_CTRL;
                    data_reg(7 downto 0) <= BTYPE_S4;
                    data_reg(14 downto 8)  <= encode_ctrl(txd0);
                    data_reg(21 downto 15) <= encode_ctrl(txd1);
                    data_reg(28 downto 22) <= encode_ctrl(txd2);
                    data_reg(35 downto 29) <= encode_ctrl(txd3);
                    data_reg(43 downto 36) <= txd5;
                    data_reg(51 downto 44) <= txd6;
                    data_reg(59 downto 52) <= txd7;
                    data_reg(63 downto 60) <= "0000";

                elsif has_term then
                    ------------------------------------------------------------
                    -- Terminate Block: position determines type field
                    ------------------------------------------------------------
                    header_reg <= SYNC_CTRL;

                    case term_lane is
                        when 0 =>
                            -- T in lane 0: 10 + 0x87 + C1C2C3C4C5C6C7
                            data_reg(7 downto 0) <= BTYPE_T0;
                            data_reg(14 downto 8)  <= encode_ctrl(txd1);
                            data_reg(21 downto 15) <= encode_ctrl(txd2);
                            data_reg(28 downto 22) <= encode_ctrl(txd3);
                            data_reg(35 downto 29) <= encode_ctrl(txd4);
                            data_reg(42 downto 36) <= encode_ctrl(txd5);
                            data_reg(49 downto 43) <= encode_ctrl(txd6);
                            data_reg(56 downto 50) <= encode_ctrl(txd7);
                            data_reg(63 downto 57) <= "0000000";

                        when 1 =>
                            -- D0,T in lane 1: 10 + 0x99 + D0 + C2C3C4C5C6C7
                            data_reg(7 downto 0) <= BTYPE_T1;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(22 downto 16) <= encode_ctrl(txd2);
                            data_reg(29 downto 23) <= encode_ctrl(txd3);
                            data_reg(36 downto 30) <= encode_ctrl(txd4);
                            data_reg(43 downto 37) <= encode_ctrl(txd5);
                            data_reg(50 downto 44) <= encode_ctrl(txd6);
                            data_reg(57 downto 51) <= encode_ctrl(txd7);
                            data_reg(63 downto 58) <= "000000";

                        when 2 =>
                            -- D0D1,T: 10 + 0xAA + D0D1 + C3C4C5C6C7
                            data_reg(7 downto 0) <= BTYPE_T2;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(30 downto 24) <= encode_ctrl(txd3);
                            data_reg(37 downto 31) <= encode_ctrl(txd4);
                            data_reg(44 downto 38) <= encode_ctrl(txd5);
                            data_reg(51 downto 45) <= encode_ctrl(txd6);
                            data_reg(58 downto 52) <= encode_ctrl(txd7);
                            data_reg(63 downto 59) <= "00000";

                        when 3 =>
                            -- D0D1D2,T: 10 + 0xB4 + D0D1D2 + C4C5C6C7
                            data_reg(7 downto 0) <= BTYPE_T3;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(31 downto 24) <= txd2;
                            data_reg(38 downto 32) <= encode_ctrl(txd4);
                            data_reg(45 downto 39) <= encode_ctrl(txd5);
                            data_reg(52 downto 46) <= encode_ctrl(txd6);
                            data_reg(59 downto 53) <= encode_ctrl(txd7);
                            data_reg(63 downto 60) <= "0000";

                        when 4 =>
                            -- D0D1D2D3,T: 10 + 0xCC + D0D1D2D3 + C5C6C7
                            data_reg(7 downto 0) <= BTYPE_T4;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(31 downto 24) <= txd2;
                            data_reg(39 downto 32) <= txd3;
                            data_reg(46 downto 40) <= encode_ctrl(txd5);
                            data_reg(53 downto 47) <= encode_ctrl(txd6);
                            data_reg(60 downto 54) <= encode_ctrl(txd7);
                            data_reg(63 downto 61) <= "000";

                        when 5 =>
                            -- D0D1D2D3D4,T: 10 + 0xD2 + D0D1D2D3D4 + C6C7
                            data_reg(7 downto 0) <= BTYPE_T5;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(31 downto 24) <= txd2;
                            data_reg(39 downto 32) <= txd3;
                            data_reg(47 downto 40) <= txd4;
                            data_reg(54 downto 48) <= encode_ctrl(txd6);
                            data_reg(61 downto 55) <= encode_ctrl(txd7);
                            data_reg(63 downto 62) <= "00";

                        when 6 =>
                            -- D0D1D2D3D4D5,T: 10 + 0xE1 + D0D1D2D3D4D5 + C7
                            data_reg(7 downto 0) <= BTYPE_T6;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(31 downto 24) <= txd2;
                            data_reg(39 downto 32) <= txd3;
                            data_reg(47 downto 40) <= txd4;
                            data_reg(55 downto 48) <= txd5;
                            data_reg(62 downto 56) <= encode_ctrl(txd7);
                            data_reg(63) <= '0';

                        when 7 =>
                            -- D0D1D2D3D4D5D6,T: 10 + 0xFF + D0D1D2D3D4D5D6
                            data_reg(7 downto 0) <= BTYPE_T7;
                            data_reg(15 downto 8) <= txd0;
                            data_reg(23 downto 16) <= txd1;
                            data_reg(31 downto 24) <= txd2;
                            data_reg(39 downto 32) <= txd3;
                            data_reg(47 downto 40) <= txd4;
                            data_reg(55 downto 48) <= txd5;
                            data_reg(63 downto 56) <= txd6;

                        when others =>
                            error_reg <= '1';
                    end case;

                elsif all_ctrl then
                    ------------------------------------------------------------
                    -- All Control Block: 10 + 0x1E + C0C1C2C3C4C5C6C7
                    -- Only idle/error characters (no start/terminate)
                    ------------------------------------------------------------
                    header_reg <= SYNC_CTRL;
                    data_reg(7 downto 0) <= BTYPE_C8;
                    data_reg(14 downto 8)  <= encode_ctrl(txd0);
                    data_reg(21 downto 15) <= encode_ctrl(txd1);
                    data_reg(28 downto 22) <= encode_ctrl(txd2);
                    data_reg(35 downto 29) <= encode_ctrl(txd3);
                    data_reg(42 downto 36) <= encode_ctrl(txd4);
                    data_reg(49 downto 43) <= encode_ctrl(txd5);
                    data_reg(56 downto 50) <= encode_ctrl(txd6);
                    data_reg(63 downto 57) <= encode_ctrl(txd7);

                else
                    ------------------------------------------------------------
                    -- Invalid/Unknown pattern - encode as error
                    ------------------------------------------------------------
                    header_reg <= SYNC_CTRL;
                    data_reg(7 downto 0) <= BTYPE_C8;  -- All control
                    data_reg(14 downto 8)  <= ENC_ERROR;
                    data_reg(21 downto 15) <= ENC_ERROR;
                    data_reg(28 downto 22) <= ENC_ERROR;
                    data_reg(35 downto 29) <= ENC_ERROR;
                    data_reg(42 downto 36) <= ENC_ERROR;
                    data_reg(49 downto 43) <= ENC_ERROR;
                    data_reg(56 downto 50) <= ENC_ERROR;
                    data_reg(63 downto 57) <= ENC_ERROR;
                    error_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Output assignments
    tx_header <= header_reg;
    tx_data <= data_reg;
    tx_valid <= valid_reg;
    encode_error <= error_reg;

end rtl;
