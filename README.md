# Veryl Stacked Register File

Stacked register file implementation with outstanding features:

- Stacked register windowing, with low complexity access to current register context (top of stack).
- Write forwarding, hiding latency allowing for single-cycle interrupt entry/exit.
- RISC-V ABI conformant.

## Resources

- [The RISC-V Instruction Set Manual Volume I: Unprivileged ISA](https://drive.google.com/file/d/1uviu1nH-tScFfgrovvFCrj7Omv8tFtkp/view?usp=drive_link)
- [RISC-V ABIs Specification](https://drive.google.com/file/d/1Ja_Tpp_5Me583CGVD-BIZMlgGBnlKU4R/view)


# Architectural design

The RV32 ISA specifies either 32 or 16 user accessible registers, mostly general purpose, besides register `x0` being a read only register, returning the value 0.

To the ratified RV32 specification we have added `Top Regs` and `Stacked Regs`:

| Name      | ABI Mnemonic | Meaning                | Preserved across calls? | Top Regs | Stacked Regs |
| --------- | ------------ | ---------------------- | ----------------------- | -------- | ------------ |
| x0        | zero         | Zero                   | — (Immutable)           | 0        | 0            |
| x1        | ra           | Return address         | No                      | 1        | 0            |
| x2        | sp           | Stack pointer          | Yes                     | 1        | 0            |
| x3        | gp           | Global pointer         | — (Unallocatable)       | 0        | 0            |
| x4        | tp           | Thread pointer         | — (Unallocatable)       | 0        | 0            |
| x5 - x7   | t0 - t2      | Temporary registers    | No                      | 3        | 3            |
| x8 - x9   | s0 - s1      | Callee-saved registers | Yes                     | 2        | 0            |
| x10 - x17 | a0 - a7      | Argument registers     | No                      | 8        | 8            |
| x18 - x27 | s2 - s11     | Callee-saved registers | Yes                     | 10       | 0            |
| x28 - x31 | t3 - t6      | Temporary registers    | No                      | 4        | 4            |
| Total     |              |                        |                         | 29       | 15           |

The non ratified RV32E follows the same approach while restricting the number of user accessible registers to 16. The RV32E ISA remains (mostly) the same as RV32, while the ABI differ:

| Name      | ABI Mnemonic | Meaning                | Preserved across calls? | Top Regs | Stacked Regs |
| --------- | ------------ | ---------------------- | ----------------------- | -------- | ------------ |
| x0        | zero         | Zero                   | — (Immutable)           | 0        | 0            |
| x1        | ra           | Return address         | No                      | 1        | 0            |
| x2        | sp           | Stack pointer          | Yes                     | 1        | 0            |
| x3        | gp           | Global pointer         | — (Unallocatable)       | 0        | 0            |
| x4        | tp           | Thread pointer         | — (Unallocatable)       | 0        | 0            |
| x5 - x7   | t0 - t2      | Temporary registers    | No                      | 3        | 3            |
| x8 - x9   | s0 - s1      | Callee-saved registers | Yes                     | 2        | 0            |
| x10 - x15 | a0 - a5      | Argument registers     | No                      | 6        | 6            |
| Total     |              |                        |                         | 13       | 9            |

The `Top Regs` column indicates the number of registers to be persistently store at the top level of the register file. Notice, `x0` (Zero) and `x2/x3` (Global/Thread pointers) do not need a backing store.

The `Stacked Regs` column indicates the number of registers that needs to be stacked by hardware in case of interrupt/trap entry (and correspondingly de-stacked) on interrupt exit.

For the discussion, we assume IRQ handlers to be defined as *functions* according to the RV32 ABI(s), e.g., compiled for the `riscv32i-unknown-none` triple (implies no operating system, thus .... ehhh needs checking). In case of Rust being used, we assume the IRQ handlers to be attributed `extern "C"` to ensure ABI compatibility. An IRQ handler is bound to the interrupt vector via a wrapping function calling the user provided handler (without arguments) followed by `mret`. The compiler is free to perform inlining of the user provided handler function. 

- `x0`, always reads zero so no need for top level store or stacking.
- `x1` (Return address), the handler will be responsible for storing/restoring the return address so no hardware stacking is needed.
- `x2` (Stack pointer), does not need hardware stacking assuming interrupts run on a shared stack (which we assume here).
- `x2, x4` (Global/Thread pointers), do not need stacking assuming that generated code follows the RV32 ISA(s).
- `x5 - x7` (Temporary registers), need hardware stacking as the user handler is not required to store/restore temporary registers.
- `x8 - x9` (Callee-saved registers), do not need hardware stacking as the user handler is required to store/restore callee-saved registers.
- `x10 - x15/x17` (Argument registers), need hardware stacking as the user handler is not required to store/restore argument registers.
- `x18 - x27` (Callee-saved registers), do not need hardware stacking as the user handler is required to store/restore callee-saved registers.
- `x28 - x31` (Temporary registers), need hardware stacking as the user handler is not required to store/restore temporary registers.

## Implementation

In the following subsections, we break down the design into components and explain their implementation.

### Top level interface

The top level component defines the user facing input and outputs as follows:

![top](/images/top.svg)

The corresponding Veryl component:

```sv
module RegFileStack #(
    param Depth: u32       = 4,
    param mask : logic<32> = {
        1'1, // x31 t6
        ...
        1'1, // x5  t0

        1'0, // x4  tp
        1'0, // x3  gp
        1'1, // x2  sp
        1'1, // x1  ra
        1'0, // x0  zero
    },
) (
    i_clk    : input  clock                  , // dedicated clock
    i_reset  : input  reset                  , // dedicated reset
    i_command: input  RegFilePkg::Command    ,
    i_a_addr : input  logic              <5> ,
    i_b_addr : input  logic              <5> ,
    i_w_ena  : input  logic                  ,
    i_w_addr : input  logic              <5> ,
    i_w_data : input  logic              <32>,
    o_a_data : output logic              <32>,
    o_b_data : output logic              <32>,
) 
```

The `mask` parameters defines the set of backing store registers (as seen, `x0`, `x3` and `x4` are disabled in this example).

The `i_command` defines the operations (`Command` enum) is `src/regfile_pkg`.

```sv
    enum Command: logic<2> {
        none = 0, // normal operation
        push = 1, // interrupt/trap entry
        pop = 2, // interrupt/trap exit
    }
```

In case the `i_command` has the `Command::none` the register file operates like expected for a non-stacked register file. It implements register write forwarding, allowing to hide latency. Writes to registers without backing store are allowed (e.g., writing register zero) but has no effect (write forwarding is disabled).

In case of `Command::push`, the current context is pushed. Concurrent write operation is allowed and affects the "new" top level, while the stacked context reflects the state *before* the concurrent write. This allows the very first handler instruction to operate on the "new" context.

In case of `Command::pop`, the previous context is poped. By definition, the current instruction is an `mret`, thus no concurrent write will be handled. 

### Top level implementation

The top level component caters the user facing register file (blue in below Figure) along with a configurable sized context stack (green in below Figure). The latter essentially operates as a shift  register, where `Command::push` shifts the data right, while the `Command::pop` shifts the data left. In the default case (`Command::none`), the context stack retains its state.

![to](/images/instance.svg)

### Register file instance

The `RegFileInstance` (`src/regfile_instance.veryl`) provides a configurable mask defining the set of register instances for backing store (thus reducing the complexity of each instance and corresponding interconnects).

```sv
module RegFileInstance #(
    param mask: logic<32> = 32'hffff_ffff,
) (
    i_clk  : input clock, // dedicated clock
    i_reset: input reset, // dedicated reset

    i_command  : input  Command         ,
    i_push_data: input  logic  <32> [32],
    i_pop_data : input  logic  <32> [32],
    o_data     : output logic  <32> [32],
)
```

### Example RV32 instantiation

The example RV32 instantiation is given below:

![to](/images/instance_reg.svg)


As seen, the top level instantiates the set of user accessible registers (excluding `x0, x3 and x4` in our example). Each stack instance provides the set of stacked registers (allowing for further exclusions).

## FPGA Evaluation

Todo:


## ASIC Evaluation

Targeting ASIC implementations brings both a new opportunities and new challenges, to name a few:

- Flexible gate level implementations, such as latches (with optional single inverter designs).
- Clock and power gating.

![to](/images/stacked_power_global.svg) 

The figure above strives to capture possibilities for further evaluation, along the following line of reasoning:

- Targeting small embedded (hard real-time) systems, low power consumption might be deciding factor for success.
- Implemented by means of interrupt driven execution, idle state implies that no context state needs retention. 
- The top left clock gate may effectively prevent clock distribution to the complete register file sub system.
- The bottom left power gate may effectively disable power distribution to the complete register file sub system.
- Each level of the stacked register file holds an extra single bit to record wether the instance is active or not (0 on reset and power on). Effectively this allows us to detect the case when the system becomes idle on interrupt exit (`Command::pop` marked blue, `Command::push` marked red in Figure). 

This course grained power save approach might be sufficient to reach superior power characteristics over a naive implementation. The challenge here is to correctly implement isolation in between non-powered and powered components. To our advantage, at the point the system becomes idle, there will be no state in the register file that needs to be retained, and consequently, on resuming operation there is no retained state to be restored. This limits power-on transition timing to a bare minimum. 

Further power saves can be envisioned by extending the clock and power gating to individual control for each instance of the stack, as shown below.

![to](/images/stacked_power_save.svg) 

The idea here, is that the clock and power is distributed *only* to active instances of the context stack, thus the cost payed regarding leakage and clock distribution is kept optimal (for the proposed architecture).

Also in this case, the power transition timing will not have to cater for state retention. Wether the fine grained clock and power gating will actually pay off, regarding size/complexity 

## Dependencies

- Verilator, [install](https://verilator.org/guide/latest/install.html)
- Veryl, [install](https://veryl-lang.org/install/)
- Optional dependencies:
  - Surfer, [install](https://gitlab.com/surfer-project/surfer) (Stand alone wave viewer)


## Test

```shell
veryl test --wave
```

## FPGA Workflow

This repo includes scaffolding for an FPGA workflow (mostly to verify post-synthesis and post-implementation characteristics). The example assumes a Numato Labs ECP5 dev board.

### Dependencies
- [Synlig](https://github.com/chipsalliance/synlig), wraps Yosys with a SystemVerilog frontend
- [Yosys](https://github.com/YosysHQ/yosys?tab=readme-ov-file#building-from-source) for synthesis
- [NextPNR](https://github.com/YosysHQ/nextpnr?tab=readme-ov-file#getting-started) for place and route
- [Project Trellis](https://github.com/YosysHQ/prjtrellis) for bitstream generation, and other device specifics.

### Typical build commands

```
veryl build
synlig -p "read_systemverilog $(cat files.f) oscillator.sv; synth_ecp5 -json out.json"
```
transpiles the Veryl code to SystemVerilog, parses it using Synlig, synthesizes a netlist and writes it to `out.json`.

```
nextpnr-ecp5 --json out.json --textcfg out.cfg --45k --package CABGA256 --lpf numato.lpf
```
takes that netlist, and runs place-and-route assuming a 45k Lattice ECP5 FPGA, and the constraints specified in numato.lpf. The end results are written to `out.cfg`.

