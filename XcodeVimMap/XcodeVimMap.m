//
//  XcodeVimMap.m
//  XcodeVimMap
//
//  Created by Bryce Pauken on 8/1/21.
//

#import "XcodeVimMap.h"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

typedef NS_ENUM(uint8_t, VimMode) {
    VimModeInsert = 5
};

@implementation XcodeVimMap

// MARK: - Plugin Startup & Swizzling Setup

static BOOL(*originalKeyDown)(id self, SEL _cmd, NSEvent *event);

+ (void)pluginDidLoad:(NSBundle *)plugin {
    NSLog(@"[XcodeVimMap] Plugin Loaded");
    
    static dispatch_once_t token = 0;
    dispatch_once(&token, ^{
        [self swizzleKeyDown];
    }); 
}

+ (void)swizzleKeyDown {
    NSString *xcodePath = [[NSBundle mainBundle] bundlePath];
    NSString *sourceEditorPath = [xcodePath stringByAppendingPathComponent:@"Contents/SharedFrameworks/SourceEditor.framework/Versions/A/SourceEditor"];
    dlopen([sourceEditorPath cStringUsingEncoding:NSUTF8StringEncoding], RTLD_NOW);

    NSLog(@"[XcodeVimMap] SourceEditor Loaded");

    Method originalMethod = class_getInstanceMethod(
        NSClassFromString(@"SourceEditor.SourceEditorView"),
        NSSelectorFromString(@"keyDown:"));

    Method replacementMethod = class_getInstanceMethod(
        [self class],
        @selector(swizzled_keyDown:));

    originalKeyDown = (void *)method_getImplementation(originalMethod);
    method_setImplementation(
                             originalMethod,
                             method_getImplementation(replacementMethod));
}

// MARK: - Swizzle Implementation

static NSEvent *queuedEvent;
static dispatch_block_t sendQueuedEventAfterTimeout;

- (BOOL)swizzled_keyDown:(NSEvent *)event {
    // Block to send an event to the original implementation
    BOOL (^sendEvent)(NSEvent *) = ^BOOL(NSEvent *event) {
        return originalKeyDown(self, _cmd, event);
    };

    // Get the current vim mode
    VimMode vimMode = [XcodeVimMap vimModeFromSourceEditorView:self];

    // Exit early if we're not in insert mode
    if (vimMode != VimModeInsert) {
        return sendEvent(event);
    }

    // Check if we've recieved a `k` press while a `j` press is still queued
    if ([event.characters isEqualToString:@"k"] && queuedEvent != nil) {
        // Clear the queued j press
        queuedEvent = nil;

        // And cancel its timeout-based-sending.
        dispatch_block_cancel(sendQueuedEventAfterTimeout);

        // Create an "escape" key event and send it,
        // returning early in the process.
        NSEvent *escapeEvent = [XcodeVimMap modifiedEvent:event withCharacters:@"\x1b"];
        return sendEvent(escapeEvent);
    }

    // Check if we have a previous `j` press queued up
    if (queuedEvent != nil) {
        // Apply the `j` press
        sendEvent(queuedEvent);

        // Clear the queued event so it's not sent again
        queuedEvent = nil;

        // Cancel the timeout-based application of the event,
        // since we've invoked it manually.
        dispatch_block_cancel(sendQueuedEventAfterTimeout);
    }

    // Check if we've recieved a "j" keypress
    if ([event.characters isEqualToString:@"j"]) {
        // Save a reference to the event for later sending
        queuedEvent = event;

        // Create a block to send the event for use in the timeout functionality
        sendQueuedEventAfterTimeout = dispatch_block_create(0, ^{
            // Send the queued event
            sendEvent(queuedEvent);

            // Clear out the queued event so that it won't be sent again
            queuedEvent = nil;
        });

        // Invoke the above block after 1 second. This invocation
        // should be cancelled if the event is manually sendt sooner.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), sendQueuedEventAfterTimeout);

        // Return early so that the default implementation
        // (which would apply our `j` press immediately)
        // is not called.
        return true;
    }

    // Fall back to default implementation
    return sendEvent(event);
}

// MARK: - Helpers

+ (NSEvent *)modifiedEvent:(NSEvent *)event withCharacters:(NSString *)characters {
    return [NSEvent keyEventWithType:event.type
                            location:event.locationInWindow
                       modifierFlags:event.modifierFlags
                           timestamp:event.timestamp
                        windowNumber:event.windowNumber
                             context:nil // event.context is deprecated and only returns `nil`
                          characters:characters
         charactersIgnoringModifiers:characters // unclear if we have to worry about this distiction
                           isARepeat:NO
                             keyCode:event.keyCode];
}

+ (id)getIvar:(NSString *)ivarName from:(NSObject *)object {
    const char *ivarNameCString = [ivarName cStringUsingEncoding:NSUTF8StringEncoding];
    Ivar ivar = class_getInstanceVariable([object class], ivarNameCString);
    return object_getIvar(object, ivar);
}

+ (uint8_t)getIntIvar:(NSString *)ivarName from:(NSObject *)object {
    const char *ivarNameCString = [ivarName cStringUsingEncoding:NSUTF8StringEncoding];
    Ivar ivar = class_getInstanceVariable([object class], ivarNameCString);
    // In Apple Silicon, the compiler will try to retain the return value from `object_getIvar` then crash.
    // In this case, we cast the `object_getIvar` to avoid this.
    uint8_t result = ((uint8_t (*)(id, Ivar))object_getIvar)(object, ivar);
    return result;
}

+ (NSArray *)arrayFromSwiftArrayStorage:(void *)swiftArrayStorage {
    // Create a mutable array to hold each encountered element
    NSMutableArray *results = [NSMutableArray new];

    // Read array length at offset 0x10
    long arrayLength = *(long *)((char *)swiftArrayStorage + 0x10);

    // Get each element of the array, every 0x10 bytes, starting at offset 0x20
    for (long i=0; i<arrayLength; i++) {
        void **elementPtr = (void **)((char *)swiftArrayStorage + 0x20 + (0x10 * i));
        id element = (__bridge NSObject *)(*elementPtr);
        [results addObject:element];
    }

    return results;
}

+ (VimMode)vimModeFromSourceEditorView:(id)sourceEditorView {
    // Get our current event consumers
    void *eventConsumersStorage = (__bridge void *)([XcodeVimMap getIvar:@"eventConsumers" from:sourceEditorView]);
    NSArray *eventConsumers = [XcodeVimMap arrayFromSwiftArrayStorage:eventConsumersStorage];

    // Find the vim consumer
    id vimEventConsumer;
    for (id eventConsumer in eventConsumers) {
        if ([NSStringFromClass([eventConsumer class]) isEqualToString:@"IDESourceEditor.IDEViEventConsumer"]) {
            vimEventConsumer = eventConsumer;
            break;
        }
    }

    // Get the vim context
    id vimContext = [XcodeVimMap getIvar:@"context" from:vimEventConsumer];

    // Get the current vim mode
    uint8_t vimMode = [XcodeVimMap getIntIvar:@"mode" from:vimContext];
    return vimMode;
}

@end
