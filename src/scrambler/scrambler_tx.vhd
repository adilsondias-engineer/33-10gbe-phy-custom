--------------------------------------------------------------------------------
-- TX Scrambler for 10GBASE-R PCS
--
-- Implements the self-synchronizing scrambler defined in IEEE 802.3 Clause 49.
--
-- Polynomial: G(X) = 1 + X^39 + X^58
--
-- The scrambler XORs data with the LFSR output. The sync header (2 bits)
-- is NOT scrambled - only the 64-bit payload is scrambled.
--
-- Self-synchronizing property:
--   - RX descrambler will automatically synchronize to TX within 58 bits
--   - No explicit synchronization sequence required
--
-- Operation:
--   - Input: 64-bit data payload (already 64B/66B encoded)
--   - Output: 64-bit scrambled payload
--   - Sync header passes through unchanged
--
-- Performance:
--   - Fully parallel implementation (scrambles all 64 bits per clock)
--   - Single clock cycle latency
--   - Runs at 156.25 MHz line rate
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

entity scrambler_tx is
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Input (from 64B/66B encoder)
        data_in         : in  std_logic_vector(63 downto 0);
        header_in       : in  std_logic_vector(1 downto 0);
        valid_in        : in  std_logic;

        -- Output (to GTX transmitter)
        data_out        : out std_logic_vector(63 downto 0);
        header_out      : out std_logic_vector(1 downto 0);
        valid_out       : out std_logic
    );
end scrambler_tx;

architecture rtl of scrambler_tx is

    -- LFSR state (58 bits for G(X) = 1 + X^39 + X^58)
    signal lfsr : std_logic_vector(57 downto 0) := (others => '1');

    -- Scrambled output register
    signal data_scrambled : std_logic_vector(63 downto 0);
    signal header_reg     : std_logic_vector(1 downto 0);
    signal valid_reg      : std_logic;

    -- Temporary LFSR state for parallel computation
    type lfsr_array is array (0 to 63) of std_logic_vector(57 downto 0);

begin

    ----------------------------------------------------------------------------
    -- Parallel Scrambler
    --
    -- For each input bit, compute:
    --   scrambled[i] = data_in[i] XOR lfsr[38] XOR lfsr[57]
    --
    -- Then update LFSR by shifting in scrambled bit:
    --   lfsr_next = lfsr(56 downto 0) & scrambled[i]
    --
    -- For parallel operation, compute all 64 bits and final LFSR state
    ----------------------------------------------------------------------------
    process(clk)
        variable lfsr_temp : std_logic_vector(57 downto 0);
        variable scram_bit : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                lfsr <= (others => '1');  -- Initialize to all 1s
                data_scrambled <= (others => '0');
                header_reg <= "00";
                valid_reg <= '0';
            elsif valid_in = '1' then
                -- Start with current LFSR state
                lfsr_temp := lfsr;

                -- Scramble each bit in parallel using unrolled loop
                -- Bit 0 (first to transmit)
                scram_bit := data_in(0) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(0) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 1
                scram_bit := data_in(1) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(1) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 2
                scram_bit := data_in(2) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(2) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 3
                scram_bit := data_in(3) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(3) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 4
                scram_bit := data_in(4) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(4) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 5
                scram_bit := data_in(5) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(5) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 6
                scram_bit := data_in(6) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(6) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 7
                scram_bit := data_in(7) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(7) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 8
                scram_bit := data_in(8) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(8) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 9
                scram_bit := data_in(9) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(9) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 10
                scram_bit := data_in(10) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(10) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 11
                scram_bit := data_in(11) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(11) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 12
                scram_bit := data_in(12) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(12) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 13
                scram_bit := data_in(13) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(13) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 14
                scram_bit := data_in(14) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(14) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bit 15
                scram_bit := data_in(15) xor lfsr_temp(38) xor lfsr_temp(57);
                data_scrambled(15) <= scram_bit;
                lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;

                -- Bits 16-31
                for i in 16 to 31 loop
                    scram_bit := data_in(i) xor lfsr_temp(38) xor lfsr_temp(57);
                    data_scrambled(i) <= scram_bit;
                    lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;
                end loop;

                -- Bits 32-47
                for i in 32 to 47 loop
                    scram_bit := data_in(i) xor lfsr_temp(38) xor lfsr_temp(57);
                    data_scrambled(i) <= scram_bit;
                    lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;
                end loop;

                -- Bits 48-63
                for i in 48 to 63 loop
                    scram_bit := data_in(i) xor lfsr_temp(38) xor lfsr_temp(57);
                    data_scrambled(i) <= scram_bit;
                    lfsr_temp := lfsr_temp(56 downto 0) & scram_bit;
                end loop;

                -- Update LFSR state for next block
                lfsr <= lfsr_temp;

                -- Pass through header unchanged (not scrambled)
                header_reg <= header_in;
                valid_reg <= '1';
            else
                valid_reg <= '0';
            end if;
        end if;
    end process;

    -- Output assignments
    data_out <= data_scrambled;
    header_out <= header_reg;
    valid_out <= valid_reg;

end rtl;
