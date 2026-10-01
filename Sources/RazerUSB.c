// Talks to the Razer lighting controller: 90-byte feature reports sent as USB class requests to
// interface 3 (the Huntsman V2 answers there), same protocol as OpenRazer. No driver or Synapse needed.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <string.h>
#include <unistd.h>

static IOUSBDeviceInterface **dev;

static IOUSBDeviceInterface **open_dev(int vendor, int product) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor), p = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!s) return NULL;
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(s);
    if (kr || !plug) return NULL;
    IOUSBDeviceInterface **d = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&d);
    (*plug)->Release(plug);
    return d;
}

static kern_return_t request(unsigned char *r, int in) {
    IOUSBDevRequest q = { USBmakebmRequestType(in ? kUSBIn : kUSBOut, kUSBClass, kUSBInterface),
                          in ? 0x01 : 0x09, 0x300, 3, 90, r, 0 };
    return (*dev)->DeviceRequest(dev, &q);
}

/// Sends one command; returns the keyboard's status byte (2 = OK) or -1 when it isn't reachable.
int razer_send(int vendor, int product, unsigned char cls, unsigned char cmd, unsigned char size, const unsigned char *args) {
    unsigned char r[90] = {0};
    r[1] = 0x1F; r[5] = size; r[6] = cls; r[7] = cmd;
    if (args && size) memcpy(r + 8, args, size > 80 ? 80 : size);
    unsigned char crc = 0;
    for (int i = 2; i < 88; i++) crc ^= r[i];
    r[88] = crc;

    for (int attempt = 0; attempt < 2; attempt++) {
        if (!dev) dev = open_dev(vendor, product);
        if (!dev) return -1;
        if (request(r, 0) == kIOReturnSuccess) {
            usleep(1000);
            unsigned char resp[90] = {0};
            for (int i = 0; i < 20; i++) {       // the controller answers "busy" (1) for a moment
                usleep(2000);
                if (request(resp, 1) != kIOReturnSuccess) break;
                if (resp[0] != 0x01) return resp[0];
            }
            return resp[0];
        }
        // unplugged and replugged: drop the stale handle and retry once
        (*dev)->Release(dev);
        dev = NULL;
    }
    return -1;
}
