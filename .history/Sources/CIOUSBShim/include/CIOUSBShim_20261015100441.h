#ifndef CIOUSBSHIM_H
#define CIOUSBSHIM_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

CFUUIDRef bc_pluginInterfaceID(void);
CFUUIDRef bc_usbDeviceUserClientTypeID(void);
CFUUIDRef bc_usbDeviceInterfaceID(void);
CFUUIDRef bc_usbInterfaceUserClientTypeID(void);
CFUUIDRef bc_usbInterfaceInterfaceID300(void);

#endif
