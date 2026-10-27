// Lighting over USB without drivers: HID class requests sent straight to a device's interface.
// - Razer (OpenRazer protocol): 90-byte feature report, SET_REPORT then GET_REPORT for the status byte.
//   Huntsman V2: interface 3, transaction id 0x1F. Viper Ultimate / Mouse Dock: interface 0, id 0x3F.
// - Logitech G203 LIGHTSYNC (HID++ 2.0 long report 0x11, 20 bytes): output report on interface 1.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

// Keyboard and mouse lighting run on different threads: one request at a time over the shared device table
// (two at once raced on it, and the keyboard's commands could fail while the mouse's went through).
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

// a few open devices, by vendor/product
#define SLOTS 8
static struct { int vendor, product; IOUSBDeviceInterface **dev; } slots[SLOTS];

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

static IOUSBDeviceInterface **device(int vendor, int product) {
    for (int i = 0; i < SLOTS; i++) if (slots[i].dev && slots[i].vendor == vendor && slots[i].product == product) return slots[i].dev;
    IOUSBDeviceInterface **d = open_dev(vendor, product);
    if (!d) return NULL;
    for (int i = 0; i < SLOTS; i++) if (!slots[i].dev) { slots[i].vendor = vendor; slots[i].product = product; slots[i].dev = d; return d; }
    return d;   // all slots used: works, just isn't cached
}

static void forget(int vendor, int product) {
    for (int i = 0; i < SLOTS; i++) if (slots[i].dev && slots[i].vendor == vendor && slots[i].product == product) {
        (*slots[i].dev)->Release(slots[i].dev);
        slots[i].dev = NULL;
    }
}

/// Is this USB device plugged in?
int usb_present(int vendor, int product) {   // read-only, no table access
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor), p = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!s) return 0;
    IOObjectRelease(s);
    return 1;
}

static kern_return_t class_request(IOUSBDeviceInterface **d, int in, int request, int value, int iface, unsigned char *buf, int len) {
    IOUSBDevRequest q = { USBmakebmRequestType(in ? kUSBIn : kUSBOut, kUSBClass, kUSBInterface),
                          (UInt8)request, (UInt16)value, (UInt16)iface, (UInt16)len, buf, 0 };
    return (*d)->DeviceRequest(d, &q);
}

/// Razer: sends one command; returns the status byte (2 = OK) or -1 when the device isn't reachable.
static int razer_send_locked(int vendor, int product, int iface, unsigned char tid,
                             unsigned char cls, unsigned char cmd, unsigned char size, const unsigned char *args);

int razer_send_to(int vendor, int product, int iface, unsigned char tid,
                  unsigned char cls, unsigned char cmd, unsigned char size, const unsigned char *args) {
    pthread_mutex_lock(&lock);
    int r = razer_send_locked(vendor, product, iface, tid, cls, cmd, size, args);
    pthread_mutex_unlock(&lock);
    return r;
}

static int razer_send_locked(int vendor, int product, int iface, unsigned char tid,
                             unsigned char cls, unsigned char cmd, unsigned char size, const unsigned char *args) {
    unsigned char r[90] = {0};
    r[1] = tid; r[5] = size; r[6] = cls; r[7] = cmd;
    if (args && size) memcpy(r + 8, args, size > 80 ? 80 : size);
    unsigned char crc = 0;
    for (int i = 2; i < 88; i++) crc ^= r[i];
    r[88] = crc;
    for (int attempt = 0; attempt < 2; attempt++) {
        IOUSBDeviceInterface **d = device(vendor, product);
        if (!d) return -1;
        if (class_request(d, 0, 0x09, 0x300, iface, r, 90) == kIOReturnSuccess) {
            usleep(1000);
            unsigned char resp[90] = {0};
            for (int i = 0; i < 20; i++) {       // the controller answers "busy" (1) for a moment
                usleep(2000);
                if (class_request(d, 1, 0x01, 0x300, iface, resp, 90) != kIOReturnSuccess) break;
                if (resp[0] != 0x01) return resp[0];
            }
            return resp[0];
        }
        forget(vendor, product);   // unplugged and replugged: drop the stale handle and retry once
    }
    return -1;
}

/// The Huntsman V2 (kept for the keyboard code).
int razer_send(int vendor, int product, unsigned char cls, unsigned char cmd, unsigned char size, const unsigned char *args) {
    return razer_send_to(vendor, product, 3, 0x1F, cls, cmd, size, args);
}

/// Output report (SET_REPORT, type output) to an interface; first byte of `buf` is the report id. 0 = sent.
int usb_output_report(int vendor, int product, int iface, const unsigned char *buf, int len) {
    unsigned char copy[64] = {0};
    if (len > 64) len = 64;
    memcpy(copy, buf, len);
    int result = -1;
    pthread_mutex_lock(&lock);
    for (int attempt = 0; attempt < 2; attempt++) {
        IOUSBDeviceInterface **d = device(vendor, product);
        if (!d) break;
        if (class_request(d, 0, 0x09, 0x200 | copy[0], iface, copy, len) == kIOReturnSuccess) { result = 0; break; }
        forget(vendor, product);
    }
    pthread_mutex_unlock(&lock);
    return result;
}
