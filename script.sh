#!/usr/bin/env bash
#
# setup.sh — IranOpen 2026-2027 (StarterAgent2D base)
#
# Installs every dependency needed to build and run this team, builds the team
# into ./build, and can start a local match you watch in soccerwindow2.
#
# THIS SCRIPT TARGETS THE DEVELOPER'S OWN UBUNTU/DEBIAN MACHINE.
# It needs a normal network (apt + github.com) and, for --watch, a desktop.
#
# It is idempotent: anything already present is detected and skipped, so it is
# safe to re-run at any time.
#
# Usage:
#   ./setup.sh                 install deps + build the team
#   ./setup.sh --watch         deps + build + start server, 2 teams, viewer
#   ./setup.sh --deps-only     install dependencies only
#   ./setup.sh --build-only    build the team only (deps assumed present)
#   ./setup.sh --no-server     deps + librcsc + team, skip simulator and viewer
#   ./setup.sh --server-only   build rcssserver + soccerwindow2 only
#   ./setup.sh --help
#
# Everything downloaded is kept OUTSIDE this repo:
#   sources  -> $HOME/src
#   installs -> $HOME/local   (librcsc specifically -> $HOME/local/starter)
#
set -euo pipefail

#-----------------------------------------------------------------------------
# Configuration (override from the environment if you like)
#-----------------------------------------------------------------------------
SRC_DIR="${IRANOPEN_SRC_DIR:-$HOME/src}"           # where we clone sources
PREFIX="${IRANOPEN_PREFIX:-$HOME/local}"           # where we install tools
LIBRCSC_PREFIX="${LIBRCSC_PREFIX:-$HOME/local/starter}"  # MUST match CMakeLists.txt
# soccerwindow2 is written against helios-base/librcsc, which may be newer than
# the RCSS-IR fork this team builds against. If needed we install it separately
# so the two never overwrite each other.
HELIOS_LIBRCSC_PREFIX="${HELIOS_LIBRCSC_PREFIX:-$HOME/local/librcsc-helios}"
VIEWER_LIBRCSC_PREFIX=""   # set if the viewer ends up using the helios build

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_DIR/build"

JOBS="$(nproc 2>/dev/null || echo 2)"
TEAM_NAME="${IRANOPEN_TEAM_NAME:-IranOpen2026}"

DO_DEPS=1
DO_BUILD=1
DO_SERVER=1
DO_WATCH=0

QT_OK=1   # set to 0 if no Qt5 dev package is available (skips the viewer)

#-----------------------------------------------------------------------------
# Output helpers
#-----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
skip() { printf '    %s·%s %s (already present)\n' "$C_Y" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Import librcsc shared libs for anything we run that links against it.
export LD_LIBRARY_PATH="${LIBRCSC_PREFIX}/lib:${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

#-----------------------------------------------------------------------------
# Argument parsing
#-----------------------------------------------------------------------------
usage() { awk 'NR>1 && /^set -euo pipefail/{exit} NR>1' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --watch)       DO_WATCH=1 ;;
        --deps-only)   DO_BUILD=0; DO_SERVER=0 ;;
        --build-only)  DO_DEPS=0;  DO_SERVER=0 ;;
        --server-only) DO_DEPS=1;  DO_BUILD=0 ;;
        --no-server)   DO_SERVER=0 ;;
        --team-name)   [ $# -ge 2 ] || die "--team-name needs a value"; TEAM_NAME="$2"; shift ;;
        --jobs)        [ $# -ge 2 ] || die "--jobs needs a value"; JOBS="$2"; shift ;;
        -h|--help)     usage ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

#-----------------------------------------------------------------------------
# Step 1 — system packages
#-----------------------------------------------------------------------------
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# True if the package exists in the configured repositories.
# Used instead of guessing names from the distro string — derivatives such as
# Linux Mint or Pop!_OS report their own ID, and 'qt5-default' was removed from
# Ubuntu after 20.04, so distro-based guessing fails. Ask apt instead.
pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

install_packages() {
    step "System packages"

    have apt-get || die "this script needs apt-get (Ubuntu/Debian). Install manually on other systems."

    # sudo only if we are not already root
    local SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"
    if [ -n "$SUDO" ] && ! have sudo; then
        die "not root and 'sudo' is missing — install packages by hand, then re-run."
    fi

    # Core packages: everything the base, librcsc and rcssserver need.
    local CORE_PKGS="
        build-essential cmake git pkg-config
        autoconf automake libtool flex libfl-dev bison
        zlib1g-dev libboost-all-dev
        libfontconfig1-dev libaudio-dev libxt-dev libglib2.0-dev libxi-dev libxrender-dev
    "
    # libfl-dev provides FlexLexer.h — rcssserver's coach-language parser
    # includes it, and the 'flex' package alone does not ship that header.

    $SUDO apt-get update -qq

    # --- Qt5 -----------------------------------------------------------------
    # Candidate groups, most modern first. Take the first group where every
    # package is either already installed or available in the repositories.
    # Distro-agnostic on purpose: Mint/Pop/Zorin all report their own ID, and
    # 'qt5-default' was dropped after Ubuntu 20.04, so name-based guessing broke.
    # 'qtbase5-dev' alone is enough for the CMake build — qmake is only needed
    # for the .pro path, which we do not use.
    local QT_PKGS="" group p all_ok
    for group in "qtbase5-dev qt5-qmake" "qtbase5-dev" "qt5-default"; do
        all_ok=1
        for p in $group; do
            if ! pkg_installed "$p" && ! pkg_available "$p"; then all_ok=0; fi
        done
        if [ "$all_ok" -eq 1 ]; then QT_PKGS="$group"; break; fi
    done

    if [ -z "$QT_PKGS" ]; then
        QT_OK=0
        warn "no Qt5 development package exists in your repositories"
        warn "soccerwindow2 (the viewer) will be skipped — the team still builds fine"
    else
        ok "Qt5 development packages: $QT_PKGS"
    fi

    # --- Work out what is actually missing ------------------------------------
    local MISSING="" UNAVAILABLE=""
    for p in $CORE_PKGS $QT_PKGS; do
        if pkg_installed "$p"; then
            continue
        elif pkg_available "$p"; then
            MISSING="$MISSING $p"
        else
            UNAVAILABLE="$UNAVAILABLE $p"
        fi
    done

    [ -n "$UNAVAILABLE" ] && warn "not in your repositories, skipping:$UNAVAILABLE"

    if [ -z "$MISSING" ]; then
        skip "all system packages present"
        ok   "toolchain: $(g++ --version 2>/dev/null | head -1 || echo 'g++ ?')"
        return 0
    fi

    # shellcheck disable=SC2086
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING
    ok "packages installed"
}

#-----------------------------------------------------------------------------
# Step 2 — librcsc (the agent library this base is written against)
#-----------------------------------------------------------------------------
ensure_librcsc() {
    step "librcsc -> $LIBRCSC_PREFIX"

    if [ -f "$LIBRCSC_PREFIX/include/rcsc/types.h" ] \
       && ls "$LIBRCSC_PREFIX"/lib/librcsc* >/dev/null 2>&1; then
        skip "librcsc already installed"
        return 0
    fi

    have cmake || die "cmake missing — run the package step first."
    mkdir -p "$SRC_DIR"
    local DIR="$SRC_DIR/StarterLibRCSC-V2"

    if [ -d "$DIR/.git" ]; then
        ok "updating existing checkout"
        git -C "$DIR" pull --ff-only || warn "pull failed, using what is on disk"
    else
        ok "cloning RCSS-IR/StarterLibRCSC-V2"
        git clone --depth 1 https://github.com/RCSS-IR/StarterLibRCSC-V2 "$DIR"
    fi

    cmake -S "$DIR" -B "$DIR/build" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$LIBRCSC_PREFIX"
    cmake --build "$DIR/build" -j "$JOBS"
    cmake --install "$DIR/build"

    [ -f "$LIBRCSC_PREFIX/include/rcsc/types.h" ] || die "librcsc install did not produce headers"
    ok "librcsc installed"
}

#-----------------------------------------------------------------------------
# Step 3 — build this team
#-----------------------------------------------------------------------------
build_team() {
    step "Building the team -> $BUILD_DIR"

    [ -f "$LIBRCSC_PREFIX/include/rcsc/types.h" ] || die "librcsc missing — run the dependency step first."

    cmake -S "$REPO_DIR" -B "$BUILD_DIR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DLIBRCSC_INSTALL_DIR="$LIBRCSC_PREFIX"
    cmake --build "$BUILD_DIR" -j "$JOBS"

    [ -x "$BUILD_DIR/bin/start.sh" ] || die "build finished but build/bin/start.sh is missing"
    ok "team built"

    # start.sh points --config_dir at formations-dt, which is not in the base.
    # Positions are hardcoded in strategy.cpp, so an empty dir is enough to
    # keep the launch script happy.
    local FORM="$BUILD_DIR/bin/formations-dt"
    if [ ! -d "$FORM" ]; then
        mkdir -p "$FORM"
        warn "created empty build/bin/formations-dt (base has none; positions are hardcoded)"
    fi
}

#-----------------------------------------------------------------------------
# Step 4 — rcssserver (the simulator) and soccerwindow2 (the viewer)
#-----------------------------------------------------------------------------
ensure_rcssserver() {
    step "rcssserver -> $PREFIX"

    if have rcssserver || [ -x "$PREFIX/bin/rcssserver" ]; then
        skip "rcssserver already available"
        return 0
    fi

    mkdir -p "$SRC_DIR"
    local DIR="$SRC_DIR/rcssserver"

    if [ -d "$DIR/.git" ]; then
        git -C "$DIR" pull --ff-only || warn "pull failed, using what is on disk"
    else
        ok "cloning rcsoccersim/rcssserver"
        git clone --depth 1 https://github.com/rcsoccersim/rcssserver "$DIR"
    fi

    # rcssserver 17+ supports CMake; the autotools path needs flex/bison.
    cmake -S "$DIR" -B "$DIR/build" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build "$DIR/build" -j "$JOBS"
    cmake --install "$DIR/build"

    ok "rcssserver installed"
}

# soccerwindow2 targets helios-base/librcsc. If it will not build against the
# RCSS-IR fork the team uses, install the upstream one under its own prefix.
ensure_helios_librcsc() {
    step "helios-base/librcsc -> $HELIOS_LIBRCSC_PREFIX"

    if [ -f "$HELIOS_LIBRCSC_PREFIX/include/rcsc/types.h" ] \
       && ls "$HELIOS_LIBRCSC_PREFIX"/lib/librcsc.so* >/dev/null 2>&1; then
        skip "helios-base/librcsc already installed"
        return 0
    fi

    mkdir -p "$SRC_DIR"
    local DIR="$SRC_DIR/librcsc-helios"

    if [ -d "$DIR/.git" ]; then
        git -C "$DIR" pull --ff-only || warn "pull failed, using what is on disk"
    else
        ok "cloning helios-base/librcsc"
        git clone --depth 1 https://github.com/helios-base/librcsc "$DIR"
    fi

    # Built with autotools, NOT CMake, on purpose. The CMake build of
    # helios-base/librcsc is broken: its CMakeLists never runs
    # check_include_file_cxx("netinet/in.h" ...), so HAVE_NETINET_IN_H stays
    # undefined, the guarded #include is skipped, and sockaddr_in becomes an
    # incomplete type. It also hard-sets CMAKE_CXX_FLAGS, so the define cannot
    # be injected from the command line either. Autotools runs every check.
    ( cd "$DIR" \
      && ./bootstrap \
      && ./configure --prefix="$HELIOS_LIBRCSC_PREFIX" \
      && make -j "$JOBS" \
      && make install )

    [ -f "$HELIOS_LIBRCSC_PREFIX/include/rcsc/types.h" ] \
        && ls "$HELIOS_LIBRCSC_PREFIX"/lib/librcsc.so* >/dev/null 2>&1 \
        || die "helios-base/librcsc install produced no headers or shared library"
    ok "helios-base/librcsc installed"
}

ensure_soccerwindow2() {
    step "soccerwindow2 -> $PREFIX"

    if have soccerwindow2; then
        if [ -f "$PREFIX/share/soccerwindow2/librcsc-prefix" ]; then
            VIEWER_LIBRCSC_PREFIX="$(cat "$PREFIX/share/soccerwindow2/librcsc-prefix")"
        fi
        skip "soccerwindow2 already available on PATH"
        return 0
    fi

    if [ -x "$PREFIX/bin/soccerwindow2" ] \
       && [ -f "$PREFIX/share/soccerwindow2/soccerwindow2.xpm" ]; then
        if [ -f "$PREFIX/share/soccerwindow2/librcsc-prefix" ]; then
            VIEWER_LIBRCSC_PREFIX="$(cat "$PREFIX/share/soccerwindow2/librcsc-prefix")"
        fi
        skip "soccerwindow2 already installed under $PREFIX"
        return 0
    fi

    if [ "$QT_OK" -ne 1 ]; then
        skip "soccerwindow2 skipped (no Qt5 dev package available)"
        return 0
    fi

    mkdir -p "$SRC_DIR"
    local DIR="$SRC_DIR/soccerwindow2"

    if [ -d "$DIR/.git" ]; then
        git -C "$DIR" pull --ff-only || warn "pull failed, using what is on disk"
    else
        ok "cloning helios-base/soccerwindow2 (branch develop)"
        git clone --depth 1 -b develop https://github.com/helios-base/soccerwindow2 "$DIR"
    fi

    # soccerwindow2's CMakeLists defaults LIBRCSC_INSTALL_DIR to
    # $HOME/.local;$HOME/local — NOT $HOME/local/starter where the team's
    # librcsc lives. CMAKE_PREFIX_PATH does not override that variable, so pass
    # it explicitly. Its CMake install rule also looks for generated sswindow2
    # in the source tree; configure_file actually writes it under build/src.
    # Build with CMake, then install the known outputs manually.
    local LOG="$SRC_DIR/soccerwindow2-build.log"

    build_viewer() {
        local librcsc_dir="$1"
        rm -rf "$DIR/build"
        { cmake -S "$DIR" -B "$DIR/build" \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX="$PREFIX" \
              -DLIBRCSC_INSTALL_DIR="$librcsc_dir" \
          && cmake --build "$DIR/build" -j "$JOBS" \
          && { test -x "$DIR/build/soccerwindow2" \
                   || { echo "built soccerwindow2 executable is missing" >&2; false; }; } \
          && install -D -m 0755 "$DIR/build/soccerwindow2" "$PREFIX/bin/soccerwindow2" \
          && install -D -m 0755 "$DIR/build/src/sswindow2" "$PREFIX/bin/sswindow2" \
          && install -D -m 0644 "$DIR/xpm/soccerwindow2.xpm" \
               "$PREFIX/share/soccerwindow2/soccerwindow2.xpm"
        } >"$LOG" 2>&1
    }

    if build_viewer "$LIBRCSC_PREFIX"; then
        rm -f "$PREFIX/share/soccerwindow2/librcsc-prefix"
        ok "soccerwindow2 installed (linked against the team's librcsc)"
        return 0
    fi

    warn "soccerwindow2 did not build against the team's librcsc fork. Showing the tail:"
    [ -s "$LOG" ] && tail -15 "$LOG" | sed 's/^/        /'
    warn "retrying against helios-base/librcsc, which is what soccerwindow2 targets"

    ensure_helios_librcsc

    if build_viewer "$HELIOS_LIBRCSC_PREFIX"; then
        VIEWER_LIBRCSC_PREFIX="$HELIOS_LIBRCSC_PREFIX"
        printf '%s\n' "$VIEWER_LIBRCSC_PREFIX" \
            > "$PREFIX/share/soccerwindow2/librcsc-prefix"
        ok "soccerwindow2 installed (linked against helios-base/librcsc)"
        return 0
    fi

    [ -s "$LOG" ] && tail -30 "$LOG" | sed 's/^/        /'
    die "soccerwindow2 failed against both librcsc builds. It needs Qt5 dev (qtbase5-dev), Boost and librcsc. Full log: $LOG"
}

#-----------------------------------------------------------------------------
# Step 5 — watch a match
#-----------------------------------------------------------------------------
find_bin() {
    local name="$1"
    if have "$name"; then command -v "$name"; return 0; fi
    [ -x "$PREFIX/bin/$name" ] && { echo "$PREFIX/bin/$name"; return 0; }
    return 1
}

watch_match() {
    step "Starting a local match"

    # If the viewer was linked against the separate helios librcsc, it needs to
    # find that .so at runtime.
    [ -n "$VIEWER_LIBRCSC_PREFIX" ] \
        && export LD_LIBRARY_PATH="${VIEWER_LIBRCSC_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

    local SERVER VIEWER=""
    SERVER="$(find_bin rcssserver)" || die "rcssserver not found"
    find_bin soccerwindow2 >/dev/null 2>&1 && VIEWER="$(find_bin soccerwindow2)"
    [ -x "$BUILD_DIR/bin/start.sh" ] || die "team not built yet"

    if [ -z "$VIEWER" ]; then
        warn "soccerwindow2 not installed — starting the match without a viewer."
        warn "The server and both teams will still run; connect any monitor to localhost:6000."
    fi

    local PIDS=()
    cleanup() {
        printf '\n    stopping match...\n'
        for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
        pkill -f 'rcssserver' 2>/dev/null || true
        pkill -f 'sample_player' 2>/dev/null || true
        pkill -f 'sample_coach' 2>/dev/null || true
        pkill -f 'soccerwindow2' 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    ok "server:  $SERVER"
    "$SERVER" &
    PIDS+=("$!")
    sleep 2

    ok "team L:  ${TEAM_NAME}_L"
    ( cd "$BUILD_DIR/bin" && ./start.sh -t "${TEAM_NAME}_L" ) &
    PIDS+=("$!")
    sleep 1

    ok "team R:  ${TEAM_NAME}_R"
    ( cd "$BUILD_DIR/bin" && ./start.sh -t "${TEAM_NAME}_R" ) &
    PIDS+=("$!")
    sleep 1

    if [ -n "$VIEWER" ]; then
        ok "viewer:  $VIEWER"
        "$VIEWER" &
        PIDS+=("$!")
    fi

    printf '\n%sMatch running. Press Ctrl-C to stop everything.%s\n\n' "$C_B" "$C_0"
    wait
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
[ "$DO_DEPS"   -eq 1 ] && install_packages
[ "$DO_DEPS"   -eq 1 ] && ensure_librcsc
[ "$DO_BUILD"  -eq 1 ] && build_team
[ "$DO_SERVER" -eq 1 ] && ensure_rcssserver
[ "$DO_SERVER" -eq 1 ] && ensure_soccerwindow2

if [ "$DO_WATCH" -eq 1 ]; then
    watch_match
else
    step "Done"
    ok "team binary:  $BUILD_DIR/bin/start.sh"
    printf '\n    To play a match and watch it:\n'
    printf '        %s\n\n' "./setup.sh --watch"
fi
