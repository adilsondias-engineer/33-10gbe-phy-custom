--------------------------------------------------------------------------------
-- Block Lock FSM for 10GBASE-R PCS
--
-- Implements the block synchronization state machine from IEEE 802.3 Clause 49.
--
-- The 64B/66B sync header pattern ("01" or "10") is used to find block boundaries.
-- Invalid headers ("00" or "11") indicate misalignment or errors.
--
-- State Machine:
--   LOCK_INIT   -> Start, no lock
--   RESET_CNT   -> Reset counters after slip
--   WAIT_BLOCK  -> Wait for new block (edge of rx_header_valid or rx_datavalid)
--   TEST_SH     -> Test sync header validity
--   VALID_SH    -> Valid header counted
--   INVALID_SH  -> Invalid header, prepare for slip
--   SLIP        -> Request gearbox slip
--   SLIP_WAIT   -> Wait for gearbox to settle after slip
--   ST_LOCKED   -> Locked, monitor for loss of lock
--
-- Lock Criteria:
--   - 64 consecutive valid sync headers = LOCK
--   - 16 invalid sync headers in 64-block window = UNLOCK
--
-- Note: Uses rx_datavalid as new-block indicator since in 64-bit gearbox mode,
-- rx_header_valid may be continuously high. The FSM waits for falling edge
-- then rising edge of rx_datavalid to ensure a new block is present.
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

entity block_lock_fsm is
    generic (
        -- Number of valid headers required for lock (Clause 49: 64)
        LOCK_THRESHOLD      : integer := 64;
        -- Number of invalid headers to lose lock (Clause 49: 16 in 64)
        UNLOCK_THRESHOLD    : integer := 16;
        -- Window size for invalid header counting
        WINDOW_SIZE         : integer := 64;
        -- Cycles to wait after slip for gearbox to settle
        SLIP_WAIT_CYCLES    : integer := 8
    );
    port (
        clk                 : in  std_logic;
        reset               : in  std_logic;

        -- Input from GTX receiver
        rx_header           : in  std_logic_vector(1 downto 0);
        rx_header_valid     : in  std_logic;  -- High when header is valid
        rx_datavalid        : in  std_logic;  -- High when data is valid (new block indicator)

        -- Gearbox control
        slip_request        : out std_logic;  -- Request 1-bit slip

        -- Status outputs
        block_lock          : out std_logic;  -- Block lock achieved
        header_error_count  : out std_logic_vector(7 downto 0);  -- For debug
        state_debug         : out std_logic_vector(2 downto 0);  -- FSM state

        -- Debug: last tested header value (00/01/10/11)
        debug_last_header   : out std_logic_vector(1 downto 0);
        
        -- Debug: FSM internal counters for lock acquisition progress
        debug_valid_cnt     : out std_logic_vector(6 downto 0);  -- Valid header count in window
        debug_invalid_cnt   : out std_logic_vector(5 downto 0);  -- Invalid header count in window
        debug_window_cnt    : out std_logic_vector(6 downto 0)   -- Window position counter
    );
end block_lock_fsm;

architecture rtl of block_lock_fsm is

    -- FSM states (added WAIT_BLOCK and SLIP_WAIT)
    type state_type is (
        LOCK_INIT,      -- Initial state, no lock
        RESET_CNT,      -- Reset counters
        WAIT_BLOCK,     -- Wait for new block (rising edge of datavalid)
        TEST_SH,        -- Test sync header
        VALID_SH,       -- Valid header counted (one cycle only)
        INVALID_SH,     -- Invalid header (one cycle only)
        SLIP,           -- Request slip
        SLIP_WAIT,      -- Wait for gearbox to settle after slip
        ST_LOCKED       -- Locked state
    );
    signal state, next_state : state_type;

    -- Counters
    signal sh_valid_cnt     : unsigned(6 downto 0) := (others => '0');  -- Valid header count
    signal sh_invalid_cnt   : unsigned(5 downto 0) := (others => '0');  -- Invalid header count
    signal window_cnt       : unsigned(6 downto 0) := (others => '0');  -- Window counter
    signal slip_wait_cnt    : unsigned(3 downto 0) := (others => '0');  -- Slip settle counter

    -- Header validity check
    signal header_valid     : std_logic;
    signal header_error     : std_logic;

    -- Lock status register
    signal locked           : std_logic := '0';

    -- Slip pulse generation
    signal slip_pulse       : std_logic := '0';

    -- Edge detection for new block
    signal datavalid_d      : std_logic := '0';
    signal datavalid_rise   : std_logic;

    -- Latch header when datavalid rises (ensures stable header during TEST_SH)
    signal rx_header_lat    : std_logic_vector(1 downto 0) := "00";

begin

    ----------------------------------------------------------------------------
    -- Edge Detection for New Block
    -- Detect rising edge of rx_datavalid to identify new 66-bit blocks
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                datavalid_d <= '0';
            else
                datavalid_d <= rx_datavalid;
            end if;
        end if;
    end process;

    datavalid_rise <= rx_datavalid and not datavalid_d;

    ----------------------------------------------------------------------------
    -- Latch Header on Datavalid Rising Edge
    -- Tests the header corresponding to this block
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                rx_header_lat <= "00";
            elsif datavalid_rise = '1' then
                -- Latch header regardless of GTX header_valid signal
                -- The FSM determines validity, not the GTX (fixes chicken-and-egg)
                -- Latch header directly (no transformation)
                rx_header_lat <= rx_header;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Sync Header Validity Check
    -- Valid: "01" (data) or "10" (control)
    -- Invalid: "00" or "11"
    ----------------------------------------------------------------------------
    header_valid <= '1' when (rx_header_lat = "01" or rx_header_lat = "10") else '0';
    header_error <= not header_valid;

    ----------------------------------------------------------------------------
    -- FSM State Register
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= LOCK_INIT;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM Next State Logic
    ----------------------------------------------------------------------------
    process(state, rx_header, rx_header_valid, rx_datavalid, datavalid_rise, header_valid,
            sh_valid_cnt, sh_invalid_cnt, slip_wait_cnt)
    begin
        next_state <= state;

        case state is
            when LOCK_INIT =>
                -- Start: go to reset counters
                next_state <= RESET_CNT;

            when RESET_CNT =>
                -- Counters reset, go wait for first block
                next_state <= WAIT_BLOCK;

            when WAIT_BLOCK =>
                -- Wait for rising edge of datavalid (new block)
                -- NOTE: Do NOT wait for rx_header_valid! GTX header_valid is only
                -- high when GTX thinks it has valid alignment. Must test
                -- headers even on misaligned data to generate slip requests.
                -- IEEE 802.3 Clause 49 tests EVERY sync header, not just GTX-validated ones.
                if datavalid_rise = '1' then
                    next_state <= TEST_SH;
                end if;

            when TEST_SH =>
                -- Test the sync header (latched on datavalid rise)
                if header_valid = '1' then
                    next_state <= VALID_SH;
                else
                    next_state <= INVALID_SH;
                end if;

            when VALID_SH =>
                -- Valid header counted - check for lock or go wait for next
                if sh_valid_cnt >= LOCK_THRESHOLD - 1 then
                    -- Lock achieved!
                    next_state <= ST_LOCKED;
                else
                    -- Wait for next block
                    next_state <= WAIT_BLOCK;
                end if;

            when INVALID_SH =>
                -- Invalid header - need to slip
                next_state <= SLIP;

            when SLIP =>
                -- Issue slip pulse, then wait for settle
                next_state <= SLIP_WAIT;

            when SLIP_WAIT =>
                -- Wait for gearbox to settle after slip
                if slip_wait_cnt >= SLIP_WAIT_CYCLES - 1 then
                    next_state <= RESET_CNT;
                end if;

            when ST_LOCKED =>
                -- Locked state - monitor for unlock condition
                -- Test every block with valid data (don't depend on GTX header_valid)
                if datavalid_rise = '1' then
                    -- Check header on each new block
                    -- Note: Checks the CURRENT header here (not latched) since
                    -- the latch hasn't updated yet on this cycle
                    if rx_header /= "01" and rx_header /= "10" then
                        -- Invalid header while locked
                        if sh_invalid_cnt >= UNLOCK_THRESHOLD - 1 then
                            -- Too many errors, lose lock
                            next_state <= LOCK_INIT;
                        end if;
                    end if;
                end if;

            when others =>
                next_state <= LOCK_INIT;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Counter Logic
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sh_valid_cnt <= (others => '0');
                sh_invalid_cnt <= (others => '0');
                window_cnt <= (others => '0');
                slip_wait_cnt <= (others => '0');
                locked <= '0';
                slip_pulse <= '0';
            else
                slip_pulse <= '0';  -- Default: no slip

                case state is
                    when LOCK_INIT =>
                        locked <= '0';

                    when RESET_CNT =>
                        -- Reset all counters
                        sh_valid_cnt <= (others => '0');
                        sh_invalid_cnt <= (others => '0');
                        window_cnt <= (others => '0');
                        slip_wait_cnt <= (others => '0');

                    when WAIT_BLOCK =>
                        -- Just waiting, no counter action
                        null;

                    when TEST_SH =>
                        -- Header being tested, no counter action here
                        null;

                    when VALID_SH =>
                        -- Increment valid counter (only once per VALID_SH entry)
                        if sh_valid_cnt < LOCK_THRESHOLD then
                            sh_valid_cnt <= sh_valid_cnt + 1;
                        end if;

                    when INVALID_SH =>
                        -- Count invalid headers (for debug)
                        if sh_invalid_cnt < 63 then
                            sh_invalid_cnt <= sh_invalid_cnt + 1;
                        end if;

                    when SLIP =>
                        -- Generate slip pulse (one cycle only)
                        slip_pulse <= '1';
                        slip_wait_cnt <= (others => '0');

                    when SLIP_WAIT =>
                        -- Count wait cycles
                        if slip_wait_cnt < SLIP_WAIT_CYCLES then
                            slip_wait_cnt <= slip_wait_cnt + 1;
                        end if;

                    when ST_LOCKED =>
                        -- Locked: track errors in sliding window
                        locked <= '1';

                        -- Track on every block with valid data (consistent with FSM logic)
                        if datavalid_rise = '1' then
                            if window_cnt >= WINDOW_SIZE - 1 then
                                -- Window boundary: reset counters unconditionally.
                                -- The combinational unlock check still fires this cycle
                                -- using the OLD sh_invalid_cnt value, so the 16th invalid
                                -- header at the boundary still triggers unlock correctly.
                                window_cnt <= (others => '0');
                                sh_invalid_cnt <= (others => '0');
                            else
                                -- Normal: advance window, count invalid headers
                                window_cnt <= window_cnt + 1;
                                if rx_header /= "01" and rx_header /= "10" then
                                    if sh_invalid_cnt < 63 then
                                        sh_invalid_cnt <= sh_invalid_cnt + 1;
                                    end if;
                                end if;
                            end if;
                        end if;

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Output Assignments
    ----------------------------------------------------------------------------
    slip_request <= slip_pulse;
    block_lock <= locked;
    header_error_count <= std_logic_vector(resize(sh_invalid_cnt, 8));
    debug_last_header <= rx_header_lat;  -- Show last tested header (00/01/10/11)
    debug_valid_cnt <= std_logic_vector(sh_valid_cnt);    -- Valid header count
    debug_invalid_cnt <= std_logic_vector(sh_invalid_cnt); -- Invalid header count
    debug_window_cnt <= std_logic_vector(window_cnt);      -- Window position

    -- Debug state encoding (reorganized to fit 3 bits with ST_LOCKED visible)
    -- States: 0=INIT, 1=RESET, 2=WAIT, 3=TEST, 4=VALID, 5=SLIP/INVALID, 6=SLIP_WAIT, 7=LOCKED
    with state select state_debug <=
        "000" when LOCK_INIT,
        "001" when RESET_CNT,
        "010" when WAIT_BLOCK,
        "011" when TEST_SH,
        "100" when VALID_SH,
        "101" when INVALID_SH,    -- Combined with SLIP for debug (both lead to slip)
        "101" when SLIP,          -- Combined with INVALID_SH
        "110" when SLIP_WAIT,
        "111" when ST_LOCKED,     -- Most important - must be visible!
        "000" when others;

end rtl;
