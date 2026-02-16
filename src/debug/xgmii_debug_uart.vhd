--------------------------------------------------------------------------------
-- Module: xgmii_debug_uart
-- Description: Captures XGMII RX words in a circular buffer. On corruption
--              trigger, freezes buffer and dumps via UART.
--
-- Purpose: Debug 10GBASE-R PCS/GTX by capturing raw XGMII output words.
--          Trigger fires when consecutive pure-data words (rxc=0x00) have
--          matching 32-bit groups — the exact corruption pattern observed
--          in Project 34 (stock symbol bytes leaking into price field).
--
-- Operation:
--   1. RECORD: stores non-IDLE XGMII words (rxc /= 0xFF) into circular buffer
--   2. FREEZE: when trigger fires, buffer freezes
--   3. DUMP: outputs buffer contents as hex via UART at 115200 baud
--      Format: "=XGM=\r\n" + one line per XGMII word + "=END=\r\n"
--   4. DONE: stays frozen until reset
--
-- Buffer format per entry (72 bits):
--   [71:64] = rxc(7:0)   -- control byte
--   [63:0]  = rxd(63:0)  -- data word
--
-- Dump output format (one line per XGMII word):
--   DD DD DD DD DD DD DD DD|CC\r\n
--   Where DD = data bytes (lane 0 first = wire order), CC = control byte
--
-- Example output:
--   =XGM=
--   07 07 07 07 55 55 55 FB|FF
--   63 17 FB 5D 3F 80 FF FF|00
--   00 08 FF FF FF FF 63 17|00
--   ...
--   =END=
--
-- Design: FSM and UART TX in SINGLE process (proven fix for character-skip
-- race condition observed in two-process designs).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity xgmii_debug_uart is
    generic (
        CLK_FREQ  : integer := 161_130_000;  -- tx_clk frequency (Hz)
        BAUD_RATE : integer := 115200;
        BUF_AW    : integer := 11            -- log2(buffer depth), 11 = 2048 entries
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- XGMII RX from PCS
        xgmii_rxd       : in  std_logic_vector(63 downto 0);
        xgmii_rxc       : in  std_logic_vector(7 downto 0);
        xgmii_rx_valid  : in  std_logic;

        -- UART TX output
        uart_tx          : out std_logic;

        -- Status: '1' while dump is active (used to mux UART at top level)
        dump_active      : out std_logic
    );
end entity;

architecture rtl of xgmii_debug_uart is

    constant BUF_DEPTH : integer := 2**BUF_AW;
    constant BAUD_DIV  : integer := CLK_FREQ / BAUD_RATE;

    ----------------------------------------------------------------------------
    -- Circular buffer (distributed RAM, 128 x 72 bits)
    -- Entry = rxc(7:0) & rxd(63:0)
    ----------------------------------------------------------------------------
    type buf_t is array(0 to BUF_DEPTH-1) of std_logic_vector(71 downto 0);
    signal buf    : buf_t := (others => (others => '0'));
    signal wr_ptr : unsigned(BUF_AW-1 downto 0) := (others => '0');
    signal frozen : std_logic := '0';

    -- Arm on magic pattern: full XGMII word of 0xAA (sent by test script)
    signal armed      : std_logic := '0';
    -- Cooldown: wait for arm frame to end before recording
    signal arm_ready  : std_logic := '0';

    -- Dump read pointer
    signal rd_ptr   : unsigned(BUF_AW-1 downto 0) := (others => '0');
    signal rd_count : unsigned(BUF_AW downto 0) := (others => '0');

    -- Current buffer entry (async read from distributed RAM)
    signal cur_entry : std_logic_vector(71 downto 0);

    -- Current byte to output (muxed from entry by byte_idx)
    signal cur_byte : std_logic_vector(7 downto 0);

    ----------------------------------------------------------------------------
    -- UART TX shift register (8N1, LSB first)
    ----------------------------------------------------------------------------
    signal tx_shift : std_logic_vector(9 downto 0) := "1111111111";
    signal tx_busy  : std_logic := '0';
    signal tx_bit   : integer range 0 to 9 := 0;
    signal tx_baud  : unsigned(13 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Dump FSM
    ----------------------------------------------------------------------------
    type state_t is (
        S_RECORD,         -- Recording XGMII words, waiting for trigger
        S_HDR,            -- Sending header string
        S_HI_NIB,         -- Send high hex nibble of current byte
        S_LO_NIB,         -- Send low hex nibble of current byte
        S_SEP,            -- Send separator (space between data bytes, '|' before ctrl)
        S_CR,             -- Send \r after control byte
        S_LF,             -- Send \n
        S_FTR,            -- Send footer string
        S_DONE            -- Dump complete, stay frozen
    );
    signal state : state_t := S_RECORD;

    -- String index for header/footer
    signal str_idx : integer range 0 to 15 := 0;

    -- Byte index within entry: 0-7 = rxd lanes, 8 = rxc
    signal byte_idx : integer range 0 to 8 := 0;

    -- dump_active register
    signal dump_active_r : std_logic := '0';

    ----------------------------------------------------------------------------
    -- Header: "\r\n=XGM=\r\n" (9 characters)
    ----------------------------------------------------------------------------
    type str_rom_t is array(natural range <>) of std_logic_vector(7 downto 0);
    constant HDR : str_rom_t(0 to 8) := (
        x"0D", x"0A",                                  -- \r\n
        x"3D", x"58", x"47", x"4D", x"3D",             -- =XGM=
        x"0D", x"0A"                                    -- \r\n
    );

    -- Footer: "\r\n=END=\r\n" (9 characters)
    constant FTR : str_rom_t(0 to 8) := (
        x"0D", x"0A",                                  -- \r\n
        x"3D", x"45", x"4E", x"44", x"3D",             -- =END=
        x"0D", x"0A"                                    -- \r\n
    );

    ----------------------------------------------------------------------------
    -- Nibble to ASCII hex ('0'-'9', 'A'-'F')
    ----------------------------------------------------------------------------
    function hex(n : std_logic_vector(3 downto 0))
        return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        case n is
            when "0000" => result := x"30";
            when "0001" => result := x"31";
            when "0010" => result := x"32";
            when "0011" => result := x"33";
            when "0100" => result := x"34";
            when "0101" => result := x"35";
            when "0110" => result := x"36";
            when "0111" => result := x"37";
            when "1000" => result := x"38";
            when "1001" => result := x"39";
            when "1010" => result := x"41";
            when "1011" => result := x"42";
            when "1100" => result := x"43";
            when "1101" => result := x"44";
            when "1110" => result := x"45";
            when "1111" => result := x"46";
            when others => result := x"3F";  -- '?'
        end case;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- Procedure: load UART shift register with a byte
    ----------------------------------------------------------------------------
    procedure uart_load(
        signal   sr      : out std_logic_vector(9 downto 0);
        signal   busy    : out std_logic;
        signal   bit_cnt : out integer range 0 to 9;
        signal   baud    : out unsigned(13 downto 0);
        constant data    : in  std_logic_vector(7 downto 0)
    ) is
    begin
        sr      <= '1' & data & '0';  -- stop + data + start
        busy    <= '1';
        bit_cnt <= 0;
        baud    <= (others => '0');
    end procedure;

begin

    -- Async read from circular buffer (distributed RAM)
    cur_entry <= buf(to_integer(rd_ptr));

    -- Byte mux: extract one of 9 bytes from the 72-bit entry
    -- Bytes 0-7 = rxd lanes (lane 0 first = wire order)
    -- Byte 8   = rxc
    with byte_idx select cur_byte <=
        cur_entry(7  downto  0) when 0,   -- rxd lane 0
        cur_entry(15 downto  8) when 1,   -- rxd lane 1
        cur_entry(23 downto 16) when 2,   -- rxd lane 2
        cur_entry(31 downto 24) when 3,   -- rxd lane 3
        cur_entry(39 downto 32) when 4,   -- rxd lane 4
        cur_entry(47 downto 40) when 5,   -- rxd lane 5
        cur_entry(55 downto 48) when 6,   -- rxd lane 6
        cur_entry(63 downto 56) when 7,   -- rxd lane 7
        cur_entry(71 downto 64) when 8,   -- rxc
        x"00" when others;

    dump_active <= dump_active_r;

    ----------------------------------------------------------------------------
    -- Buffer write process (one-shot fill after arm)
    --
    -- 1. Wait for magic pattern (0xAA word) to arm
    -- 2. Wait for arm frame to end (IDLE = cooldown)
    -- 3. Record next BUF_DEPTH non-IDLE words into buffer (indices 0..N-1)
    -- 4. Freeze and auto-dump — no corruption trigger needed
    --
    -- User examines the raw XGMII dump manually for corruption.
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr     <= (others => '0');
                frozen     <= '0';
                armed      <= '0';
                arm_ready  <= '0';
            elsif frozen = '0' then
                -- Arm on magic pattern: full XGMII data word of 0xAA
                if armed = '0' and xgmii_rx_valid = '1'
                   and xgmii_rxc = "00000000"
                   and xgmii_rxd = x"AAAAAAAAAAAAAAAA" then
                    armed <= '1';
                end if;

                -- Cooldown: wait for arm frame to end (IDLE).
                -- Reset wr_ptr so buffer fills from index 0.
                if armed = '1' and arm_ready = '0'
                   and xgmii_rx_valid = '1' and xgmii_rxc = "11111111" then
                    arm_ready <= '1';
                    wr_ptr    <= (others => '0');
                end if;

                -- One-shot fill: record non-IDLE words after arm_ready
                if arm_ready = '1' then
                    if xgmii_rx_valid = '1' and xgmii_rxc /= "11111111" then
                        buf(to_integer(wr_ptr)) <= xgmii_rxc & xgmii_rxd;
                        -- Freeze when buffer is full (wr_ptr about to wrap)
                        if wr_ptr = BUF_DEPTH - 1 then
                            frozen <= '1';
                        end if;
                        wr_ptr <= wr_ptr + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Combined UART TX + Dump FSM (SINGLE PROCESS)
    --
    -- When tx_busy='1': shift register runs (UART bit output)
    -- When tx_busy='0': FSM advances and directly loads next byte
    --
    -- Dump format per buffer entry:
    --   DD DD DD DD DD DD DD DD|CC\r\n
    -- (8 data hex bytes + pipe + 1 control hex byte + newline)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state         <= S_RECORD;
                dump_active_r <= '0';
                str_idx       <= 0;
                rd_ptr        <= (others => '0');
                rd_count      <= (others => '0');
                byte_idx      <= 0;
                tx_shift      <= "1111111111";
                tx_busy       <= '0';
                tx_bit        <= 0;
                tx_baud       <= (others => '0');
            elsif tx_busy = '1' then
                --------------------------------------------------------
                -- UART TX: shift register running (8N1, LSB first)
                --------------------------------------------------------
                if tx_baud = BAUD_DIV - 1 then
                    tx_baud <= (others => '0');
                    if tx_bit = 9 then
                        tx_busy  <= '0';
                        tx_shift <= "1111111111";
                    else
                        tx_shift <= '1' & tx_shift(9 downto 1);
                        tx_bit   <= tx_bit + 1;
                    end if;
                else
                    tx_baud <= tx_baud + 1;
                end if;
            else
                --------------------------------------------------------
                -- tx_busy = '0': FSM runs, can load next byte
                --------------------------------------------------------
                case state is

                    ----------------------------------------------------
                    -- RECORD: wait for buffer full (frozen='1')
                    ----------------------------------------------------
                    when S_RECORD =>
                        dump_active_r <= '0';
                        if frozen = '1' then
                            dump_active_r <= '1';
                            state    <= S_HDR;
                            str_idx  <= 0;
                            rd_ptr   <= (others => '0');  -- start from index 0
                            rd_count <= (others => '0');
                            byte_idx <= 0;
                        end if;

                    ----------------------------------------------------
                    -- HDR: send header string character by character
                    ----------------------------------------------------
                    when S_HDR =>
                        if str_idx = HDR'length then
                            state <= S_HI_NIB;
                        else
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      HDR(str_idx));
                            str_idx <= str_idx + 1;
                        end if;

                    ----------------------------------------------------
                    -- HI_NIB: send high hex nibble of current byte
                    -- Also checks for buffer exhaustion at entry start
                    ----------------------------------------------------
                    when S_HI_NIB =>
                        if rd_count = BUF_DEPTH then
                            -- All entries dumped
                            state   <= S_FTR;
                            str_idx <= 0;
                        else
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      hex(cur_byte(7 downto 4)));
                            state <= S_LO_NIB;
                        end if;

                    ----------------------------------------------------
                    -- LO_NIB: send low hex nibble, then separator or CR
                    ----------------------------------------------------
                    when S_LO_NIB =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  hex(cur_byte(3 downto 0)));
                        if byte_idx = 8 then
                            -- After control byte: end of line
                            state    <= S_CR;
                            byte_idx <= 0;
                        else
                            -- After data byte: separator
                            state <= S_SEP;
                        end if;

                    ----------------------------------------------------
                    -- SEP: send space (between data bytes) or pipe
                    --       (between last data byte and control byte)
                    ----------------------------------------------------
                    when S_SEP =>
                        if byte_idx = 7 then
                            -- Pipe separator before control byte
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      x"7C");  -- '|'
                        else
                            -- Space separator between data bytes
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      x"20");  -- ' '
                        end if;
                        byte_idx <= byte_idx + 1;
                        state    <= S_HI_NIB;

                    ----------------------------------------------------
                    -- CR: send \r, advance to next buffer entry
                    ----------------------------------------------------
                    when S_CR =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  x"0D");  -- \r
                        rd_ptr   <= rd_ptr + 1;
                        rd_count <= rd_count + 1;
                        state    <= S_LF;

                    ----------------------------------------------------
                    -- LF: send \n
                    ----------------------------------------------------
                    when S_LF =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  x"0A");  -- \n
                        state <= S_HI_NIB;

                    ----------------------------------------------------
                    -- FTR: send footer string
                    ----------------------------------------------------
                    when S_FTR =>
                        if str_idx = FTR'length then
                            state <= S_DONE;
                        else
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      FTR(str_idx));
                            str_idx <= str_idx + 1;
                        end if;

                    ----------------------------------------------------
                    -- DONE: stay frozen until reset
                    ----------------------------------------------------
                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

    uart_tx <= tx_shift(0);

end rtl;
