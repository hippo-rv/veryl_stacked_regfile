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

For the discussion, we assume IRQ handlers to be generated as *functions* according to the RV32 ABI(s). In case of Rust being used, we assume the IRQ handlers to be attributed `extern "C"` to ensure ABI compatibility. An IRQ handler is bound to the interrupt vector via a wrapping function calling the user provided handler (without arguments) followed by `mret`. The compiler is free to perform inlining of the user provided handler function. 

- `x0`, always reads zero so no need for top level store or stacking.
- `x1` (Return address), the handler will be responsible for storing/restoring the return address so no hardware stacking is needed.
- `x2` (Stack pointer), does not need hardware stacking assuming interrupts run on a shared stack (which we assume here).
- `x2, x4` (Global/Thread pointers), do not need stacking assuming that generated code follows the RV32 ISA(s).
- `x5 - x7` (Temporary registers), need hardware stacking as the user handler is not required to store/restore temporary registers.
- `x8 - x9` (Callee-saved registers), do not need hardware stacking as the user handler is required to store/restore callee-saved registers.
- `x10 - x15/x17` (Argument registers), need hardware stacking as the user handler is not required to store/restore argument resters.
- `x18 - x27` (Callee-saved registers), do not need hardware stacking as the user handler is required to store/restore callee-saved registers.
- `x28 - x31` (Temporary registers), need hardware stacking as the user handler is not required to store/restore temporary registers.

## Dependencies

- Verilator, [install](https://verilator.org/guide/latest/install.html)
- Veryl, [install](https://veryl-lang.org/install/)
- Optional dependencies:
  - Surfer, [install](https://gitlab.com/surfer-project/surfer) (Stand alone wave viewer)


## Test

```shell
veryl test --wave
```

