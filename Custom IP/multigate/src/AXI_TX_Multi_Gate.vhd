-- V4: Vivado-compatible named reset signals are used in all port maps.
----------------------------------------------------------------------------------
-- AXI_TX_Multi_Gate -- AXI-Lite wrapper for generalized DAC gate
--
-- Defaults: 256-bit AXIS = 8 complex samples/beat at a 15.36 MHz gate clock.
-- All programmed lengths are AXIS BEATS, not scalar I/Q values.
--
-- Register map (byte offsets):
--   0x00 SEG_SEL        RW
--   0x04 ACTIVE_LEN     RW  beats; internal zero is clamped to 1
--   0x08 GAP_LEN        RW  beats; zero means seamless/no gap
--   0x0C COMMIT_SEG     WO  any write; accepted only after CDC cooldown
--   0x10 NUM_SEGMENTS   RW  core clamps to [1, SEGMENTS]
--   0x14 SW_START       WO  any write; manual start always uses INTERNAL mode
--   0x18 SEG_PTR        RO
--   0x1C STATUS         RO/RW1C: bit0 BUSY, bit1 CONTROL_OVERRUN
--                              write bit1=1 to clear CONTROL_OVERRUN
--
-- Segment fields are snapshotted on an accepted COMMIT, held stable, and the
-- commit pulse is delayed before CDC. Too-close COMMIT/SW_START operations are
-- suppressed and set STATUS.bit1. This prevents one source-side command from
-- overwriting configuration still settling for an earlier command.
--
-- xpm_cdc_array_single is used only as a quasi-static stable-bus crossing; it
-- is not treated as an atomic correlated-word primitive. Pulse CDC outputs are
-- registered and simulation misuse checks are enabled.
--
-- XPM_CDC_PULSE reset rule: source and destination resets must overlap long
-- enough for the macro to reset fully (about 0.411 us for the clocks/depth used
-- here). Configuration should be completed before hardware triggering begins.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library xpm;
use xpm.vcomponents.all;

entity AXI_TX_Multi_Gate is
    generic (
        C_S_AXIS_DATA_WIDTH : integer := 256;
        C_S_AXI_DATA_WIDTH  : integer := 32;
        C_S_AXI_ADDR_WIDTH  : integer := 5;
        SEGMENTS                  : integer := 8;
        CFG_LAUNCH_DELAY          : integer := 32;
        CFG_MIN_COMMIT_GAP_CYCLES : integer := 64
        );
    Port (
        aclk    : in std_logic;
        aresetn : in std_logic;

        s_axi_aclk    : in std_logic;
        s_axi_aresetn : in std_logic;

        -- plain external inputs from AXI_Pulse_Sequencer, already in the
        -- aclk domain. NOT AXI signals. hw_active_length picks this arm
        -- event's mode: /=0 -> one externally-timed window this many
        -- samples long; =0 -> internal preloaded segment table.
        hw_start         : in std_logic;
        hw_active_length : in std_logic_vector(31 downto 0);

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
        s_axi_rready    : in std_logic;

        s_axis_re_tvalid : in STD_LOGIC;
        s_axis_re_tdata  : in STD_LOGIC_VECTOR (C_S_AXIS_DATA_WIDTH-1 downto 0);
        s_axis_re_tready : out STD_LOGIC;

        m_axis_re_tvalid : out STD_LOGIC;
        m_axis_re_tdata  : out STD_LOGIC_VECTOR (C_S_AXIS_DATA_WIDTH-1 downto 0);
        m_axis_re_tready : in STD_LOGIC);

end AXI_TX_Multi_Gate;

architecture arch_imp of AXI_TX_Multi_Gate is

    component TX_Multi_Gate is
        Generic ( N        : integer := 256;
                  SEGMENTS : integer := 8 );
        Port ( clk : in STD_LOGIC;
               rst : in STD_LOGIC;

               num_segments : in STD_LOGIC_VECTOR (31 downto 0);
               hw_active_length : in STD_LOGIC_VECTOR (31 downto 0);

               wr_seg_addr   : in STD_LOGIC_VECTOR (31 downto 0);
               wr_active_len : in STD_LOGIC_VECTOR (31 downto 0);
               wr_gap_len    : in STD_LOGIC_VECTOR (31 downto 0);
               wr_strobe     : in STD_LOGIC;

               hw_start : in STD_LOGIC;
               sw_start : in STD_LOGIC;

               s_tvalid : in  STD_LOGIC;
               s_tdata  : in  STD_LOGIC_VECTOR (N-1 downto 0);
               s_tready : out STD_LOGIC;
               m_tvalid : out STD_LOGIC;
               m_tdata  : out STD_LOGIC_VECTOR (N-1 downto 0);
               m_tready : in  STD_LOGIC;

               seg_idx_out : out STD_LOGIC_VECTOR (31 downto 0);
               active_out  : out STD_LOGIC );
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
    signal reg_seg_sel      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_active_len   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_gap_len      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_num_segments : std_logic_vector(31 downto 0) := (others => '0');
    signal commit_strobe    : std_logic := '0';
    signal sw_start_strobe  : std_logic := '0';  -- FIX: replaces reg_sw_start level register

    -- Snapshot each segment command at COMMIT so subsequent AXI register writes
    -- cannot race the data associated with the delayed commit pulse.
    signal snap_seg_sel    : std_logic_vector(31 downto 0) := (others => '0');
    signal snap_active_len : std_logic_vector(31 downto 0) := (others => '0');
    signal snap_gap_len    : std_logic_vector(31 downto 0) := (others => '0');
    type commit_delay_t is array (0 to CFG_LAUNCH_DELAY-1) of std_logic;
    signal commit_delay_sr : commit_delay_t := (others => '0');
    signal commit_delayed  : std_logic := '0';
    signal cfg_gap_cnt      : integer range 0 to CFG_MIN_COMMIT_GAP_CYCLES := CFG_MIN_COMMIT_GAP_CYCLES;
    signal cfg_overrun      : std_logic := '0';

    -- readback registers, s_axi_aclk domain, CDC'd back from aclk
    signal seg_ptr_readback : std_logic_vector(31 downto 0);
    signal status_readback  : std_logic_vector(31 downto 0);

    -- synchronized copies, aclk domain
    signal wr_seg_addr_cdc   : std_logic_vector(31 downto 0);
    signal wr_active_len_cdc : std_logic_vector(31 downto 0);
    signal wr_gap_len_cdc    : std_logic_vector(31 downto 0);
    signal num_segments_cdc  : std_logic_vector(31 downto 0);
    signal wr_strobe_cdc     : std_logic;
    signal sw_start_cdc      : std_logic;

    -- core outputs, aclk domain
    signal seg_idx_sig : std_logic_vector(31 downto 0);
    signal active_sig  : std_logic;

    -- Named active-high reset signals. Vivado/XPM requires reset port-map
    -- actuals to be signal names rather than expressions such as `not aresetn`.
    signal rst_axi  : std_logic;
    signal rst_aclk : std_logic;

begin

    rst_axi  <= not s_axi_aresetn;
    rst_aclk <= not aresetn;

    assert CFG_LAUNCH_DELAY >= 2
        report "AXI_TX_Multi_Gate: CFG_LAUNCH_DELAY must be >= 2"
        severity failure;
    assert CFG_MIN_COMMIT_GAP_CYCLES >= CFG_LAUNCH_DELAY + 2
        report "AXI_TX_Multi_Gate: CFG_MIN_COMMIT_GAP_CYCLES is too small"
        severity failure;

    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= axi_bresp;
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= axi_rresp;
    s_axi_rvalid  <= axi_rvalid;

    -- Single-outstanding AXI-Lite write channel.
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

    -- Register write decode.  COMMIT_SEG is accepted only when the previous
    -- snapshot has had enough time to cross and be consumed in the aclk domain.
    -- An unsafe back-to-back commit is rejected (never allowed to overwrite the
    -- in-flight snapshot) and STATUS bit1 latches high until W1C at 0x1C.
    process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                reg_seg_sel       <= (others => '0');
                reg_active_len    <= (others => '0');
                reg_gap_len       <= (others => '0');
                reg_num_segments  <= (others => '0');
                commit_strobe     <= '0';
                sw_start_strobe   <= '0';
                snap_seg_sel      <= (others => '0');
                snap_active_len   <= (others => '0');
                snap_gap_len      <= (others => '0');
                cfg_gap_cnt       <= CFG_MIN_COMMIT_GAP_CYCLES;
                cfg_overrun       <= '0';
            else
                commit_strobe   <= '0';
                sw_start_strobe <= '0';

                if cfg_gap_cnt < CFG_MIN_COMMIT_GAP_CYCLES then
                    cfg_gap_cnt <= cfg_gap_cnt + 1;
                end if;

                if slv_reg_wren = '1' then
                    case axi_awaddr(4 downto 2) is
                        when "000" => reg_seg_sel      <= s_axi_wdata;      -- 0x00
                        when "001" => reg_active_len   <= s_axi_wdata;      -- 0x04
                        when "010" => reg_gap_len      <= s_axi_wdata;      -- 0x08
                        when "011" =>                                                -- 0x0C COMMIT
                            if cfg_gap_cnt >= CFG_MIN_COMMIT_GAP_CYCLES then
                                commit_strobe   <= '1';
                                snap_seg_sel    <= reg_seg_sel;
                                snap_active_len <= reg_active_len;
                                snap_gap_len    <= reg_gap_len;
                                cfg_gap_cnt     <= 0;
                            else
                                cfg_overrun <= '1';
                            end if;
                        when "100" =>                                                -- 0x10
                            reg_num_segments <= s_axi_wdata;
                            -- num_segments crosses continuously; restart the
                            -- settling/cooldown interval before a manual start.
                            cfg_gap_cnt <= 0;
                        when "101" =>                                                -- 0x14 SW_START
                            -- Do not launch a manual start while a recent table
                            -- commit/num-segment update is still settling, or too
                            -- soon after a previous software-start pulse.
                            if cfg_gap_cnt >= CFG_MIN_COMMIT_GAP_CYCLES then
                                sw_start_strobe <= '1';
                                cfg_gap_cnt <= 0;
                            else
                                cfg_overrun <= '1';
                            end if;
                        when "111" =>                                               -- 0x1C STATUS W1C bit1
                            if s_axi_wdata(1) = '1' then
                                cfg_overrun <= '0';
                            end if;
                        when others => null;
                    end case;
                end if;
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

    process(axi_araddr, reg_seg_sel, reg_active_len, reg_gap_len, reg_num_segments,
            seg_ptr_readback, status_readback)
    begin
        case axi_araddr(4 downto 2) is
            when "000" => axi_rdata <= reg_seg_sel;
            when "001" => axi_rdata <= reg_active_len;
            when "010" => axi_rdata <= reg_gap_len;
            when "100" => axi_rdata <= reg_num_segments;
            -- 0x14 SW_START is now write-strobe-only (see FIX note in file
            -- header); it never held a meaningful value to read back, so
            -- reads return 0, same as any other write-only strobe register
            -- (COMMIT_SEG/COMMIT_ROW/RESET_PULSE elsewhere in this design).
            when "101" => axi_rdata <= (others => '0');
            when "110" => axi_rdata <= seg_ptr_readback;                   -- 0x18
            when "111" => axi_rdata <= status_readback;                    -- 0x1C
            when others => axi_rdata <= (others => '0');
        end case;
    end process;

    ------------------------------------------------------------------
    -- Delay COMMIT after snapshotting the data. At the actual clocks used in
    -- this design, 32 source cycles at ~100 MHz is ~320 ns, or ~4.9 cycles
    -- of the 15.36 MHz destination clock. The three 32-bit array crossings
    -- therefore have time to settle before the commit pulse reaches aclk.
    ------------------------------------------------------------------
    COMMIT_DELAY : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                commit_delay_sr <= (others => '0');
            else
                commit_delay_sr <= commit_strobe & commit_delay_sr(0 to CFG_LAUNCH_DELAY-2);
            end if;
        end if;
    end process;
    commit_delayed <= commit_delay_sr(CFG_LAUNCH_DELAY-1);

    ------------------------------------------------------------------
    -- CDC: s_axi_aclk -> aclk (table load side)
    ------------------------------------------------------------------
    CDC_SEG_ADDR : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk  => s_axi_aclk, src_in   => snap_seg_sel,
                   dest_clk => aclk,       dest_out => wr_seg_addr_cdc );

    CDC_ACTIVE_LEN : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk  => s_axi_aclk, src_in   => snap_active_len,
                   dest_clk => aclk,       dest_out => wr_active_len_cdc );

    CDC_GAP_LEN : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk  => s_axi_aclk, src_in   => snap_gap_len,
                   dest_clk => aclk,       dest_out => wr_gap_len_cdc );

    CDC_NUM_SEGMENTS : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk  => s_axi_aclk, src_in   => reg_num_segments,
                   dest_clk => aclk,       dest_out => num_segments_cdc );

    -- Pulse CDC for an accepted commit. Source-side spacing logic rejects
    -- commits that are too close for the pulse crossing. REG_OUTPUT registers the
    -- destination pulse. Source/destination resets must satisfy the XPM reset rule.
    CDC_COMMIT : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => commit_delayed,
                   dest_clk => aclk,      dest_rst => rst_aclk,      dest_pulse => wr_strobe_cdc );

    -- FIX: xpm_cdc_pulse (with reset) instead of xpm_cdc_single, crossing
    -- sw_start_strobe (a genuine one-cycle strobe) instead of a level
    -- register - see FIX note in file header. sw_start_cdc is now itself a
    -- registered one-cycle pulse in the aclk domain. Source/destination
    -- resets must satisfy the XPM_CDC_PULSE simultaneous-reset requirement.
    CDC_SW_START : xpm_cdc_pulse
        generic map ( DEST_SYNC_FF => 4, REG_OUTPUT => 1, RST_USED => 1, SIM_ASSERT_CHK => 1 )
        port map ( src_clk => s_axi_aclk, src_rst => rst_axi, src_pulse => sw_start_strobe,
                   dest_clk => aclk,      dest_rst => rst_aclk,      dest_pulse => sw_start_cdc );

    ------------------------------------------------------------------
    -- CDC: aclk -> s_axi_aclk (readback side)
    ------------------------------------------------------------------
    CDC_SEG_PTR : xpm_cdc_array_single
        generic map ( DEST_SYNC_FF => 4, SIM_ASSERT_CHK => 1, SRC_INPUT_REG => 1, WIDTH => 32 )
        port map ( src_clk  => aclk,       src_in   => seg_idx_sig,
                   dest_clk => s_axi_aclk, dest_out => seg_ptr_readback );

    CDC_STATUS : xpm_cdc_single
        port map ( src_clk  => aclk,       src_in   => active_sig,
                   dest_clk => s_axi_aclk, dest_out => status_readback(0) );
    status_readback(1) <= cfg_overrun;
    status_readback(31 downto 2) <= (others => '0');

    ------------------------------------------------------------------
    -- core
    ------------------------------------------------------------------
    GATE_MULTI : TX_Multi_Gate
        generic map (N => C_S_AXIS_DATA_WIDTH, SEGMENTS => SEGMENTS)
        port map (clk => aclk,
                  rst => rst_aclk,

                  num_segments      => num_segments_cdc,
                  hw_active_length  => hw_active_length,   -- pre-synchronized, straight through

                  wr_seg_addr   => wr_seg_addr_cdc,
                  wr_active_len => wr_active_len_cdc,
                  wr_gap_len    => wr_gap_len_cdc,
                  wr_strobe     => wr_strobe_cdc,

                  hw_start => hw_start,
                  sw_start => sw_start_cdc,

                  s_tvalid => s_axis_re_tvalid,
                  s_tdata  => s_axis_re_tdata,
                  s_tready => s_axis_re_tready,
                  m_tvalid => m_axis_re_tvalid,
                  m_tdata  => m_axis_re_tdata,
                  m_tready => m_axis_re_tready,

                  seg_idx_out => seg_idx_sig,
                  active_out  => active_sig);

end arch_imp;
