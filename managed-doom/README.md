# Managed Doom (DoomDNS Fork)

This is a modified fork of [managed-doom](https://github.com/sinshu/managed-doom) by sinshu, patched to run entirely from memory with zero native dependencies. These changes were made for the [DoomDNS](<!-- TODO: repo link -->) project, which fetches and launches DOOM from DNS TXT records without writing a single byte to disk.

### What Changed

The core game engine — rendering, physics, AI, collision, maps — is **completely untouched**. The patches only modify the I/O boundaries and build configuration:

- **Build target:** Removed Native AOT compilation so the output is a managed assembly loadable via `Assembly.Load(byte[])`. Changed target framework from `net10.0` to `net8.0`.
- **WAD loading:** Added a `Stream`-based constructor to `Wad` and `GameContent` so the game can boot from a `MemoryStream` instead of requiring files on disk.
- **Windowing:** Replaced GLFW (a native C DLL that must exist on disk) with direct Win32 P/Invoke calls to `user32.dll`, `gdi32.dll`, and `opengl32.dll` — system DLLs that are always present on Windows.
- **Input:** Rewrote `SilkUserInput` to use Win32 virtual key codes instead of Silk.NET.Input (which depended on GLFW).
- **OpenGL context:** Replaced Silk.NET's GLFW-based context with a custom `Win32GlContext` using `wglGetProcAddress`.
- **Audio:** Disabled. Removed OpenAL/DrippyAL/MeltySynth dependencies. The engine's existing `NullSound`/`NullMusic` stubs handle this gracefully.
- **Entry point:** Added `SilkProgram.RunFromStream(Stream, string, string[])` as a reflection-callable entry point for the PowerShell player script.

The result is a set of pure managed .NET assemblies with no native DLL dependencies, invokable from raw bytes in memory.

All credit for the engine itself goes to sinshu — it's an impressive piece of work.

---

# Managed Doom

![Doom II MAP01 screenshot](screenshots/doom2-map01.png)

Managed Doom is a Doom source port written in C#. The entire code is manually translated from [Linux Doom](https://github.com/id-Software/DOOM) with some effort to make it natural C# code. Most functionalities necessary for single player game are implemented, and now it's in the playable state.

## Screenshots

![Doom E1M1](screenshots/doom-e1m1.png)

![Doom II MAP11](screenshots/doom2-map11.png)

![Mr.DooM 30 MAP29](screenshots/mrdoom30-map29.png)

![Eternal Doom MAP29](screenshots/eternal-map29.png)

![Requiem MAP13](screenshots/requiem-map13.png)

![Zombies TC MAP01](screenshots/zombies-map01.png)

![Batman Doom MAP27](screenshots/batman-map27.png)

## Demo video

https://www.youtube.com/watch?v=WIdIOzQFVq0  

[![Demo video](https://img.youtube.com/vi/WIdIOzQFVq0/0.jpg)](https://www.youtube.com/watch?v=WIdIOzQFVq0)

## Todo

* __Software renderering__  
    - [x] Front-to-back rendering using BSP
    - [x] Wall texture mapping
    - [x] Ceiling / floor texture mapping
    - [x] Transparent textures
    - [x] Diminishing lighting
    - [x] Sky rendering
    - [x] Sprite rendering
    - [x] High resolution rendering
    - [x] Optimization
    - [x] Fuzz effect
    - [x] Palette effects

* __Game__
    - [x] Collision detection
    - [x] Player movement
    - [x] Player attack
    - [x] Monster AI
    - [x] Doors and platforms
    - [x] Animated textures
    - [x] Demo compatibility

* __Audio__
    - [x] Sound
    - [x] Music

* __Misc__
    - [x] Status bar
    - [x] Automap
    - [x] Title screen
    - [x] Intermission screen
    - [x] Menu screen
    - [x] Save / load
    - [x] Screen melt animation
    - [x] Config
    - [x] DeHackEd support
    - [x] Frame interpolation

## License

Managed Doom is distributed under the [GPLv2 license](licenses/LICENSE_ManagedDoom.txt).  
Managed Doom uses the following libraries:

* [Silk.NET](https://github.com/dotnet/Silk.NET) by the the Silk.NET team ([MIT License](licenses/LICENSE_SilkNET.txt))
* [TrippyGL](https://github.com/SilkCommunity/TrippyGL) by Thomas Mizrahi ([MIT License](licenses/LICENSE_TrippyGL.txt))
* [TimGM6mb](https://musescore.org/en/handbook/soundfonts-and-sfz-files#gm_soundfonts) by Tim Brechbill ([GPLv2 license](licenses/LICENSE_TimGM6mb.txt))
* [DrippyAL](https://github.com/sinshu/DrippyAL) ([MIT License](licenses/LICENSE_DrippyAL.txt))
* [MeltySynth](https://github.com/sinshu/meltysynth/) ([MIT license](licenses/LICENSE_MeltySynth.txt))

Silk.NET uses the following native libraries:

* [GLFW](https://www.glfw.org/) ([zlib/libpng license](licenses/LICENSE_GLFW.txt))
* [OpenAL Soft](https://openal-soft.org/) ([LGPL license](licenses/LICENSE_OpenALSoft.txt))

## References

* __The Game Engine Black Book: DOOM by Fabien Sanglard__  
If you want to understand the big picture of the rendering process in Doom, buy this one.  
https://fabiensanglard.net/gebbdoom/index.html

* __The Unofficial Doom Specs by Matthew S Fell__  
http://www.gamers.org/dhs/helpdocs/dmsp1666.html

* __MUS File Format Description by Vladimir Arnost__  
https://www.doomworld.com/idgames/docs/editing/mus_form

* __Chocolate Doom by Simon Howard__  
Chocolate Doom is used as the reference of  compatibility tests.  
https://github.com/chocolate-doom/chocolate-doom

* __Crispy Doom by Fabian Greffrath__  
The minimal HUD is imported from Crispy Doom.  
https://github.com/fabiangreffrath/crispy-doom

* __Doom Wiki__  
https://doomwiki.org/wiki/Entryway

* __Eternity Engine DeHackEd / BEX Reference__  
http://eternity.mancubus.net/svn/trunk/docs/dehref.html
