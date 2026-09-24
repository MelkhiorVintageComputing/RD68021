#!/bin/bash
# RD68021 -- build TME with the RTL core as a CPU element.
#
#   sim/tme/build.sh <repo-root> <rtl files...>
#
# Inputs/ is immutable, so TME is copied to build/tme/src and built there, once;
# after that only the core and the element are rebuilt. Three things are done to
# the copy, and nothing else:
#   - sim/tme/rd68021.c and rd68021_model.h go into ic/m68k/, and rd68021.lo
#     into the m68k module's object list, so that `tme/ic/rd68021` exists and
#     can use the module's MC68020 byte-lane router;
#   - tmesh is linked against the Verilator model, its runtime and libstdc++;
#   - make runs with the autotools disabled: the tree's generated files are for
#     autoconf 2.61, and nothing here changes what they were generated from.
set -euo pipefail
ROOT=$1; shift
B=$ROOT/build/tme
SRC=$B/src
TME=$ROOT/Inputs/ref/Run-Sun3-SunOS-4.1.1/tme-0.8_up
AUTO="ACLOCAL=true AUTOCONF=true AUTOHEADER=true AUTOMAKE=true"
CFL="-O2 -g -std=gnu89 -fcommon -Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"

mkdir -p $B
if [ ! -f $SRC/.configured ]; then
  rm -rf $SRC
  cp -a $TME $SRC
  (cd $SRC && (make distclean >/dev/null 2>&1 || true) \
     && CFLAGS="$CFL" ./configure --disable-shared --disable-warnings \
        --enable-ltdl-install --prefix=$B/inst > $B/configure.log 2>&1)
  touch $SRC/.configured
fi

# The core, as a static library behind a C interface.
V=$B/vobj
verilator --cc -O3 --top-module rd68021_top -GICACHE_ENTRIES=64 \
  -Wno-fatal --Mdir $V -CFLAGS "-O2" $ROOT/rtl/rd68021.vlt $ROOT/sim/tme/public.vlt "$@" \
  > $B/verilator.log 2>&1
make -s -C $V -f Vrd68021_top.mk -j8 > $B/vmake.log 2>&1
VINC=$(verilator --getenv VERILATOR_ROOT)/include
g++ -O2 -c -I$V -I$VINC -I$VINC/vltstd $ROOT/sim/tme/rd68021_model.cpp -o $V/rd68021_model.o
# One relocatable object holding the wrapper, the model and the Verilator
# runtime, with every symbol but the C interface made local. libtool builds a
# table of every global symbol it can see for its static module preloading, and
# the runtime's thread-local variables cannot be named from it: "TLS reference
# ... mismatches non-TLS reference in tmeshS.o".
ld -r -o $V/rd68021_all.o $V/rd68021_model.o \
   --whole-archive $V/Vrd68021_top__ALL.a $V/libverilated.a --no-whole-archive
nm -g --defined-only $V/rd68021_model.o | awk '$3 ~ /^rdm_/ {print $3}' > $V/keep.txt
objcopy --keep-global-symbols=$V/keep.txt $V/rd68021_all.o $V/rd68021_lib.o
rm -f $V/librd68021.a
ar rcs $V/librd68021.a $V/rd68021_lib.o
MODEL_LIBS="$V/librd68021.a -lstdc++ -lpthread"

# The element, into the m68k module.
cp $ROOT/sim/tme/rd68021.c $ROOT/sim/tme/rd68021_model.h $SRC/ic/m68k/
grep -q 'rd68021.lo' $SRC/ic/m68k/Makefile \
  || sed -i 's/^\(\tm68010.lo m68020.lo m6888x.lo\)$/\1 rd68021.lo/' $SRC/ic/m68k/Makefile
grep -q 'rd68021.lo' $SRC/ic/m68k/Makefile || { echo "sim/tme/build.sh: could not add rd68021.lo"; exit 1; }

# Build. Serially: the modules' all-local rule copies a library before -j has
# built it.
# ... and only tmesh links the model, so only its Makefile names it. tmesh does
# not depend on the preloaded module archives, so make would not relink it when
# the element changes and install would copy the old one: remove it first.
sed -i "s|^LIBS = .*|LIBS = $MODEL_LIBS|" $SRC/tmesh/Makefile
rm -f $SRC/tmesh/tmesh
(cd $SRC && make $AUTO > $B/make.log 2>&1 && make $AUTO install > $B/install.log 2>&1) \
  || { grep -E 'error:|\*\*\* \[|undefined reference' $B/make.log | head -20; exit 1; }
echo "  tme: built with tme/ic/rd68021 in $B/inst"
