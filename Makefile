THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 22222
ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XiaoXiaoYouXuanAdBlock

XiaoXiaoYouXuanAdBlock_FILES = Tweak.xm
XiaoXiaoYouXuanAdBlock_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
