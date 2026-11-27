ARCHS = arm64
TARGET = iphone:clang:16.5:14.0
export TARGET

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = kugou_noad_v9d
kugou_noad_v9d_FILES = src/Tweak.xm
kugou_noad_v9d_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
