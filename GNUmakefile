include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = KateWrapper
KateWrapper_OBJC_FILES = KateWrapper.m
KateWrapper_RESOURCE_FILES = Info.plist

# X11 libraries and includes
ADDITIONAL_INCLUDE_DIRS += -I/usr/local/include
ADDITIONAL_LIB_DIRS += -L/usr/local/lib
ADDITIONAL_LDFLAGS += -lX11 -lXcomposite

include $(GNUSTEP_MAKEFILES)/application.make
