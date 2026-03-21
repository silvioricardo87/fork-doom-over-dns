using System;
using System.IO;
using System.Runtime.ExceptionServices;
using Silk.NET.OpenGL;

namespace ManagedDoom.Silk
{
    public partial class SilkDoom : IDisposable
    {
        private CommandLineArgs args;

        private Config config;
        private GameContent content;

        private Win32Window window;

        private GL gl;
        private SilkVideo video;

        private SilkUserInput userInput;

        private Doom doom;

        private int fpsScale;
        private int frameCount;

        private Exception exception;

        /// <summary>
        /// Launch Doom with a WAD loaded entirely from an in-memory stream.
        /// wadName should be "doom1" for shareware, "doom" for retail, "doom2" for Doom II.
        /// Audio is disabled (no OpenAL required).
        /// </summary>
        public SilkDoom(Stream wadStream, string wadName, CommandLineArgs args)
        {
            try
            {
                this.args = args;

                config = SilkConfigUtilities.GetConfig();
                content = new GameContent(wadStream, wadName, args);

                config.video_screenwidth = Math.Clamp(config.video_screenwidth, 320, 3200);
                config.video_screenheight = Math.Clamp(config.video_screenheight, 200, 2000);

                window = new Win32Window(
                    config.video_screenwidth,
                    config.video_screenheight,
                    ApplicationInfo.Title,
                    config.video_fullscreen);

                Initialize();
            }
            catch (Exception e)
            {
                Dispose();
                ExceptionDispatchInfo.Throw(e);
            }
        }

        public SilkDoom(CommandLineArgs args)
        {
            try
            {
                this.args = args;

                config = SilkConfigUtilities.GetConfig();
                content = new GameContent(args);

                config.video_screenwidth = Math.Clamp(config.video_screenwidth, 320, 3200);
                config.video_screenheight = Math.Clamp(config.video_screenheight, 200, 2000);

                window = new Win32Window(
                    config.video_screenwidth,
                    config.video_screenheight,
                    ApplicationInfo.Title,
                    config.video_fullscreen);

                Initialize();
            }
            catch (Exception e)
            {
                Dispose();
                ExceptionDispatchInfo.Throw(e);
            }
        }

        private void Initialize()
        {
            gl = GL.GetApi(new Win32GlContext());
            gl.ClearColor(0.15F, 0.15F, 0.15F, 1F);
            gl.Clear(ClearBufferMask.ColorBufferBit);
            window.SwapBuffers();

            video = new SilkVideo(config, content, window.Width, window.Height, gl);

            userInput = new SilkUserInput(config, window, this, !args.nomouse.Present);

            window.Resize += (w, h) => video.Resize(w, h);

            doom = new Doom(args, config, content, video, null, null, userInput);

            fpsScale = args.timedemo.Present ? 1 : config.video_fpsscale;
            frameCount = -1;
        }

        private void Quit()
        {
            if (exception != null)
            {
                ExceptionDispatchInfo.Throw(exception);
            }
        }

        private void OnUpdate()
        {
            try
            {
                frameCount++;

                if (frameCount % fpsScale == 0)
                {
                    if (doom.Update() == UpdateResult.Completed)
                    {
                        window.Close();
                    }
                }
            }
            catch (Exception e)
            {
                exception = e;
            }

            if (exception != null)
            {
                window.Close();
            }
        }

        private void OnRender()
        {
            try
            {
                var frameFrac = Fixed.FromInt(frameCount % fpsScale + 1) / fpsScale;
                video.Render(doom, frameFrac);
                window.SwapBuffers();
            }
            catch (Exception e)
            {
                exception = e;
            }
        }

        private void OnClose()
        {
            if (userInput != null)
            {
                userInput.Dispose();
                userInput = null;
            }

            if (video != null)
            {
                video.Dispose();
                video = null;
            }

            if (gl != null)
            {
                gl.Dispose();
                gl = null;
            }

            config.Save(ConfigUtilities.GetConfigPath());
        }

        public void KeyDown(int vk)
        {
            doom.PostEvent(new DoomEvent(EventType.KeyDown, SilkUserInput.VkToDoom(vk)));
        }

        public void KeyUp(int vk)
        {
            doom.PostEvent(new DoomEvent(EventType.KeyUp, SilkUserInput.VkToDoom(vk)));
        }

        public void Dispose()
        {
            if (window != null)
            {
                window.Dispose();
                window = null;
            }
        }

        public string QuitMessage => doom.QuitMessage;
        public Exception Exception => exception;
    }
}
