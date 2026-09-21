library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Capture-gate AXI-Lite register block.
-- 0x00 CAPTURE_LENGTH  RW
-- 0x04 SW_START        WO, any write produces a one-cycle transfer(0) pulse
-- 0x08 STATUS          RO, returns status_in
-- 0x0C STATUS_CLEAR    WO, any write produces a one-cycle status_clear pulse
entity S_AXI_Lite is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 4
    );
    port (
        packetsize   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        transfer     : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        status_in    : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        status_clear : out std_logic;

        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN : in  std_logic;
        S_AXI_AWADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic
    );
end S_AXI_Lite;

architecture rtl of S_AXI_Lite is
    constant ADDR_LSB : integer := (C_S_AXI_DATA_WIDTH/32) + 1;

    signal axi_awaddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal axi_awready : std_logic := '0';
    signal axi_wready  : std_logic := '0';
    signal axi_bresp   : std_logic_vector(1 downto 0) := "00";
    signal axi_bvalid  : std_logic := '0';
    signal axi_araddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal axi_arready : std_logic := '0';
    signal axi_rdata   : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal axi_rresp   : std_logic_vector(1 downto 0) := "00";
    signal axi_rvalid  : std_logic := '0';
    signal aw_en       : std_logic := '1';
    signal slv_reg_wren : std_logic;
    signal slv_reg_rden : std_logic;

    signal reg_capture_length : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal transfer_pulse     : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal status_clear_pulse : std_logic := '0';

begin
    assert C_S_AXI_DATA_WIDTH = 32
        report "S_AXI_Lite capture block currently requires 32-bit AXI-Lite data"
        severity failure;

    S_AXI_AWREADY <= axi_awready;
    S_AXI_WREADY  <= axi_wready;
    S_AXI_BRESP   <= axi_bresp;
    S_AXI_BVALID  <= axi_bvalid;
    S_AXI_ARREADY <= axi_arready;
    S_AXI_RDATA   <= axi_rdata;
    S_AXI_RRESP   <= axi_rresp;
    S_AXI_RVALID  <= axi_rvalid;

    packetsize   <= reg_capture_length;
    transfer     <= transfer_pulse;
    status_clear <= status_clear_pulse;

    -- Single-outstanding write transaction.
    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_awready <= '0';
                axi_awaddr  <= (others => '0');
                aw_en       <= '1';
            else
                if axi_awready = '0' and S_AXI_AWVALID = '1' and
                   S_AXI_WVALID = '1' and aw_en = '1' then
                    axi_awready <= '1';
                    axi_awaddr  <= S_AXI_AWADDR;
                    aw_en       <= '0';
                else
                    axi_awready <= '0';
                    if S_AXI_BREADY = '1' and axi_bvalid = '1' then
                        aw_en <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_wready <= '0';
            elsif axi_wready = '0' and S_AXI_WVALID = '1' and
                  S_AXI_AWVALID = '1' and aw_en = '1' then
                axi_wready <= '1';
            else
                axi_wready <= '0';
            end if;
        end if;
    end process;

    slv_reg_wren <= axi_awready and S_AXI_AWVALID and axi_wready and S_AXI_WVALID;

    process(S_AXI_ACLK)
        variable addr_word : std_logic_vector(1 downto 0);
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                reg_capture_length <= (others => '0');
                transfer_pulse     <= (others => '0');
                status_clear_pulse <= '0';
            else
                transfer_pulse     <= (others => '0');
                status_clear_pulse <= '0';

                if slv_reg_wren = '1' then
                    addr_word := axi_awaddr(ADDR_LSB+1 downto ADDR_LSB);
                    case addr_word is
                        when "00" =>
                            for byte_index in 0 to (C_S_AXI_DATA_WIDTH/8)-1 loop
                                if S_AXI_WSTRB(byte_index) = '1' then
                                    reg_capture_length(byte_index*8+7 downto byte_index*8) <=
                                        S_AXI_WDATA(byte_index*8+7 downto byte_index*8);
                                end if;
                            end loop;
                        when "01" =>
                            transfer_pulse(0) <= '1';
                        when "10" =>
                            null; -- STATUS is read-only
                        when "11" =>
                            status_clear_pulse <= '1';
                        when others =>
                            null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_bvalid <= '0';
                axi_bresp  <= "00";
            elsif slv_reg_wren = '1' then
                axi_bvalid <= '1';
                axi_bresp  <= "00";
            elsif axi_bvalid = '1' and S_AXI_BREADY = '1' then
                axi_bvalid <= '0';
            end if;
        end if;
    end process;

    -- Do not accept a second read address while RVALID is outstanding.
    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_arready <= '0';
                axi_araddr  <= (others => '0');
            elsif axi_arready = '0' and S_AXI_ARVALID = '1' and axi_rvalid = '0' then
                axi_arready <= '1';
                axi_araddr  <= S_AXI_ARADDR;
            else
                axi_arready <= '0';
            end if;
        end if;
    end process;

    slv_reg_rden <= axi_arready and S_AXI_ARVALID and not axi_rvalid;

    process(S_AXI_ACLK)
        variable addr_word : std_logic_vector(1 downto 0);
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_rvalid <= '0';
                axi_rresp  <= "00";
                axi_rdata  <= (others => '0');
            else
                if slv_reg_rden = '1' then
                    addr_word := axi_araddr(ADDR_LSB+1 downto ADDR_LSB);
                    case addr_word is
                        when "00" => axi_rdata <= reg_capture_length;
                        when "01" => axi_rdata <= (others => '0');
                        when "10" => axi_rdata <= status_in;
                        when "11" => axi_rdata <= (others => '0');
                        when others => axi_rdata <= (others => '0');
                    end case;
                    axi_rvalid <= '1';
                    axi_rresp  <= "00";
                elsif axi_rvalid = '1' and S_AXI_RREADY = '1' then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process;

end rtl;
