// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Experimental, standalone metadata-only probe; not linked into the shipping host.
// DFRFoundation is private and these inferred signatures are not an Apple compatibility promise.
// No screenshot or pixel is saved and no touch or keyboard event is posted.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <string.h>

typedef id (*MakeSimulator)(int, id, int);
typedef void *(*GetTouchBar)(id);
typedef CGDisplayStreamRef (*MakeStream)(void *, int, dispatch_queue_t, CGDisplayStreamFrameAvailableHandler);
typedef void (*InvalidateSimulator)(id);
typedef CGError (*StreamControl)(CGDisplayStreamRef);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // The default is a read-only preflight. There is no call to the system's request APIs.
        BOOL attempt = argc == 2 && strcmp(argv[1], "--sample") == 0;
        if (argc > 2 || (argc == 2 && !attempt)) {
            fprintf(stderr, "usage: touch-bar-probe [--sample]\n");
            return 64;
        }
        BOOL recording = CGPreflightScreenCaptureAccess();
        BOOL accessibility = AXIsProcessTrusted();
        printf("recording=%s accessibility=%s explicitSample=%s\n",
               recording ? "allowed" : "not-allowed", accessibility ? "allowed" : "not-allowed",
               attempt ? "yes" : "no");
        if (!attempt) { puts("PREFLIGHT ONLY: no framework loaded or stream started"); return 0; }
        if (!recording || !accessibility) {
            puts("SKIPPED: this process lacks existing recording or accessibility permission; no request made");
            return 2;
        }

        void *framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW | RTLD_LOCAL);
        if (!framework) { puts("UNAVAILABLE: framework"); return 3; }
        MakeSimulator create = (MakeSimulator)dlsym(framework, "DFRTouchBarSimulatorCreate");
        GetTouchBar get = (GetTouchBar)dlsym(framework, "DFRTouchBarSimulatorGetTouchBar");
        MakeStream streamCreate = (MakeStream)dlsym(framework, "DFRTouchBarCreateDisplayStream");
        InvalidateSimulator invalidate = (InvalidateSimulator)dlsym(framework, "DFRTouchBarSimulatorInvalidate");
        // These two APIs are unavailable to a macOS 27 SDK at compile time, although symbols may
        // remain. Lookup is for this isolated experiment only, never an assertion of support.
        StreamControl startStream = (StreamControl)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
        StreamControl stopStream = (StreamControl)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
        if (!create || !get || !streamCreate || !invalidate || !startStream || !stopStream) {
            puts("UNAVAILABLE: required symbols"); dlclose(framework); return 3;
        }
        // An experimental simulator source may differ from a physical Touch Bar. Do not advertise
        // it as the physical source or enable it in the product without separate hardware evidence.
        id simulator = create(3, nil, 3);
        if (!simulator) { puts("UNAVAILABLE: simulator"); dlclose(framework); return 3; }
        void *bar = get(simulator);
        if (!bar) { puts("UNAVAILABLE: simulator bar"); invalidate(simulator); dlclose(framework); return 3; }
        __block unsigned frames = 0;
        __block size_t width = 0, height = 0;
        __block BOOL stopping = NO;
        __block CGDisplayStreamRef stream = NULL;
        stream = streamCreate(bar, 0, dispatch_get_main_queue(),
            ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
                (void)displayTime; (void)update;
                if (status == kCGDisplayStreamFrameStatusStopped && stopping) {
                    // Apple's header requires waiting for this status after Stop before release.
                    invalidate(simulator);
                    printf("SIMULATOR METADATA ONLY: frames=%u last=%zux%zu\n", frames, width, height);
                    CFRelease(stream);
                    dlclose(framework);
                    exit(frames > 0 ? 0 : 4);
                }
                if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface || stopping) return;
                // Read dimensions only while the callback owns the surface. Retaining pixel data
                // beyond this callback would require the IOSurface use-count lifetime contract.
                width = IOSurfaceGetWidth(surface); height = IOSurfaceGetHeight(surface); frames++;
            });
        if (!stream) { puts("UNAVAILABLE: stream"); invalidate(simulator); dlclose(framework); return 3; }
        CGError start = startStream(stream);
        if (start != kCGErrorSuccess) {
            printf("UNAVAILABLE: stream start error=%d\n", start);
            CFRelease(stream); invalidate(simulator); dlclose(framework); return 3;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            stopping = YES;
            CGError stopped = stopStream(stream);
            if (stopped != kCGErrorSuccess) {
                printf("UNAVAILABLE: stream stop error=%d; process exits without releasing a potentially active stream\n", stopped);
                exit(5);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                puts("UNAVAILABLE: stopped callback timed out; process exits without releasing a potentially active stream");
                exit(5);
            });
        });
        dispatch_main();
    }
}
