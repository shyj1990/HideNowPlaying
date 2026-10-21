THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HideNowPlaying
HideNowPlaying_FILES = Tweak.x
HideNowPlaying_CFLAGS = -fobjc-arc
HideNowPlaying_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# v0.0.76: 设置面板子项目(PreferenceLoader + CFPreferences)
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
