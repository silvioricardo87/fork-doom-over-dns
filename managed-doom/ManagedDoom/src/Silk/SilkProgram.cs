using System;
using System.IO;
using System.Threading;

namespace ManagedDoom.Silk
{
    public static class SilkProgram
    {
        /// <summary>
        /// Entry point for in-memory launch: WAD comes from a MemoryStream,
        /// no WAD file is ever written to disk.
        /// wadName: "doom1" (shareware), "doom" (retail), "doom2".
        /// Typical extra args: ["-nosound"] if OpenAL is unavailable.
        /// </summary>
        public static void RunFromStream(Stream wadStream, string wadName, string[] extraArgs)
        {
            Console.ForegroundColor = ConsoleColor.White;
            Console.BackgroundColor = ConsoleColor.DarkGreen;
            Console.WriteLine(ApplicationInfo.Title);
            Console.ResetColor();

            try
            {
                string quitMessage = null;

                using (var app = new SilkDoom(wadStream, wadName, new CommandLineArgs(extraArgs)))
                {
                    app.Run();
                    quitMessage = app.QuitMessage;
                }

                if (quitMessage != null)
                {
                    Console.ForegroundColor = ConsoleColor.Green;
                    Console.WriteLine(quitMessage);
                    Console.ResetColor();
                }
            }
            catch (Exception e)
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine(e);
                Console.ResetColor();
            }
        }

        public static void Main(string[] args)
        {
            Console.ForegroundColor = ConsoleColor.White;
            Console.BackgroundColor = ConsoleColor.DarkGreen;
            Console.WriteLine(ApplicationInfo.Title);
            Console.ResetColor();

            try
            {
                string quitMessage = null;

                using (var app = new SilkDoom(new CommandLineArgs(args)))
                {
                    app.Run();
                    quitMessage = app.QuitMessage;
                }

                if (quitMessage != null)
                {
                    Console.ForegroundColor = ConsoleColor.Green;
                    Console.WriteLine(quitMessage);
                    Console.ResetColor();
                    Console.Write("Press any key to exit.");
                    Console.ReadKey();
                }
            }
            catch (Exception e)
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine(e);
                Console.ResetColor();
                Thread.Sleep(3000);
                Console.Write("Press any key to exit.");
                Console.ReadKey();
            }
        }
    }
}
