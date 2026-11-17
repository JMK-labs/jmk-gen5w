#!/bin/bash
# build.sh: host half of the jmk-wifi driver build (macOS + colima, or any Docker host).
#
# Runs inner-build.sh in an x86-64 Ubuntu 20.04 container, because the AOSP
# arm-eabi-4.7 toolchain is an x86 binary. Results land in ./out:
#   DRIVER=88x2bu (default)          DRIVER=8851bu (trial)       
#   out/88x2bu.ko                    out/8851bu.ko              the module (debug info stripped)
#   out/SOURCE.txt                   out/SOURCE-8851bu.txt      commit, patch hashes, toolchain
#                                                               and kernel used (ship it with the .ko)
#   out/build.log                    out/build-8851bu.log       full log of this run
#
# Environment (all optional):
#   DRIVER         88x2bu (default) or 8851bu
#   WORK_VOLUME    docker volume for downloads and build trees     (default jmkwifi-cr)
#   SHARED_VOLUME  older cache volume, mounted read-only; its toolchain copy is a
#                  fallback when the AOSP clone fails               (default jmkwifi-opt)
#   REF_KO         path of a module to compare vermagic and parameter names with
#   DRIVER_COMMIT  build another upstream commit (patches must still apply)
#   JOBS           parallel make jobs
#   FORCE_KERNEL_PREP=1   re-extract and re-prepare the kernel tree
#
# Usage: ./build.sh               (88x2bu)
#        DRIVER=8851bu ./build.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=${IMAGE:-ubuntu:20.04}
work_volume=${WORK_VOLUME:-jmkwifi-cr}
shared_volume=${SHARED_VOLUME:-jmkwifi-opt}

command -v docker >/dev/null || { echo "docker not found (start colima?)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable (colima start?)" >&2; exit 1; }

driver=${DRIVER:-88x2bu}
case "$driver" in
    88x2bu) source_txt=SOURCE.txt; log_name=build.log ;;
    8851bu) source_txt=SOURCE-8851bu.txt; log_name=build-8851bu.log ;;
    *) echo "unknown DRIVER=$driver (88x2bu or 8851bu)" >&2; exit 1 ;;
esac

mkdir -p "$here/out"
rm -f "$here/out/$driver.ko" "$here/out/$source_txt"
docker volume create "$work_volume" >/dev/null

mounts=(-v "$work_volume:/work" -v "$here:/src:ro" -v "$here/out:/out")
if docker volume inspect "$shared_volume" >/dev/null 2>&1; then
    mounts+=(-v "$shared_volume:/opt/shared:ro")
fi
if [ -n "${REF_KO:-}" ]; then
    ref=$(cd "$(dirname "$REF_KO")" && pwd)/$(basename "$REF_KO")
    mounts+=(-v "$ref:/ref/ref.ko:ro")
fi

envs=(-e "DRIVER=$driver")
for var in DRIVER_COMMIT JOBS FORCE_KERNEL_PREP; do
    if [ -n "${!var:-}" ]; then envs+=(-e "$var=${!var}"); fi
done

log=$here/out/$log_name
{
    echo "jmk-wifi $driver build, $(date '+%Y-%m-%d %H:%M:%S %z'), host $(uname -sm)"
    echo "image $image, work volume $work_volume"
} > "$log"

docker run --rm --platform linux/amd64 \
    "${mounts[@]}" "${envs[@]}" \
    "$image" bash /src/inner-build.sh 2>&1 | tee -a "$log"
