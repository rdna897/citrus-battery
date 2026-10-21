#import "CPowerUI.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>

// Read-only subset of PowerUISmartChargeClient (PowerUI.framework, private).
@interface PowerUISmartChargeClient : NSObject
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isOBCSupported;
- (BOOL)isMCLSupported;
- (unsigned long long)isSmartChargingCurrentlyEnabled:(NSError **)error;
- (unsigned long long)isMCLCurrentlyEnabled:(NSError **)error;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (BOOL)isOBCEngaged:(NSError **)error;
@end

void cpowerui_read_status(cpowerui_status *status) {
    *status = (cpowerui_status){0};

    static void *handle;
    if (handle == NULL) {
        handle = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
    }
    Class clientClass = NSClassFromString(@"PowerUISmartChargeClient");
    if (handle == NULL || clientClass == Nil) return;

    @autoreleasepool {
        PowerUISmartChargeClient *client = [[clientClass alloc] initWithClientName:@"org.citrusbattery"];
        if (client == nil) return;

        // Guard every selector: the private API changes between macOS versions.
        NSError *error = nil;
        if ([client respondsToSelector:@selector(isMCLSupported)]) {
            status->charge_limit_supported = [client isMCLSupported];
        }
        if (status->charge_limit_supported) {
            if ([client respondsToSelector:@selector(isMCLCurrentlyEnabled:)]) {
                status->charge_limit_enabled = [client isMCLCurrentlyEnabled:&error] == 1 && error == nil;
            }
            error = nil;
            if ([client respondsToSelector:@selector(getMCLLimitWithError:)]) {
                unsigned char limit = [client getMCLLimitWithError:&error];
                if (error == nil && limit > 0 && limit <= 100) status->charge_limit_percent = limit;
            }
        }

        if ([client respondsToSelector:@selector(isOBCSupported)]) {
            status->optimized_supported = [client isOBCSupported];
        }
        if (status->optimized_supported) {
            error = nil;
            if ([client respondsToSelector:@selector(isSmartChargingCurrentlyEnabled:)]) {
                status->optimized_enabled = [client isSmartChargingCurrentlyEnabled:&error] == 1 && error == nil;
            }
            error = nil;
            if ([client respondsToSelector:@selector(isOBCEngaged:)]) {
                status->optimized_engaged = [client isOBCEngaged:&error] && error == nil;
            }
        }
        status->available = true;
    }
}
