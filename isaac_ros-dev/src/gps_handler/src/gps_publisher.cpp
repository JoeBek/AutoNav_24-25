#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <sstream>
#include <vector>
#include <cstring>
#include <cstdlib>

#include "serialib.hpp"
#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/string.hpp"
#include "sensor_msgs/msg/nav_sat_fix.hpp"

using namespace std::chrono_literals;

// GPS Serial Port
#define SERIAL_PORT "/dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller_D-if00-port0"
// Indices for GPS Data when header is removed from the original serial data string
#define GPS_SOLUTION_STATUS_INDEX 0
#define POSITION_TYPE_INDEX 1
#define LATITUDE_INDEX 2
#define LONGITUDE_INDEX 3
#define ALTITUDE_INDEX 4
#define UNDULATION_INDEX 5
#define DATUM_ID_INDEX 6
#define LATITUDE_STANDARD_DEVIATION_INDEX 7
#define LONGITUDE_STANDARD_DEVIATION_INDEX 8
#define ALTITUDE_STANDARD_DEVIATION_INDEX 9
#define BASE_STATION_ID_INDEX 10
#define DIFFERENTIAL_AGE_INDEX 11
#define SOLUTION_AGE_INDEX 12
#define NUM_OF_SATELLITES_TRACKED_INDEX 13
#define NUM_OF_SATELLITES_SOLUTIONS_INDEX 14
#define NUM_OF_SATELLITES_L1_SOLUTIONS_INDEX 15
#define NUM_OF_SATELLITES_WITH_MULTI_FREQUENCY_SIGNAL_SOLUTIONS_INDEX 16
#define RESERVED_INDEX 17
#define EXTENDED_SOLUTION_STATUS_INDEX 18
#define GALILEO_SIGNAL_INDEX 19
#define CRC_CHECKSUM_INDEX 20

class GPSPublisher : public rclcpp::Node {
  public:
    GPSPublisher()
    : Node("gps_publisher"), gps_connected(false){
      publisher_ = this->create_publisher<sensor_msgs::msg::NavSatFix>("gps_fix", 50);
      timer_ = this->create_wall_timer(200ms, std::bind(&GPSPublisher::update_gps, this));
    }
  private:
    void init_gps() {
        char opened = gps_serial.openDevice(SERIAL_PORT, 115200);
        if (opened != 1) {  // Check if Serial Connection was successful
            printf("Failed to open serial port: %d\n", (int)opened);
            return;
        }
        printf("Successful connection to %s\n", SERIAL_PORT);

        // Handle GPS setup
        gps_serial.writeString("unlogall\r\n");
        char gps_start_cmd[32] = "log bestposa ontime 0.2\r\n"; // Send GPS updates every 0.5 seconds
        gps_serial.writeString(gps_start_cmd); 

        // Clear the serial read cache
        for(int i = 0; i <= 4; i++){
            char gps_buffer[1024] = {};
            // int bytes_read = gps_serial.readString(gps_buffer, '\n', 1023, 1000);
            gps_serial.readString(gps_buffer, '\n', 1023, 1000);
        }
        gps_connected = true;
    }

    std::vector<std::string> split(const std::string &input, char delimiter) {
        std::vector<std::string> tokens;
        std::string token;
        std::istringstream ss(input);

        // Split the Data Segment fields into seperate tokens that are passed into an iterable vector of strings
        while (std::getline(ss, token, delimiter)) {
            tokens.push_back(token);
        }
        return tokens;
    }

    void update_gps() {
        if (!gps_connected) {   // Initialize Serial Connection with GPS
            init_gps();
        }
        else {  // If Serial Connection is secure read GPS data serially and publish it
            // Read Incomming GPS data
            char gps_buffer[1024] = {};
            int bytes_read = gps_serial.readString(gps_buffer, '\n', 1023, 500);
            std::string gps_data;
            if (bytes_read > 0) {   // Check if message has any relevant data 
                gps_data = std::string(gps_buffer, bytes_read);
                printf("Current GPS Data: %s\n", gps_data.c_str());	// For Debugging
            }
            else {  // If message does not have any relevant data do not publish anything and just wait for next callback
                printf("No data received within timeout!\n");
                return;
            }

            // Check if GPS data recieved has a valid Header and Data segment
            size_t semicolon_pos = gps_data.find(';'); // Header and Data segment is seperated via semi-colon ';'
            if (semicolon_pos == std::string::npos) {
                printf("Encountered Invalid GPS data!(No Header or Data Segment)\n");
                return;
            }
            std::string header = gps_data.substr(0, semicolon_pos);  // GPS Header Segment
            std::string data_payload = gps_data.substr(semicolon_pos + 1);  // GPS Data Segment (lat, long, alt, etc.)

            // Get Data segment fields (fields are comma seperated ',')
            // printf("Current GPS Data Segment: %s\n", data_payload.c_str());	// For Debugging
            std::vector<std::string> fields = split(data_payload, ',');

	    // Check if GPS Reading contains valid data
	    if (fields[POSITION_TYPE_INDEX] == "SINGLE" || fields[POSITION_TYPE_INDEX] == "INS_PSRSP") {
	    	// printf("Encountered Valid GPS Data!\n");  // For Debugging
		// Get GPS Information for NavSatFix Message in the publisher
		double latitude = std::stod(fields[LATITUDE_INDEX]);
		double latitude_sd = std::stod(fields[LATITUDE_STANDARD_DEVIATION_INDEX]);
		double longitude = std::stod(fields[LONGITUDE_INDEX]);
		double longitude_sd = std::stod(fields[LONGITUDE_STANDARD_DEVIATION_INDEX]);
		double altitude = std::stod(fields[ALTITUDE_INDEX]);
		double altitude_sd = std::stod(fields[ALTITUDE_STANDARD_DEVIATION_INDEX]);
		// printf("Lat: %f, Long: %f, Alt: %f\n", latitude, longitude, altitude);  // For Debugging
		// printf("LatSD: %f, LongSD: %f, AltSD: %f\n", latitude_sd, longitude_sd, altitude_sd);  // For Debugging

		// Fill in Relevant GPS Data into NavSatFix Message Type
		sensor_msgs::msg::NavSatFix gps_msg;
		gps_msg.header.stamp = this->now();  // Timestamp
		gps_msg.header.frame_id = "gps_footprint";  // Parent Frame

		gps_msg.latitude = latitude;
		gps_msg.longitude = longitude;
		gps_msg.altitude = altitude;

		gps_msg.position_covariance = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
		gps_msg.position_covariance_type = sensor_msgs::msg::NavSatFix::COVARIANCE_TYPE_UNKNOWN;
		// gps_msg.position_covariance = {latitude_sd * latitude_sd, 0.0, 0.0, 0.0, longitude_sd * longitude_sd, 0.0, 0.0, 0.0, altitude_sd * altitude_sd};
		// gps_msg.position_covariance_type = sensor_msgs::msg::NavSatFix::COVARIANCE_TYPE_DIAGONAL_KNOWN;

		// Publish the GPS data
		publisher_->publish(gps_msg);
	    }
	    else {
	    	printf("Encountered Invalid GPS Data!(Invalid Data Segment)\n");
		return;
	    }

        }
    }
    bool gps_connected; // Check gps serial connection

    serialib gps_serial;
    rclcpp::TimerBase::SharedPtr timer_;
    rclcpp::Publisher<sensor_msgs::msg::NavSatFix>::SharedPtr publisher_;
};

int main(int argc, char * argv[]) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<GPSPublisher>());
  rclcpp::shutdown();
  return 0;
}
