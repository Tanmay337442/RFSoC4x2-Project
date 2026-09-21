----------------------------------------------------------------------------------
-- Capture_Gate -- non-stallable ADC capture window + elasticity FIFO
--
-- capture_length counts valid ADC AXIS BEATS. For the intended RX stream,
-- one 128-bit beat = 8 real 16-bit samples = 65.1041667 ns at 15.36 MHz.
-- A requested length of 0 is clamped to 1 beat.
--
-- s_tready is permanently '1': the physical ADC stream is treated as free-running.
-- During ACTIVE, each s_tvalid beat advances the capture interval regardless of
-- DMA readiness. Captured {TLAST,TDATA} words enter a common-clock xpm_fifo_sync.
-- The FIFO read side is presented as a normal backpressure-safe AXI stream.
--
-- If the FIFO cannot accept a requested input beat, that physical sample is lost
-- and overflow_out latches until clear_overflow (idle only) or reset. If the final
-- requested beat is the dropped beat, a synthetic zero-data TLAST is queued once
-- FIFO space returns so packet-oriented downstream logic can still terminate.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library xpm;
use xpm.vcomponents.all;

entity Capture_Gate is
    Generic (
        N          : integer := 128;
        FIFO_DEPTH : integer := 2048
    );
    Port (
        rst            : in  STD_LOGIC;
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
        clk            : in  STD_LOGIC
    );
end Capture_Gate;

architecture rtl of Capture_Gate is
    function is_power_of_two(n : integer) return boolean is
        variable v : integer := n;
    begin
        if v < 1 then return false; end if;
        while (v mod 2) = 0 loop
            v := v / 2;
        end loop;
        return v = 1;
    end function;

    constant FIFO_WORD_WIDTH : integer := N + 1;

    signal active_sig          : STD_LOGIC := '0';
    signal overflow_sig        : STD_LOGIC := '0';
    signal pending_end_sig     : STD_LOGIC := '0';
    signal capture_len_latched : unsigned(31 downto 0) := to_unsigned(1, 32);
    signal beat_index          : unsigned(31 downto 0) := (others => '0');

    signal fifo_din            : STD_LOGIC_VECTOR(FIFO_WORD_WIDTH-1 downto 0);
    signal fifo_dout           : STD_LOGIC_VECTOR(FIFO_WORD_WIDTH-1 downto 0);
    signal fifo_wr_en          : STD_LOGIC;
    signal fifo_rd_en          : STD_LOGIC;
    signal fifo_full           : STD_LOGIC;
    signal fifo_empty          : STD_LOGIC;
    signal fifo_wr_rst_busy    : STD_LOGIC;
    signal fifo_rd_rst_busy    : STD_LOGIC;
    signal fifo_overflow       : STD_LOGIC;
    signal fifo_underflow      : STD_LOGIC;
    signal fifo_wr_ack         : STD_LOGIC;
    signal fifo_data_valid     : STD_LOGIC;
    signal fifo_almost_full    : STD_LOGIC;
    signal fifo_almost_empty   : STD_LOGIC;
    signal fifo_prog_full      : STD_LOGIC;
    signal fifo_prog_empty     : STD_LOGIC;
    signal fifo_sbiterr        : STD_LOGIC;
    signal fifo_dbiterr        : STD_LOGIC;
    signal fifo_wr_count       : STD_LOGIC_VECTOR(0 downto 0);
    signal fifo_rd_count       : STD_LOGIC_VECTOR(0 downto 0);

    signal current_is_last     : STD_LOGIC;
    signal live_capture_write  : STD_LOGIC;
    signal marker_write        : STD_LOGIC;

    attribute mark_debug : string;
    attribute mark_debug of hw_start        : signal is "true";
    attribute mark_debug of active_sig      : signal is "true";
    attribute mark_debug of beat_index      : signal is "true";
    attribute mark_debug of overflow_sig    : signal is "true";
    attribute mark_debug of fifo_full       : signal is "true";
    attribute mark_debug of pending_end_sig : signal is "true";

begin
    assert FIFO_DEPTH >= 16
        report "Capture_Gate: FIFO_DEPTH must be at least 16"
        severity failure;
    assert is_power_of_two(FIFO_DEPTH)
        report "Capture_Gate: FIFO_DEPTH must be a power of two for xpm_fifo_sync"
        severity failure;

    -- RFDC ADC source is never backpressured by this block.
    s_tready <= '1';

    overflow_out <= overflow_sig;
    -- Busy remains asserted while a synthetic packet terminator is pending.
    active_out   <= active_sig or pending_end_sig;

    current_is_last <= '1' when (active_sig = '1' and s_tvalid = '1' and
                                 beat_index = capture_len_latched - 1) else '0';

    -- Raw FIFO write requests.  A pending synthetic end marker has priority.
    marker_write       <= pending_end_sig;
    live_capture_write <= active_sig and s_tvalid and (not pending_end_sig);
    fifo_wr_en         <= (marker_write or live_capture_write) and (not fifo_full) and
                          (not fifo_wr_rst_busy) and (not rst);

    fifo_din(FIFO_WORD_WIDTH-1) <= '1' when marker_write = '1' else current_is_last;
    fifo_din(N-1 downto 0)      <= (others => '0') when marker_write = '1' else s_tdata;

    -- FWFT FIFO output maps naturally onto AXI Stream: while m_tready is low,
    -- no rd_en occurs, so fifo_dout remains stable and m_tvalid remains asserted.
    m_tvalid <= (not rst) and (not fifo_empty) and (not fifo_rd_rst_busy);
    m_tlast  <= fifo_dout(FIFO_WORD_WIDTH-1);
    m_tdata  <= fifo_dout(N-1 downto 0);
    fifo_rd_en <= (not rst) and m_tready and (not fifo_empty) and (not fifo_rd_rst_busy);

    CAPTURE_FIFO : xpm_fifo_sync
        generic map (
            DOUT_RESET_VALUE     => "0",
            ECC_MODE             => "no_ecc",
            FIFO_MEMORY_TYPE     => "auto",
            FIFO_READ_LATENCY    => 0,
            FIFO_WRITE_DEPTH     => FIFO_DEPTH,
            FULL_RESET_VALUE     => 0,
            PROG_EMPTY_THRESH    => 10,
            PROG_FULL_THRESH     => FIFO_DEPTH-10,
            RD_DATA_COUNT_WIDTH  => 1,
            READ_DATA_WIDTH      => FIFO_WORD_WIDTH,
            READ_MODE            => "fwft",
            SIM_ASSERT_CHK       => 1,
            USE_ADV_FEATURES     => "0000",
            WAKEUP_TIME          => 0,
            WRITE_DATA_WIDTH     => FIFO_WORD_WIDTH,
            WR_DATA_COUNT_WIDTH  => 1
        )
        port map (
            sleep         => '0',
            wr_clk        => clk,
            rst           => rst,
            wr_rst_busy   => fifo_wr_rst_busy,
            wr_en         => fifo_wr_en,
            din           => fifo_din,
            wr_ack        => fifo_wr_ack,
            full          => fifo_full,
            almost_full   => fifo_almost_full,
            prog_full     => fifo_prog_full,
            wr_data_count => fifo_wr_count,
            overflow      => fifo_overflow,

            rd_en         => fifo_rd_en,
            dout          => fifo_dout,
            empty         => fifo_empty,
            almost_empty  => fifo_almost_empty,
            prog_empty    => fifo_prog_empty,
            rd_data_count => fifo_rd_count,
            data_valid    => fifo_data_valid,
            underflow     => fifo_underflow,
            rd_rst_busy   => fifo_rd_rst_busy,

            injectsbiterr => '0',
            injectdbiterr => '0',
            sbiterr       => fifo_sbiterr,
            dbiterr       => fifo_dbiterr
        );

    process(clk)
        variable len_v : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                active_sig          <= '0';
                overflow_sig        <= '0';
                pending_end_sig     <= '0';
                capture_len_latched <= to_unsigned(1, 32);
                beat_index          <= (others => '0');
            else
                -- Software-visible overflow is sticky across shots until explicitly
                -- cleared.  A newly detected drop later in this same process wins.
                if clear_overflow = '1' and active_sig = '0' and pending_end_sig = '0' then
                    overflow_sig <= '0';
                end if;

                -- Complete the synthetic TLAST once the raw FIFO accepts it.
                if pending_end_sig = '1' and fifo_full = '0' and
                   fifo_wr_rst_busy = '0' then
                    pending_end_sig <= '0';
                end if;

                -- Starts are accepted only while idle and after any synthetic
                -- packet terminator from the preceding shot has been queued.
                if active_sig = '0' and pending_end_sig = '0' and
                   (hw_start = '1' or sw_start = '1') then
                    if unsigned(capture_length) = 0 then
                        len_v := to_unsigned(1, 32);
                    else
                        len_v := unsigned(capture_length);
                    end if;
                    capture_len_latched <= len_v;
                    beat_index          <= (others => '0');
                    active_sig          <= '1';

                elsif active_sig = '1' and s_tvalid = '1' then
                    -- Capture time advances with ADC input beats, never with DMA.
                    -- If storage cannot accept this beat, the physical sample is
                    -- irrecoverably lost and this shot is marked invalid.
                    if fifo_full = '1' or fifo_wr_rst_busy = '1' then
                        overflow_sig <= '1';
                    end if;

                    if beat_index = capture_len_latched - 1 then
                        active_sig <= '0';
                        beat_index <= (others => '0');
                        if fifo_full = '1' or fifo_wr_rst_busy = '1' then
                            pending_end_sig <= '1';
                        end if;
                    else
                        beat_index <= beat_index + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end rtl;
