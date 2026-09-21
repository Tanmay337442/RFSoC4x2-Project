----------------------------------------------------------------------------------
-- TX_Multi_Gate -- generalized DAC gate, datapath clock domain
--
-- Modes per accepted arm while CLOSED:
--   HW start + hw_active_length /= 0 : EXTERNAL mode, one window of that many
--                                      AXIS beats.
--   HW start + hw_active_length  = 0 : INTERNAL mode, walk local segment table.
--   SW start                         : INTERNAL mode (prevents stale HW length
--                                      from changing a manual bring-up run).
--   If HW and SW arrive together, HW has priority.
--
-- INTERNAL segment: ACTIVE_LEN beats of waveform/zero-on-underrun followed by
-- GAP_LEN beats of zero. GAP_LEN=0 transitions seamlessly to the next ACTIVE
-- segment. ACTIVE_LEN=0 is clamped to 1. NUM_SEGMENTS is clamped to
-- [1, SEGMENTS]. Out-of-range segment write addresses are ignored.
--
-- Output is a registered, always-present zero/data stream. While m_tready='0',
-- m_tdata is held exactly stable. Upstream waveform data is consumed only when
-- priming the next ACTIVE output beat; GAP/CLOSED do not drain the source.
-- Gate counts advance only on accepted RFDC output beats (m_tready='1').
-- There is one gate-clock pipeline beat from an accepted trigger to the first
-- ACTIVE output beat. A start received while not CLOSED is intentionally ignored.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity TX_Multi_Gate is
    Generic ( N        : integer := 256;   -- sample data width
              SEGMENTS : integer := 8 );  -- max table depth per arm
    Port ( clk : in STD_LOGIC;
           rst : in STD_LOGIC;    -- sync reset: FSM -> CLOSED. Table contents
                                   -- are NOT cleared (mirrors Pulse_Sequencer).

           num_segments : in STD_LOGIC_VECTOR (31 downto 0);  -- active segments
                                                                -- this run, 1..SEGMENTS,
                                                                -- latched on arm (INTERNAL
                                                                -- TABLE MODE only)

           hw_active_length : in STD_LOGIC_VECTOR (31 downto 0);  -- mode selector,
                                                                -- latched on arm.
                                                                -- /=0 -> EXTERNAL MODE,
                                                                -- one window this many
                                                                -- samples long.
                                                                --  =0 -> INTERNAL TABLE
                                                                -- MODE (num_segments/table).

           -- table write port - one segment committed per wr_strobe pulse
           wr_seg_addr   : in STD_LOGIC_VECTOR (31 downto 0);
           wr_active_len : in STD_LOGIC_VECTOR (31 downto 0);
           wr_gap_len    : in STD_LOGIC_VECTOR (31 downto 0);
           wr_strobe     : in STD_LOGIC;

           hw_start : in STD_LOGIC;   -- synchronized hardware trigger (pulse)
           sw_start : in STD_LOGIC;   -- AXI-Lite manual trigger, OR'd with hw_start

           s_tvalid : in  STD_LOGIC;                       -- from async FIFO (waveform)
           s_tdata  : in  STD_LOGIC_VECTOR (N-1 downto 0);
           s_tready : out STD_LOGIC;                       -- to async FIFO
           m_tvalid : out STD_LOGIC;                       -- to RFDC s00_axis - always '1'
           m_tdata  : out STD_LOGIC_VECTOR (N-1 downto 0);
           m_tready : in  STD_LOGIC;                       -- from RFDC s00_axis

           seg_idx_out : out STD_LOGIC_VECTOR (31 downto 0);  -- current running segment, debug
           active_out  : out STD_LOGIC );                     -- '1' any time a window (ACTIVE or GAP)
                                                                -- is in progress, debug
end TX_Multi_Gate;

architecture arch_imp of TX_Multi_Gate is

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

    constant SEG_BITS : integer := clog2_min1(SEGMENTS);

    type seg_array_t is array (0 to SEGMENTS-1) of STD_LOGIC_VECTOR (31 downto 0);
    signal active_len_tbl : seg_array_t := (others => (others => '0'));
    signal gap_len_tbl    : seg_array_t := (others => (others => '0'));

    -- ARMED is used only if the RFDC output is stalled when a trigger arrives.
    -- It preserves the command until the first ACTIVE output word can be loaded.
    type phase_t is (CLOSED, ARMED, ACTIVE, GAP);
    signal phase   : phase_t := CLOSED;
    signal seg_idx : integer range 0 to SEGMENTS-1 := 0;

    signal num_segments_latched      : unsigned(31 downto 0) := to_unsigned(1, 32);
    signal ext_mode                  : STD_LOGIC := '0';
    signal hw_active_length_latched  : unsigned(31 downto 0) := (others => '0');
    signal samp_cnt                  : unsigned(31 downto 0) := (others => '0');
    signal gap_cnt                   : unsigned(31 downto 0) := (others => '0');

    signal num_segments_eff : unsigned(31 downto 0);
    signal active_len_eff   : unsigned(31 downto 0);

    -- Registered output stage.  m_tvalid is intentionally always high, so TDATA
    -- MUST be held stable whenever m_tready is low.  The previous combinational
    -- pass-through violated that rule during an RFDC stall.
    signal m_tdata_reg      : STD_LOGIC_VECTOR(N-1 downto 0) := (others => '0');
    signal load_active_next : STD_LOGIC := '0';
    signal arm_req          : STD_LOGIC;
    signal window_open_sig  : STD_LOGIC;

begin

    assert SEGMENTS >= 1
        report "TX_Multi_Gate: SEGMENTS must be >= 1"
        severity failure;

    num_segments_eff <= to_unsigned(1, 32) when num_segments_latched = 0
                         else to_unsigned(SEGMENTS, 32) when num_segments_latched > to_unsigned(SEGMENTS, 32)
                         else num_segments_latched;

    active_len_eff <= to_unsigned(1, 32) when unsigned(active_len_tbl(seg_idx)) = 0
                       else unsigned(active_len_tbl(seg_idx));

    TABLE_WRITE : process(clk)
    begin
        if rising_edge(clk) then
            if wr_strobe = '1' and unsigned(wr_seg_addr) < to_unsigned(SEGMENTS, 32) then
                active_len_tbl(to_integer(unsigned(wr_seg_addr))) <= wr_active_len;
                gap_len_tbl(to_integer(unsigned(wr_seg_addr)))    <= wr_gap_len;
            end if;
        end if;
    end process;

    -- Both inputs are already clean one-cycle pulses in clk domain.  Do not edge
    -- detect them again: a second edge detector is unnecessary and introduces
    -- reset/history corner cases.  If both arrive together, hardware start wins
    -- the mode-selection priority below and the event is intentionally one arm.
    arm_req <= hw_start or sw_start;

    -- Determine whether the output word AFTER the next accepted RFDC beat must
    -- contain ACTIVE data.  s_tready therefore requests exactly the upstream word
    -- that will populate the registered output for that next ACTIVE slot.
    NEXT_ACTIVE : process(phase, arm_req, m_tready, ext_mode,
                          samp_cnt, hw_active_length_latched,
                          active_len_eff, gap_len_tbl, gap_cnt,
                          seg_idx, num_segments_eff)
    begin
        load_active_next <= '0';
        if m_tready = '1' then
            case phase is
                when CLOSED =>
                    if arm_req = '1' then
                        load_active_next <= '1';
                    end if;

                when ARMED =>
                    load_active_next <= '1';

                when ACTIVE =>
                    if ext_mode = '1' then
                        if samp_cnt < hw_active_length_latched - 1 then
                            load_active_next <= '1';
                        end if;
                    else
                        if samp_cnt < active_len_eff - 1 then
                            load_active_next <= '1';
                        elsif unsigned(gap_len_tbl(seg_idx)) = 0 and
                              seg_idx < to_integer(num_segments_eff) - 1 then
                            -- Last beat of this segment, no gap, another segment:
                            -- consume the first word of the next segment now so
                            -- the output remains seamless after this edge.
                            load_active_next <= '1';
                        end if;
                    end if;

                when GAP =>
                    -- GAP is only entered for a nonzero gap length.
                    if gap_cnt = unsigned(gap_len_tbl(seg_idx)) - 1 and
                       seg_idx < to_integer(num_segments_eff) - 1 then
                        -- Last zero beat of the gap: prime next ACTIVE segment.
                        load_active_next <= '1';
                    end if;
            end case;
        end if;
    end process;

    -- Upstream is consumed only when a word is needed for the NEXT ACTIVE output
    -- slot and the RFDC is accepting the current registered output slot.
    s_tready <= load_active_next and (not rst);

    OUTPUT_REG : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                m_tdata_reg <= (others => '0');
            elsif m_tready = '1' then
                if load_active_next = '1' and s_tvalid = '1' then
                    m_tdata_reg <= s_tdata;
                else
                    -- CLOSED/GAP, or ACTIVE underrun: deterministic zero fill.
                    m_tdata_reg <= (others => '0');
                end if;
            end if;
            -- If m_tready='0', hold TDATA exactly stable as AXI4-Stream requires.
        end if;
    end process;

    GATE_FSM : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase                    <= CLOSED;
                seg_idx                  <= 0;
                samp_cnt                 <= (others => '0');
                gap_cnt                  <= (others => '0');
                num_segments_latched     <= to_unsigned(1, 32);
                ext_mode                 <= '0';
                hw_active_length_latched <= (others => '0');
            else
                case phase is
                    when CLOSED =>
                        if arm_req = '1' then
                            seg_idx              <= 0;
                            samp_cnt             <= (others => '0');
                            gap_cnt              <= (others => '0');
                            num_segments_latched <= unsigned(num_segments);

                            -- Manual software start always means INTERNAL TABLE
                            -- mode.  This prevents a stale sequencer hw length from
                            -- changing a later manual bring-up shot.  If HW and SW
                            -- pulses coincide, HW wins intentionally.
                            if hw_start = '1' then
                                hw_active_length_latched <= unsigned(hw_active_length);
                                if unsigned(hw_active_length) = 0 then
                                    ext_mode <= '0';
                                else
                                    ext_mode <= '1';
                                end if;
                            else
                                hw_active_length_latched <= (others => '0');
                                ext_mode <= '0';
                            end if;

                            if m_tready = '1' then
                                -- First ACTIVE word is loaded by OUTPUT_REG on
                                -- this same edge and transferred on the next edge.
                                phase <= ACTIVE;
                            else
                                phase <= ARMED;
                            end if;
                        end if;

                    when ARMED =>
                        -- Command is already latched; wait without consuming input
                        -- until the stalled RFDC can accept the current zero word.
                        if m_tready = '1' then
                            phase    <= ACTIVE;
                            samp_cnt <= (others => '0');
                        end if;

                    when ACTIVE =>
                        if m_tready = '1' then
                            if ext_mode = '1' then
                                if samp_cnt = hw_active_length_latched - 1 then
                                    samp_cnt <= (others => '0');
                                    phase    <= CLOSED;
                                else
                                    samp_cnt <= samp_cnt + 1;
                                end if;
                            else
                                if samp_cnt = active_len_eff - 1 then
                                    samp_cnt <= (others => '0');
                                    if unsigned(gap_len_tbl(seg_idx)) = 0 then
                                        if seg_idx >= to_integer(num_segments_eff) - 1 then
                                            phase <= CLOSED;
                                        else
                                            seg_idx <= seg_idx + 1;
                                            -- stay ACTIVE; OUTPUT_REG has already
                                            -- loaded the next segment's first word.
                                        end if;
                                    else
                                        phase   <= GAP;
                                        gap_cnt <= (others => '0');
                                    end if;
                                else
                                    samp_cnt <= samp_cnt + 1;
                                end if;
                            end if;
                        end if;

                    when GAP =>
                        if m_tready = '1' then
                            if gap_cnt = unsigned(gap_len_tbl(seg_idx)) - 1 then
                                gap_cnt <= (others => '0');
                                if seg_idx >= to_integer(num_segments_eff) - 1 then
                                    phase <= CLOSED;
                                else
                                    seg_idx <= seg_idx + 1;
                                    phase   <= ACTIVE;
                                end if;
                            else
                                gap_cnt <= gap_cnt + 1;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    m_tvalid <= not rst;
    m_tdata  <= m_tdata_reg;

    window_open_sig <= '1' when phase /= CLOSED else '0';
    seg_idx_out <= std_logic_vector(to_unsigned(seg_idx, 32));
    active_out  <= window_open_sig;

end arch_imp;
