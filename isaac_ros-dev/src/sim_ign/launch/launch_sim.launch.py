import os

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import (
    IncludeLaunchDescription,
    DeclareLaunchArgument,
    SetEnvironmentVariable,
    OpaqueFunction,
)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():

    package_name = 'sim_ign'
    pkg_share = get_package_share_directory(package_name)

    # ----------------------------------------------------------------------
    # Resource path so `model://...` includes in the world resolve to the
    # installed custom_models (Fortress uses IGN_GAZEBO_RESOURCE_PATH).
    # ----------------------------------------------------------------------
    resource_paths = os.pathsep.join([
        os.path.join(pkg_share, 'custom_models'),
        os.path.join(pkg_share, 'worlds'),
    ])
    set_resource_path = SetEnvironmentVariable(
        name='IGN_GAZEBO_RESOURCE_PATH',
        value=resource_paths,
    )

    # ----------------------------------------------------------------------
    # Launch args
    # ----------------------------------------------------------------------
    world = DeclareLaunchArgument(
        'world',
        default_value=os.path.join(pkg_share, 'worlds', 'empty.world'),
        description='Absolute path to the Ignition/Fortress .world (SDF) file',
    )
    spawn_pose = DeclareLaunchArgument(
        'spawn_pose',
        default_value='0 0 0 0 0 0',
        description="Robot spawn pose 'x y z r p y' (meters, radians).",
    )

    # ----------------------------------------------------------------------
    # robot_state_publisher (publishes /robot_description + static TF)
    # ----------------------------------------------------------------------
    rsp = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([os.path.join(
            pkg_share, 'launch', 'rsp.launch.py')]),
        launch_arguments={'use_sim_time': 'true'}.items()
    )

    # ----------------------------------------------------------------------
    # Gazebo Fortress via ros_gz_sim. '-r' runs the sim immediately.
    # ----------------------------------------------------------------------
    gazebo = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([PathJoinSubstitution([
            FindPackageShare('ros_gz_sim'), 'launch', 'gz_sim.launch.py'])]),
        launch_arguments={
            'gz_args': ['-r -v 4 ', LaunchConfiguration('world')],
            'gz_version': '6',
        }.items()
    )

    # ----------------------------------------------------------------------
    # Spawn the robot from the /robot_description topic (ros_gz_sim create).
    # ----------------------------------------------------------------------
    # Parse spawn_pose ('x y z r p y') at launch time and build the create Node.
    def _spawn_robot(context, *args, **kwargs):
        pose = LaunchConfiguration('spawn_pose').perform(context).split()
        if len(pose) != 6:
            raise RuntimeError(
                "spawn_pose must be 6 floats 'x y z r p y', got "
                f"{len(pose)}: {pose!r}")
        x, y, z, r, p, yaw = pose
        return [Node(
            package='ros_gz_sim',
            executable='create',
            arguments=[
                '-topic', 'robot_description',
                '-name', 'my_bot',
                '-x', x, '-y', y, '-z', z,
                '-R', r, '-P', p, '-Y', yaw,
            ],
            output='screen',
        )]

    spawn_entity = OpaqueFunction(function=_spawn_robot)

    # ----------------------------------------------------------------------
    # ros_gz parameter_bridge: Ignition <-> ROS 2 topic bridge.
    # Format: TOPIC@ROS_TYPE(dir)IGN_TYPE  where  [ = gz->ros, ] = ros->gz.
    # ----------------------------------------------------------------------
    bridge = Node(
        package='ros_gz_bridge',
        executable='parameter_bridge',
        name='ros_gz_bridge',
        output='screen',
        arguments=[
            # sim clock -> ROS (drives use_sim_time)
            '/clock@rosgraph_msgs/msg/Clock[ignition.msgs.Clock',
            # velocity command ROS -> sim
            '/cmd_vel@geometry_msgs/msg/Twist]ignition.msgs.Twist',
            # odometry + TF + joint states  sim -> ROS
            '/odom@nav_msgs/msg/Odometry[ignition.msgs.Odometry',
            '/tf@tf2_msgs/msg/TFMessage[ignition.msgs.Pose_V',
            '/joint_states@sensor_msgs/msg/JointState[ignition.msgs.Model',
            # IMU  sim -> ROS
            '/imu@sensor_msgs/msg/Imu[ignition.msgs.IMU',
            # front RGB-D camera ("zed")  sim -> ROS
            '/camera/image@sensor_msgs/msg/Image[ignition.msgs.Image',
            '/camera/camera_info@sensor_msgs/msg/CameraInfo[ignition.msgs.CameraInfo',
            '/camera/depth_image@sensor_msgs/msg/Image[ignition.msgs.Image',
            '/camera/points@sensor_msgs/msg/PointCloud2[ignition.msgs.PointCloudPacked',
            # 3D lidar point cloud  sim -> ROS
            '/lidar/points@sensor_msgs/msg/PointCloud2[ignition.msgs.PointCloudPacked',
            # --- optional sensors (enable the matching xacro include first) ---
            # '/navsat@sensor_msgs/msg/NavSatFix[ignition.msgs.NavSat',
        ],
        # The camera streams out as /camera/*; remap into the /zed/* namespace
        # the Classic package used so downstream nodes keep working.
        remappings=[
            ('/camera/image', '/zed/image'),
            ('/camera/camera_info', '/zed/camera_info'),
            ('/camera/depth_image', '/zed/depth/image'),
            ('/camera/points', '/zed/points'),
        ],
    )

    return LaunchDescription([
        set_resource_path,
        world,
        spawn_pose,
        rsp,
        gazebo,
        spawn_entity,
        bridge,
    ])
