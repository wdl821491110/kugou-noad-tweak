ARCHS = arm64
TARGET = iphone:clang:16.5:14.0
export TARGET

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = kugou_noad_v8
kugou_noad_v8_FILES = src/Tweak.xm
kugou_noad_v8_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
