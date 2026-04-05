ARCHS = arm64
TARGET = iphone:clang:latest:10.0

LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQESign

QQESign_FILES = Tweak.x
QQESign_CFLAGS = -fobjc-arc -DQQESIGN_SIDELOAD=1
QQESign_FRAMEWORKS = UIKit Foundation CoreGraphics Photos

include $(THEOS)/makefiles/tweak.mk
