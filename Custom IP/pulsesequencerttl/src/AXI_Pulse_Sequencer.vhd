-- V4: Vivado-compatible named reset signals are used in all port maps.
----------------------------------------------------------------------------------
-- AXI_Pulse_Sequencer -- internal-trigger bring-up / cyclic scheduler
--                        + optional TTL external-trigger single-pass mode
--
-- AXI-Lite register map (byte offsets):
--   0x00 ROW_SEL           RW
--   0x04 MASK              RW  bits[3:0] = lanes 3..0
--   0x08 GAP                RW  sequencer-clock cycles before row fires; 0 -> 1
--   0x0C DUR0                RW
--   0x10 DUR1                RW
--   0x14 DUR2                RW
--   0x18 DUR3                RW
--   0x1C COMMIT_ROW          WO  any write commits staging registers
--   0x20 TABLE_LENGTH        RW  clamped to [1, ROWS]
--   0x24 ENABLE              RW  bit0; table loops while 1 (ignored in TTL mode)
--   0x28 RESET_PULSE         WO  any write resets row/counters and source delay pipes
--   0x2C ROW_PTR             RO
--   0x30 CDC_OVERRUN         RW1C bits[3:0]; unsafe same-lane triggers are SUPPRESSED
--   0x34 TTL_ARM             WO  any write sets sticky ttl_armed_reg (new)
--   0x38 TTL_MODE            RW  bit0: 1 = hardware-edge-triggered single-pass mode
--   0x3C TTL_STATUS          RO  bit0 ARMED, bit1 RUNNING, bit2 RUN_DONE (sticky)
--   0x40 TTL_STATUS_CLEAR    WO  any write clears RUN_DONE
--   0x44 TTL_EDGE_COUNT      RO  accepted trig_in edges since last reset (saturates)
--
-- TTL trigger mode (new) - "one external edge fires exactly one full pass":
--   * trig_in is a plain top-level, fully asynchronous port with NO known
--     source clock domain - e.g. a DG4000 Sync/Trig-Out pulse, already
--     leveled to this bank's IOSTANDARD by external hardware before it
--     reaches this pin. It is synchronized here with xpm_cdc_single using
--     SRC_INPUT_REG=>0 (no source register stage), which is AMD's documented
--     pattern for synchronizing a signal with no defined source clock -
--     src_clk is wired to s_axi_aclk only to satisfy the port; it performs no
--     source-side registration. A rising edge is then detected on the
--     synchronized signal.
--   * TTL_MODE bit0 = 0 (default, power-up/reset state): identical to
--     today's behavior. reg_enable(0) (0x24 ENABLE) drives the sequencer
--     directly, table_length wraps continuously while ENABLE=1, trig_in is
--     ignored entirely. Existing internal-trigger bring-up flows do not
--     change, and no rebuild is needed to keep using them.
--   * TTL_MODE bit0 = 1: reg_enable(0) is ignored. The sequencer core's
--     enable is now driven ONLY by an internal ttl_running state:
--       1. Software writes TTL_ARM (0x34) once it has finished re-arming
--          every resource this pass will use (same "confirm idle, THEN arm"
--          discipline already used for SEQ_ENABLE in the working
--          software-timed notebooks - this is just handing the final "go"
--          decision to an external edge instead of a Python write).
--       2. The next accepted rising edge on trig_in (only accepted while
--          armed AND not already running) atomically: clears TTL_ARM
--          (self-clearing - a second edge before software re-arms is simply
--          ignored, not queued), issues a one-cycle reset to the
--          Pulse_Sequencer core ONLY (row_ptr/cyc_cnt clear - this does NOT
--          touch CDC_OVERRUN or dur_hold, which is deliberate: a hardware
--          trigger should not silently wipe diagnostic history the way a
--          manual RESET_PULSE does), and asserts ttl_running.
--       3. The core runs from row 0. Pulse_Sequencer's new row_advance
--          output (one pulse per row VISITED, regardless of that row's
--          mask - see Pulse_Sequencer.vhd) is counted; once the count
--          reaches table_length_eff (replicated here with the identical
--          clamp-to-[1,ROWS] formula Pulse_Sequencer applies internally,
--          since that internal value isn't otherwise observable from
--          outside), ttl_running deasserts and RUN_DONE (TTL_STATUS bit2)
--          sets sticky. This correctly handles a 1-row table too (row_ptr
--          never visibly leaves 0 in that case; row_advance still pulses
--          once and the count still reaches 1).
--       4. seq_ready_out (new output, intended for the sync_out top-level
--          port) is a registered, glitch-free LEVEL = TTL_MODE(0) AND
--          ttl_armed_reg AND NOT ttl_running - i.e. exactly "genuinely
--          ready for the next hardware edge". It goes high once armed and
--          stays high (no timed pulse-width to manage on the DG4000 side)
--          until an edge is accepted, then drops. Program the DG4000 to
--          fire on the RISING EDGE of this level.
--   * Per-lane safe-spacing (CDC_OVERRUN, existing) still applies underneath
--     TTL mode exactly as before - TTL mode only changes what starts a pass,
--     not what happens to any individual lane's trigger once running.
--   * This wrapper does not implement per-row external triggering (each row
--     waiting on its own edge instead of counting GAP cycles). That would
--     require restructuring Pulse_Sequencer's row FSM itself, not just this
--     wrapper, and is a separate, larger change from single-pass TTL mode.
--
-- The row FSM runs in s_axi_aclk (~100 MHz). Each output lane crosses into its
-- own destination clock domain (nominally 15.36 MHz in this design).
--
-- Command CDC contract:
--   * Pulse_Sequencer changes a lane's duration only when that lane fires.
--   * This wrapper snapshots each accepted lane duration into durN_hold and keeps
--     it unchanged until that lane's next accepted trigger.
--   * xpm_cdc_array_single carries that quasi-static held word. AMD documents
--     array_single as independent-bit synchronization, NOT an atomic correlated
--     bus primitive; correctness therefore relies on the stable-bus protocol.
--   * The trigger is delayed CDC_LAUNCH_DELAY source cycles, then crosses through
--     xpm_cdc_pulse with a registered destination output, giving the held word a
--     large settling interval before the gate samples it.
--   * Same-lane triggers closer than MIN_SAFE_GAP_CYCLES are suppressed and set
--     CDC_OVERRUN instead of being launched into the pulse CDC.
--
-- XPM reset requirement: with RST_USED=1, s_axi_aresetn and each destination
-- aresetnN must be asserted together long enough to fully reset XPM_CDC_PULSE.
-- For DEST_SYNC_FF=4, ~100 MHz source and 15.36 MHz destination, AMD's formula is
-- about 0.411 us minimum overlap. Derive these resets from coordinated reset
-- logic and keep clocks running/stable through reset release.
--
-- Load/modify the row table only with ENABLE=0 (or, in TTL mode, only while
-- ttl_running='0').
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library xpm;
use xpm.vcomponents.all;

entity AXI_Pulse_Sequencer is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        -- widened from 6 to 7 to fit the new TTL_ARM/TTL_MODE/TTL_STATUS/
        -- TTL_STATUS_CLEAR/TTL_EDGE_COUNT registers at 0x34-0x44; all
        -- pre-existing register offsets (0x00-0x30) are unchanged.
        C_S_AXI_ADDR_WIDTH  : integer := 7;
        ROWS : integer := 32;

        -- CDC_LAUNCH_DELAY is a fixed source-domain command latency used to
        -- let each held duration word settle before its trigger enters the pulse
        -- CDC. At ~100 MHz, 32 cycles is ~320 ns. This delay ADDS fixed latency
        -- from row-fire to gate trigger; it does not change row-to-row scheduling.
        -- MIN_SAFE_GAP_CYCLES is the conservative same-lane source-trigger guard.
        -- Unsafe repeats are suppressed and reported in CDC_OVERRUN.
        CDC_LAUNCH_DELAY    : integer := 32;
        MIN_SAFE_GAP_CYCLES : integer := 64
        );
    Port (
        -- per-lane destination clocks - each lane's trigN/durN is
        -- synchronized independently into its own aclkN domain, since the
        -- four targets (TX_Multi_Gate x2, Capture_Gate x2) may sit on
        -- separate, unrelated clock nets. Tie two or more of these together
        -- at the instantiation site if the corresponding targets really do
        -- share one clock.
        aclk0    : in std_logic; aresetn0 : in std_logic;
        aclk1    : in std_logic; aresetn1 : in std_logic;
        aclk2    : in std_logic; aresetn2 : in std_logic;
        aclk3    : in std_logic; aresetn3 : in std_logic;

        s_axi_aclk    : in std_logic;
        s_axi_aresetn : in std_logic;

        -- four target lanes, each synchronized to its own aclkN
        hw_start0 : out std_logic; hw_len0 : out std_logic_vector(31 downto 0);
        hw_start1 : out std_logic; hw_len1 : out std_logic_vector(31 downto 0);
        hw_start2 : out std_logic; hw_len2 : out std_logic_vector(31 downto 0);
        hw_start3 : out std_logic; hw_len3 : out std_logic_vector(31 downto 0);

        -- new: external hardware trigger input (e.g. DG4000 Sync/Trig-Out,
        -- already level-shifted to this bank's IOSTANDARD off-chip). Plain
        -- top-level port, no defined source clock domain - see file header.
        -- Ignored entirely unless TTL_MODE bit0 = 1.
        trig_in : in std_logic := '0';

        -- new: registered "ready for the next trig_in edge" level, intended
        -- for the sync_out top-level port feeding the DG4000. See file
        -- header for exact semantics. Always '0' while TTL_MODE bit0 = 0.
        seq_ready_out : out std_logic;

        s_axi_awaddr    : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_awprot    : in std_logic_vector(2 downto 0);
        s_axi_awvalid   : in std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_wstrb     : in std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        s_axi_wvalid    : in std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in std_logic;
        s_axi_araddr    : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_arprot    : in std_logic_vector(2 downto 0);
        s_axi_arvalid   : in std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in std_logic
        );
end AXI_Pulse_Sequencer;

architecture arch_imp of AXI_Pulse_Sequencer is

    component Pulse_Sequencer is
        Generic ( ROWS : integer := 32 );
        Port ( clk    : in STD_LOGIC;
               rst    : in STD_LOGIC;
               enable : in STD_LOGIC;
               table_length : in STD_LOGIC_VECTOR (31 downto 0);
               wr_row_addr : in STD_LOGIC_VECTOR (31 downto 0);
               wr_mask     : in STD_LOGIC_VECTOR (3 downto 0);
               wr_gap      : in STD_LOGIC_VECTOR (31 downto 0);
               wr_dur0     : in STD_LOGIC_VECTOR (31 downto 0);
               wr_dur1     : in STD_LOGIC_VECTOR (31 downto 0);
               wr_dur2     : in STD_LOGIC_VECTOR (31 downto 0);
               wr_dur3     : in STD_LOGIC_VECTOR (31 downto 0);
               wr_strobe   : in STD_LOGIC;
               row_ptr_out : out STD_LOGIC_VECTOR (31 downto 0);
               row_advance : out STD_LOGIC;
               trig0 : out STD_LOGIC; dur0 : out STD_LOGIC_VECTOR (31 downto 0);
               trig1 : out STD_LOGIC; dur1 : out STD_LOGIC_VECTOR (31 downto 0);
               trig2 : out STD_LOGIC; dur2 : out STD_LOGIC_VECTOR (31 downto 0);
               trig3 : out STD_LOGIC; dur3 : out STD_LOGIC_VECTOR (31 downto 0) );
    end component;

    -- AXI-Lite bookkeeping
    signal axi_awaddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_awready : std_logic := '0';
    signal axi_wready  : std_logic := '0';
    signal axi_bresp   : std_logic_vector(1 downto 0) := "00";
    signal axi_bvalid  : std_logic := '0';
    signal axi_araddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_arready : std_logic := '0';
    signal axi_rdata   : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal axi_rresp   : std_logic_vector(1 downto 0) := "00";
    signal axi_rvalid  : std_logic := '0';
    signal slv_reg_wren : std_logic;
    signal slv_reg_rden : std_logic;
    signal aw_en         : std_logic := '1';

    -- register file (s_axi_aclk domain)
    signal reg_row_sel    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_mask       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_gap        : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_dur0       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_dur1       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_dur2       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_dur3       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_table_len  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_enable     : std_logic_vector(31 downto 0) := (others => '0');
    signal commit_strobe  : std_logic := '0';
    signal reset_strobe   : std_logic := '0';
    signal row_ptr_sig    : std_logic_vector(31 downto 0);

    -- sequencer outputs, s_axi_aclk domain
    signal trig0_s, trig1_s, trig2_s, trig3_s : std_logic;
    signal dur0_s, dur1_s, dur2_s, dur3_s : std_logic_vector(31 downto 0);
    signal row_advance_s : std_logic;   -- from Pulse_Sequencer core

    -- CDC launch-delay shift registers (s_axi_aclk domain) - give durN's
    -- continuous array_single crossing a head start over the (delayed)
    -- trigN pulse CDC. See FIX note in the file header.
    type delay_sr_t is array (0 to CDC_LAUNCH_DELAY-1) of std_logic;
    signal trig0_dly_sr, trig1_dly_sr, trig2_dly_sr, trig3_dly_sr : delay_sr_t := (others => '0');
    signal trig0_dly, trig1_dly, trig2_dly, trig3_dly : std_logic;

    -- min-safe-gap tracking + sticky overrun flags, s_axi_aclk domain, one
    -- per lane. Counts cycles since this lane's last (undelayed) trigN
    -- pulse; a new trigN before the counter reaches MIN_SAFE_GAP_CYCLES
    -- sets that lane's sticky bit rather than silently risking a
    -- merged/dropped pulse in xpm_cdc_pulse. Unsafe repeats are suppressed.
    type gap_cnt_t is array (0 to 3) of integer range 0 to MIN_SAFE_GAP_CYCLES;
    signal lane_gap_cnt     : gap_cnt_t := (others => MIN_SAFE_GAP_CYCLES);
    signal trig_vec         : std_logic_vector(3 downto 0);
    signal trig_safe_vec    : std_logic_vector(3 downto 0);
    signal dur0_hold, dur1_hold, dur2_hold, dur3_hold : std_logic_vector(31 downto 0) := (others => '0');
    signal cdc_overrun_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal cdc_overrun_wr   : std_logic_vector(31 downto 0) := (others => '0');

    -- TTL trigger mode state (new). All in the s_axi_aclk domain except
    -- trig_in itself, which is synchronized by CDC_TRIGIN below.
    signal ttl_mode_reg     : std_logic_vector(31 downto 0) := (others => '0');
    signal ttl_arm_wr       : std_logic := '0';
    signal ttl_mode_wr      : std_logic := '0';
    signal ttl_status_clear_wr : std_logic := '0';

    signal trig_in_sync     : std_logic;                -- post-CDC, s_axi_aclk domain
    signal trig_in_prev     : std_logic := '0';          -- for edge detect

    signal ttl_armed_reg    : std_logic := '0';
    signal ttl_running      : std_logic := '0';
    signal ttl_run_done_reg : std_logic := '0';
    signal ttl_rows_fired   : unsigned(31 downto 0) := (others => '0');
    signal ttl_edge_count_reg : std_logic_vector(31 downto 0) := (others => '0');
    signal ttl_start_pulse  : std_logic := '0';
    signal ttl_table_len_eff : unsigned(31 downto 0);
    signal ttl_status_reg   : std_logic_vector(31 downto 0);

    signal seq_enable_core  : std_logic;   -- actual enable fed to Pulse_Sequencer
    signal seq_core_rst     : std_logic;   -- actual rst fed to Pulse_Sequencer
    signal seq_ready_out_reg : std_logic := '0';

    -- ILA debug markers (ILA #1, s_axi_aclk domain) - confirms the
    -- sequencer itself is firing lane 2 (ADC1/Capture_Gate) correctly with
    -- the right duration, before the signal ever crosses the CDC.
    attribute mark_debug : string;
    attribute mark_debug of row_ptr_sig   : signal is "true";
    attribute mark_debug of trig2_s       : signal is "true";
    attribute mark_debug of dur2_s        : signal is "true";
    attribute mark_debug of commit_strobe : signal is "true";
    attribute mark_debug of reg_enable    : signal is "true";
    attribute mark_debug of ttl_armed_reg : signal is "true";
    attribute mark_debug of ttl_running   : signal is "true";
    attribute mark_debug of trig_in_sync  : signal is "true";
    attribute mark_debug of row_advance_s : signal is "true";

    -- Named active-high resets for XPM port maps.  Vivado requires these
    -- reset actuals to be signal names rather than expressions (`not ...`).
    signal rst_axi   : std_logic;
    signal rst_aclk0 : std_logic;
    signal rst_aclk1 : std_logic;
    signal rst_aclk2 : std_logic;
    signal rst_aclk3 : std_logic;

begin

    rst_axi   <= not s_axi_aresetn;
    rst_aclk0 <= not aresetn0;
    rst_aclk1 <= not aresetn1;
    rst_aclk2 <= not aresetn2;
    rst_aclk3 <= not aresetn3;

    assert CDC_LAUNCH_DELAY >= 2
        report "AXI_Pulse_Sequencer: CDC_LAUNCH_DELAY must be >= 2"
        severity failure;
    assert MIN_SAFE_GAP_CYCLES >= CDC_LAUNCH_DELAY + 2
        report "AXI_Pulse_Sequencer: MIN_SAFE_GAP_CYCLES is too small for the launch pipeline"
        severity failure;

    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= axi_bresp;
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= axi_rresp;
    s_axi_rvalid  <= axi_rvalid;

    -- AWREADY / AWADDR latch.  aw_en prevents accepting a second write
    -- transaction until the response for the previous one has completed.
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_awready <= '0';
                axi_awaddr  <= (others => '0');
                aw_en       <= '1';
            else
                if axi_awready = '0' and s_axi_awvalid = '1' and
                   s_axi_wvalid = '1' and aw_en = '1' then
                    axi_awready <= '1';
                    axi_awaddr  <= s_axi_awaddr;
                    aw_en       <= '0';
                else
                    axi_awready <= '0';
                    if s_axi_bready = '1' and axi_bvalid = '1' then
                        aw_en <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- WREADY is coupled to the same single-outstanding write acceptance.
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_wready <= '0';
            elsif axi_wready = '0' and s_axi_wvalid = '1' and
                  s_axi_awvalid = '1' and aw_en = '1' then
                axi_wready <= '1';
            else
                axi_wready <= '0';
            end if;
        end if;
    end process;

    slv_reg_wren <= axi_wready and s_axi_wvalid and axi_awready and s_axi_awvalid;

    -- register write decode + one-cycle strobes for COMMIT_ROW / RESET_PULSE
    -- / TTL_ARM / TTL_STATUS_CLEAR
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                reg_row_sel   <= (others => '0');
                reg_mask      <= (others => '0');
                reg_gap       <= (others => '0');
                reg_dur0      <= (others => '0');
                reg_dur1      <= (others => '0');
                reg_dur2      <= (others => '0');
                reg_dur3      <= (others => '0');
                reg_table_len <= (others => '0');
                reg_enable    <= (others => '0');
                ttl_mode_reg  <= (others => '0');
                commit_strobe <= '0';
                reset_strobe  <= '0';
                cdc_overrun_wr <= (others => '0');
                ttl_arm_wr          <= '0';
                ttl_mode_wr         <= '0';
                ttl_status_clear_wr <= '0';
            else
                commit_strobe  <= '0';
                reset_strobe   <= '0';
                cdc_overrun_wr <= (others => '0');
                ttl_arm_wr          <= '0';
                ttl_mode_wr         <= '0';
                ttl_status_clear_wr <= '0';
                if slv_reg_wren = '1' then
                    case axi_awaddr(6 downto 2) is
                        when "00000" => reg_row_sel   <= s_axi_wdata;             -- 0x00
                        when "00001" => reg_mask      <= s_axi_wdata;             -- 0x04
                        when "00010" => reg_gap       <= s_axi_wdata;             -- 0x08
                        when "00011" => reg_dur0      <= s_axi_wdata;             -- 0x0C
                        when "00100" => reg_dur1      <= s_axi_wdata;             -- 0x10
                        when "00101" => reg_dur2      <= s_axi_wdata;             -- 0x14
                        when "00110" => reg_dur3      <= s_axi_wdata;             -- 0x18
                        when "00111" => commit_strobe <= '1';                     -- 0x1C
                        when "01000" => reg_table_len <= s_axi_wdata;             -- 0x20
                        when "01001" => reg_enable    <= s_axi_wdata;             -- 0x24
                        when "01010" => reset_strobe  <= '1';                     -- 0x28
                        when "01100" => cdc_overrun_wr <= s_axi_wdata;            -- 0x30, write-1-to-clear
                        when "01101" => ttl_arm_wr          <= '1';               -- 0x34 TTL_ARM
                        when "01110" => ttl_mode_reg <= s_axi_wdata; ttl_mode_wr <= '1'; -- 0x38 TTL_MODE
                        when "10000" => ttl_status_clear_wr <= '1';               -- 0x40 TTL_STATUS_CLEAR
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Reject a trigger that violates the per-lane safe-spacing contract.
    -- This is stronger than merely flagging it: an unsafe command is not
    -- launched into the CDC and therefore cannot corrupt an earlier in-flight
    -- duration/trigger pair.
    trig_vec <= trig3_s & trig2_s & trig1_s & trig0_s;
    GEN_SAFE_TRIG : for i in 0 to 3 generate
        trig_safe_vec(i) <= trig_vec(i) when lane_gap_cnt(i) >= MIN_SAFE_GAP_CYCLES else '0';
    end generate;

    -- Per-lane source holding registers.  A duration changes only when that
    -- lane has an ACCEPTED trigger; it then remains stable until the next
    -- accepted trigger for the same lane.
    CMD_HOLD : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' or reset_strobe = '1' then
                dur0_hold <= (others => '0');
                dur1_hold <= (others => '0');
                dur2_hold <= (others => '0');
                dur3_hold <= (others => '0');
            else
                if trig_safe_vec(0) = '1' then dur0_hold <= dur0_s; end if;
                if trig_safe_vec(1) = '1' then dur1_hold <= dur1_s; end if;
                if trig_safe_vec(2) = '1' then dur2_hold <= dur2_s; end if;
                if trig_safe_vec(3) = '1' then dur3_hold <= dur3_s; end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- CDC launch-delay shift registers: hold trigN back CDC_LAUNCH_DELAY
    -- s_axi_aclk cycles before it reaches xpm_cdc_pulse. Each accepted
    -- lane trigger first snapshots that lane's duration into durN_hold; the word
    -- then remains unchanged until that lane's next accepted trigger. The delay
    -- gives the quasi-static array_single crossing several destination clocks to
    -- settle before the registered destination pulse is emitted. This is a
    -- stable-bus timing contract, not an atomic guarantee from array_single.
    ------------------------------------------------------------------
    DELAY_SR : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' or reset_strobe = '1' then
                trig0_dly_sr <= (others => '0');
                trig1_dly_sr <= (others => '0');
                trig2_dly_sr <= (others => '0');
                trig3_dly_sr <= (others => '0');
            else
                trig0_dly_sr <= trig_safe_vec(0) & trig0_dly_sr(0 to CDC_LAUNCH_DELAY-2);
                trig1_dly_sr <= trig_safe_vec(1) & trig1_dly_sr(0 to CDC_LAUNCH_DELAY-2);
                trig2_dly_sr <= trig_safe_vec(2) & trig2_dly_sr(0 to CDC_LAUNCH_DELAY-2);
                trig3_dly_sr <= trig_safe_vec(3) & trig3_dly_sr(0 to CDC_LAUNCH_DELAY-2);
            end if;
        end if;
    end process;
    trig0_dly <= trig0_dly_sr(CDC_LAUNCH_DELAY-1);
    trig1_dly <= trig1_dly_sr(CDC_LAUNCH_DELAY-1);
    trig2_dly <= trig2_dly_sr(CDC_LAUNCH_DELAY-1);
    trig3_dly <= trig3_dly_sr(CDC_LAUNCH_DELAY-1);

    ------------------------------------------------------------------
    -- min-safe-gap tracking, one counter per lane, s_axi_aclk domain
    -- (same domain trigN_s is generated in - no CDC needed for this
    -- check). See FIX note in the file header + CDC_OVERRUN register.
    ------------------------------------------------------------------
    OVERRUN_TRACK : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' or reset_strobe = '1' then
                lane_gap_cnt    <= (others => MIN_SAFE_GAP_CYCLES);
                cdc_overrun_reg <= (others => '0');
            else
                -- write-1-to-clear evaluated first in program order so a
                -- freshly-detected overrun on this same cycle (below) always
                -- wins over a stale clear request racing it - a real
                -- overrun is never allowed to be silently cleared before
                -- it's observed.
                for i in 0 to 3 loop
                    if cdc_overrun_wr(i) = '1' then
                        cdc_overrun_reg(i) <= '0';
                    end if;
                end loop;
                for i in 0 to 3 loop
                    if trig_vec(i) = '1' then
                        if lane_gap_cnt(i) < MIN_SAFE_GAP_CYCLES then
                            cdc_overrun_reg(i) <= '1';
                        end if;
                        lane_gap_cnt(i) <= 0;
                    elsif lane_gap_cnt(i) < MIN_SAFE_GAP_CYCLES then
                        lane_gap_cnt(i) <= lane_gap_cnt(i) + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- BVALID
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_bvalid <= '0';
                axi_bresp  <= "00";
            elsif slv_reg_wren = '1' then
                axi_bvalid <= '1';
                axi_bresp  <= "00";
            elsif s_axi_bready = '1' and axi_bvalid = '1' then
                axi_bvalid <= '0';
            end if;
        end if;
    end process;

    -- ARREADY / ARADDR latch
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_arready <= '0';
                axi_araddr  <= (others => '0');
            elsif axi_arready = '0' and s_axi_arvalid = '1' and axi_rvalid = '0' then
                axi_arready <= '1';
                axi_araddr  <= s_axi_araddr;
            else
                axi_arready <= '0';
            end if;
        end if;
    end process;

    slv_reg_rden <= axi_arready and s_axi_arvalid and not axi_rvalid;

    -- RVALID / RDATA
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_rvalid <= '0';
                axi_rresp  <= "00";
            elsif slv_reg_rden = '1' then
                axi_rvalid <= '1';
                axi_rresp  <= "00";
            elsif s_axi_rready = '1' and axi_rvalid = '1' then
                axi_rvalid <= '0';
            end if;
        end if;
    end process;

    -- TTL_STATUS composite readback: bit0 ARMED, bit1 RUNNING, bit2 RUN_DONE
    ttl_status_reg <= (0 => ttl_armed_reg,
                       1 => ttl_running,
                       2 => ttl_run_done_reg,
                       others => '0');

    process(axi_araddr, reg_row_sel, reg_mask, reg_gap, reg_dur0, reg_dur1, reg_dur2,
            reg_dur3, reg_table_len, reg_enable, row_ptr_sig, cdc_overrun_reg,
            ttl_mode_reg, ttl_status_reg, ttl_edge_count_reg)
    begin
        case axi_araddr(6 downto 2) is
            when "00000" => axi_rdata <= reg_row_sel;
            when "00001" => axi_rdata <= reg_mask;
            when "00010" => axi_rdata <= reg_gap;
            when "00011" => axi_rdata <= reg_dur0;
            when "00100" => axi_rdata <= reg_dur1;
            when "00101" => axi_rdata <= reg_dur2;
            when "00110" => axi_rdata <= reg_dur3;
            when "01000" => axi_rdata <= reg_table_len;
            when "01001" => axi_rdata <= reg_enable;
            when "01011" => axi_rdata <= row_ptr_sig;                            -- 0x2C
            when "01100" => axi_rdata <= cdc_overrun_reg;                        -- 0x30
            when "01110" => axi_rdata <= ttl_mode_reg;                           -- 0x38
            when "01111" => axi_rdata <= ttl_status_reg;                         -- 0x3C
            when "10001" => axi_rdata <= ttl_edge_count_reg;                     -- 0x44
            when others => axi_rdata <= (others => '0');
        end case;
    end process;

    -- trig_in has NO defined source clock domain - SRC_INPUT_REG=>0 is
    -- AMD's documented pattern for synchronizing a signal with no source
    -- clock; src_clk is wired here only to satisfy the port and performs no
    -- source-side registration in that configuration.
    CDC_TRIGIN : xpm_cdc_single
        generic map ( DEST_SYNC_FF => 4, INIT_SYNC_FF => 1, SRC_INPUT_REG => 0, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_in => trig_in,
                   dest_clk => s_axi_aclk, dest_out => trig_in_sync );

    -- Mirrors Pulse_Sequencer's own table_length clamp (0 -> 1, > ROWS ->
    -- ROWS) so this wrapper can count "one full pass" without that internal
    -- clamped value being exposed as a port.
    ttl_table_len_eff <= to_unsigned(1, 32) when unsigned(reg_table_len) = 0
                          else to_unsigned(ROWS, 32) when unsigned(reg_table_len) > to_unsigned(ROWS, 32)
                          else unsigned(reg_table_len);

    -- Actual enable/rst fed to the sequencer core. In TTL mode, reg_enable(0)
    -- (0x24) is ignored entirely; the core only ever runs under ttl_running.
    -- seq_core_rst is intentionally separate from reset_strobe: a TTL-started
    -- run must clear row_ptr/cyc_cnt in the core, but must NOT also wipe
    -- CDC_OVERRUN/dur_hold history the way a manual RESET_PULSE does - see
    -- file header.
    seq_enable_core <= ttl_running when ttl_mode_reg(0) = '1' else reg_enable(0);
    seq_core_rst    <= reset_strobe or ttl_start_pulse;

    TTL_RUN_FSM : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                ttl_armed_reg      <= '0';
                ttl_running        <= '0';
                ttl_run_done_reg   <= '0';
                ttl_rows_fired     <= (others => '0');
                ttl_edge_count_reg <= (others => '0');
                ttl_start_pulse    <= '0';
                trig_in_prev       <= '0';
            elsif reset_strobe = '1' then
                -- Manual RESET_PULSE aborts any in-flight TTL run and
                -- requires a fresh TTL_ARM before the next edge is honored -
                -- same "don't fire on stale state after a reset" posture as
                -- everywhere else in this file.
                ttl_armed_reg      <= '0';
                ttl_running        <= '0';
                ttl_run_done_reg   <= '0';
                ttl_rows_fired     <= (others => '0');
                ttl_edge_count_reg <= (others => '0');
                ttl_start_pulse    <= '0';
            else
                ttl_start_pulse <= '0';                 -- one-cycle pulse, default low
                trig_in_prev    <= trig_in_sync;

                if ttl_arm_wr = '1' then
                    ttl_armed_reg <= '1';
                end if;
                if ttl_status_clear_wr = '1' then
                    ttl_run_done_reg <= '0';
                end if;

                if ttl_mode_reg(0) = '1' and ttl_armed_reg = '1' and ttl_running = '0'
                   and trig_in_sync = '1' and trig_in_prev = '0' then
                    -- Accepted edge: consume the arm token, start one pass.
                    ttl_armed_reg   <= '0';
                    ttl_running     <= '1';
                    ttl_rows_fired  <= (others => '0');
                    ttl_start_pulse <= '1';
                    if unsigned(ttl_edge_count_reg) /= x"FFFFFFFF" then
                        ttl_edge_count_reg <= std_logic_vector(unsigned(ttl_edge_count_reg) + 1);
                    end if;
                elsif ttl_running = '1' and row_advance_s = '1' then
                    -- One more table row visited (row_advance fires
                    -- regardless of that row's mask - see Pulse_Sequencer.vhd).
                    if ttl_rows_fired + 1 >= ttl_table_len_eff then
                        ttl_running      <= '0';
                        ttl_run_done_reg <= '1';
                        ttl_rows_fired   <= (others => '0');
                    else
                        ttl_rows_fired <= ttl_rows_fired + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Registered, glitch-free "ready for the next trig_in edge" level - see
    -- file header. '0' whenever TTL mode is off.
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                seq_ready_out_reg <= '0';
            else
                seq_ready_out_reg <= ttl_mode_reg(0) and ttl_armed_reg and (not ttl_running);
            end if;
        end if;
    end process;
    seq_ready_out <= seq_ready_out_reg;

    SEQ_CORE : Pulse_Sequencer
        generic map (ROWS => ROWS)
        port map (
            clk          => s_axi_aclk,
            rst          => seq_core_rst,
            enable       => seq_enable_core,
            table_length => reg_table_len,
            wr_row_addr  => reg_row_sel,
            wr_mask      => reg_mask(3 downto 0),
            wr_gap       => reg_gap,
            wr_dur0      => reg_dur0,
            wr_dur1      => reg_dur1,
            wr_dur2      => reg_dur2,
            wr_dur3      => reg_dur3,
            wr_strobe    => commit_strobe,
            row_ptr_out  => row_ptr_sig,
            row_advance  => row_advance_s,
            trig0 => trig0_s, dur0 => dur0_s,
            trig1 => trig1_s, dur1 => dur1_s,
            trig2 => trig2_s, dur2 => dur2_s,
            trig3 => trig3_s, dur3 => dur3_s
        );

    -- CDC: s_axi_aclk -> aclkN, independently per lane. See FIX note in the
    -- file header for the full reasoning. Summary:
    --   * an accepted trigger snapshots durN_s into a per-lane durN_hold;
    --     xpm_cdc_array_single continuously synchronizes that stable held word.
    --   * trigN is delayed before xpm_cdc_pulse, which uses a registered
    --     destination output. The duration therefore has a large settling margin.
    --   * array_single does not guarantee atomic correlated-bus transfer; this
    --     design relies on durN_hold staying unchanged around the command.
    --   * with RST_USED=1, the source and destination resets must be asserted
    --     together long enough to satisfy AMD's XPM_CDC_PULSE reset requirement.
    CDC_LEN0 : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk => s_axi_aclk, src_in => dur0_hold,
                   dest_clk => aclk0,     dest_out => hw_len0 );
    CDC_TRIG0 : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => trig0_dly,
                   dest_clk => aclk0,     dest_rst => rst_aclk0,     dest_pulse => hw_start0 );

    CDC_LEN1 : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk => s_axi_aclk, src_in => dur1_hold,
                   dest_clk => aclk1,     dest_out => hw_len1 );
    CDC_TRIG1 : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => trig1_dly,
                   dest_clk => aclk1,     dest_rst => rst_aclk1,     dest_pulse => hw_start1 );

    CDC_LEN2 : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk => s_axi_aclk, src_in => dur2_hold,
                   dest_clk => aclk2,     dest_out => hw_len2 );
    CDC_TRIG2 : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => trig2_dly,
                   dest_clk => aclk2,     dest_rst => rst_aclk2,     dest_pulse => hw_start2 );

    CDC_LEN3 : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk => s_axi_aclk, src_in => dur3_hold,
                   dest_clk => aclk3,     dest_out => hw_len3 );
    CDC_TRIG3 : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => trig3_dly,
                   dest_clk => aclk3,     dest_rst => rst_aclk3,     dest_pulse => hw_start3 );

end arch_imp;
