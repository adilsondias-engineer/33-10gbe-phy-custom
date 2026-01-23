--------------------------------------------------------------------------------
-- UART TX Debug Module
-- Periodically transmits GTX status over UART for debugging
--
-- Baud rate: 115200 at 200 MHz clock (divider = 1736)
-- Format: "Q:X L:X T:X R:X P:X G:X QR:X TU:X RU:X\r\n"
--
-- Fields:
--   Q  = QPLL locked (1=locked)
--   L  = QPLL refclk lost (1=LOST/BAD!)
--   T  = TX reset done (1=complete)
--   R  = RX reset done (1=complete)
--   P  = POR done (1=power-on reset complete)
--   G  = GTX reset (1=reset ACTIVE)
--   QR = QPLL reset (1=reset ACTIVE)
--   TU = TX user ready (1=ready)
--   RU = RX user ready (1=ready)
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

entity uart_tx_debug is
    generic (
        CLK_FREQ    : integer := 200_000_000;  -- 200 MHz
        BAUD_RATE   : integer := 115200
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- Status inputs to report
        qpll_lock       : in  std_logic;
        qpll_refclk_lost: in  std_logic;
        tx_resetdone    : in  std_logic;
        rx_resetdone    : in  std_logic;

        -- Extended debug inputs
        debug_por_done  : in  std_logic;  -- Power-on reset complete
        debug_qpll_reset: in  std_logic;  -- QPLL reset active
        debug_gtx_reset : in  std_logic;  -- GTX channel reset active
        debug_tx_userrdy: in  std_logic;  -- TX user ready
        debug_rx_userrdy: in  std_logic;  -- RX user ready

        -- UART output
        uart_tx         : out std_logic
    );
end uart_tx_debug;

architecture rtl of uart_tx_debug is

    -- Baud rate divider
    constant BAUD_DIV : integer := CLK_FREQ / BAUD_RATE;

    -- Report interval (~500ms at 200 MHz)
    constant REPORT_INTERVAL : integer := 100_000_000;

    -- UART TX state machine
    type uart_state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal uart_state : uart_state_t := IDLE;

    -- Baud counter
    signal baud_cnt : integer range 0 to BAUD_DIV-1 := 0;
    signal baud_tick : std_logic := '0';

    -- TX shift register
    signal tx_data : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_bit_cnt : integer range 0 to 7 := 0;
    signal tx_busy : std_logic := '0';

    -- Message buffer (maximum 64 characters)
    type msg_array_t is array (0 to 63) of std_logic_vector(7 downto 0);
    signal msg_buffer : msg_array_t := (others => (others => '0'));
    signal msg_len : integer range 0 to 64 := 0;
    signal msg_idx : integer range 0 to 63 := 0;

    -- Report timer
    signal report_cnt : integer range 0 to REPORT_INTERVAL := 0;
    signal send_report : std_logic := '0';

    -- Message generation state
    type msg_state_t is (MSG_IDLE, MSG_BUILDING, MSG_SENDING);
    signal msg_state : msg_state_t := MSG_IDLE;

    -- TX output register
    signal tx_out : std_logic := '1';

    -- Sampled status (to prevent metastability)
    signal qpll_lock_s    : std_logic := '0';
    signal qpll_lost_s    : std_logic := '0';
    signal tx_done_s      : std_logic := '0';
    signal rx_done_s      : std_logic := '0';
    signal por_done_s     : std_logic := '0';
    signal qpll_reset_s   : std_logic := '0';
    signal gtx_reset_s    : std_logic := '0';
    signal tx_userrdy_s   : std_logic := '0';
    signal rx_userrdy_s   : std_logic := '0';

begin

    uart_tx <= tx_out;

    ----------------------------------------------------------------------------
    -- Baud rate generator
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if baud_cnt = BAUD_DIV - 1 then
                baud_cnt <= 0;
                baud_tick <= '1';
            else
                baud_cnt <= baud_cnt + 1;
                baud_tick <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Sample status inputs (reduce metastability)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            qpll_lock_s   <= qpll_lock;
            qpll_lost_s   <= qpll_refclk_lost;
            tx_done_s     <= tx_resetdone;
            rx_done_s     <= rx_resetdone;
            por_done_s    <= debug_por_done;
            qpll_reset_s  <= debug_qpll_reset;
            gtx_reset_s   <= debug_gtx_reset;
            tx_userrdy_s  <= debug_tx_userrdy;
            rx_userrdy_s  <= debug_rx_userrdy;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Report timer
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if report_cnt = REPORT_INTERVAL - 1 then
                report_cnt <= 0;
                send_report <= '1';
            else
                report_cnt <= report_cnt + 1;
                if msg_state /= MSG_IDLE then
                    send_report <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Message builder
    -- Format: "Q:X L:X T:X R:X P:X G:X QR:X TU:X RU:X\r\n"
    ----------------------------------------------------------------------------
    process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            case msg_state is
                when MSG_IDLE =>
                    if send_report = '1' and tx_busy = '0' then
                        msg_state <= MSG_BUILDING;
                    end if;

                when MSG_BUILDING =>
                    idx := 0;

                    -- "Q:" QPLL lock
                    msg_buffer(idx) <= x"51"; idx := idx + 1;  -- 'Q'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if qpll_lock_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "L:" Refclk lost
                    msg_buffer(idx) <= x"4C"; idx := idx + 1;  -- 'L'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if qpll_lost_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "T:" TX reset done
                    msg_buffer(idx) <= x"54"; idx := idx + 1;  -- 'T'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if tx_done_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "R:" RX reset done
                    msg_buffer(idx) <= x"52"; idx := idx + 1;  -- 'R'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if rx_done_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "P:" POR done
                    msg_buffer(idx) <= x"50"; idx := idx + 1;  -- 'P'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if por_done_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "G:" GTX reset active
                    msg_buffer(idx) <= x"47"; idx := idx + 1;  -- 'G'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if gtx_reset_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "QR:" QPLL reset active
                    msg_buffer(idx) <= x"51"; idx := idx + 1;  -- 'Q'
                    msg_buffer(idx) <= x"52"; idx := idx + 1;  -- 'R'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if qpll_reset_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "TU:" TX user ready
                    msg_buffer(idx) <= x"54"; idx := idx + 1;  -- 'T'
                    msg_buffer(idx) <= x"55"; idx := idx + 1;  -- 'U'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if tx_userrdy_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;
                    msg_buffer(idx) <= x"20"; idx := idx + 1;  -- ' '

                    -- "RU:" RX user ready
                    msg_buffer(idx) <= x"52"; idx := idx + 1;  -- 'R'
                    msg_buffer(idx) <= x"55"; idx := idx + 1;  -- 'U'
                    msg_buffer(idx) <= x"3A"; idx := idx + 1;  -- ':'
                    if rx_userrdy_s = '1' then
                        msg_buffer(idx) <= x"31";  -- '1'
                    else
                        msg_buffer(idx) <= x"30";  -- '0'
                    end if;
                    idx := idx + 1;

                    -- Line ending
                    msg_buffer(idx) <= x"0D"; idx := idx + 1;  -- CR
                    msg_buffer(idx) <= x"0A"; idx := idx + 1;  -- LF

                    msg_len <= idx;
                    msg_idx <= 0;
                    msg_state <= MSG_SENDING;

                when MSG_SENDING =>
                    if tx_busy = '0' then
                        if msg_idx < msg_len then
                            tx_data <= msg_buffer(msg_idx);
                            tx_busy <= '1';
                            msg_idx <= msg_idx + 1;
                        else
                            msg_state <= MSG_IDLE;
                        end if;
                    end if;
            end case;

            -- Clear tx_busy when transmission complete
            if uart_state = STOP_BIT and baud_tick = '1' then
                tx_busy <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- UART TX state machine
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            case uart_state is
                when IDLE =>
                    tx_out <= '1';  -- Idle high
                    if tx_busy = '1' and msg_state = MSG_SENDING then
                        uart_state <= START_BIT;
                        tx_bit_cnt <= 0;
                    end if;

                when START_BIT =>
                    tx_out <= '0';  -- Start bit is low
                    if baud_tick = '1' then
                        uart_state <= DATA_BITS;
                    end if;

                when DATA_BITS =>
                    tx_out <= tx_data(tx_bit_cnt);  -- LSB first
                    if baud_tick = '1' then
                        if tx_bit_cnt = 7 then
                            uart_state <= STOP_BIT;
                        else
                            tx_bit_cnt <= tx_bit_cnt + 1;
                        end if;
                    end if;

                when STOP_BIT =>
                    tx_out <= '1';  -- Stop bit is high
                    if baud_tick = '1' then
                        uart_state <= IDLE;
                    end if;
            end case;
        end if;
    end process;

end rtl;
