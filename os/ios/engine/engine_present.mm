#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include "engine_present.h"

@interface VaultPresentView : UIView
@end

@implementation VaultPresentView

+ (Class)layerClass
{
    return [CAMetalLayer class];
}

@end

namespace {

NSString* const kPresentShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VaultPresentVertex {\n"
     "    float4 position [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VaultPresentVertex vault_present_vertex(uint vertexID [[vertex_id]]) {\n"
     "    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);\n"
     "    VaultPresentVertex out;\n"
     "    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);\n"
     "    out.uv = float2(corner.x, 1.0 - corner.y);\n"
     "    return out;\n"
     "}\n"
     "fragment float4 vault_present_fragment(VaultPresentVertex in [[stage_in]],\n"
     "                                       texture2d<float> source [[texture(0)]],\n"
     "                                       constant float2& scale [[buffer(0)]]) {\n"
     "    constexpr sampler smp(filter::linear, address::clamp_to_edge);\n"
     "    float2 size = float2(source.get_width(), source.get_height());\n"
     "    float2 texel = in.uv * size;\n"
     "    float2 base = floor(texel);\n"
     "    float2 phase = clamp((texel - base - 0.5) / max(scale, float2(1.0)) + 0.5,\n"
     "                         float2(0.0), float2(1.0));\n"
     "    return float4(source.sample(smp, (base + phase) / size).rgb, 1.0);\n"
     "}\n";

id<MTLDevice> gPresentDevice = nil;
id<MTLCommandQueue> gPresentQueue = nil;
id<MTLRenderPipelineState> gPresentPipeline = nil;
id<MTLTexture> gPresentTexture = nil;
VaultPresentView* gPresentView = nil;
CAMetalLayer* gPresentLayer = nil;
int gPresentTextureWidth = 0;
int gPresentTextureHeight = 0;
bool gPresentUnavailable = false;

UIWindow* presentWindow()
{
    UIApplication* application = [UIApplication sharedApplication];
    for (UIWindow* window in application.windows) {
        if (window.hidden) {
            continue;
        }
        if (window.windowLevel != UIWindowLevelNormal) {
            continue;
        }
        return window;
    }

    return nil;
}

bool presentResourcesReady()
{
    if (gPresentUnavailable) {
        return false;
    }

    if (gPresentDevice == nil) {
        gPresentDevice = MTLCreateSystemDefaultDevice();
        if (gPresentDevice == nil) {
            gPresentUnavailable = true;
            return false;
        }

        gPresentQueue = [gPresentDevice newCommandQueue];
        if (gPresentQueue == nil) {
            gPresentUnavailable = true;
            return false;
        }

        NSError* error = nil;
        id<MTLLibrary> library = [gPresentDevice newLibraryWithSource:kPresentShaderSource
                                                              options:nil
                                                                error:&error];
        if (library == nil) {
            gPresentUnavailable = true;
            return false;
        }

        MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"vault_present_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"vault_present_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        gPresentPipeline = [gPresentDevice newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (gPresentPipeline == nil) {
            gPresentUnavailable = true;
            return false;
        }
    }

    UIWindow* window = presentWindow();
    if (window == nil) {
        return false;
    }

    if (gPresentView == nil) {
        gPresentView = [[VaultPresentView alloc] initWithFrame:window.bounds];
        gPresentView.userInteractionEnabled = NO;
        gPresentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gPresentView.backgroundColor = [UIColor blackColor];
        gPresentLayer = (CAMetalLayer*)gPresentView.layer;
        gPresentLayer.device = gPresentDevice;
        gPresentLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gPresentLayer.framebufferOnly = YES;
        gPresentLayer.opaque = YES;
    }

    if (gPresentView.superview != window) {
        [gPresentView removeFromSuperview];

        NSUInteger position = 0;
        UIView* engineView = window.rootViewController.view;
        if (engineView != nil) {
            NSUInteger index = [window.subviews indexOfObject:engineView];
            if (index != NSNotFound) {
                position = index + 1;
            }
        }

        [window insertSubview:gPresentView atIndex:position];
    }

    gPresentView.frame = window.bounds;

    return true;
}

}

int fallout_engine_present_frame(const void* pixels, int pitch, int width, int height)
{
    if (pixels == NULL || pitch <= 0 || width <= 0 || height <= 0) {
        return 0;
    }

    @autoreleasepool {
        if (!presentResourcesReady()) {
            return 0;
        }

        UIWindow* window = gPresentView.window;
        if (window == nil) {
            return 0;
        }

        CGFloat scale = window.screen.nativeScale;
        if (scale <= 0) {
            scale = gPresentView.contentScaleFactor;
        }

        CGSize drawableSize = CGSizeMake(gPresentView.bounds.size.width * scale,
                                         gPresentView.bounds.size.height * scale);
        if (drawableSize.width < 1 || drawableSize.height < 1) {
            return 0;
        }

        if (!CGSizeEqualToSize(gPresentLayer.drawableSize, drawableSize)) {
            gPresentLayer.drawableSize = drawableSize;
            gPresentLayer.contentsScale = scale;
        }

        if (gPresentTexture == nil || gPresentTextureWidth != width || gPresentTextureHeight != height) {
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                  width:(NSUInteger)width
                                                                                                 height:(NSUInteger)height
                                                                                              mipmapped:NO];
            descriptor.usage = MTLTextureUsageShaderRead;
            gPresentTexture = [gPresentDevice newTextureWithDescriptor:descriptor];
            gPresentTextureWidth = width;
            gPresentTextureHeight = height;
            if (gPresentTexture == nil) {
                return 0;
            }
        }

        id<CAMetalDrawable> drawable = [gPresentLayer nextDrawable];
        if (drawable == nil) {
            return 1;
        }

        [gPresentTexture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                           mipmapLevel:0
                             withBytes:pixels
                           bytesPerRow:(NSUInteger)pitch];

        CGFloat gameAspect = (CGFloat)width / (CGFloat)height;
        CGFloat drawableAspect = drawableSize.width / drawableSize.height;
        CGFloat fitWidth = drawableSize.width;
        CGFloat fitHeight = drawableSize.height;
        if (drawableAspect > gameAspect) {
            fitWidth = drawableSize.height * gameAspect;
        } else {
            fitHeight = drawableSize.width / gameAspect;
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLCommandBuffer> commandBuffer = [gPresentQueue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];

        MTLViewport viewport;
        viewport.originX = (drawableSize.width - fitWidth) * 0.5;
        viewport.originY = (drawableSize.height - fitHeight) * 0.5;
        viewport.width = fitWidth;
        viewport.height = fitHeight;
        viewport.znear = 0.0;
        viewport.zfar = 1.0;
        [encoder setViewport:viewport];

        [encoder setRenderPipelineState:gPresentPipeline];
        [encoder setFragmentTexture:gPresentTexture atIndex:0];
        float ratios[2] = { (float)(fitWidth / (CGFloat)width), (float)(fitHeight / (CGFloat)height) };
        [encoder setFragmentBytes:ratios length:sizeof(ratios) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        return 1;
    }
}
