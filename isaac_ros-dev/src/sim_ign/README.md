# sim_ign — IGVC simulation on Gazebo Fortress (Ignition Gazebo 6)

A port of the Classic `sim` package to **Gazebo Fortress**, the LTS Gazebo for
ROS 2 Humble. ROS 2 talks to the simulator through the **`ros_gz` bridge**
instead of the Classic `gazebo_ros` in-process plugins.

## Relevant software
- Simulator: **Gazebo Fortress** (`ign gazebo`, Ignition Gazebo 6.x)
- ROS distro: **Humble**
- Bridge: **ros_gz** (`ros_gz_sim`, `ros_gz_bridge`, `ros_gz_image`)

## Build & run
```bash
colcon build --packages-select sim_ign
source install/setup.bash
ros2 launch sim_ign launch_sim.launch.py                 # empty world (default)
ros2 launch sim_ign launch_sim.launch.py \
    world:=$(ros2 pkg prefix sim_ign)/share/sim_ign/worlds/autonav_igvc_course.world
```
Drive it: `ros2 run teleop_twist_keyboard teleop_twist_keyboard` (publishes `/cmd_vel`).

## What changed vs the Classic `sim` package
The move is architectural, not a rename. Highlights:

| Classic (`sim`) | Fortress (`sim_ign`) |
|---|---|
| `gazebo` + `libgazebo_ros_init/factory.so` | `ign gazebo` via `ros_gz_sim/gz_sim.launch.py` |
| `gazebo_ros spawn_entity.py` | `ros_gz_sim create` |
| in-SDF `libgazebo_ros_*` sensor plugins | world-level system plugins + `ros_gz_bridge` |
| `libgazebo_ros_diff_drive.so` | `ignition-gazebo-diff-drive-system` (uses `wheel_radius`, not diameter) |
| `libgazebo_ros_imu_sensor.so` | `<sensor type="imu">` + world `Imu` system |
| `type="ray"` + `libgazebo_ros_ray_sensor.so` | `type="gpu_lidar"` (`<ray>`→`<lidar>`) + world `Sensors` system |
| `type="depth"` + `libgazebo_ros_camera.so` | `type="rgbd_camera"` / `type="depth_camera"` + world `Sensors` system |
| `libhector_gazebo_ros_gps.so` | `<sensor type="navsat">` + world `NavSat` system + world `<spherical_coordinates>` |
| `libgazebo_ros_p3d.so` (ground truth) | `ignition-gazebo-odometry-publisher-system` |
| `<gazebo><material>Gazebo/Blue</material>` | dropped; URDF `<material><color rgba>` is used |

**Plugin naming note:** Fortress plugins are `filename="ignition-gazebo-*-system"`
with `name="gz::sim::systems::*"`. The abandoned `autonav_sim` attempt used
`filename="gz-sim-*"` (Garden/Harmonic naming), which does not load in Fortress.

## ROS topics (via the bridge)
| ROS topic | Direction | Notes |
|---|---|---|
| `/clock` | sim → ROS | drives `use_sim_time` |
| `/cmd_vel` | ROS → sim | diff-drive input |
| `/odom`, `/tf`, `/joint_states` | sim → ROS | odom + transforms |
| `/imu` | sim → ROS | IMU |
| `/zed/image`, `/zed/camera_info`, `/zed/depth/image`, `/zed/points` | sim → ROS | front RGB-D camera (bridged from `/camera/*`) |
| `/scan`, `/navsat` | sim → ROS | commented out — enable the xacro include **and** the matching bridge line |

Enabled sensors are controlled by the `<xacro:include>` lines in
`description/custom_robot/robot.urdf.xacro` (lidar / gps / ground_truth are
commented, matching the Classic default).

## KNOWN LIMITATION — the course world is a scaffold
`worlds/autonav_igvc_course.world` launches and loads the road-tile geometry,
but it is **not a finished port**:

1. **Layout** — the Classic world stored 50+ tile/barrel poses in a 6000-line
   `<state>` dump. Those exact poses are not transcribed; tiles are on a
   placeholder grid.
2. **Textures** — every road `model.sdf` in `custom_models/` uses a Classic
   Ogre `<material><script>` (e.g. `vrc/course`) that ign-rendering cannot
   load. The painted lane lines will **not** render until each model is
   converted to a Fortress PBR `<material>` with an `<albedo_map>` pointing at
   its texture PNG. Until then tiles are grey and unusable for line detection.

`worlds/empty.world` is fully functional and is the default.
