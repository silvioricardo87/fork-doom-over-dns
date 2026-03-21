using System;

namespace ManagedDoom.Silk
{
    public static class SilkConfigUtilities
    {
        public static Config GetConfig()
        {
            var config = new Config(ConfigUtilities.GetConfigPath());

            if (!config.IsRestoredFromFile)
            {
                var (screenWidth, screenHeight) = Win32Window.GetScreenResolution();
                var (w, h) = GetDefaultWindowSize(screenWidth, screenHeight);
                config.video_screenwidth = w;
                config.video_screenheight = h;
            }

            return config;
        }

        private static (int width, int height) GetDefaultWindowSize(int screenWidth, int screenHeight)
        {
            var baseWidth = 640;
            var baseHeight = 400;

            var currentWidth = baseWidth;
            var currentHeight = baseHeight;

            while (true)
            {
                var nextWidth = currentWidth + baseWidth;
                var nextHeight = currentHeight + baseHeight;

                if (nextWidth >= 0.9 * screenWidth ||
                    nextHeight >= 0.9 * screenHeight)
                {
                    break;
                }

                currentWidth = nextWidth;
                currentHeight = nextHeight;
            }

            return (currentWidth, currentHeight);
        }
    }
}
