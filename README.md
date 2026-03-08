# BF16.lua
## Older versions of this compiler can be found in my gists
bf16.lua is a brainfuck compiler/transpiler to lua, designed with execution speed in mind

### bf16.lua has 3 modes:
1) Normal : Slow, but portable and wont cause segfaults
2) FFI : Fast, but works only in luajit and can cause segfaults
3) FFI_Raylib (BF16-greyscale) : Same speed as in FFI mode and also displays first 256 memory cells onto screen
-----
### bf16.lua works with optimization 7 passes
1) Folding
2) Cycle->Linear instruction (Multiplication, Free, Scan)
3) Cycle->If/For
4) Offsetting
5) Multiplication shrinker (Unstable, not used by default)
6) Repeated instruction->ForI(Linear instruction)
7) Algorithm matching (No any algorithm patterns by far, so NoOp)
--------------------------------
### Performance benchmarks (mandelbrot.bf):
1) bf16.lua (Normal) - 1.72s
2) bf16.lua (FFI) - 0.90s
3) fast_brainfuck.lua - 1.75s
4) bffsree - 2.14s
5) brainfuck_jit - 0.77s
6) bf-fs (compiler) - 0.8s
## Conclusions
Well, bf16.lua in FFI mode is kinda fast.
