# DeskSaw

## This is the source code page. To download the executable, [go to releases here!](https://github.com/dee-dee-catorce/desksaw/releases)

<img width="800" height="450" alt="prev" src="https://github.com/user-attachments/assets/711adeb3-b843-4819-8ccd-539c799052ce" />

It's true! Experiments from hit games [Casualties: Unknown](https://store.steampowered.com/app/4576490/Casualties_Unknown/) and [GunSaw](https://orsonik.itch.io/gunsaw-demo) right on your desktop! Spawn them, feed them, throw sawblades at them! Or give them the life they deserve by petting them restlessly. <3

### Controls

**F1** / **Ctrl + Right Click** *an Expie* to bring up the terminal

**Left Click** an Expie to pet them or **Right Click** one of their limbs to drag them around

## How to build

* Get the latest [.NET Godot Engine](https://godotengine.org/download/) release *(required to build C# solutions)*
* Clone the git repository
  * Via [git](https://git-scm.com/install/), run ``git clone https://github.com/dee-dee-catorce/desksaw``
  * or [download the source code directly](https://github.com/dee-dee-catorce/desksaw/archive/refs/heads/master.zip)
* You will also need the ``godot-console`` addon to load the project correctly
  * Via git, run the following commands inside the project's path:

	```console
	cd addons/godot-console
	git submodule init
	git submodule update
	```
  
  * or [manually download the godot-console repository](https://github.com/4d49/godot-console) and move its contents inside the ``addons/godot-console`` folder

* Open Godot, click the ``Import`` button and find the cloned repository folder
* If you haven't built a Godot project before, go to ``Editor > Manage Export Features`` and download a template for the platform you're building to
* Go to ``Project > Export`` and add a new preset for the target platform, click ``Export Project`` and go to your target path before saving
  * If the build fails, you might need to rebuild the C# solution. Do so by going to ``Project > Tools > C# > Create C# Solution``. If you don't see the option, you downloaded the wrong Godot release! :p

You successfully built DeskSaw!

## Credits

### [Casualties: Unknown](https://store.steampowered.com/app/4576490/Casualties_Unknown/) *by [Orsoniks/Moffee](https://orsonik.itch.io)*

### [Godot "Minimalistic UI" Theme](https://azagaya.itch.io/minimalistic-ui) *by [azagaya](https://azagaya.itch.io)*


### [Godot Console Plugin](https://github.com/4d49/godot-console) *by [4d49](https://github.com/4d49), [stevenctl](https://github.com/stevenctl), [v-for-vandal](https://github.com/v-for-vandal) & [lolomap](https://github.com/lolomap)*

### [Godot Rapier Physics](https://godot.rapier.rs/) *by [appsinacup](https://github.com/appsinacup) & [several contributors](https://github.com/appsinacup/godot-rapier-physics/graphs/contributors?all=1)*

## Contributing

This project is in active development. Feel free to fork and contribute to it by making a pull request.
