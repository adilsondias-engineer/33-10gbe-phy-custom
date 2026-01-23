--------------------------------------------------------------------------------
-- Testbench: PCS 64B/66B Loopback Test
--
-- Tests the complete TX -> RX path:
--   XGMII TX -> Encoder -> Scrambler -> Descrambler -> Decoder -> XGMII RX
--
-- Test Cases:
--   1. Idle frames (all control)
--   2. Data frames (all data)
--   3. Start of frame (various lanes)
--   4. End of frame (all terminate positions)
--   5. Mixed data/control patterns
--   6. Random data stress test
--   7. Back-to-back frames
--
-- Self-checking: Compares XGMII output with expected values
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
use IEEE.MATH_REAL.ALL;  -- For random number generation

entity tb_pcs_loopback is
end tb_pcs_loopback;

architecture sim of tb_pcs_loopback is

    -- Clock period (156.25 MHz)
    constant CLK_PERIOD : time := 6.4 ns;

    -- XGMII control characters
    constant XGMII_IDLE     : std_logic_vector(7 downto 0) := x"07";
    constant XGMII_START    : std_logic_vector(7 downto 0) := x"FB";
    constant XGMII_TERM     : std_logic_vector(7 downto 0) := x"FD";
    constant XGMII_ERROR    : std_logic_vector(7 downto 0) := x"FE";

    -- Signals
    signal clk              : std_logic := '0';
    signal reset            : std_logic := '1';

    -- XGMII TX (input to PCS)
    signal xgmii_txd        : std_logic_vector(63 downto 0) := (others => '0');
    signal xgmii_txc        : std_logic_vector(7 downto 0) := (others => '1');

    -- XGMII RX (output from PCS)
    signal xgmii_rxd        : std_logic_vector(63 downto 0);
    signal xgmii_rxc        : std_logic_vector(7 downto 0);
    signal xgmii_rx_valid   : std_logic;

    -- Encoder outputs
    signal enc_data         : std_logic_vector(63 downto 0);
    signal enc_header       : std_logic_vector(1 downto 0);
    signal enc_valid        : std_logic;
    signal enc_error        : std_logic;

    -- Scrambler outputs
    signal scram_data       : std_logic_vector(63 downto 0);
    signal scram_header     : std_logic_vector(1 downto 0);
    signal scram_valid      : std_logic;

    -- Descrambler outputs
    signal descram_data     : std_logic_vector(63 downto 0);
    signal descram_header   : std_logic_vector(1 downto 0);
    signal descram_valid    : std_logic;
    signal descram_sync     : std_logic;

    -- Decoder outputs
    signal dec_rxd          : std_logic_vector(63 downto 0);
    signal dec_rxc          : std_logic_vector(7 downto 0);
    signal dec_valid        : std_logic;
    signal dec_error        : std_logic;

    -- Test control
    signal test_phase       : integer := 0;
    signal test_count       : integer := 0;
    signal error_count      : integer := 0;
    signal pass_count       : integer := 0;

    -- Expected values (delayed input for comparison)
    type delay_array is array (0 to 7) of std_logic_vector(63 downto 0);
    type delay_ctrl_array is array (0 to 7) of std_logic_vector(7 downto 0);
    signal txd_delay        : delay_array := (others => (others => '0'));
    signal txc_delay        : delay_ctrl_array := (others => (others => '1'));
    signal valid_delay      : std_logic_vector(7 downto 0) := (others => '0');

    -- Pipeline delay (encoder + scrambler + descrambler + decoder = 4 cycles)
    -- Use index 3 because delay array is 0-indexed (0,1,2,3 = 4 delays)
    constant PIPELINE_DELAY : integer := 3;

    -- Random seed
    shared variable seed1   : positive := 12345;
    shared variable seed2   : positive := 67890;

    -- Component declarations
    component encoder_64b66b is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            xgmii_txd       : in  std_logic_vector(63 downto 0);
            xgmii_txc       : in  std_logic_vector(7 downto 0);
            tx_header       : out std_logic_vector(1 downto 0);
            tx_data         : out std_logic_vector(63 downto 0);
            tx_valid        : out std_logic;
            encode_error    : out std_logic
        );
    end component;

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

    component decoder_64b66b is
        port (
            clk             : in  std_logic;
            reset           : in  std_logic;
            rx_header       : in  std_logic_vector(1 downto 0);
            rx_data         : in  std_logic_vector(63 downto 0);
            rx_valid        : in  std_logic;
            xgmii_rxd       : out std_logic_vector(63 downto 0);
            xgmii_rxc       : out std_logic_vector(7 downto 0);
            rx_data_valid   : out std_logic;
            decode_error    : out std_logic
        );
    end component;

    -- Helper function: generate random byte
    impure function rand_byte return std_logic_vector is
        variable r : real;
        variable result : std_logic_vector(7 downto 0);
    begin
        uniform(seed1, seed2, r);
        result := std_logic_vector(to_unsigned(integer(r * 255.0), 8));
        return result;
    end function;

    -- Helper function: generate random 64-bit data
    impure function rand_data return std_logic_vector is
        variable result : std_logic_vector(63 downto 0);
    begin
        for i in 0 to 7 loop
            result(i*8+7 downto i*8) := rand_byte;
        end loop;
        return result;
    end function;

begin

    ----------------------------------------------------------------------------
    -- Clock Generation
    ----------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- DUT Instantiation: Encoder -> Scrambler -> Descrambler -> Decoder
    ----------------------------------------------------------------------------

    encoder_inst : encoder_64b66b
        port map (
            clk             => clk,
            reset           => reset,
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,
            tx_header       => enc_header,
            tx_data         => enc_data,
            tx_valid        => enc_valid,
            encode_error    => enc_error
        );

    scrambler_inst : scrambler_tx
        port map (
            clk             => clk,
            reset           => reset,
            data_in         => enc_data,
            header_in       => enc_header,
            valid_in        => enc_valid,
            data_out        => scram_data,
            header_out      => scram_header,
            valid_out       => scram_valid
        );

    descrambler_inst : descrambler_rx
        port map (
            clk             => clk,
            reset           => reset,
            data_in         => scram_data,
            header_in       => scram_header,
            valid_in        => scram_valid,
            data_out        => descram_data,
            header_out      => descram_header,
            valid_out       => descram_valid,
            sync_status     => descram_sync
        );

    decoder_inst : decoder_64b66b
        port map (
            clk             => clk,
            reset           => reset,
            rx_header       => descram_header,
            rx_data         => descram_data,
            rx_valid        => descram_valid,
            xgmii_rxd       => dec_rxd,
            xgmii_rxc       => dec_rxc,
            rx_data_valid   => dec_valid,
            decode_error    => dec_error
        );

    -- Output mapping
    xgmii_rxd <= dec_rxd;
    xgmii_rxc <= dec_rxc;
    xgmii_rx_valid <= dec_valid;

    ----------------------------------------------------------------------------
    -- Delay Pipeline for Comparison
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            -- Shift delay registers
            for i in 7 downto 1 loop
                txd_delay(i) <= txd_delay(i-1);
                txc_delay(i) <= txc_delay(i-1);
                valid_delay(i) <= valid_delay(i-1);
            end loop;
            txd_delay(0) <= xgmii_txd;
            txc_delay(0) <= xgmii_txc;
            valid_delay(0) <= '1';
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Output Verification
    -- Note: Skip first few blocks due to scrambler warmup
    ----------------------------------------------------------------------------
    process(clk)
        variable expected_txd : std_logic_vector(63 downto 0);
        variable expected_txc : std_logic_vector(7 downto 0);
        variable blocks_seen : integer := 0;
        constant WARMUP_BLOCKS : integer := 2;  -- Skip first 2 blocks for scrambler warmup
    begin
        if rising_edge(clk) then
            if reset = '0' and dec_valid = '1' and valid_delay(PIPELINE_DELAY) = '1' then
                blocks_seen := blocks_seen + 1;
                expected_txd := txd_delay(PIPELINE_DELAY);
                expected_txc := txc_delay(PIPELINE_DELAY);

                -- Skip warmup blocks, then compare
                if blocks_seen > WARMUP_BLOCKS then
                    if dec_rxd = expected_txd and dec_rxc = expected_txc then
                        pass_count <= pass_count + 1;
                    else
                        error_count <= error_count + 1;
                        report "MISMATCH at test " & integer'image(test_count) &
                               " Expected TXD=" & to_hstring(expected_txd) &
                               " TXC=" & to_hstring(expected_txc) &
                               " Got RXD=" & to_hstring(dec_rxd) &
                               " RXC=" & to_hstring(dec_rxc)
                            severity warning;
                    end if;
                else
                    -- During warmup, don't count as pass or error
                    report "Warmup block " & integer'image(blocks_seen) & " (skipped)" severity note;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Main Test Stimulus
    ----------------------------------------------------------------------------
    process
        -- Idle frame (all control, idle characters)
        procedure send_idle is
        begin
            xgmii_txd <= XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                        XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE;
            xgmii_txc <= "11111111";
            wait until rising_edge(clk);
            test_count <= test_count + 1;
        end procedure;

        -- Data frame (all data)
        procedure send_data(data : std_logic_vector(63 downto 0)) is
        begin
            xgmii_txd <= data;
            xgmii_txc <= "00000000";
            wait until rising_edge(clk);
            test_count <= test_count + 1;
        end procedure;

        -- Start frame in lane 0: S, D1-D7
        procedure send_start_lane0(d1_d7 : std_logic_vector(55 downto 0)) is
        begin
            xgmii_txd <= d1_d7 & XGMII_START;
            xgmii_txc <= "00000001";
            wait until rising_edge(clk);
            test_count <= test_count + 1;
        end procedure;

        -- Terminate frame at specified lane
        procedure send_terminate(lane : integer; data_before : std_logic_vector(55 downto 0)) is
            variable txd : std_logic_vector(63 downto 0);
            variable txc : std_logic_vector(7 downto 0);
        begin
            txd := (others => '0');
            txc := (others => '1');  -- Default all control

            case lane is
                when 0 =>
                    -- T in lane 0, idle in rest
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                          XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_TERM;
                    txc := "11111111";

                when 1 =>
                    -- D0, T, idle
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                          XGMII_IDLE & XGMII_IDLE & XGMII_TERM & data_before(7 downto 0);
                    txc := "11111110";

                when 2 =>
                    -- D0, D1, T, idle
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                          XGMII_IDLE & XGMII_TERM & data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "11111100";

                when 3 =>
                    -- D0, D1, D2, T, idle
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                          XGMII_TERM & data_before(23 downto 16) & data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "11111000";

                when 4 =>
                    -- D0-D3, T, idle
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_TERM &
                          data_before(31 downto 24) & data_before(23 downto 16) &
                          data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "11110000";

                when 5 =>
                    -- D0-D4, T, idle
                    txd := XGMII_IDLE & XGMII_IDLE & XGMII_TERM & data_before(39 downto 32) &
                          data_before(31 downto 24) & data_before(23 downto 16) &
                          data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "11100000";

                when 6 =>
                    -- D0-D5, T, idle
                    txd := XGMII_IDLE & XGMII_TERM & data_before(47 downto 40) & data_before(39 downto 32) &
                          data_before(31 downto 24) & data_before(23 downto 16) &
                          data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "11000000";

                when 7 =>
                    -- D0-D6, T
                    txd := XGMII_TERM & data_before(55 downto 48) & data_before(47 downto 40) &
                          data_before(39 downto 32) & data_before(31 downto 24) &
                          data_before(23 downto 16) & data_before(15 downto 8) & data_before(7 downto 0);
                    txc := "10000000";

                when others =>
                    null;
            end case;

            xgmii_txd <= txd;
            xgmii_txc <= txc;
            wait until rising_edge(clk);
            test_count <= test_count + 1;
        end procedure;

    begin
        -- Initialize
        report "=== Starting PCS Loopback Test ===" severity note;
        reset <= '1';
        xgmii_txd <= XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE &
                    XGMII_IDLE & XGMII_IDLE & XGMII_IDLE & XGMII_IDLE;
        xgmii_txc <= "11111111";
        wait for CLK_PERIOD * 10;
        reset <= '0';
        wait for CLK_PERIOD * 5;

        ------------------------------------------------------------------------
        -- Test Phase 1: Idle frames (scrambler sync warmup)
        ------------------------------------------------------------------------
        report "Phase 1: Idle frames (scrambler warmup)" severity note;
        test_phase <= 1;
        for i in 0 to 9 loop
            send_idle;
        end loop;

        ------------------------------------------------------------------------
        -- Test Phase 2: Pure data frames
        ------------------------------------------------------------------------
        report "Phase 2: Pure data frames" severity note;
        test_phase <= 2;

        -- Fixed patterns
        send_data(x"0123456789ABCDEF");
        send_data(x"FEDCBA9876543210");
        send_data(x"AAAAAAAAAAAAAAAA");
        send_data(x"5555555555555555");
        send_data(x"FFFFFFFFFFFFFFFF");
        send_data(x"0000000000000000");

        -- Random data
        for i in 0 to 19 loop
            send_data(rand_data);
        end loop;

        ------------------------------------------------------------------------
        -- Test Phase 3: Start of frame
        ------------------------------------------------------------------------
        report "Phase 3: Start of frame" severity note;
        test_phase <= 3;

        -- Start in lane 0 with various data
        send_start_lane0(x"01020304050607");
        send_data(x"1112131415161718");  -- Frame data
        send_data(x"2122232425262728");
        send_terminate(7, x"31323334353637");  -- End frame

        send_idle;
        send_idle;

        -- Another frame
        send_start_lane0(x"AABBCCDDEEFF00");
        send_data(x"DEADBEEFCAFEBABE");
        send_terminate(4, x"00000012345678");

        send_idle;
        send_idle;

        ------------------------------------------------------------------------
        -- Test Phase 4: All terminate positions
        ------------------------------------------------------------------------
        report "Phase 4: Terminate at all lane positions" severity note;
        test_phase <= 4;

        for lane in 0 to 7 loop
            send_idle;
            send_start_lane0(x"FFEEDDCCBBAA99");
            send_data(x"0102030405060708");
            send_terminate(lane, x"A1B2C3D4E5F607");
            send_idle;
        end loop;

        ------------------------------------------------------------------------
        -- Test Phase 5: Back-to-back frames
        ------------------------------------------------------------------------
        report "Phase 5: Back-to-back frames" severity note;
        test_phase <= 5;

        for frame in 0 to 4 loop
            send_start_lane0(x"F0F1F2F3F4F5F6");
            send_data(rand_data);
            send_data(rand_data);
            send_terminate(7, x"E0E1E2E3E4E5E6");
            send_idle;  -- Minimum IFG
        end loop;

        ------------------------------------------------------------------------
        -- Test Phase 6: Extended random stress test
        ------------------------------------------------------------------------
        report "Phase 6: Random stress test (100 frames)" severity note;
        test_phase <= 6;

        for frame in 0 to 99 loop
            send_idle;
            send_start_lane0(rand_data(55 downto 0));

            -- Random frame length (1-10 data beats)
            for beat in 0 to (frame mod 10) loop
                send_data(rand_data);
            end loop;

            -- Random terminate position
            send_terminate(frame mod 8, rand_data(55 downto 0));
        end loop;

        ------------------------------------------------------------------------
        -- Drain pipeline and report results
        ------------------------------------------------------------------------
        report "Draining pipeline..." severity note;
        for i in 0 to 20 loop
            send_idle;
        end loop;

        wait for CLK_PERIOD * 10;

        report "=== Test Complete ===" severity note;
        report "Total tests: " & integer'image(test_count) severity note;
        report "Passed: " & integer'image(pass_count) severity note;
        report "Errors: " & integer'image(error_count) severity note;

        if error_count = 0 then
            report "*** ALL TESTS PASSED ***" severity note;
        else
            report "*** TESTS FAILED ***" severity error;
        end if;

        -- End simulation
        wait for CLK_PERIOD * 10;
        assert false report "Simulation complete" severity failure;
    end process;

end sim;
