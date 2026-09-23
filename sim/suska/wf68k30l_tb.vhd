-- A bus-trace testbench for the Suska WF68K30L, under ghdl.
--
-- WHY THIS EXISTS
--
-- Inputs/ref/Suska_Configware/68K30L/ is a 68030-class design by somebody else,
-- with the same asynchronous DSACK bus. CLAUDE.md is explicit about what it is
-- for: it may be RUN to check our testbenches' reading of the manual, and it may
-- never be READ to work out how to write our RTL. This is the running. Its entity
-- declaration is what an instantiation needs and is all that was looked at.
--
-- The question is the one our bus testbenches cannot ask of themselves: how is
-- an operand split into bus cycles across a 32-, a 16- and an 8-bit port, and
-- what goes on the byte lanes (UM tables 5-6 and 5-7)? Both cores run the same
-- probe, sim/suska/bus_probe.S, against the same memory map, and each prints one
-- line per bus cycle. tools/suska_diff.py compares the data cycles; instruction
-- fetches differ by design and are only counted.
--
-- The memory model is written from UM table 5-7 and from nothing else, and it is
-- the same model sim/models/rd68021_slave.sv is: a read drives the port's lanes
-- from the addressed bytes, a write takes the bytes the port's lanes carry.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity wf68k30l_tb is
end entity wf68k30l_tb;

architecture sim of wf68k30l_tb is

    constant CLK_PERIOD : time := 60 ns;       -- 16.67 MHz, the slowest grade
    constant LIMIT      : integer := 20000;    -- clocks to run

    signal clk       : std_logic := '0';
    signal adr_out   : std_logic_vector(31 downto 0);
    signal data_in   : std_logic_vector(31 downto 0) := (others => '0');
    signal data_out  : std_logic_vector(31 downto 0);
    signal data_en   : std_logic;
    signal berrn     : std_logic := '1';
    signal reset_inn : std_logic := '0';
    signal reset_out : std_logic;
    signal halt_inn  : std_logic := '0';
    signal halt_outn : std_logic;
    signal fc_out    : std_logic_vector(2 downto 0);
    signal avecn     : std_logic := '1';
    signal ipln      : std_logic_vector(2 downto 0) := "111";
    signal ipendn    : std_logic;
    signal dsackn    : std_logic_vector(1 downto 0) := "11";
    signal size      : std_logic_vector(1 downto 0);
    signal asn       : std_logic;
    signal rwn       : std_logic;
    signal rmcn      : std_logic;
    signal dsn       : std_logic;
    signal ecsn      : std_logic;
    signal ocsn      : std_logic;
    signal dbenn     : std_logic;
    signal bus_en    : std_logic;
    signal statusn   : std_logic;
    signal refilln   : std_logic;
    signal bgn       : std_logic;
    signal fc_q      : std_logic_vector(2 downto 0) := "000";
    signal a_q       : std_logic_vector(31 downto 0) := (others => '0');
    signal s_q       : std_logic_vector(1 downto 0) := "00";
    signal rw_q      : std_logic := '1';
    signal d_q       : std_logic_vector(31 downto 0) := (others => '0');
    signal rmc_q     : std_logic := '1';

    -- Three 64 KB memories, one per port width.
    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    impure function load(path : string) return mem_t is
        file     f    : text;
        variable l    : line;
        variable m    : mem_t := (others => (others => '0'));
        variable v    : std_logic_vector(7 downto 0);
        variable i    : integer := 0;
        variable good : boolean;
    begin
        file_open(f, path, read_mode);
        while not endfile(f) and i <= mem_t'high loop
            readline(f, l);
            hread(l, v, good);
            if good then
                m(i) := v;
                i := i + 1;
            end if;
        end loop;
        file_close(f);
        return m;
    end function;

    -- SIZ1/SIZ0 to a byte count: UM table 5-2, 00 is four.
    function nbytes(s : std_logic_vector(1 downto 0)) return integer is
    begin
        case s is
            when "01"   => return 1;
            when "10"   => return 2;
            when "11"   => return 3;
            when others => return 4;
        end case;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.WF68K30L_TOP
        port map (
            CLK       => clk,
            ADR_OUT   => adr_out,
            DATA_IN   => data_in,
            DATA_OUT  => data_out,
            DATA_EN   => data_en,
            BERRn     => berrn,
            RESET_INn => reset_inn,
            RESET_OUT => reset_out,
            HALT_INn  => halt_inn,
            HALT_OUTn => halt_outn,
            FC_OUT    => fc_out,
            AVECn     => avecn,
            IPLn      => ipln,
            IPENDn    => ipendn,
            DSACKn    => dsackn,
            SIZE      => size,
            ASn       => asn,
            RWn       => rwn,
            RMCn      => rmcn,
            DSn       => dsn,
            ECSn      => ecsn,
            OCSn      => ocsn,
            DBENn     => dbenn,
            BUS_EN    => bus_en,
            STERMn    => '1',
            STATUSn   => statusn,
            REFILLn   => refilln,
            BRn       => '1',
            BGn       => bgn,
            BGACKn    => '1');

    -- The memory. It answers on the rising edge after it sees AS, with the port
    -- size the address selects, and takes write data on that same edge -- the
    -- processor has driven it since S2 (UM 5.2.2).
    slave : process(clk)
        variable a, n, lo, hi, port_bytes : integer;
        variable d : std_logic_vector(31 downto 0);
        -- Three 64 KB memories, one per port width; nothing else touches them.
        variable m32 : mem_t := load("bus_probe.hex");
        variable m16 : mem_t := (others => (others => '0'));
        variable m8  : mem_t := (others => (others => '0'));
    begin
        if rising_edge(clk) then
            if asn = '0' and fc_out /= "111" then
                a := to_integer(unsigned(adr_out(15 downto 0)));
                case adr_out(31 downto 28) is
                    when x"1"   => port_bytes := 2; dsackn <= "01";
                    when x"2"   => port_bytes := 1; dsackn <= "10";
                    when others => port_bytes := 4; dsackn <= "00";
                end case;
                -- The bytes this cycle can move: from the address up to the end
                -- of the port's width, and no further than the operand.
                lo := a;
                hi := a - (a mod port_bytes) + port_bytes - 1;
                n  := nbytes(size);
                if lo + n - 1 < hi then
                    hi := lo + n - 1;
                end if;
                d := (others => '0');
                for b in lo to hi loop
                    -- A byte's lane is its offset within the port, from D31.
                    if rwn = '1' then
                        case port_bytes is
                            when 4 => d(31 - 8 * (b mod 4) downto 24 - 8 * (b mod 4)) := m32(b);
                            when 2 => d(31 - 8 * (b mod 2) downto 24 - 8 * (b mod 2)) := m16(b);
                            when others => d(31 downto 24) := m8(b);
                        end case;
                    else
                        case port_bytes is
                            when 4 => m32(b) := data_out(31 - 8 * (b mod 4) downto 24 - 8 * (b mod 4));
                            when 2 => m16(b) := data_out(31 - 8 * (b mod 2) downto 24 - 8 * (b mod 2));
                            when others => m8(b) := data_out(31 downto 24);
                        end case;
                    end if;
                end loop;
                data_in <= d;
            else
                dsackn <= "11";
            end if;
        end if;
    end process slave;

    -- RESET and HALT together, then let go (UM 5.8).
    reset_proc : process
    begin
        reset_inn <= '0';
        halt_inn  <= '0';
        wait for CLK_PERIOD * 40;
        reset_inn <= '1';
        halt_inn  <= '1';
        wait;
    end process reset_proc;

    -- One line per bus cycle, at the negation of AS, from what was on the pins
    -- while it was asserted: function code, address, SIZ, direction, the
    -- write data, and whether RMC was asserted. The same format sim/suska/rd68021_bus_tb.sv prints. The pins
    -- are latched on every falling edge while AS is asserted, so the write data
    -- is what the processor drove last, not what it had not yet driven at S1.
    latch : process(clk)
    begin
        if falling_edge(clk) and asn = '0' then
            fc_q <= fc_out; a_q <= adr_out; s_q <= size; rw_q <= rwn; rmc_q <= rmcn;
            if rwn = '0' then d_q <= data_out; else d_q <= (others => '0'); end if;
        end if;
    end process latch;

    trace : process
        variable l : line;
    begin
        wait until rising_edge(asn);
        write(l, string'("BUS "));
        write(l, to_integer(unsigned(fc_q)));
        write(l, string'(" "));
        hwrite(l, a_q);
        write(l, string'(" "));
        write(l, to_integer(unsigned(s_q)));
        if rw_q = '1' then write(l, string'(" R ")); else write(l, string'(" W ")); end if;
        hwrite(l, d_q);
        if rmc_q = '0' then write(l, string'(" RMC")); else write(l, string'(" -")); end if;
        writeline(output, l);
    end process trace;

    -- The probe ends in a branch to itself; the run is simply long enough.
    stop : process
    begin
        wait for CLK_PERIOD * LIMIT;
        std.env.finish;
    end process stop;

end architecture sim;
