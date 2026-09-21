----------------------------------------------------------------------------------
-- Pulse_Sequencer -- cyclic four-lane row scheduler (single clock domain)
--
-- Each programmed row contains GAP, MASK, and DUR0..DUR3. GAP is measured in
-- clk cycles. A zero GAP is clamped to one cycle. TABLE_LENGTH is clamped to
-- [1, ROWS]. While enable='1', rows wrap cyclically from the last active row to 0.
--
-- Critical duration rule: durN changes ONLY when mask(N) fires. This keeps a
-- lane's duration stable until its next trigger and is required by the wrapper's
-- delayed stable-bus CDC protocol.
--
-- Table writes with an out-of-range full 32-bit row address are ignored; they do
-- not alias/wrap into another row. The table survives rst; rst resets execution
-- state only. Pause (enable=0) holds row_ptr but restarts the current row's GAP
-- count from zero when resumed.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Pulse_Sequencer is
    Generic ( ROWS : integer := 32 );
    Port ( clk    : in STD_LOGIC;
           rst    : in STD_LOGIC;    -- sync reset: row pointer -> 0, counters clear
           enable : in STD_LOGIC;    -- level: '1' = run/loop, '0' = paused (row pointer holds)

           table_length : in STD_LOGIC_VECTOR (31 downto 0);  -- active rows, 1..ROWS

           -- table write port - one row committed per wr_strobe pulse
           wr_row_addr : in STD_LOGIC_VECTOR (31 downto 0);
           wr_mask     : in STD_LOGIC_VECTOR (3 downto 0);
           wr_gap      : in STD_LOGIC_VECTOR (31 downto 0);
           wr_dur0     : in STD_LOGIC_VECTOR (31 downto 0);
           wr_dur1     : in STD_LOGIC_VECTOR (31 downto 0);
           wr_dur2     : in STD_LOGIC_VECTOR (31 downto 0);
           wr_dur3     : in STD_LOGIC_VECTOR (31 downto 0);
           wr_strobe   : in STD_LOGIC;

           -- current row pointer, for readback/debug
           row_ptr_out : out STD_LOGIC_VECTOR (31 downto 0);

           -- one-cycle pulse each time a row fires/advances (cyc_cnt reaches
           -- gap_eff-1), REGARDLESS of that row's mask - i.e. this fires even
           -- for an all-zero-mask guard row, since the row still "counts" as
           -- a table position visited. Added so an external wrapper (e.g. a
           -- single hardware-trigger-fires-one-full-pass wrapper) can count
           -- exactly table_length_eff row-visits to detect "one full lap of
           -- the table complete" without needing to duplicate this file's
           -- internal gap/table_length clamp logic or peek at row_ptr_out
           -- and guess at wrap-vs-still-running (which is ambiguous when
           -- table_length_eff = 1, since row_ptr_out never leaves 0).
           row_advance : out STD_LOGIC;

           -- per-target outputs
           trig0 : out STD_LOGIC; dur0 : out STD_LOGIC_VECTOR (31 downto 0);
           trig1 : out STD_LOGIC; dur1 : out STD_LOGIC_VECTOR (31 downto 0);
           trig2 : out STD_LOGIC; dur2 : out STD_LOGIC_VECTOR (31 downto 0);
           trig3 : out STD_LOGIC; dur3 : out STD_LOGIC_VECTOR (31 downto 0) );
end Pulse_Sequencer;

architecture arch_imp of Pulse_Sequencer is

    function clog2_min1(n : integer) return integer is
        variable v : integer := n - 1;
        variable r : integer := 0;
    begin
        while v > 0 loop
            v := v / 2;
            r := r + 1;
        end loop;
        if r < 1 then return 1; else return r; end if;
    end function;

    constant ROW_BITS : integer := clog2_min1(ROWS);

    type mask_array_t is array (0 to ROWS-1) of STD_LOGIC_VECTOR (3 downto 0);
    type word_array_t is array (0 to ROWS-1) of STD_LOGIC_VECTOR (31 downto 0);

    signal mask_tbl : mask_array_t := (others => (others => '0'));
    signal gap_tbl  : word_array_t := (others => (others => '0'));
    signal dur0_tbl : word_array_t := (others => (others => '0'));
    signal dur1_tbl : word_array_t := (others => (others => '0'));
    signal dur2_tbl : word_array_t := (others => (others => '0'));
    signal dur3_tbl : word_array_t := (others => (others => '0'));

    signal row_ptr : unsigned (ROW_BITS-1 downto 0) := (others => '0');
    signal cyc_cnt : unsigned (31 downto 0) := (others => '0');

    signal row_idx     : integer range 0 to ROWS-1;

    -- registered duration outputs (see fix note below) - hold the OLD row's
    -- durations, updated on the same clock edge and using the same
    -- pre-advance row_idx as trig0..3, so a target sampling dur0..3 on the
    -- cycle its own trigN is high always sees the row that fired it, never
    -- the row after
    signal dur0_r, dur1_r, dur2_r, dur3_r : STD_LOGIC_VECTOR (31 downto 0) := (others => '0');

    -- registered one-cycle row_advance pulse - see port declaration above.
    -- Set on the identical clock edge/branch that advances row_ptr, cleared
    -- every other cycle, exactly like trig0..3 above.
    signal row_advance_r : STD_LOGIC := '0';

    -- clamped-minimum-1 views of table_length/gap so an unwritten (all-zero)
    -- row or an unset table_length can't underflow the unsigned "-1" compare
    -- below into a huge number and hang the FSM in that row/gap forever
    signal table_length_eff : unsigned (31 downto 0);
    signal gap_eff          : unsigned (31 downto 0);

    -- ILA debug markers (see request "wire the ILAs" - ILA #1, s_axi_aclk
    -- domain): row_ptr and cyc_cnt aren't exposed as ports, so they need
    -- mark_debug set here directly to be probeable at all.
    attribute mark_debug : string;
    attribute mark_debug of row_ptr : signal is "true";
    attribute mark_debug of cyc_cnt : signal is "true";

begin

    assert ROWS >= 1
        report "Pulse_Sequencer: ROWS must be >= 1"
        severity failure;

    -- clamp to [1, ROWS]: a 0 (unwritten register) clamps up to 1, and
    -- anything >= ROWS (including a garbage/oversized value) clamps down to
    -- ROWS - row_idx physically cannot exceed ROWS-1, so without this
    -- upper clamp an oversized table_length would silently never trigger
    -- the intended wrap and the table would loop all ROWS rows instead of
    -- the requested subset with no error indication.
    table_length_eff <= to_unsigned(1, 32) when unsigned(table_length) = 0
                         else to_unsigned(ROWS, 32) when unsigned(table_length) > to_unsigned(ROWS, 32)
                         else unsigned(table_length);
    gap_eff <= to_unsigned(1, 32) when unsigned(gap_tbl(row_idx)) = 0
               else unsigned(gap_tbl(row_idx));

    row_idx    <= to_integer(row_ptr);

    -- table write: plain synchronous commit, same clock domain as the
    -- AXI-Lite writer that drives wr_*, so no CDC needed here
    TABLE_WRITE : process(clk)
    begin
        if rising_edge(clk) then
            if wr_strobe = '1' and unsigned(wr_row_addr) < to_unsigned(ROWS, 32) then
                mask_tbl(to_integer(unsigned(wr_row_addr))) <= wr_mask;
                gap_tbl(to_integer(unsigned(wr_row_addr)))  <= wr_gap;
                dur0_tbl(to_integer(unsigned(wr_row_addr))) <= wr_dur0;
                dur1_tbl(to_integer(unsigned(wr_row_addr))) <= wr_dur1;
                dur2_tbl(to_integer(unsigned(wr_row_addr))) <= wr_dur2;
                dur3_tbl(to_integer(unsigned(wr_row_addr))) <= wr_dur3;
            end if;
        end if;
    end process;

    -- row-advance FSM: waits gap_tbl(row_idx) cycles, fires whichever
    -- targets are masked in for one cycle, advances (wraps at table_length)
    ROW_FSM : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                row_ptr <= (others => '0');
                cyc_cnt <= (others => '0');
                trig0 <= '0'; trig1 <= '0'; trig2 <= '0'; trig3 <= '0';
                dur0_r <= (others => '0'); dur1_r <= (others => '0');
                dur2_r <= (others => '0'); dur3_r <= (others => '0');
                row_advance_r <= '0';
            elsif enable = '0' then
                cyc_cnt <= (others => '0');
                trig0 <= '0'; trig1 <= '0'; trig2 <= '0'; trig3 <= '0';
                row_advance_r <= '0';
                -- dur0_r..dur3_r intentionally NOT cleared here: they should
                -- keep holding whatever row last fired while paused, same
                -- as row_ptr holding its position
            else
                trig0 <= '0'; trig1 <= '0'; trig2 <= '0'; trig3 <= '0';
                row_advance_r <= '0';
                if cyc_cnt = gap_eff - 1 then
                    -- fix: latch dur0_r..3_r HERE, using this same
                    -- pre-advance row_idx, on the identical clock edge that
                    -- trig0..3 register - previously dur0..3 were driven by
                    -- a concurrent assignment tracking row_idx directly, so
                    -- by the time trigN was visible, row_idx (and therefore
                    -- durN) had already advanced to the NEXT row. Registering
                    -- them together here keeps durN aligned to the row that
                    -- actually fired trigN.
                    -- A lane's duration must remain stable until THAT lane's
                    -- next trigger.  Updating all four duration registers on every
                    -- row is unsafe because the wrapper intentionally delays trigger
                    -- CDC launch; an unrelated later row could otherwise overwrite
                    -- the duration before the earlier trigger reaches its gate.
                    if mask_tbl(row_idx)(0) = '1' then
                        dur0_r <= dur0_tbl(row_idx);
                        trig0  <= '1';
                    end if;
                    if mask_tbl(row_idx)(1) = '1' then
                        dur1_r <= dur1_tbl(row_idx);
                        trig1  <= '1';
                    end if;
                    if mask_tbl(row_idx)(2) = '1' then
                        dur2_r <= dur2_tbl(row_idx);
                        trig2  <= '1';
                    end if;
                    if mask_tbl(row_idx)(3) = '1' then
                        dur3_r <= dur3_tbl(row_idx);
                        trig3  <= '1';
                    end if;
                    cyc_cnt <= (others => '0');
                    row_advance_r <= '1';   -- fires even if this row's mask is all-zero
                    if row_idx >= to_integer(table_length_eff) - 1 then
                        row_ptr <= (others => '0');
                    else
                        row_ptr <= row_ptr + 1;
                    end if;
                else
                    cyc_cnt <= cyc_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- duration buses are the registered dur0_r..3_r latched inside ROW_FSM
    -- at the same edge trig0..3 fire (see fix note above) - guaranteed
    -- aligned to whichever row just triggered, exactly like
    -- active_length/capture_length being valid at the arm edge in
    -- TX_Zero_Gate / Capture_Gate
    dur0 <= dur0_r;
    dur1 <= dur1_r;
    dur2 <= dur2_r;
    dur3 <= dur3_r;

    row_ptr_out <= std_logic_vector(resize(row_ptr, 32));
    row_advance <= row_advance_r;

end arch_imp;
