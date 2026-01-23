--------------------------------------------------------------------------------
-- RX Descrambler for 10GBASE-R PCS
--
-- Implements the self-synchronizing descrambler defined in IEEE 802.3 Clause 49.
--
-- Polynomial: G(X) = 1 + X^39 + X^58
--
-- Self-synchronizing descrambler:
--   - Uses received (scrambled) data to update LFSR
--   - Automatically synchronizes within 58 bits of valid data
--   - No handshake or sync pattern required
--
-- Operation:
--   descrambled[i] = scrambled[i] XOR lfsr[38] XOR lfsr[57]
--   lfsr_next = lfsr(56:0) & scrambled[i]  (shift in received data)
--
-- Note: The sync header (2 bits) is NOT descrambled - only the 64-bit payload.
--
-- TEST 2026-01-22: PCS layer may pass raw GTX data (MSB-first) or reversed data
-- (LSB-first) depending on ENABLE_RX_BIT_REVERSE setting. This descrambler
-- processes bits in order received (LSB-first expected if reversed, MSB-first if raw).
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

entity descrambler_rx is
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Input (from GTX receiver, scrambled)
        data_in         : in  std_logic_vector(63 downto 0);
        header_in       : in  std_logic_vector(1 downto 0);
        valid_in        : in  std_logic;

        -- Output (to 64B/66B decoder, descrambled)
        data_out        : out std_logic_vector(63 downto 0);
        header_out      : out std_logic_vector(1 downto 0);
        valid_out       : out std_logic;

        -- Status
        sync_status     : out std_logic   -- High after 58+ bits processed
    );
end descrambler_rx;

architecture rtl of descrambler_rx is

    -- LFSR state (58 bits for G(X) = 1 + X^39 + X^58)
    signal lfsr : std_logic_vector(57 downto 0) := (others => '0');

    -- Descrambled output register
    signal data_descrambled : std_logic_vector(63 downto 0);
    signal header_reg       : std_logic_vector(1 downto 0);
    signal valid_reg        : std_logic;

    -- Sync counter (counts blocks processed, saturates at 64)
    signal sync_count : unsigned(6 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- Parallel Descrambler (LSB-first processing)
    --
    -- NOTE: This descrambler expects LSB-first data (bit 0 first)
    -- TEST 2026-01-22: PCS layer may pass raw GTX data (MSB-first) or reversed data
    -- (LSB-first) depending on ENABLE_RX_BIT_REVERSE setting.
    -- When ENABLE_RX_BIT_REVERSE=true: PCS reverses GTX RX data (MSB-first) to LSB-first
    -- When ENABLE_RX_BIT_REVERSE=false: PCS passes raw GTX data (MSB-first)
    -- This descrambler processes bits in order received.
    --
    -- Self-synchronizing: LFSR is loaded with RECEIVED (scrambled) data
    -- This allows automatic synchronization without knowing TX LFSR state
    --
    -- For each bit:
    --   descrambled[i] = scrambled[i] XOR lfsr[38] XOR lfsr[57]
    --   lfsr_next = lfsr(56:0) & scrambled[i]
    ----------------------------------------------------------------------------
    process(clk)
        variable lfsr_temp : std_logic_vector(57 downto 0);
        variable descram_bit : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                lfsr <= (others => '0');
                data_descrambled <= (others => '0');
                header_reg <= "00";
                valid_reg <= '0';
                sync_count <= (others => '0');
            elsif valid_in = '1' then
                -- Start with current LFSR state
                lfsr_temp := lfsr;

                -- Descramble each bit, shifting in RECEIVED data to LFSR
                -- Process bits 0 to 63 (LSB-first, matching TX scrambler order)
                -- Data is already reversed by PCS layer (GTX MSB-first -> LSB-first)
                for i in 0 to 63 loop
                    descram_bit := data_in(i) xor lfsr_temp(38) xor lfsr_temp(57);
                    data_descrambled(i) <= descram_bit;
                    lfsr_temp := lfsr_temp(56 downto 0) & data_in(i);  -- Shift in scrambled
                end loop;

                -- Update LFSR state
                lfsr <= lfsr_temp;

                -- Pass through header unchanged
                header_reg <= header_in;
                valid_reg <= '1';

                -- Update sync counter (saturates at 64)
                if sync_count < 64 then
                    sync_count <= sync_count + 1;
                end if;
            else
                valid_reg <= '0';
            end if;
        end if;
    end process;

    -- Output assignments
    data_out <= data_descrambled;
    header_out <= header_reg;
    valid_out <= valid_reg;

    -- Sync status: high after at least 2 full blocks (128 bits) processed
    -- First block output is corrupted during LFSR warmup, second block is valid
    sync_status <= '1' when sync_count >= 2 else '0';

end rtl;
