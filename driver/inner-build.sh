#!/bin/bash
# inner-build.sh: container half of the jmk-wifi driver build (88x2bu, or 8851bu on trial).
#
# build.sh starts this in an x86-64 Ubuntu 20.04 container with:
#   /src         this folder, read-only (patches*/, config_tcc803x.txt)
#   /out         this folder's out/, writable (<module>.ko, SOURCE*.txt)
#   /work        docker volume of our own (downloads, kernel tree, driver checkouts)
#   /opt/shared  optional, read-only: an older cache volume; only its toolchain
#                copy is used, and only when the AOSP clone fails
#   /ref/ref.ko  optional, read-only: a module to compare vermagic and parameters with
#
# DRIVER selects the driver (default 88x2bu; see the table under "inputs").
#
# What it does, in order:
#   1. install the host tools it needs
#   2. toolchain: AOSP prebuilt arm-eabi-4.7 (kitkat-release), pinned commit
#   3. kernel: kernel.org linux-3.18.24 (sha256 checked), configured with the car's
#      .config, `olddefconfig` + `modules_prepare`, release string 3.18.24-tcc
#   4. driver: the upstream repository at a pinned commit, then its patch folder's
#      *.patch in name order
#   5. build, check vermagic / parameters / imported symbols, copy the result to /out
#
# Every step is skipped when its result is already in /work and still matches its inputs.

set -euo pipefail

# ---- inputs ---------------------------------------------------------------------------

# Per driver:
#   D_REPO, D_COMMIT  upstream repository and pinned commit (DRIVER_REPO / DRIVER_COMMIT
#                     override them)
#   D_PATCHES         our patch folder under /src
#   D_MODULE          module file name without .ko (also the name in /out)
#   D_TREE            checkout folder under /work/driver
#   D_PARAMS          module parameters that must exist (the daemon passes them)
#   D_PROC            /proc/net/<name>/ folder the driver creates (its DRV_NAME)
#   D_FLAGS_ON        -D flags our patch 0001 must have put in the build
#   D_FLAGS_OFF       -D flags it must have kept out
#   D_SOURCE          name of the build record in /out
DRIVER=${DRIVER:-88x2bu}
case "$DRIVER" in
    88x2bu)
        D_REPO=https://github.com/cilynx/rtl88x2bu.git
        # Parent of upstream's "Fix build for Linux v7.2" merge, which upstream itself names
        # as the last commit for kernels older than 6.15 (README.md at 04ed7009). See README.md.
        D_COMMIT=fc158d1f71b9e5dfcd1fccaf4d28725b65086e3b
        D_PATCHES=/src/patches
        D_MODULE=88x2bu
        D_TREE=rtl88x2bu
        D_PARAMS="ifname if2name rtw_country_code rtw_en_napi rtw_en_gro rtw_power_mgnt rtw_ips_mode rtw_enusbss rtw_usbfs_block"
        D_PROC=rtl88x2bu
        D_FLAGS_ON="CONFIG_CONCURRENT_MODE CONFIG_FORCE_SW_CHANNEL_PLAN CONFIG_PROC_DEBUG"
        D_FLAGS_OFF="CONFIG_MP_INCLUDED CONFIG_LOAD_PHY_PARA_FROM_FILE"
        D_SOURCE=SOURCE.txt
        ;;
    8851bu)
        # Realtek RTL8851BU (AX900 class), Realtek "phl" driver v1.19.10-78-gfbe3fba11.20240422
        # with fofajardo's kernel-compatibility fixes. See README-8851bu.md.
        D_REPO=https://github.com/fofajardo/rtl8851bu.git
        D_COMMIT=9e37e7a1101316a05d5daede91549ea779b64539
        D_PATCHES=/src/patches-8851bu
        D_MODULE=8851bu
        D_TREE=rtl8851bu
        # No rtw_power_mgnt / rtw_enusbss in this driver, and rtw_ips_mode / rtw_lps_mode only
        # exist with CONFIG_RTW_IPS / CONFIG_RTW_LPS, which upstream's autoconf.h leaves off
        # (power save compiled out). rtw_usbfs_block comes with the M1 patches.
        D_PARAMS="ifname if2name rtw_country_code rtw_en_napi rtw_en_gro"
        D_PROC=rtl8851bu
        D_FLAGS_ON="CONFIG_CONCURRENT_MODE CONFIG_FORCE_SW_CHANNEL_PLAN CONFIG_PROC_DEBUG"
        D_FLAGS_OFF="CONFIG_MP_INCLUDED CONFIG_LOAD_PHY_PARA_FROM_FILE CONFIG_FILE_FWIMG"
        D_SOURCE=SOURCE-8851bu.txt
        ;;
    *)
        printf '\nBUILD FAILED: unknown DRIVER=%s (88x2bu or 8851bu)\n' "$DRIVER" >&2
        exit 1
        ;;
esac
DRIVER_REPO=${DRIVER_REPO:-$D_REPO}
DRIVER_COMMIT=${DRIVER_COMMIT:-$D_COMMIT}
MODULE=$D_MODULE

KERNEL_VERSION=3.18.24
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-${KERNEL_VERSION}.tar.xz
# From https://cdn.kernel.org/pub/linux/kernel/v3.x/sha256sums.asc
KERNEL_SHA256=ed54cf8c3ac6b95fc17b07b3a236bc42719c96fee08fe696cabfb5b8e07f8c1b
KERNEL_RELEASE=3.18.24-tcc             # must equal `uname -r` on the car
EXPECT_VERMAGIC="3.18.24-tcc SMP preempt mod_unload ARMv7 p2v8 "

TOOLCHAIN_REPO=https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-eabi-4.7
TOOLCHAIN_BRANCH=kitkat-release
TOOLCHAIN_COMMIT=8b880805d454664b3eed11d0f053cdeafa1ff06e

CAR_CONFIG=/src/config_tcc803x.txt
PATCH_DIR=$D_PATCHES
JOBS=${JOBS:-$(nproc)}
FORCE_KERNEL_PREP=${FORCE_KERNEL_PREP:-0}

# The module must answer to these names: the daemon passes them on the insmod line.
REQUIRED_PARAMS=$D_PARAMS

CACHE=/work/cache
KTREE=/work/kernel/linux-${KERNEL_VERSION}
DTREE=/work/driver/$D_TREE

step() { printf '\n==== %s ====\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nBUILD FAILED: %s\n' "$*" >&2; exit 1; }

# ---- 1. host tools --------------------------------------------------------------------

step "host tools"
need_pkgs=""
for tool in git wget xz bc make gcc file modinfo; do
    command -v "$tool" >/dev/null 2>&1 || need_pkgs=yes
done
if [ -n "$need_pkgs" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends \
        ca-certificates git wget xz-utils bc make gcc libc6-dev file kmod >/dev/null
fi
note "$(git --version), $(make --version | head -1), host $(gcc -dumpversion)"
mkdir -p "$CACHE" /work/kernel /work/driver

# ---- 2. toolchain ---------------------------------------------------------------------

step "toolchain: arm-eabi-4.7 ($TOOLCHAIN_BRANCH)"
TC=$CACHE/arm-eabi-4.7
if [ ! -x "$TC/bin/arm-eabi-gcc" ]; then
    rm -rf "$TC"
    if git clone -q --depth 1 -b "$TOOLCHAIN_BRANCH" "$TOOLCHAIN_REPO" "$TC"; then
        note "cloned $TOOLCHAIN_REPO"
    elif [ -x /opt/shared/arm-eabi-4.7/bin/arm-eabi-gcc ]; then
        rm -rf "$TC"
        TC=/opt/shared/arm-eabi-4.7
        note "AOSP clone failed; using the copy in the shared volume ($TC)"
    else
        die "toolchain: git clone of $TOOLCHAIN_REPO ($TOOLCHAIN_BRANCH) failed and no shared copy exists"
    fi
fi
if [ -d "$TC/.git" ]; then
    tc_head=$(git -C "$TC" rev-parse HEAD)
    [ "$tc_head" = "$TOOLCHAIN_COMMIT" ] \
        || die "toolchain is at $tc_head, expected $TOOLCHAIN_COMMIT"
    note "commit $tc_head"
else
    tc_head=unknown
    note "no git metadata in $TC: provenance not checked"
fi
CROSS=$TC/bin/arm-eabi-
note "$("${CROSS}gcc" --version | head -1)"

# ---- 3. kernel ------------------------------------------------------------------------

step "kernel: linux-$KERNEL_VERSION"
tarball=$CACHE/linux-${KERNEL_VERSION}.tar.xz
if ! echo "$KERNEL_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
    rm -f "$tarball"
    wget -q -O "$tarball.part" "$KERNEL_URL" || die "kernel: download of $KERNEL_URL failed"
    mv "$tarball.part" "$tarball"
    echo "$KERNEL_SHA256  $tarball" | sha256sum -c --status \
        || die "kernel: $tarball does not match sha256 $KERNEL_SHA256"
    note "downloaded $KERNEL_URL"
fi
note "tarball sha256 ok ($KERNEL_SHA256)"

kmake() {
    make -C "$KTREE" ARCH=arm CROSS_COMPILE="$CROSS" LOCALVERSION= "$@"
}

# The prepared tree is reused while these inputs are unchanged.
kstamp_want=$( { sha256sum "$CAR_CONFIG" | cut -d' ' -f1
                 echo "$KERNEL_SHA256 $tc_head $CROSS kprep-v2"; } | sha256sum | cut -d' ' -f1)
kstamp_have=$(cat /work/kernel/.prepared 2>/dev/null || true)
need_prep=0
if [ "$FORCE_KERNEL_PREP" = 1 ] || [ "$kstamp_want" != "$kstamp_have" ] \
        || [ ! -f "$KTREE/include/generated/utsrelease.h" ]; then
    need_prep=1
fi

if [ "$need_prep" = 1 ]; then
    rm -rf /work/kernel
    mkdir -p /work/kernel
    tar -C /work/kernel -xf "$tarball"

    # The car's kernel selects these from its Telechips TCC803X machine entry, which
    # kernel.org 3.18 does not have, so olddefconfig would silently drop them. Each one
    # changes a layout a module sees. This only touches the tree we compile against.
    cat >> "$KTREE/arch/arm/Kconfig" <<'EOF'

# jmk-wifi module build: options selected by the car's TCC803X machine entry.
#   ARCH_DMA_ADDR_T_64BIT  64-bit dma_addr_t (struct urb, struct scatterlist)
#   ZONE_DMA               page zone bits used by inline page helpers
#   PINCTRL                struct device carries a 'pins' pointer
config JMK_TCC803X_LAYOUT
	def_bool y
	select ARCH_DMA_ADDR_T_64BIT
	select ZONE_DMA
	select PINCTRL
EOF

    cp "$CAR_CONFIG" "$KTREE/.config"
    # gcc 4.7 has no -fstack-protector-strong and the 3.18 Makefile only warns about
    # that, then passes the flag anyway. Regular protection uses the same
    # __stack_chk_guard / __stack_chk_fail symbols, so it is ABI-compatible.
    "$KTREE/scripts/config" --file "$KTREE/.config" \
        --disable CC_STACKPROTECTOR_STRONG --enable CC_STACKPROTECTOR_REGULAR
    kmake olddefconfig >/dev/null 2>&1 || die "kernel: make olddefconfig failed"
    note "olddefconfig done"
else
    note "reusing prepared tree (stamp $kstamp_want)"
fi

# --- compare the car's .config with what olddefconfig made of it ---
# Every option that olddefconfig changed is listed here. After the driver is built, the
# ones that the module's compilation actually saw are checked again (see "checks").
cfg_value() {  # file symbol -> value, "n" when unset or absent
    local line
    line=$(grep -E "^(CONFIG_$2=|# CONFIG_$2 is not set)" "$1" | head -1 || true)
    case "$line" in
        "CONFIG_$2="*) printf '%s' "${line#CONFIG_$2=}" ;;
        *) printf 'n' ;;
    esac
}
all_car_syms=$(grep -oE '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$CAR_CONFIG" \
               | sed -E 's/^# //; s/ is not set$//; s/=$//; s/^CONFIG_//' | sort -u)
known_syms=$(find "$KTREE" -name 'Kconfig*' -print0 \
             | xargs -0 grep -hoE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' \
             | awk '{print $2}' | sort -u)
cfg_table() {  # file -> "SYMBOL<tab>value" lines, "n" for "is not set"
    sed -nE 's/^CONFIG_([A-Za-z0-9_]+)=(.*)$/\1\t\2/p; s/^# CONFIG_([A-Za-z0-9_]+) is not set$/\1\tn/p' "$1"
}
# /tmp/cfg-changed.txt: "SYMBOL<tab>car value<tab>build value" for every option that
# vanilla 3.18 knows and whose value olddefconfig changed.
awk -F'\t' -v OFS='\t' '
    FNR == 1 { file++ }
    file == 1 { known[$1] = 1; next }
    file == 2 { build[$1] = $2; next }
    ($1 in known) { have = ($1 in build) ? build[$1] : "n"; if ($2 != have) print $1, $2, have }
' <(echo "$known_syms") <(cfg_table "$KTREE/.config") <(cfg_table "$CAR_CONFIG") > /tmp/cfg-changed.txt
note "options changed by olddefconfig (car -> build):"
awk -F'\t' '{printf "%s(%s->%s) ", $1, $2, $3}' /tmp/cfg-changed.txt | fold -s -w 100 | sed 's/^/      /'
echo
for sym in ARCH_DMA_ADDR_T_64BIT ZONE_DMA PINCTRL ARM_LPAE HZ NR_CPUS SMP PREEMPT; do
    [ "$(cfg_value "$CAR_CONFIG" $sym)" = "$(cfg_value "$KTREE/.config" $sym)" ] \
        || die "kernel: CONFIG_$sym differs from the car's .config"
done
note "layout options kept: ARCH_DMA_ADDR_T_64BIT ZONE_DMA PINCTRL ARM_LPAE HZ NR_CPUS SMP PREEMPT"
car_only=$(comm -23 <(echo "$all_car_syms") <(echo "$known_syms"))
note "$(echo "$car_only" | wc -l) car options unknown to kernel.org 3.18 (Telechips/Android), dropped:"
echo $car_only | fold -s -w 100 | sed 's/^/      /'

if [ "$need_prep" = 1 ]; then
    kmake -j"$JOBS" modules_prepare >/dev/null 2>&1 || die "kernel: make modules_prepare failed"
    echo "$kstamp_want" > /work/kernel/.prepared
    note "modules_prepare done"
fi
release=$(cat "$KTREE/include/config/kernel.release")
[ "$release" = "$KERNEL_RELEASE" ] || die "kernel: release is '$release', expected '$KERNEL_RELEASE'"
note "kernel release $release"

# ---- 4. driver source -----------------------------------------------------------------

step "driver $DRIVER: $DRIVER_REPO @ $DRIVER_COMMIT"
if [ ! -d "$DTREE/.git" ]; then
    rm -rf "$DTREE"
    git clone -q "$DRIVER_REPO" "$DTREE" || die "driver: git clone of $DRIVER_REPO failed"
fi
if ! git -C "$DTREE" cat-file -e "$DRIVER_COMMIT^{commit}" 2>/dev/null; then
    git -C "$DTREE" fetch -q origin || die "driver: git fetch failed"
fi
git -C "$DTREE" checkout -q -f --detach "$DRIVER_COMMIT" || die "driver: commit $DRIVER_COMMIT not found"
git -C "$DTREE" clean -q -fdx
[ "$(git -C "$DTREE" rev-parse HEAD)" = "$DRIVER_COMMIT" ] || die "driver: checkout mismatch"
note "$(git -C "$DTREE" log -1 --format='%H %cd %s' --date=short)"

patches=$(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | sort)
[ -n "$patches" ] || die "no patches in $PATCH_DIR"
for p in $patches; do
    git -C "$DTREE" apply --whitespace=nowarn "$p" || die "patch $(basename "$p") does not apply"
    note "applied $(basename "$p")  sha256 $(sha256sum "$p" | cut -c1-16)"
done

# ---- 5. build -------------------------------------------------------------------------

step "build"
make_rc=0
make -C "$DTREE" ARCH=arm CROSS_COMPILE="$CROSS" KSRC="$KTREE" KVER="$KERNEL_RELEASE" \
    -j"$JOBS" modules > /tmp/driver-make.log 2>&1 || make_rc=$?
# Show everything except the one-line-per-file progress output.
grep -vE '^  (CC \[M\]|LD \[M\]|LD|CC|MODPOST|Building)' /tmp/driver-make.log || true
[ "$make_rc" = 0 ] || die "driver: make failed (exit $make_rc)"
ko=$DTREE/$MODULE.ko
[ -f "$ko" ] || die "driver: $ko was not produced"
note "$(grep -c 'warning:' /tmp/driver-make.log || true) compiler warnings (listed above)"

KO=/tmp/$MODULE.ko
"${CROSS}strip" --strip-debug -o "$KO" "$ko"

# ---- checks ---------------------------------------------------------------------------

step "checks"
vermagic=$(modinfo -F vermagic "$KO")
note "vermagic:  '$vermagic'"
[ "$vermagic" = "$EXPECT_VERMAGIC" ] || die "vermagic is not '$EXPECT_VERMAGIC'"

params=$(modinfo -F parmtype "$KO" | cut -d: -f1 | sort -u)
missing=""
for p in $REQUIRED_PARAMS; do
    echo "$params" | grep -qx "$p" || missing="$missing $p"
done
[ -z "$missing" ] || die "module parameters missing:$missing"
note "required parameters present: $REQUIRED_PARAMS"

# Every imported symbol must be exported somewhere in 3.18.24.
# Two exporters build the symbol name inside a macro; they are listed by their calls.
exports=$( {
    grep -rhoE 'EXPORT_SYMBOL(_GPL)?(_FUTURE)?\([[:space:]]*[A-Za-z0-9_]+' \
        --include='*.c' --include='*.S' --include='*.h' "$KTREE" | sed -E 's/.*\([[:space:]]*//'
    # drivers/base/core.c: define_dev_printk_level(_dev_info, KERN_INFO) and friends
    grep -hoE '^define_dev_printk_level\([A-Za-z0-9_]+' "$KTREE/drivers/base/core.c" | sed 's/.*(//'
    # kernel/params.c: STANDARD_PARAM_DEF(int, ...) exports param_set_int, param_get_int, param_ops_int
    grep -hoE '^STANDARD_PARAM_DEF\([a-z0-9_]+' "$KTREE/kernel/params.c" | sed 's/.*(//' \
        | sed -E 's/^(.*)$/param_set_\1\nparam_get_\1\nparam_ops_\1/'
} | sort -u)
undef=$("${CROSS}nm" -u "$KO" | awk '{print $2}' | sort -u)
unexported=$(comm -23 <(echo "$undef") <(echo "$exports"))
note "$(echo "$undef" | wc -l) imported kernel symbols"
[ -z "$unexported" ] || die "symbols not exported by linux-$KERNEL_VERSION: $(echo $unexported)"

# kbuild's fixdep writes every CONFIG_ symbol a compilation looked at into the .cmd
# files, as $(wildcard include/config/<symbol>.h). Those are the only options that
# can have changed the module. Any of them that olddefconfig changed must be listed
# here with the reason it does not matter, or the build stops.
declare -A cfg_ok=(
    [CC_STACKPROTECTOR_STRONG]="gcc 4.7 lacks it; REGULAR uses the same __stack_chk_* symbols"
    [CC_STACKPROTECTOR_REGULAR]="replaces CC_STACKPROTECTOR_STRONG"
    [NEED_MACH_IO_H]="asm/io.h: port I/O macros (inb/outb) only, unused by a USB driver"
    [ARCH_HAS_SG_CHAIN]="scatterlist.h: a BUG() in sg_chain() only; the driver does not chain"
    [SPARSE_IRQ]="NR_IRQS / irq_desc; the module requests no interrupt"
    [USB_OTG]="include/linux/usb/gadget.h only (device side)"
    [USB_PHY]="include/linux/usb/phy.h function stubs"
    [PCI_DOMAINS]="PCI bus structures; no PCI code in this USB build"
    [PM_GENERIC_DOMAINS]="pm_subsys_data is allocated separately; genpd API only"
    [PM_GENERIC_DOMAINS_SLEEP]="genpd API only"
    [PM_OPP]="OPP / cpufreq API only"
    [HARDLOCKUP_DETECTOR]="touch_nmi_watchdog() becomes an inline call of touch_softlockup_watchdog()"
    [HAVE_ARM_SCU]="SCU helpers only"
)
module_cfg=$(find "$DTREE" -name '.*.o.cmd' -print0 | xargs -0 cat \
             | grep -oE 'include/config/[a-z0-9_/]+\.h' | sed 's|^include/config/||; s|\.h$||' \
             | tr '/a-z' '_A-Z' | sort -u)
note "$(echo "$module_cfg" | wc -l) kernel options are visible to the module's compilation"
cfg_bad=0
while read -r sym want have; do
    echo "$module_cfg" | grep -qx "$sym" || continue
    if [ -n "${cfg_ok[$sym]:-}" ]; then
        note "seen by the module, changed, harmless: CONFIG_$sym $want->$have (${cfg_ok[$sym]})"
    else
        note "seen by the module, changed, NOT EXPLAINED: CONFIG_$sym $want->$have"
        cfg_bad=1
    fi
done < <(tr '\t' ' ' < /tmp/cfg-changed.txt)
[ "$cfg_bad" = 0 ] || die "the module depends on kernel options that differ from the car's .config"
note "all other options the module depends on equal the car's .config"

# Driver features our patch 0001 sets: each -D flag must be on every C compilation of
# the module (D_FLAGS_ON), or on none (D_FLAGS_OFF).
cc_cmds=$(find "$DTREE" -name '.*.o.cmd' ! -name '.*.mod.o.cmd' -print0 \
          | xargs -0 grep -l -- ' -c -o ' | sort)
n_cc=$(echo "$cc_cmds" | wc -l)
flag_count() {  # flag -> number of compilations that define it
    { echo "$cc_cmds" | xargs grep -lE -- "-D$1( |=|\$)" || true; } | wc -l
}
for f in $D_FLAGS_ON; do
    n=$(flag_count "$f")
    [ "$n" = "$n_cc" ] || die "-D$f is missing from $((n_cc - n)) of $n_cc compilations"
done
for f in $D_FLAGS_OFF; do
    n=$(flag_count "$f")
    [ "$n" = 0 ] || die "-D$f is set in $n of $n_cc compilations"
done
note "build flags in all $n_cc compilations: $D_FLAGS_ON"
note "build flags in none:                 $D_FLAGS_OFF"

for s in survey_info ap_info rx_signal; do
    grep -q "\"$s\"" "$DTREE/os_dep/linux/rtw_proc.c" || die "proc entry $s missing"
done
grep -q -- '-DCONFIG_PROC_DEBUG' "$DTREE/os_dep/linux/.rtw_proc.o.cmd" \
    || die "CONFIG_PROC_DEBUG is not in the build flags"
note "proc entries survey_info, ap_info, rx_signal compiled in (CONFIG_PROC_DEBUG)"
# The proc folder is /proc/net/<DRV_NAME>/ (rtw_proc.c: RTW_PROC_NAME is DRV_NAME).
grep -qE '^#define RTW_PROC_NAME[[:space:]]+DRV_NAME' "$DTREE/os_dep/linux/rtw_proc.c" \
    || die "rtw_proc.c: RTW_PROC_NAME is not DRV_NAME"
drv_name=$(sed -nE 's/^#define DRV_NAME "([^"]+)".*/\1/p' "$DTREE/include/autoconf.h" | head -1)
[ "$drv_name" = "$D_PROC" ] || die "DRV_NAME is '$drv_name', expected '$D_PROC'"
grep -qa "$D_PROC" "$KO" || die "'$D_PROC' is not in the module"
note "proc folder /proc/net/$D_PROC/"
usb_ids=$(modinfo -F alias "$KO" | sed -nE 's/^usb:v([0-9A-F]{4})p([0-9A-F]{4}).*/\1:\2/p' \
          | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ')
note "USB IDs: $usb_ids"

if [ -f /ref/ref.ko ]; then
    ref_vm=$(modinfo -F vermagic /ref/ref.ko)
    note "reference vermagic: '$ref_vm' $([ "$ref_vm" = "$vermagic" ] && echo '(same)' || echo '(DIFFERENT)')"
    ref_params=$(modinfo -F parmtype /ref/ref.ko | cut -d: -f1 | sort -u)
    our_params=$(modinfo -F parmtype "$KO" | cut -d: -f1 | sort -u)
    note "parameters only in reference: $(comm -23 <(echo "$ref_params") <(echo "$our_params") | tr '\n' ' ')"
    note "parameters only in ours:      $(comm -13 <(echo "$ref_params") <(echo "$our_params") | tr '\n' ' ')"
fi

# ---- output ---------------------------------------------------------------------------

step "output"
cp "$KO" "/out/$MODULE.ko"
size=$(stat -c %s "/out/$MODULE.ko")
sum=$(sha256sum "/out/$MODULE.ko" | cut -d' ' -f1)
{
    echo "$MODULE.ko for $KERNEL_RELEASE (Telechips tcc803x), GPL-2.0"
    echo "sha256 $sum  size $size"
    echo "source  $DRIVER_REPO"
    echo "commit  $DRIVER_COMMIT"
    echo "patches (applied in this order, shipped next to this file):"
    for p in $patches; do echo "  $(basename "$p")  sha256 $(sha256sum "$p" | cut -d' ' -f1)"; done
    echo "kernel  linux-$KERNEL_VERSION (sha256 $KERNEL_SHA256), car .config sha256 $(sha256sum "$CAR_CONFIG" | cut -d' ' -f1)"
    echo "toolchain $TOOLCHAIN_REPO @ $tc_head"
    echo "vermagic $vermagic"
} > "/out/$D_SOURCE"
note "/out/$MODULE.ko  $size bytes  sha256 $sum"
note "parameters: $(modinfo -F parmtype "/out/$MODULE.ko" | cut -d: -f1 | sort | tr '\n' ' ')"
echo
echo "BUILD OK"
