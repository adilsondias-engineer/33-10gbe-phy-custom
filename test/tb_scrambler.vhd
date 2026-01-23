--------------------------------------------------------------------------------
-- Testbench: Scrambler/Descrambler Verification
--
-- Verifies that:
--   1. Scrambler output is different from input (actually scrambles)
--   2. Descrambler recovers original data
--   3. Self-synchronization works (descrambler starts from zero state)
--   4. Header passes through unchanged
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

entity tb_scrambler is
end tb_scrambler;

architecture sim of tb_scrambler is

    constant CLK_PERIOD : time := 6.4 ns;

    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';

    -- TX side (scrambler)
    signal tx_data_in   : std_logic_vector(63 downto 0) := (others => '0');
    signal tx_header_in : std_logic_vector(1 downto 0) := "01";
    signal tx_valid_in  : std_logic := '0';
    signal tx_data_out  : std_logic_vector(63 downto 0);
    signal tx_header_out: std_logic_vector(1 downto 0);
    signal tx_valid_out : std_logic;

    -- RX side (descrambler)
    signal rx_data_out  : std_logic_vector(63 downto 0);
    signal rx_header_out: std_logic_vector(1 downto 0);
    signal rx_valid_out : std_logic;
    signal rx_sync      : std_logic;

    -- Verification
    signal expected_data: std_logic_vector(63 downto 0);
    signal expected_hdr : std_logic_vector(1 downto 0);
    signal data_match   : std_logic := '0';
    signal header_match : std_logic := '0';
    signal scrambled    : std_logic := '0';  -- Verify scrambler actually changed data

    -- Delay line for comparison (3 cycles: scram + descram + output reg)
    type data_delay_t is array(0 to 3) of std_logic_vector(63 downto 0);
    type hdr_delay_t is array(0 to 3) of std_logic_vector(1 downto 0);
    signal data_delay   : data_delay_t := (others => (others => '0'));
    signal hdr_delay    : hdr_delay_t := (others => "00");
    signal valid_delay  : std_logic_vector(3 downto 0) := (others => '0');

    signal test_count   : integer := 0;
    signal pass_count   : integer := 0;
    signal error_count  : integer := 0;

    component scrambler_tx is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            data_in         : in  std_logic_vector(63 downto 0);
            header_in       : in  std_logic_vector(1 downto 0);
            valid_in        : in  std_logic;
            data_out        : out std_logic_vector(63 downto 0);
            header_out      : out std_logic_vector(1 downto 0);
            valid_out       : out std_logic
        );
    end component;

    component descrambler_rx is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            data_in         : in  std_logic_vector(63 downto 0);
            header_in       : in  std_logic_vector(1 downto 0);
            valid_in        : in  std_logic;
            data_out        : out std_logic_vector(63 downto 0);
            header_out      : out std_logic_vector(1 downto 0);
            valid_out       : out std_logic;
            sync_status     : out std_logic
        );
    end component;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2;

    -- Scrambler
    scrambler_inst : scrambler_tx
        port map (
            clk         => clk,
            reset       => reset,
            data_in     => tx_data_in,
            header_in   => tx_header_in,
            valid_in    => tx_valid_in,
            data_out    => tx_data_out,
            header_out  => tx_header_out,
            valid_out   => tx_valid_out
        );

    -- Descrambler (loopback from scrambler output)
    descrambler_inst : descrambler_rx
        port map (
            clk         => clk,
            reset       => reset,
            data_in     => tx_data_out,
            header_in   => tx_header_out,
            valid_in    => tx_valid_out,
            data_out    => rx_data_out,
            header_out  => rx_header_out,
            valid_out   => rx_valid_out,
            sync_status => rx_sync
        );

    -- Delay pipeline for expected values
    process(clk)
    begin
        if rising_edge(clk) then
            data_delay(0) <= tx_data_in;
            hdr_delay(0) <= tx_header_in;
            valid_delay(0) <= tx_valid_in;

            for i in 1 to 3 loop
                data_delay(i) <= data_delay(i-1);
                hdr_delay(i) <= hdr_delay(i-1);
                valid_delay(i) <= valid_delay(i-1);
            end loop;
        end if;
    end process;

    expected_data <= data_delay(1);  -- 2 cycles: scrambler (1) + descrambler (1), 0-indexed array
    expected_hdr <= hdr_delay(1);

    -- Verification process
    process(clk)
    begin
        if rising_edge(clk) then
            -- Only check after descrambler is synced (first block will have errors - expected)
            if reset = '0' and rx_valid_out = '1' and valid_delay(1) = '1' and rx_sync = '1' then
                test_count <= test_count + 1;

                -- Check data match
                if rx_data_out = expected_data then
                    data_match <= '1';
                else
                    data_match <= '0';
                    report "DATA MISMATCH: Expected " & to_hstring(expected_data) &
                           " Got " & to_hstring(rx_data_out) severity warning;
                end if;

                -- Check header match
                if rx_header_out = expected_hdr then
                    header_match <= '1';
                else
                    header_match <= '0';
                    report "HEADER MISMATCH: Expected " & to_hstring(expected_hdr) &
                           " Got " & to_hstring(rx_header_out) severity warning;
                end if;

                -- Count results
                if rx_data_out = expected_data and rx_header_out = expected_hdr then
                    pass_count <= pass_count + 1;
                else
                    error_count <= error_count + 1;
                end if;
            end if;

            -- Verify scrambler actually scrambles (not passthrough)
            if tx_valid_out = '1' and tx_data_in /= x"0000000000000000" then
                if tx_data_out /= tx_data_in then
                    scrambled <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Stimulus
    process
    begin
        report "=== Scrambler/Descrambler Test ===" severity note;

        -- Reset
        reset <= '1';
        tx_valid_in <= '0';
        wait for CLK_PERIOD * 10;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Test 1: Warmup with known pattern (fill LFSR)
        report "Test 1: LFSR warmup" severity note;
        for i in 0 to 3 loop
            tx_data_in <= x"5555555555555555";
            tx_header_in <= "01";
            tx_valid_in <= '1';
            wait until rising_edge(clk);
        end loop;

        -- Test 2: Fixed patterns
        report "Test 2: Fixed patterns" severity note;

        tx_data_in <= x"0123456789ABCDEF";
        tx_header_in <= "01";
        wait until rising_edge(clk);

        tx_data_in <= x"FEDCBA9876543210";
        tx_header_in <= "10";
        wait until rising_edge(clk);

        tx_data_in <= x"AAAAAAAAAAAAAAAA";
        tx_header_in <= "01";
        wait until rising_edge(clk);

        tx_data_in <= x"FFFFFFFFFFFFFFFF";
        tx_header_in <= "10";
        wait until rising_edge(clk);

        tx_data_in <= x"0000000000000000";
        tx_header_in <= "01";
        wait until rising_edge(clk);

        -- Test 3: Sequential values
        report "Test 3: Sequential values" severity note;
        for i in 0 to 31 loop
            tx_data_in <= std_logic_vector(to_unsigned(i, 32)) &
                         std_logic_vector(to_unsigned(i * 17, 32));
            tx_header_in <= std_logic_vector(to_unsigned(i mod 2 + 1, 2));
            wait until rising_edge(clk);
        end loop;

        -- Test 4: All ones in different byte positions
        report "Test 4: Byte patterns" severity note;
        for byte_pos in 0 to 7 loop
            tx_data_in <= (others => '0');
            tx_data_in(byte_pos*8+7 downto byte_pos*8) <= x"FF";
            tx_header_in <= "01";
            wait until rising_edge(clk);
        end loop;

        -- Test 5: Stress test with many patterns
        report "Test 5: Stress test" severity note;
        for i in 0 to 99 loop
            tx_data_in <= std_logic_vector(to_unsigned(i * 12345 + 67890, 64));
            tx_header_in <= std_logic_vector(to_unsigned((i mod 2) + 1, 2));
            wait until rising_edge(clk);
        end loop;

        -- Drain pipeline
        tx_valid_in <= '0';
        wait for CLK_PERIOD * 10;

        -- Results
        report "=== Test Complete ===" severity note;
        report "Total: " & integer'image(test_count) severity note;
        report "Passed: " & integer'image(pass_count) severity note;
        report "Errors: " & integer'image(error_count) severity note;
        report "Scrambler active: " & std_logic'image(scrambled) severity note;

        if error_count = 0 and scrambled = '1' then
            report "*** ALL TESTS PASSED ***" severity note;
        else
            if scrambled = '0' then
                report "*** WARNING: Scrambler may not be working ***" severity warning;
            end if;
            if error_count > 0 then
                report "*** TESTS FAILED ***" severity error;
            end if;
        end if;

        wait for CLK_PERIOD * 5;
        assert false report "Simulation complete" severity failure;
    end process;

end sim;
