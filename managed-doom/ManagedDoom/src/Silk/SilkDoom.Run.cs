using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace ManagedDoom.Silk
{
    public partial class SilkDoom : IDisposable
    {
        [DllImport("winmm.dll")]
        private static extern uint timeBeginPeriod(uint uPeriod);

        [DllImport("winmm.dll")]
        private static extern uint timeEndPeriod(uint uPeriod);

        private void Sleep(int ms)
        {
            timeBeginPeriod(1);
            Thread.Sleep(ms);
            timeEndPeriod(1);
        }

        public void Run()
        {
            config.video_fpsscale = Math.Clamp(config.video_fpsscale, 1, 100);
            var targetFps = 35 * config.video_fpsscale;

            var gameTime = TimeSpan.Zero;
            var gameTimeStep = TimeSpan.FromSeconds(1.0 / targetFps);

            var sw = new Stopwatch();
            sw.Start();

            while (!window.IsClosing)
            {
                window.DoEvents();

                if (!window.IsClosing)
                {
                    OnUpdate();
                    gameTime += gameTimeStep;
                }

                if (!window.IsClosing)
                {
                    if (sw.Elapsed < gameTime)
                    {
                        OnRender();
                        var sleepTime = gameTime - sw.Elapsed;
                        var ms = (int)sleepTime.TotalMilliseconds;
                        if (ms > 0)
                        {
                            Sleep(ms);
                        }
                    }
                }
            }

            window.DoEvents();
            OnClose();

            Quit();
        }
    }
}
