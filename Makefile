ARCHS = arm64
TARGET = iphone:clang:16.5:14.0
export TARGET

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = kugou_noad_v9i
kugou_noad_v9i_FILES = src/Tweak.xm
kugou_noad_v9i_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
