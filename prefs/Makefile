THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
HideNowPlayingPrefs_PRIVATE_FRAMEWORKS = Preferences
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
