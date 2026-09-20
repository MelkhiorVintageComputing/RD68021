# The microcode tables, and the generator that checks them

```sh
make ucode         # regenerate rtl/gen/ from these tables
make ucode-check   # fail if what is committed has drifted
python3 tools/ucode/frames.py     # the frame layouts and the checkpoint budget
```

| | |
|---|---|
| `frames.py` | the six exception stack frames, the private words this design keeps inside the long one, and the frozen checkpoint set. The single place any of those offsets exists |
| `assemble.py` | emits `rtl/gen/`, and refuses to if the tables are wrong |

As of M4 that is all of it. The microword, the opcode and extension-word decoders
and the microcode store arrive in M5.

## The generator is the design-rule checker

Some properties cannot be stated in RTL, so they are stated here and fail the
build instead. `frames.py`'s checks are:

1. Every frame is contiguous, gapless, and exactly as many words as UM Table 6-5
   says.
2. The version word is at `SP+$36` and only the long frame has one.
3. No two checkpointed registers share a bit, and none sits on the version nibble.
4. **Nothing private is in the short frame**, which has no version field to
   protect it.
5. Every checkpointed register has a home, and every home is real.
6. Every internal word allocated is claimed by something. An allocation nobody
   uses is a budget nobody will re-examine.

All eight failure modes are negative-tested: mutate the table and the check that
should fire, fires. One wrong offset in the long fault frame is a silent
demand-paging failure that no instruction test would catch, which is why the
offsets exist once and why the file that holds them is written before any
instruction.
