-- V4: Vivado-compatible named reset signals are used in all port maps.
----------------------------------------------------------------------------------
-- AXI_Capture_Gate -- free-running ADC capture wrapper
--
-- Defaults: 128-bit AXIS = 8 real 16-bit samples/beat at 15.36 MHz.
-- CAPTURE_LENGTH is measured in AXIS BEATS.
--
-- Register map (byte offsets):
--   0x00 CAPTURE_LENGTH  RW  software/manual capture length
--   0x04 SW_START        WO  any write emits one-cycle start strobe
--   0x08 STATUS          RO  bit0 BUSY (capture or pending TLAST), bit1 OVERFLOW
--   0x0C STATUS_CLEAR    WO  any write clears OVERFLOW while idle
--
-- hw_start/hw_capture_length arrive already synchronized to aclk from the pulse
-- sequencer. Hardware length is selected only during hw_start; therefore manual
-- SW_START cannot inherit a stale sequencer length.
--
-- The underlying Capture_Gate never backpressures the ADC. It buffers captured
-- beats toward DMA and latches OVERFLOW if a physical input beat must be dropped.
-- OVERFLOW remains sticky across later shots until explicitly cleared/reset.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity AXI_Capture_Gate is
    generic (
        C_S_AXIS_DATA_WIDTH : integer := 128;
        C_S_AXI_DATA_WIDTH  : integer := 32;
        C_S_AXI_ADDR_WIDTH  : integer := 4;
        CAPTURE_FIFO_DEPTH : integer := 2048
        );
    Port (
        aclk    : in std_logic;
        aresetn : in std_logic;

        -- new: plain external hardware start + length inputs, driven from
        -- AXI_Pulse_Sequencer, already synchronized to aclk. NOT AXI signals.
        -- mark_debug on both (ILA #2 - see FIX note / debug markers below).
        hw_start          : in std_logic;
        hw_capture_length : in std_logic_vector(31 downto 0);

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
        m_axis_re_tlast  : out STD_LOGIC;
        m_axis_re_tready : in STD_LOGIC);

end AXI_Capture_Gate;

architecture arch_imp of AXI_Capture_Gate is

    component S_AXI_Lite is
        generic ( C_S_AXI_DATA_WIDTH : integer := 32;
                  C_S_AXI_ADDR_WIDTH : integer := 4 );
        port (
               packetsize : out std_logic_vector (C_S_AXI_DATA_WIDTH-1 downto 0);
               transfer   : out std_logic_vector (C_S_AXI_DATA_WIDTH-1 downto 0);
               status_in    : in  std_logic_vector (C_S_AXI_DATA_WIDTH-1 downto 0);
               status_clear : out std_logic;
               S_AXI_ACLK     : in std_logic;
               S_AXI_ARESETN  : in std_logic;
               S_AXI_AWADDR   : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
               S_AXI_AWPROT   : in std_logic_vector(2 downto 0);
               S_AXI_AWVALID  : in std_logic;
               S_AXI_AWREADY  : out std_logic;
               S_AXI_WDATA    : in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
               S_AXI_WSTRB    : in std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
               S_AXI_WVALID   : in std_logic;
               S_AXI_WREADY   : out std_logic;
               S_AXI_BRESP    : out std_logic_vector(1 downto 0);
               S_AXI_BVALID   : out std_logic;
               S_AXI_BREADY   : in std_logic;
               S_AXI_ARADDR   : in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
               S_AXI_ARPROT   : in std_logic_vector(2 downto 0);
               S_AXI_ARVALID  : in std_logic;
               S_AXI_ARREADY  : out std_logic;
               S_AXI_RDATA    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
               S_AXI_RRESP    : out std_logic_vector(1 downto 0);
               S_AXI_RVALID   : out std_logic;
               S_AXI_RREADY   : in std_logic);
    end component;

    component Capture_Gate is
        Generic ( N : integer := 128; FIFO_DEPTH : integer := 2048 );
        Port ( rst            : in  STD_LOGIC;
               capture_length : in  STD_LOGIC_VECTOR (31 downto 0);
               hw_start       : in  STD_LOGIC;
               sw_start       : in  STD_LOGIC;
               clear_overflow : in  STD_LOGIC;
               s_tvalid       : in  STD_LOGIC;
               s_tdata        : in  STD_LOGIC_VECTOR (N-1 downto 0);
               s_tready       : out STD_LOGIC;
               m_tvalid       : out STD_LOGIC;
               m_tdata        : out STD_LOGIC_VECTOR (N-1 downto 0);
               m_tlast        : out STD_LOGIC;
               m_tready       : in  STD_LOGIC;
               overflow_out   : out STD_LOGIC;
               active_out     : out STD_LOGIC;
               clk            : in  STD_LOGIC );
    end component;

    signal capture_length_sig : STD_LOGIC_VECTOR (C_S_AXI_DATA_WIDTH-1 downto 0);
    signal transfer_sig       : STD_LOGIC_VECTOR (C_S_AXI_DATA_WIDTH-1 downto 0);

    signal capture_length_mux : STD_LOGIC_VECTOR (31 downto 0);

    signal status_clear_sig : STD_LOGIC;
    signal capture_overflow_sig : STD_LOGIC;
    signal capture_active_sig   : STD_LOGIC;
    signal capture_status_sig   : STD_LOGIC_VECTOR(C_S_AXI_DATA_WIDTH-1 downto 0);

    -- ILA debug markers (ILA #2, aclk/ADC domain) - this is the group that
    -- directly shows whether hw_start/hw_capture_length are arriving
    -- correctly and being latched right. hw_start/hw_capture_length are
    -- entity ports, so mark_debug goes on the port declaration itself
    -- (see entity above) - Vivado's Set Up Debug wizard finds port-level
    -- and signal-level marks the same way.
    attribute mark_debug : string;
    attribute mark_debug of hw_start           : signal is "true";  -- entity port
    attribute mark_debug of hw_capture_length  : signal is "true";  -- entity port
    attribute mark_debug of capture_length_mux : signal is "true";
    attribute mark_debug of transfer_sig        : signal is "true";
    attribute mark_debug of capture_overflow_sig : signal is "true";
    attribute mark_debug of capture_active_sig   : signal is "true";

    -- Named active-high datapath reset; use a signal name in component port maps.
    signal rst_aclk : std_logic;

begin

    rst_aclk <= not aresetn;

    -- AXI-Lite 0x08 read-only STATUS:
    --   bit 0 = capture busy (active window or pending synthetic TLAST)
    --   bit 1 = capture overflow / dropped sample(s) in most recent shot
    -- OVERFLOW is sticky until STATUS_CLEAR is written while capture is idle.
    capture_status_sig <= (0 => capture_active_sig,
                           1 => capture_overflow_sig,
                           others => '0');

    AXI_LITE_CORE : S_AXI_Lite
        generic map (
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH
        )
        port map (
            packetsize     => capture_length_sig,   -- reg0
            transfer       => transfer_sig,          -- reg1(0): sw_start
            status_in      => capture_status_sig,     -- reg2 / 0x08: read-only status
            status_clear   => status_clear_sig,
            S_AXI_ACLK     => aclk,
            S_AXI_ARESETN  => aresetn,
            S_AXI_AWADDR   => s_axi_awaddr,
            S_AXI_AWPROT   => s_axi_awprot,
            S_AXI_AWVALID  => s_axi_awvalid,
            S_AXI_AWREADY  => s_axi_awready,
            S_AXI_WDATA    => s_axi_wdata,
            S_AXI_WSTRB    => s_axi_wstrb,
            S_AXI_WVALID   => s_axi_wvalid,
            S_AXI_WREADY   => s_axi_wready,
            S_AXI_BRESP    => s_axi_bresp,
            S_AXI_BVALID   => s_axi_bvalid,
            S_AXI_BREADY   => s_axi_bready,
            S_AXI_ARADDR   => s_axi_araddr,
            S_AXI_ARPROT   => s_axi_arprot,
            S_AXI_ARVALID  => s_axi_arvalid,
            S_AXI_ARREADY  => s_axi_arready,
            S_AXI_RDATA    => s_axi_rdata,
            S_AXI_RRESP    => s_axi_rresp,
            S_AXI_RVALID   => s_axi_rvalid,
            S_AXI_RREADY   => s_axi_rready
        );

    -- Hardware length is selected only on the synchronized hw_start pulse.
    -- Manual
    -- SW_START always uses the AXI-Lite register, even if a stale nonzero
    -- hw_capture_length remains from an earlier sequencer row.
    capture_length_mux <= hw_capture_length when hw_start = '1'
                           else capture_length_sig;

    GATE_RE : Capture_Gate
        generic map (N => C_S_AXIS_DATA_WIDTH, FIFO_DEPTH => CAPTURE_FIFO_DEPTH)
        port map (rst => rst_aclk,
                  capture_length => capture_length_mux,
                  hw_start => hw_start,
                  sw_start => transfer_sig(0),
                  clear_overflow => status_clear_sig,
                  s_tvalid => s_axis_re_tvalid,
                  s_tdata  => s_axis_re_tdata,
                  s_tready => s_axis_re_tready,
                  m_tvalid => m_axis_re_tvalid,
                  m_tdata  => m_axis_re_tdata,
                  m_tlast  => m_axis_re_tlast,
                  m_tready => m_axis_re_tready,
                  overflow_out => capture_overflow_sig,
                  active_out => capture_active_sig,
                  clk => aclk);

end arch_imp;
