#import <AppKit/AppKit.h>
#import <stdint.h>
#import <stdio.h>

static NSColor *ColorFromHex(uint32_t value) {
    return [NSColor colorWithRed:((value >> 16) & 0xff) / 255.0
                           green:((value >> 8) & 0xff) / 255.0
                            blue:(value & 0xff) / 255.0
                           alpha:1.0];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: generate-icon OUTPUT.png\n");
            return 2;
        }

        const CGFloat size = 1024.0;
        NSImage *canvas = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
        [canvas lockFocus];
        NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
        [NSColor.clearColor setFill];
        NSRectFill(NSMakeRect(0, 0, size, size));

        NSRect tileRect = NSMakeRect(64, 64, 896, 896);
        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:tileRect
                                                            xRadius:218
                                                            yRadius:218];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
        shadow.shadowBlurRadius = 42;
        shadow.shadowOffset = NSMakeSize(0, -18);

        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        [ColorFromHex(0x2E3C78) setFill];
        [tile fill];
        [NSGraphicsContext restoreGraphicsState];

        NSGradient *gradient = [[NSGradient alloc]
            initWithStartingColor:ColorFromHex(0x27366F)
            endingColor:ColorFromHex(0x7566F5)];
        [gradient drawInBezierPath:tile angle:55];

        NSBezierPath *highlight = [NSBezierPath
            bezierPathWithRoundedRect:NSInsetRect(tileRect, 10, 10)
            xRadius:208
            yRadius:208];
        [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
        highlight.lineWidth = 8;
        [highlight stroke];

        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"hand.raised.fill"
                                    accessibilityDescription:@"Palm"];
        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration
            configurationWithPointSize:620
            weight:NSFontWeightMedium];
        symbol = [symbol imageWithSymbolConfiguration:configuration];
        if (!symbol) {
            [canvas unlockFocus];
            fprintf(stderr, "Could not load the palm system symbol\n");
            return 3;
        }

        NSImage *whiteSymbol = [[NSImage alloc] initWithSize:symbol.size];
        [whiteSymbol lockFocus];
        [symbol drawInRect:NSMakeRect(0, 0, symbol.size.width, symbol.size.height)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0];
        [NSColor.whiteColor setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, symbol.size.width, symbol.size.height),
                                 NSCompositingOperationSourceAtop);
        [whiteSymbol unlockFocus];

        CGFloat palmWidth = 610;
        CGFloat palmHeight = palmWidth * whiteSymbol.size.height / whiteSymbol.size.width;
        NSRect palmRect = NSMakeRect((size - palmWidth) / 2.0,
                                     (size - palmHeight) / 2.0 - 5,
                                     palmWidth,
                                     palmHeight);
        [whiteSymbol drawInRect:palmRect
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver
                       fraction:1.0];
        [canvas unlockFocus];

        CGImageRef image = [canvas CGImageForProposedRect:NULL context:nil hints:nil];
        if (!image) {
            fprintf(stderr, "Could not render the app icon\n");
            return 4;
        }

        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *outputPath = [NSString stringWithUTF8String:argv[1]];
        if (!png || ![png writeToFile:outputPath atomically:YES]) {
            fprintf(stderr, "Could not write the app icon\n");
            return 5;
        }
    }
    return 0;
}
