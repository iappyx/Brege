#import "BRGVirtualDisplay.h"

#import <dlfcn.h>

// Only the methods are declared. Properties go through KVC — see the header.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

/// The classes have lived in CoreGraphics and in SkyLight at different times; ask for them once and
/// open the other framework if they are not already loaded.
static BOOL interface_available(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"CGVirtualDisplay")) {
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        }
        available = NSClassFromString(@"CGVirtualDisplay") != nil
            && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
            && NSClassFromString(@"CGVirtualDisplaySettings") != nil
            && NSClassFromString(@"CGVirtualDisplayMode") != nil;
    });
    return available;
}

/// A renamed property should make the feature unavailable, not crash the app.
static BOOL set_value(id object, id value, NSString *key) {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (NSException *problem) {
        NSLog(@"Brêge: virtual display property %@ was refused: %@", key, problem.reason);
        return NO;
    }
}

@implementation BRGVirtualDisplay {
    CGVirtualDisplay *_display;
    CGDirectDisplayID _displayID;
}

+ (BOOL)isSupported {
    return interface_available();
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI {
    if (!(self = [super init])) return nil;
    if (!interface_available()) return nil;

    id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    BOOL described = set_value(descriptor, name, @"name")
        && set_value(descriptor, @(width), @"maxPixelsWide")
        && set_value(descriptor, @(height), @"maxPixelsHigh")
        // Roughly a 13-inch panel: macOS uses this for the "looks like" sizes it offers.
        && set_value(descriptor, [NSValue valueWithSize:NSMakeSize(286, 179)], @"sizeInMillimeters")
        && set_value(descriptor, @0x42524745 /* 'BRGE' */, @"serialNum")
        && set_value(descriptor, @0x0001, @"productID")
        && set_value(descriptor, @0x42524745, @"vendorID")
        && set_value(descriptor, dispatch_get_main_queue(), @"queue");
    if (!described) return nil;

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;

    id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
               initWithWidth:width height:height refreshRate:refreshRate];
    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    if (!mode || !settings) return nil;
    if (!set_value(settings, @[mode], @"modes") || !set_value(settings, @(hiDPI ? 1 : 0), @"hiDPI")) {
        return nil;
    }
    if (![_display applySettings:settings]) {
        NSLog(@"Brêge: macOS refused the virtual display settings");
        _display = nil;
        return nil;
    }

    _displayID = (CGDirectDisplayID)[[_display valueForKey:@"displayID"] unsignedIntValue];
    if (_displayID == 0) {
        _display = nil;
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _displayID;
}

- (BOOL)isListed {
    if (_displayID == 0) return NO;
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return NO;
    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    CGGetActiveDisplayList(count, ids, &count);
    BOOL listed = NO;
    for (uint32_t i = 0; i < count && !listed; i++) listed = (ids[i] == _displayID);
    free(ids);
    return listed;
}

- (void)invalidate {
    _display = nil;
    _displayID = 0;
}

- (void)dealloc {
    [self invalidate];
}

@end
