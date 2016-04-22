/*
 Copyright (c) 2013, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
    What doesn't work:

        - Autoload savestate on start doesn't work reliably on Wii.  some games it works most it doesn't
        - Wii does not have a reset function, so restart only works in GC mode
 */

//  Changed <al*> includes to <OpenAL/al*>
//  Updated to Dolphin Git Source 28 Feb 2016
//  Added iRenderFBO to Videoconfig, OGL postprocessing and renderer
//  Added SetState to device.h
//  Add UpdateAccelData to ControllerEmu.h
//  updated to Dolphin 4.0-9196 git
//  Added Render on alternate thread in Core.cpp in EmuThread() Video Thread
//  Updated to dolphin 4.0-9211 - 12 Apr 2016

#import "DolphinGameCore.h"
#include "Dolphin-Core/DolHost.h"
#import <OpenEmuBase/OERingBuffer.h>

#import <AppKit/AppKit.h>
#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

#define SAMPLERATE 48000
#define SIZESOUNDBUFFER 48000 / 60 * 4
#define OpenEmu 1

@interface DolphinGameCore () <OEGCSystemResponderClient>
@property (copy) NSString *filePath;
@end

DolphinGameCore *_current = 0;

@implementation DolphinGameCore
{
    DolHost *dol_host;

    uint16_t *_soundBuffer;
    bool _isWii;
    bool _isInitialized;
    float _frameInterval;

    NSString *_dolphinCoreModule;
    OEIntSize _dolphinCoreAspect;
    OEIntSize _dolphinCoreScreen;
}

- (instancetype)init
{
    if(self = [super init])
        dol_host = DolHost::GetInstance();

    _current = self;
    return self;
}

- (void)dealloc
{
    delete dol_host;
    free(_soundBuffer);
}

# pragma mark - Execution
- (BOOL)loadFileAtPath:(NSString *)path
{
    self.filePath = path;

    if([[self systemIdentifier] isEqualToString:@"openemu.system.gc"])
    {
        _dolphinCoreModule = @"gc";
        _isWii = false;
        _dolphinCoreAspect = OEIntSizeMake(4, 3);
        _dolphinCoreScreen = OEIntSizeMake(640, 480);
    }
    else
    {
        _dolphinCoreModule = @"Wii";
        _isWii = true;
        _dolphinCoreAspect = OEIntSizeMake(16,9);
        _dolphinCoreScreen = OEIntSizeMake(854, 480);
    }

    dol_host->Init([[self supportDirectoryPath] UTF8String], [path UTF8String] );

    return YES;
}

- (void)setPauseEmulation:(BOOL)flag
{
     dol_host->Pause(flag);
}

- (void)stopEmulation
{
    _isInitialized = false;
    
    dol_host->RequestStop();

    [super stopEmulation];
}

- (void)startEmulation
{
    if (!_isInitialized)
    {
        [self.renderDelegate willRenderFrameOnAlternateThread];

        dol_host->SetPresentationFBO((int)[[self.renderDelegate presentationFramebuffer] integerValue]);

        if(dol_host->LoadFileAtPath())
            _isInitialized = true;
    }
    [super startEmulation];
}

- (void)resetEmulation
{
    if(!_isWii)
     dol_host->Reset();
}

- (void)executeFrame
{
    dol_host->UpdateFrame();
}

# pragma mark - Render Callback
- (void)swapBuffers
{
    //This will render the Dolphin FBO frame
    [self.renderDelegate presentDoubleBufferedFBO];
    [self.renderDelegate didRenderFrameOnAlternateThread];
}

# pragma mark - Nand directory Callback
- (const char *)getBundlePath
{
    NSBundle *coreBundle = [NSBundle bundleForClass:[self class]];
    const char *dataPath;
    dataPath = [[coreBundle resourcePath] fileSystemRepresentation];

    return dataPath;
}

# pragma mark - Video
- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL3Video;
}

- (BOOL)hasAlternateRenderingThread
{
    return YES;
}

- (BOOL)needsDoubleBufferedFBO
{
    return YES;
}

- (const void *)videoBuffer
{
    return NULL;
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval ?: 60;
}

- (OEIntSize)bufferSize
{
    return _dolphinCoreScreen;
}

- (OEIntSize)aspectSize
{
    return _dolphinCoreAspect;
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_BYTE;
}

- (GLenum)internalPixelFormat
{
    return GL_RGBA;
}

# pragma mark - Audio
- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return SAMPLERATE;
}

# pragma mark - Save States
- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // we need to make sure we are initialized before attempting to save a state
    while (! _isInitialized)
        usleep (1000);

    block(dol_host->SaveState([fileName UTF8String]),nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized)
    {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
            [self autoloadSaveState:fileName];
        });

        block(true, nil);
    } else {
        block(dol_host->LoadState([fileName UTF8String]),nil);
    }
}
- (void) autoloadSaveState:(NSString *)fileName
{
    [self beginPausedExecution];

    dol_host->setAutoloadFile([fileName UTF8String]);

    [self endPausedExecution];
}

# pragma mark - Input GC
- (oneway void)didMoveGCJoystickDirection:(OEGCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetAxis(button, value, (int)player);
    }
}

- (oneway void)didPushGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetButtonState(button, 1, (int)player);
    }
}

- (oneway void)didReleaseGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetButtonState(button, 0, (int)player);
    }
}

# pragma mark - Input Wii
- (oneway void)didMoveWiiJoystickDirection:(OEWiiButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetAxis(button, value, (int)player);
    }
}


- (oneway void)didPushWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetButtonState(button, 1, (int)player);
    }
}

- (oneway void)didReleaseWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetButtonState(button, 0, (int)player);
    }
}

- (oneway void) didMoveWiiAccelerometer:(OEWiiAccelerometer)accelerometer withValue:(CGFloat)X withValue:(CGFloat)Y withValue:(CGFloat)Z forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        if (accelerometer == OEWiiNunchuk)
        {
            dol_host->setNunchukAccel(X,Y,Z,(int)player);
        }
        else
        {
            dol_host->setWiimoteAccel(X,Y,Z,(int)player);
        }
    }
}

- (oneway void)didMoveWiiIR:(OEWiiButton)button IRinfo:(OEwiimoteIRinfo)IRinfo forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->setIRdata(IRinfo ,(int)player);
    }
}

- (oneway void)didChangeWiiExtension:(OEWiimoteExtension)extension forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->changeWiimoteExtension(extension, (int)player);
    }
}

# pragma mark - Cheats
- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    dol_host->SetCheat([code UTF8String], [type UTF8String], enabled);
    
}
@end
