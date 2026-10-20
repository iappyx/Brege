#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A display macOS believes in, created by Brêge so a tablet can be one.
///
/// macOS has no public way for an app to create a display. This wraps the private CoreGraphics
/// interface that every third-party tool in this space uses: no entitlement, and it works from an
/// unsigned app, but it is undocumented and Apple owes it nothing. The whole of Brêge's dependency
/// on it lives in this one small target, so a macOS release that changes or removes it is a
/// contained problem: `isSupported` goes false and the feature reports itself unavailable.
///
/// Objective-C rather than Swift on purpose. The classes are Objective-C with multi-argument
/// initialisers, and their property types differ between the published reverse-engineered headers,
/// so every property is set through KVC and the runtime converts to whatever the type really is.
@interface BRGVirtualDisplay : NSObject

/// Whether this macOS still offers the interface. False means the feature cannot run here.
@property (class, readonly) BOOL isSupported;

/// Creates the display. Nil when the interface is missing, or macOS refused the settings.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI;

/// What macOS called it, for matching against `CGGetActiveDisplayList` and ScreenCaptureKit.
@property (readonly) CGDirectDisplayID displayID;

/// Whether macOS currently lists it among the active displays.
@property (readonly) BOOL isListed;

/// Takes the display away. macOS moves any windows on it back to a real screen. Called again, or
/// on dealloc, it does nothing — but call it rather than wait for dealloc, so the windows move
/// while the app is still there to notice.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
