ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XiaoCanAdBlock

XiaoCanAdBlock_FILES = Tweak.xm
XiaoCanAdBlock_FRAMEWORKS = UIKit Foundation CoreMotion

include $(THEOS_MAKE_PATH)/tweak.mk
