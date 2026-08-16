[![](https://raw.githubusercontent.com/community-owned-workshop/wiki/refs/heads/main/assets/banner-title-seals-scrap-mechanic.png)](https://community-owned-workshop.github.io/wiki/)

## Why this exists

Traditional Survival file mods often install themselves by directly editing files inside _Scrap Mechanic\Survival_.
That works for one mod, but multiple installers overwrite each other's JSONs, Lua files, recipes, ShapeSets, or icon 
atlases.

The bootstrapper lets participating mods describe their changes in a _bootstrap.json_. On startup it restores clean 
vanilla merge targets and then applies all installed bootstrap-enabled mods together.


## What it does

- Detects the installed Scrap Mechanic version
- Keeps a version-specific vanilla backup of only the files it modifies
- Discovers bootstrap-enabled mods
- Restores the clean merge targets before every run
- Applies all mod registrations from scratch
- Detects conflicting UUID / resource claims instead of silently overwriting another mod
- Allocates shared icon-atlas slots centrally
- Deletes only `Cache\Bundle\core_data.cbo` when generated content changes
- Writes diagnostics to `bootstrapper.log`


## Installation

Before the first run, verify Scrap Mechanic's files through Steam. The first version-specific backup must be created 
from clean vanilla files.

Then add this to the Launch Options in Steam:

```
"[SteamWorkshopFolder]\387990\3784073427\Start-ScrapMechanic.cmd" %command% 
```

**Example:**

```
"C:\Program Files (x86)\Steam\steamapps\workshop\content\387990\3784073427\Start-ScrapMechanic.cmd" %command% 
```

**387990** is the ID for Scrap Mechanic, **3784073427** is the ID of this mod.


If you want to test the bootstrapper directly, go to its folder and execute:

```powershell
.\Bootstrapper.ps1 -GamePath "[SteamFolder]\steamapps\common\Scrap Mechanic" -NoLaunch
```

**Example:**

```powershell
.\Bootstrapper.ps1 -GamePath "C:\Program Files (x86)\Steam\steamapps\common\Scrap Mechanic" -NoLaunch
```


## Cache

When generated content changes, the bootstrapper removes only _Cache\Bundle\core_data.cbo_.
Do not delete the complete Scrap Mechanic `Cache` directory (I learned that the hard way).


## Status

Experimental. Initially tested against Scrap Mechanic 1.0.5.876 on Windows.
