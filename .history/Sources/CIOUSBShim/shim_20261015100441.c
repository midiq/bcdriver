#include "CIOUSBShim.h"

CFUUIDRef bc_pluginInterfaceID(void) { return kIOCFPlugInInterfaceID; }
CFUUIDRef bc_usbDeviceUserClientTypeID(void) { return kIOUSBDeviceUserClientTypeID; }
CFUUIDRef bc_usbDeviceInterfaceID(void) { return kIOUSBDeviceInterfaceID; }
CFUUIDRef bc_usbInterfaceUserClientTypeID(void) { return kIOUSBInterfaceUserClientTypeID; }
CFUUIDRef bc_usbInterfaceInterfaceID300(void) { return kIOUSBInterfaceInterfaceID300; }
