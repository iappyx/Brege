// Brêge Microphone — a Core Audio HAL plug-in (AudioServerPlugIn) for "phone as microphone".
//
// It publishes two devices that share one clock and one ring buffer:
//   * "Brêge Microphone"       input device that apps (video calls, recorders, …) record from;
//   * "Brêge Microphone Feed"  hidden output device that Brêge.app plays the phone's audio into.
// Audio written to the feed at output sample time T is read back by the microphone at input
// sample time T, exactly like a loopback cable. Time the feed has not written is silent.
//
// Written from Apple's AudioServerPlugIn documentation; structure follows the "NullAudio" sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------
// Configuration

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device_Mic = 2,
    kObjectID_Stream_Mic = 3,
    kObjectID_Device_Feed = 4,
    kObjectID_Stream_Feed = 5,
};

#define kSampleRate 48000.0
#define kChannels 1
#define kBytesPerSample sizeof(Float32)
#define kZeroTimeStampPeriod 16384
#define kRingFrames 96000 // 2 s

#define kMicUID CFSTR("app.brege.microphone")
#define kFeedUID CFSTR("app.brege.microphone.feed")
#define kModelUID CFSTR("app.brege.microphone.model")
#define kManufacturer CFSTR("Brêge")

// ---------------------------------------------------------------------------------------------
// State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;

static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static UInt32 gIOCount = 0; // running devices, both share the clock

static _Atomic UInt32 gMicRunning = 0;
static _Atomic UInt32 gFeedRunning = 0;

static Float32 gRing[kRingFrames * kChannels];
// Sample time up to which the feed has written (exclusive), and from which (inclusive).
static _Atomic Float64 gWrittenFrom = -1.0;
static _Atomic Float64 gWrittenTo = -1.0;

// ---------------------------------------------------------------------------------------------
// Prototypes

static HRESULT Brege_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Brege_AddRef(void *inDriver);
static ULONG Brege_Release(void *inDriver);
static OSStatus Brege_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Brege_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Brege_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Brege_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Brege_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Brege_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Brege_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void *inChangeInfo);
static Boolean Brege_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress *inAddress);
static OSStatus Brege_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus Brege_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                          const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Brege_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                      const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Brege_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                      const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus Brege_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Brege_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Brege_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Brege_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Brege_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Brege_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Brege_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Brege_QueryInterface,
    Brege_AddRef,
    Brege_Release,
    Brege_Initialize,
    Brege_CreateDevice,
    Brege_DestroyDevice,
    Brege_AddDeviceClient,
    Brege_RemoveDeviceClient,
    Brege_PerformDeviceConfigurationChange,
    Brege_AbortDeviceConfigurationChange,
    Brege_HasProperty,
    Brege_IsPropertySettable,
    Brege_GetPropertyDataSize,
    Brege_GetPropertyData,
    Brege_SetPropertyData,
    Brege_StartIO,
    Brege_StopIO,
    Brege_GetZeroTimeStamp,
    Brege_WillDoIOOperation,
    Brege_BeginIOOperation,
    Brege_DoIOOperation,
    Brege_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// ---------------------------------------------------------------------------------------------
// Factory

void *BregeAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *BregeAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

// ---------------------------------------------------------------------------------------------
// Helpers

static inline Boolean IsDevice(AudioObjectID id) { return id == kObjectID_Device_Mic || id == kObjectID_Device_Feed; }
static inline Boolean IsStream(AudioObjectID id) { return id == kObjectID_Stream_Mic || id == kObjectID_Stream_Feed; }
static inline Boolean IsMic(AudioObjectID id) { return id == kObjectID_Device_Mic || id == kObjectID_Stream_Mic; }

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerSample * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerSample * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 8 * kBytesPerSample;
    return f;
}

#define RETURN_SIZE(T, count)                                                                                                    \
    do {                                                                                                                         \
        *outDataSize = (UInt32)(sizeof(T) * (count));                                                                            \
        return kAudioHardwareNoError;                                                                                            \
    } while (0)

#define WRITE_VALUE(T, value)                                                                                                    \
    do {                                                                                                                         \
        if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError;                                                   \
        *((T *)outData) = (value);                                                                                               \
        *outDataSize = sizeof(T);                                                                                                \
        return kAudioHardwareNoError;                                                                                            \
    } while (0)

// ---------------------------------------------------------------------------------------------
// Inheritance

static HRESULT Brege_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Brege_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Brege_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// ---------------------------------------------------------------------------------------------
// Basic operations

static OSStatus Brege_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus Brege_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) {
    (void)d; (void)desc; (void)c; (void)o;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Brege_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Brege_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Brege_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Brege_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i;
    return kAudioHardwareNoError;
}

static OSStatus Brege_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i;
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------------------------
// Properties

static Boolean Brege_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t pid,
                                 const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (inDriver != gDriverRef || a == NULL) return false;
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;

    case kObjectID_Device_Mic:
    case kObjectID_Device_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return true;
        }
        return false;

    case kObjectID_Stream_Mic:
    case kObjectID_Stream_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus Brege_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t pid,
                                         const AudioObjectPropertyAddress *a, Boolean *outIsSettable) {
    if (inDriver != gDriverRef || a == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!Brege_HasProperty(inDriver, inObjectID, pid, a)) return kAudioHardwareUnknownPropertyError;
    // Formats and the sample rate are fixed, but hosts expect to be allowed to "set" them to the
    // only supported value.
    *outIsSettable = (IsDevice(inObjectID) && a->mSelector == kAudioDevicePropertyNominalSampleRate) ||
                     (IsStream(inObjectID) && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                               a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return kAudioHardwareNoError;
}

static OSStatus Brege_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t pid,
                                          const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                          UInt32 *outDataSize) {
    (void)qSize; (void)qData;
    if (inDriver != gDriverRef || a == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!Brege_HasProperty(inDriver, inObjectID, pid, a)) return kAudioHardwareUnknownPropertyError;

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID, 1);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID, 1);
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle: RETURN_SIZE(CFStringRef, 1);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: RETURN_SIZE(AudioObjectID, 2);
        case kAudioPlugInPropertyBoxList: RETURN_SIZE(AudioObjectID, 0);
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice: RETURN_SIZE(AudioObjectID, 1);
        }
        break;

    case kObjectID_Device_Mic:
    case kObjectID_Device_Feed: {
        Boolean micDevice = inObjectID == kObjectID_Device_Mic;
        Boolean scopeMatches = a->mScope == kAudioObjectPropertyScopeGlobal ||
                               (micDevice && a->mScope == kAudioObjectPropertyScopeInput) ||
                               (!micDevice && a->mScope == kAudioObjectPropertyScopeOutput);
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID, 1);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID, 1);
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: RETURN_SIZE(CFStringRef, 1);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: RETURN_SIZE(AudioObjectID, scopeMatches ? 1 : 0);
        case kAudioObjectPropertyControlList: RETURN_SIZE(AudioObjectID, 0);
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_SIZE(UInt32, 1);
        case kAudioDevicePropertyRelatedDevices: RETURN_SIZE(AudioObjectID, 1);
        case kAudioDevicePropertyNominalSampleRate: RETURN_SIZE(Float64, 1);
        case kAudioDevicePropertyAvailableNominalSampleRates: RETURN_SIZE(AudioValueRange, 1);
        case kAudioDevicePropertyPreferredChannelsForStereo: RETURN_SIZE(UInt32, 2);
        }
        break;
    }

    case kObjectID_Stream_Mic:
    case kObjectID_Stream_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID, 1);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID, 1);
        case kAudioObjectPropertyOwnedObjects: RETURN_SIZE(AudioObjectID, 0);
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency: RETURN_SIZE(UInt32, 1);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: RETURN_SIZE(AudioStreamBasicDescription, 1);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: RETURN_SIZE(AudioStreamRangedDescription, 1);
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Brege_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t pid,
                                      const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                      UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (inDriver != gDriverRef || a == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!Brege_HasProperty(inDriver, inObjectID, pid, a)) return kAudioHardwareUnknownPropertyError;

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, kManufacturer));
        case kAudioPlugInPropertyResourceBundle: WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, CFSTR("")));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            UInt32 count = inDataSize / sizeof(AudioObjectID);
            AudioObjectID *ids = (AudioObjectID *)outData;
            UInt32 written = 0;
            if (count > written) ids[written++] = kObjectID_Device_Mic;
            if (count > written) ids[written++] = kObjectID_Device_Feed;
            *outDataSize = written * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToBox: WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qSize != sizeof(CFStringRef) || qData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef *)qData);
            AudioObjectID id = kAudioObjectUnknown;
            if (uid != NULL && CFStringCompare(uid, kMicUID, 0) == kCFCompareEqualTo) id = kObjectID_Device_Mic;
            if (uid != NULL && CFStringCompare(uid, kFeedUID, 0) == kCFCompareEqualTo) id = kObjectID_Device_Feed;
            WRITE_VALUE(AudioObjectID, id);
        }
        }
        break;

    case kObjectID_Device_Mic:
    case kObjectID_Device_Feed: {
        Boolean micDevice = inObjectID == kObjectID_Device_Mic;
        Boolean scopeMatches = a->mScope == kAudioObjectPropertyScopeGlobal ||
                               (micDevice && a->mScope == kAudioObjectPropertyScopeInput) ||
                               (!micDevice && a->mScope == kAudioObjectPropertyScopeOutput);
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:
            WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, micDevice ? CFSTR("Brêge Microphone") : CFSTR("Brêge Microphone Feed")));
        case kAudioObjectPropertyManufacturer: WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, kManufacturer));
        case kAudioDevicePropertyDeviceUID: WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, micDevice ? kMicUID : kFeedUID));
        case kAudioDevicePropertyModelUID: WRITE_VALUE(CFStringRef, CFStringCreateCopy(NULL, kModelUID));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (scopeMatches && inDataSize >= sizeof(AudioObjectID)) {
                *((AudioObjectID *)outData) = micDevice ? kObjectID_Stream_Mic : kObjectID_Stream_Feed;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType: WRITE_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: WRITE_VALUE(AudioObjectID, inObjectID);
        case kAudioDevicePropertyClockDomain: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: WRITE_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning:
            WRITE_VALUE(UInt32, micDevice ? atomic_load(&gMicRunning) > 0 : atomic_load(&gFeedRunning) > 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: WRITE_VALUE(UInt32, micDevice ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: WRITE_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: WRITE_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {kSampleRate, kSampleRate};
            WRITE_VALUE(AudioValueRange, range);
        }
        case kAudioDevicePropertyIsHidden: WRITE_VALUE(UInt32, micDevice ? 0 : 1);
        case kAudioDevicePropertyZeroTimeStampPeriod: WRITE_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 1;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        break;
    }

    case kObjectID_Stream_Mic:
    case kObjectID_Stream_Feed: {
        Boolean micStream = inObjectID == kObjectID_Stream_Mic;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: WRITE_VALUE(AudioObjectID, micStream ? kObjectID_Device_Mic : kObjectID_Device_Feed);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive: WRITE_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: WRITE_VALUE(UInt32, micStream ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            WRITE_VALUE(UInt32, micStream ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: WRITE_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: WRITE_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: WRITE_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranged;
            ranged.mFormat = StreamFormat();
            ranged.mSampleRateRange.mMinimum = kSampleRate;
            ranged.mSampleRateRange.mMaximum = kSampleRate;
            WRITE_VALUE(AudioStreamRangedDescription, ranged);
        }
        }
        break;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Brege_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t pid,
                                      const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                      UInt32 inDataSize, const void *inData) {
    (void)qSize; (void)qData;
    if (inDriver != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!Brege_HasProperty(inDriver, inObjectID, pid, a)) return kAudioHardwareUnknownPropertyError;

    if (IsDevice(inObjectID) && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *((const Float64 *)inData) == kSampleRate ? kAudioHardwareNoError : kAudioHardwareIllegalOperationError;
    }
    if (IsStream(inObjectID) &&
        (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription ours = StreamFormat();
        Boolean same = f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID &&
                       f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel;
        return same ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

// ---------------------------------------------------------------------------------------------
// IO

static OSStatus Brege_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        // Both devices share one clock, anchored when the first one starts.
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        atomic_store(&gWrittenFrom, -1.0);
        atomic_store(&gWrittenTo, -1.0);
    }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    if (IsMic(inDeviceObjectID)) {
        atomic_fetch_add(&gMicRunning, 1);
    } else {
        atomic_fetch_add(&gFeedRunning, 1);
    }
    return kAudioHardwareNoError;
}

static OSStatus Brege_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) --gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    if (IsMic(inDeviceObjectID)) {
        if (atomic_load(&gMicRunning) > 0) atomic_fetch_sub(&gMicRunning, 1);
    } else {
        if (atomic_load(&gFeedRunning) > 0) atomic_fetch_sub(&gFeedRunning, 1);
    }
    return kAudioHardwareNoError;
}

static OSStatus Brege_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    Float64 nextOffset = (Float64)(gNumberTimeStamps + 1) * ticksPerPeriod;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)nextOffset;
    if (nextHostTime <= now) {
        ++gNumberTimeStamps;
    }
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Brege_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    Boolean willDo = false;
    if (inDeviceObjectID == kObjectID_Device_Mic) {
        willDo = inOperationID == kAudioServerPlugInIOOperationReadInput;
    } else {
        willDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    }
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Brege_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                       const AudioServerPlugInIOCycleInfo *info) {
    (void)d; (void)c; (void)op; (void)n; (void)info;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus Brege_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                     const AudioServerPlugInIOCycleInfo *info) {
    (void)d; (void)c; (void)op; (void)n; (void)info;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static inline UInt64 RingIndex(Float64 sampleTime) {
    SInt64 t = (SInt64)sampleTime;
    SInt64 m = t % kRingFrames;
    return (UInt64)(m < 0 ? m + kRingFrames : m);
}

static OSStatus Brege_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    if (!IsStream(inStreamObjectID) || ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareBadStreamError;

    Float32 *buffer = (Float32 *)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Feed) {
        Float64 start = inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < inIOBufferFrameSize; ++i) {
            UInt64 index = RingIndex(start + i) * kChannels;
            for (UInt32 ch = 0; ch < kChannels; ++ch) gRing[index + ch] = buffer[i * kChannels + ch];
        }
        Float64 end = start + inIOBufferFrameSize;
        Float64 from = atomic_load(&gWrittenFrom);
        Float64 to = atomic_load(&gWrittenTo);
        // Contiguous writes extend the valid window; a gap (feed restarted) begins a new one.
        if (from < 0.0 || start > to || start < from) atomic_store(&gWrittenFrom, start);
        atomic_store(&gWrittenTo, end);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Mic) {
        Float64 start = inIOCycleInfo->mInputTime.mSampleTime;
        Float64 from = atomic_load(&gWrittenFrom);
        Float64 to = atomic_load(&gWrittenTo);
        Boolean feedLive = atomic_load(&gFeedRunning) > 0;
        for (UInt32 i = 0; i < inIOBufferFrameSize; ++i) {
            Float64 t = start + i;
            Boolean valid = feedLive && from >= 0.0 && t >= from && t < to && (to - t) < kRingFrames;
            UInt64 index = RingIndex(t) * kChannels;
            for (UInt32 ch = 0; ch < kChannels; ++ch) buffer[i * kChannels + ch] = valid ? gRing[index + ch] : 0.0f;
        }
    }
    return kAudioHardwareNoError;
}
