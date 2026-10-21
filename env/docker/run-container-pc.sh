#!/bin/bash
#
# run-container-pc.sh — launch the x86_64 PC image built from Dockerfile.pc
# (Ubuntu 22.04 + CUDA 12.5 + ROS 2 Humble). Companion to run-container.sh,
# which targets the aarch64 Jetson image chain.
#
set -e # exit on command failure

# ---------------------------------------------------------------------------
# PARAMETERS
# ---------------------------------------------------------------------------
IMAGE_TAG="${IMAGE_TAG:-autonav-pc:humble}"
CONTAINER_NAME="${CONTAINER_NAME:-autonav-pc}"

# Repo root, derived from this script's location (env/docker/ -> repo root),
# so it works regardless of where the repo is cloned.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOST_WORKDIR="${HOST_WORKDIR:-$REPO_ROOT}"
CONTAINER_WORKDIR="/autonav"                       # repo mounts here
WS="${CONTAINER_WORKDIR}/isaac_ros-dev"            # colcon workspace inside repo

DOCKER_ARGS=()

# ---------------------------------------------------------------------------
# GUARD: correct platform + image present
# ---------------------------------------------------------------------------
if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "WARNING: this script targets x86_64; detected $(uname -m)." >&2
    echo "         For the Jetson (aarch64) image use run-container.sh." >&2
fi

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "ERROR: image '$IMAGE_TAG' not found." >&2
    echo "  Build it first:" >&2
    echo "    docker build -t $IMAGE_TAG -f $SCRIPT_DIR/dockerfiles/Dockerfile.pc $SCRIPT_DIR/dockerfiles" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
DOCKER_ARGS+=("-e" "ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}")
DOCKER_ARGS+=("-e" "WORKDIR=${CONTAINER_WORKDIR}")

# ---------------------------------------------------------------------------
# GPU (NVIDIA Container Toolkit)
# ---------------------------------------------------------------------------
DOCKER_ARGS+=("--runtime" "nvidia")
DOCKER_ARGS+=("--gpus" "all")
DOCKER_ARGS+=("-e" "NVIDIA_VISIBLE_DEVICES=all")
DOCKER_ARGS+=("-e" "NVIDIA_DRIVER_CAPABILITIES=all")

# ---------------------------------------------------------------------------
# NETWORKING & IPC (ROS 2 DDS discovery + shared-memory transport / ZED)
# ---------------------------------------------------------------------------
DOCKER_ARGS+=("--network=host")
DOCKER_ARGS+=("--ipc=host")

# ---------------------------------------------------------------------------
# X11 DISPLAY FORWARDING (rviz2, rqt, OpenCV windows)
# ---------------------------------------------------------------------------
if [[ -n "${DISPLAY:-}" ]]; then
    DOCKER_ARGS+=("-e" "DISPLAY=$DISPLAY")
    DOCKER_ARGS+=("-v" "/tmp/.X11-unix:/tmp/.X11-unix:rw")
    if [[ -f "$HOME/.Xauthority" ]]; then
        DOCKER_ARGS+=("-v" "$HOME/.Xauthority:/root/.Xauthority:rw")
        DOCKER_ARGS+=("-e" "XAUTHORITY=/root/.Xauthority")
    fi
    # Allow the local root-owned container to talk to the host X server.
    if command -v xhost >/dev/null 2>&1; then
        xhost +local:root >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# DBUS / UDEV (device hotplug, joystick, etc.)
# ---------------------------------------------------------------------------
[[ -d /run/dbus ]] && DOCKER_ARGS+=("-v" "/run/dbus:/run/dbus")
[[ -d /run/udev ]] && DOCKER_ARGS+=("-v" "/run/udev:/run/udev:ro")
[[ -d /dev/input ]] && DOCKER_ARGS+=("-v" "/dev/input:/dev/input")

# ---------------------------------------------------------------------------
# SERIAL / USB DEVICES (all optional — skipped cleanly if not present)
# ---------------------------------------------------------------------------
# ZED / other USB devices: expose the whole USB bus.
[[ -d /dev/bus/usb ]] && DOCKER_ARGS+=("-v" "/dev/bus/usb:/dev/bus/usb")

# Stable serial symlinks (Arduino, RoboteQ, LiDAR, GPS...).
if [[ -d /dev/serial/by-id ]]; then
    DOCKER_ARGS+=("-v" "/dev/serial/by-id:/dev/serial/by-id:ro")
    for link in /dev/serial/by-id/*; do
        [[ -e "$link" ]] || continue
        real_dev="$(readlink -f "$link")"
        DOCKER_ARGS+=("--device=${real_dev}:${real_dev}")
    done
fi

# Named udev symlinks, if the project's rules created them.
for dev in /dev/arduino_uno /dev/roboteq; do
    [[ -e "$dev" ]] && DOCKER_ARGS+=("--device=${dev}:${dev}")
done

# Group membership so the container can open tty / video / render nodes.
for grp in dialout video render input plugdev; do
    gid=$(getent group "$grp" | cut -d: -f3)
    [[ -n "$gid" ]] && DOCKER_ARGS+=("--group-add=${gid}")
done

# ---------------------------------------------------------------------------
# MOUNTS & WORKING DIRECTORY
# ---------------------------------------------------------------------------
DOCKER_ARGS+=("-v" "${HOST_WORKDIR}:${CONTAINER_WORKDIR}")
DOCKER_ARGS+=("-v" "/etc/localtime:/etc/localtime:ro")
DOCKER_ARGS+=("--workdir=${WS}")

# Persistent colcon artifacts. As named volumes these are seeded from the
# image on first use, preserving the from-source cv_bridge install while
# keeping build output out of the bind-mounted source tree.
DOCKER_ARGS+=("-v" "${CONTAINER_NAME}-build:${WS}/build")
DOCKER_ARGS+=("-v" "${CONTAINER_NAME}-install:${WS}/install")
DOCKER_ARGS+=("-v" "${CONTAINER_NAME}-log:${WS}/log")

# ZED settings/resources (optional).
[[ -d "$HOME/zed/settings" ]]  && DOCKER_ARGS+=("-v" "$HOME/zed/settings:/usr/local/zed/settings")
[[ -d "$HOME/zed/resources" ]] && DOCKER_ARGS+=("-v" "$HOME/zed/resources:/usr/local/zed/resources")

# SSH agent (optional, for private submodule pulls inside the container).
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    DOCKER_ARGS+=("-v" "$SSH_AUTH_SOCK:/ssh-agent")
    DOCKER_ARGS+=("-e" "SSH_AUTH_SOCK=/ssh-agent")
fi

# ---------------------------------------------------------------------------
# RE-USE EXISTING CONTAINER
# ---------------------------------------------------------------------------
if [ "$(docker ps --quiet --filter status=running --filter name=^/${CONTAINER_NAME}$)" ]; then
    echo "Container $CONTAINER_NAME is already running. Attaching..."
    exec docker exec -it --workdir "${WS}" "$CONTAINER_NAME" /bin/bash -l "$@"
fi

if [ "$(docker ps -a --quiet --filter status=exited --filter name=^/${CONTAINER_NAME}$)" ]; then
    echo "Container $CONTAINER_NAME exists but is stopped. Starting and attaching..."
    docker start "$CONTAINER_NAME" >/dev/null
    exec docker exec -it --workdir "${WS}" "$CONTAINER_NAME" /bin/bash -l "$@"
fi

# ---------------------------------------------------------------------------
# CREATE NEW CONTAINER
# ---------------------------------------------------------------------------
echo "Starting new container: $CONTAINER_NAME"
echo "Image:    $IMAGE_TAG"
echo "Mounting: ${HOST_WORKDIR} -> ${CONTAINER_WORKDIR}"

# '-l' login shell sources /etc/profile.d/ros_humble.sh (ROS auto-source).
exec docker run -it \
    --name "$CONTAINER_NAME" \
    "${DOCKER_ARGS[@]}" \
    "$IMAGE_TAG" \
    /bin/bash -l
