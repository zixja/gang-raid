# 🏚️ Gang Hideout Raid
**A fully synced, wave-based gang raid script for FiveM**

[![FiveM](https://img.shields.io/badge/FiveM-Ready-brightgreen?style=flat-square)](https://fivem.net/)
[![QBCore](https://img.shields.io/badge/QBCore-Compatible-blue?style=flat-square)](https://github.com/qbcore-framework)
[![QBox](https://img.shields.io/badge/QBox-Compatible-blue?style=flat-square)](https://github.com/Qbox-project)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

> Storm a randomly selected gang warehouse, fight through waves of armed NPCs, loot crates for rewards, and survive the final wave's vehicle reinforcements — all fully synced across every player on the server.

---

## ✨ Features

| Feature | Details |
|---|---|
| 🗺️ **Multiple randomized locations** | 3 gang hideouts (Ballas, Grove Street, Vagos). One is picked at random each raid |
| 🌊 **Wave-based enemy spawns** | Up to 3 configurable waves with increasing difficulty |
| 🔫 **Diverse weapons** | Each guard has an individually configured weapon from pistols to assault rifles |
| 🧠 **Fully synced NPCs** | Peds are spawned server-side (`networked = true`) — same entity, same HP for all players |
| 📦 **Loot crates** | Chance-based rewards including marked money, drugs, ammo, and armor |
| 🚗 **Escape vehicle reinforcements** | Armed driver spawns on the final wave and drives toward the raid location |
| 🚔 **Police dispatch** | `ps-dispatch` alert fires when a raid begins (with legacy API fallback) |
| 🏆 **Completion bonus** | Marked money reward paid to each player who survives the raid |
| ⏱️ **Raid cooldown** | Prevents back-to-back raids (configurable) |
| 🔧 **Auto framework detection** | Works with QBCore or QBox out of the box |
| 🎯 **Dual target support** | Compatible with both `qb-target` and `ox_target` |
| 📦 **Dual inventory support** | Compatible with both `qb-inventory` and `ox_inventory` |

---

## 📋 Requirements

**Required:**
- [`qb-core`](https://github.com/qbcore-framework/qb-core) or [`qbox`](https://github.com/Qbox-project/qbx_core)
- [`qb-target`](https://github.com/qbcore-framework/qb-target) **or** [`ox_target`](https://github.com/overextended/ox_target)

**Optional (but recommended):**
- [`ps-dispatch`](https://github.com/Project-Sloth/ps-dispatch) — for police alerts
- [`ox_inventory`](https://github.com/overextended/ox_inventory) — falls back to qb-inventory if not present

---

## 📦 Installation

1. **Download** or clone this repository
2. **Place** the `gang-raid` folder inside your server's `resources` directory
3. **Add** the following to your `server.cfg`:

```cfg
ensure gang-raid
```

4. **Make sure** your dependencies are started **before** this resource:

```cfg
ensure qb-core         # or qbox
ensure qb-target       # or ox_target
ensure ps-dispatch     # optional
ensure ox_inventory    # optional
```

5. **Configure** `config.lua` to match your server's setup (see below)
6. **Restart** your server

---

## ⚙️ Configuration

All settings live in `config.lua`.

### Framework Detection
```lua
Config.Framework       = 'auto'  -- 'qb' | 'ox' | 'auto'
Config.TargetExport    = 'auto'  -- 'qb-target' | 'ox_target' | 'auto'
Config.InventoryExport = 'auto'  -- 'qb' | 'ox_inventory' | 'auto'
```
Set to `'auto'` to let the script detect what you have running, or pin to a specific export.

### General Settings
```lua
Config.Debug                = false  -- Print debug logs to server console
Config.MaxWaves             = 3      -- Number of enemy waves per raid
Config.WaveDelay            = 30     -- Seconds between waves
Config.RaidCooldown         = 600    -- Seconds before raid can start again
Config.DispatchEnabled      = true   -- Send ps-dispatch alert on raid start
Config.EscapeVehicleEnabled = true   -- Spawn escape vehicle on final wave
```

### Adding Raid Locations
Each entry in `Config.Locations` is a full raid site with its own blip, loot crates, waves, and escape vehicle:

```lua
Config.Locations = {
    {
        name = "My New Location",
        blip = {
            coords = vector3(x, y, z),
            sprite = 161,
            color  = 1,
            scale  = 0.9,
            label  = "Gang Hideout"
        },
        lootCrates = {
            vector3(x, y, z),
            vector3(x, y, z),
        },
        escapeVehicle = {
            model  = 'sultan',
            coords = vector4(x, y, z, heading),
        },
        waves = {
            -- Wave 1
            {
                { coords = vector4(x, y, z, h), model = 'g_m_y_ballasout_01', weapon = 'WEAPON_PISTOL' },
                { coords = vector4(x, y, z, h), model = 'g_m_y_ballasout_01', weapon = 'WEAPON_SMG' },
            },
            -- Wave 2 (add armor and accuracy for tougher enemies)
            {
                { coords = vector4(x, y, z, h), model = 'g_m_y_ballasout_01', weapon = 'WEAPON_ASSAULTRIFLE', armor = 150, accuracy = 80 },
            },
        },
    },
}
```

### Loot Table
```lua
Config.LootTable = {
    { name = "markedmoney", amount = { min = 200, max = 800 }, chance = 60 },
    { name = "cokebaggy",   amount = { min = 1,   max = 3   }, chance = 25 },
    { name = "armor",       amount = { min = 1,   max = 1   }, chance = 15 },
    -- Add as many items as you want
}
```
`chance` is a percentage out of 100. The loot table is shuffled every time a crate is opened so rewards aren't predictable.

---

## 🔄 How NPC Syncing Works

This script uses **server-side ped creation** to ensure all players see the same guards with a shared health pool.

```
Server                               All Clients
  │                                       │
  ├─ CreatePed(networked = true) ───────► │  Entity replicates automatically via FiveM state
  ├─ NetworkGetNetworkIdFromEntity() ───► │
  │                                       │
  ├─ TriggerClientEvent(netIds) ────────► │  Clients resolve netId → local handle
  │                                       ├─ SetRelationshipGroup()
  │                                       └─ TaskCombatHatedTargets()
  │
  ├─ Wave monitor: IsEntityDead() checks  (server is authoritative)
  └─ Triggers next wave or raid complete when all peds dead
```

**Why this matters:** In most public FiveM scripts, `CreatePed` is called on each client separately. This produces duplicate, desynced entities — Player A shoots a guard and it dies on their screen, but Player B still sees it alive. By creating peds on the server with `networked = true`, FiveM's built-in state replication gives every player the exact same entity. One kill counts for everyone.

---

## 📁 File Structure

```
gang_hideout_raid/
├── client.lua        # Blip, loot crates, target interactions, combat task application
├── server.lua        # Ped spawning, wave monitor, loot rewards, dispatch
├── config.lua        # All configurable settings, locations, and loot table
└── fxmanifest.lua    # Resource manifest and dependency declarations
```

---

## 🐛 Known Limitations

- **Crate props are client-local.** Each player sees crate objects independently. This is intentional — the server controls whether loot is given, so there's no risk of duplication. A future version could sync crate removal via a net event.
- **Wave monitor runs on a 5-second tick.** There's up to a 5-second gap between the last guard dying and the next wave announcement. This is intentional to give players a breather.
- **Completion bonus is paid to all online players.** Every player on the server receives the bonus when a raid finishes, not just the one who started it. Adjust the `gang_hideout:raidFinished` event in `server.lua` if you want to restrict this.

---

## 🤝 Contributing

Pull requests are welcome. For major changes please open an issue first to discuss what you'd like to change.

1. Fork the repository
2. Create your feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m 'Add my feature'`
4. Push to the branch: `git push origin feature/my-feature`
5. Open a pull request

---

## 📄 License

[MIT](LICENSE) — free to use, modify, and distribute. Credit appreciated but not required.

---

*Built for the FiveM roleplay community by Decripterr.*
