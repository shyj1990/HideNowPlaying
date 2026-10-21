THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
# Preferences 为私有框架(SDK 无 tbd) → 用项目自带 stub tbd 提供链接符号, 运行时由 Settings 进程内
# 已加载的 Preferences.framework 解析(install-name 指向真机路径)
HideNowPlayingPrefs_LDFLAGS = $(PWD)/Preferences.tbd
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
