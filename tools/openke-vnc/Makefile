TOOLCHAIN_BIN ?= /root/Development/OpenKE/OpenKE/vendor/system/buildroot/output/host/bin
CXX = $(TOOLCHAIN_BIN)/mipsel-linux-g++
STRIP = $(TOOLCHAIN_BIN)/mipsel-linux-strip

CXXFLAGS = -O3 -Wall -Wextra -std=c++17 -pthread
LDFLAGS = -pthread

TARGET = openke-vnc
SRCS = main.cpp fb_device.cpp uinput_injector.cpp rfb_server.cpp websocket_server.cpp
OBJS = $(SRCS:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) $(OBJS) -o $@ $(LDFLAGS)
	$(STRIP) $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
