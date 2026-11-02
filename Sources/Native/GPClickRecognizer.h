#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <string.h>

typedef struct {
    int32_t identifier;
    CGPoint position;
} GPClickContact;

typedef struct {
    NSInteger count;
    GPClickContact origins[3];
    NSTimeInterval threeFingerSince;
    NSTimeInterval lastFrame;
    BOOL hasOrigins;
    BOOL cancelled;
    BOOL claimed;
} GPClickChord;

// A click needs a settled three-finger chord, independent of the swipe finger count.
// Track each contact, not just the centroid: a pinch must not look stationary.
static void GPUpdateClickChord(GPClickChord *chord, const GPClickContact *contacts,
                               NSInteger count, NSTimeInterval now) {
    if (count == 0) memset(chord, 0, sizeof(*chord));
    chord->count = count;
    chord->lastFrame = now;
    if (count == 0) return;
    if (count > 3 || (chord->hasOrigins && count != 3)) {
        chord->cancelled = YES;
        return;
    }
    if (count != 3 || chord->cancelled) return;
    if (!chord->hasOrigins) {
        memcpy(chord->origins, contacts, sizeof(chord->origins));
        chord->threeFingerSince = now;
        chord->hasOrigins = YES;
        return;
    }
    for (NSInteger i = 0; i < 3; i++) {
        BOOL found = NO;
        for (NSInteger j = 0; j < 3; j++) {
            if (contacts[i].identifier != chord->origins[j].identifier) continue;
            found = YES;
            CGFloat dx = contacts[i].position.x - chord->origins[j].position.x;
            CGFloat dy = contacts[i].position.y - chord->origins[j].position.y;
            if (hypot(dx, dy) > 0.02) chord->cancelled = YES;
            break;
        }
        if (!found) chord->cancelled = YES;
    }
}

static BOOL GPClickChordIsStationary(const GPClickChord *chord, NSTimeInterval now) {
    return chord->count == 3 && chord->hasOrigins && !chord->cancelled &&
        now >= chord->lastFrame && now - chord->lastFrame <= 0.25 &&
        now - chord->threeFingerSince >= 0.10;
}

static BOOL GPClickChordCanBegin(const GPClickChord *chord, NSTimeInterval now) {
    return !chord->claimed && GPClickChordIsStationary(chord, now);
}
