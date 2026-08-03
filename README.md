# DataStream

DataStream is a intuitive ReplicaService alternative. All schemas are replicated in real time (no loops!) between the client and server with no need to call obnoxious methods.

DataStreams can be used for anything from PlayerData to NPC data replication. You can even put Instances in your data as values or even as table keys! If an instance hasn't replicated to a client yet (StreamingEnabled), DataStream tracks it and links it up automatically once it arrives, even if it streams out and back in.

Recommended for use with projects that use external editors such as VSCode

## Immutability

No more deep copies! Everything you get out of a stream is frozen (`table.freeze`), so reading data is basically free. If you try to modify a table you read, it'll error instead of silently desyncing your data from the server. If you want to modify it, just clone it:

```lua
local stats = DataStream.GameData.Stats:Read()
stats.TotalDeaths += 1 -- ERROR: attempt to modify a readonly table

local mutable = table.clone(stats) -- clone it if you need your own copy
```

As a bonus, since writes swap tables out instead of modifying them, anything you `:Read()` is a snapshot that will never change out from under you, even after later writes to the same path.

## Table of Contents
- [DataStream](#datastream)
  - [Immutability](#immutability)
  - [Table of Contents](#table-of-contents)
  - [Schemas](#schemas)
    - [Global:](#global)
    - [Player:](#player)
    - [Registering schemas](#registering-schemas)
  - [Methods `DataStreamObject`](#methods-datastreamobject)
    - [**:Read()**](#read)
    - [**:Write()**](#write)
    - [**:Changed((newValue : any, oldValue : any) -\> ())**](#changednewvalue--any-oldvalue--any---)
    - [**:ChildAdded((indexOfChild : any) -\> ())**](#childaddedindexofchild--any---)
    - [**:ChildRemoved((indexOfChild : any) -\> ())**](#childremovedindexofchild--any---)
    - [**:Insert(value : any)**](#insertvalue--any)
    - [**:Remove(value : any)**](#removevalue--any)
  - [Examples](#examples)
    - [1. Increase playtime each second for a player:](#1-increase-playtime-each-second-for-a-player)
    - [2. Adding and removing players to an array](#2-adding-and-removing-players-to-an-array)
  - [Installation](#installation)


## Schemas

A schema is a template data set DataStream starts with. In DataStream, there are two types of schemas:

1. Global Schemas
   
   Global schemas are a single data set that is initialized immediately that is shared in real-time between all players and the server.
   
2. Player Schemas 
   
    Player schemas are a data set that is unique to each individual player, and are initialized as each player joins.

For our examples, we will be using the following schemas

### Global:
```lua
return { --Schemas/Global/GameData.lua
    CurrentGameTime = 0,
    GlobalPlaytime = 0,
    PlayerInGame = {},
    CurrentGameMessage = "Intermission",
    Stats = {
        TotalDeaths = 0,
        CoinsCollected = 0,
        ObjectsCollected = {}
    }
}
```

### Player:
```lua
return { --Schemas/Player/Stored.lua
    Currency = {
        Coins = 0,
        Gems = 0
    },
    PlaytimeSeconds = 0
}
```

### Registering schemas

No special folders needed — just require DataStream from a server script and add the stream itself via the methods:

```lua
-- Server
local DataStream = require(ReplicatedStorage.DataStream).Server

DataStream:MakeGlobalStream("GameData", require(script.Schemas.GameData))
DataStream:AddPlayerStreamTemplate("Stored", require(script.Schemas.Stored))
```

The only rule: register your streams as soon as your script runs, with no yields before the registration calls (no `task.wait`, no `WaitForChild`, etc).

If another script might index a stream before the registering script has run, use `WaitForSchema` — it yields until the stream exists, just like `WaitForChild` (including the warning if it's taking suspiciously long):

```lua
local gameData = DataStream:WaitForSchema("GameData")
gameData.CurrentGameMessage = "Hello!"
```

Plain indexing (`DataStream.GameData`) doesn't wait: on the server it errors if the schema isn't registered, and on the client it returns `nil` until the schema's data has arrived. This is a Luau limitation — index operations run inside metamethods, which aren't allowed to yield.

Registering a stream late (after players are already in game) is also fine: DataStream will push the stream's data to connected clients when it's registered, and any `WaitForSchema` calls waiting on it will resolve.


## Methods `DataStreamObject`
**All methods are the same on the server and client.**

### **:Read()**
Reads the current value that the StreamObject references.

```lua
local value = DataStream.SchemaName.ValueName:Read()

print("The current value of ValueName is", value)
```

### **:Write()**
**SERVER ONLY** Writes the current value that the StreamObject references.

```lua
-- There are many ways to perform a write operation:
DataStream.SchemaName.ValueName:Write(10)
DataStream.SchemaName.ValueName = 10

-- Math operators
DataStream.SchemaName.ValueName *= 10
DataStream.SchemaName.ValueName /= 10
DataStream.SchemaName.ValueName += 10
DataStream.SchemaName.ValueName -= 10
```

### **:Changed((newValue : any, oldValue : any) -> ())**
Fires a callback function when the referenced value is changed. The callback also receives the value from before the change — both are frozen snapshots, so they stay stable even as more writes happen.

```lua
DataStream.SchemaName.ValueName:Changed(function(newValue, oldValue)
    print("Value changed from", oldValue, "to", newValue)
end)

DataStream.SchemaName.ValueName = 10
```

### **:ChildAdded((indexOfChild : any) -> ())**
Fires a callback function when the referenced dictionary has a new member.

```lua
DataStream.SchemaName.ValueName = {}
DataStream.SchemaName.ValueName:ChildAdded(function(newIndex)
    print("New value is equal to", DataStream.SchemaName.ValueName[newIndex]:Read())
end)

DataStream.SchemaName.ValueName.NewValue = "Hello world!"
```

### **:ChildRemoved((indexOfChild : any) -> ())**
Fires a callback function when the referenced dictionary loses a member.

```lua
DataStream.SchemaName.ValueName = {
    NewValue = "Hello World!"
}
DataStream.SchemaName.ValueName:ChildRemoved(function(newIndex)
    print("New value is equal to", DataStream.SchemaName.ValueName[newIndex]:Read())
end)

DataStream.SchemaName.ValueName.NewValue = nil
```

### **:Insert(value : any)**
**:Insert(position : number, value : any)**

Inserts the provided value to the target position of the array. If target position is not provided, it will append at the end of the array.

```lua
DataStream.SchemaName.NewArray = {}

DataStream.SchemaName.NewArray:Insert("Hello,")
DataStream.SchemaName.NewArray:Insert("world!")

print(table.concat(DataStream.SchemaName.NewArray:Read(), " ")) --> "Hello, world!"
```

### **:Remove(value : any)**

Removes the specified element from the array, shifting later elements down to fill in the empty space if possible.

```lua
DataStream.SchemaName.NewArray = {"a", "b", "c"}

DataStream.SchemaName.NewArray:Remove(2)
DataStream.SchemaName.NewArray:Remove(2)

print(DataStream.SchemaName.NewArray:Read()) --> { "a" }
```



## Examples

*Note: These are all for example sake, some of these methods may not be the most efficient solutions depending on your use-case.*

### 1. Increase playtime each second for a player:

```lua
-- Server
local Players = game:GetService("Players")
local DataStream = require(ReplicatedStorage.DataStream).Server

local globalGameDataStream = DataStream.GameData

local function SetupPlayer(player : Player)
    local playerStoredStream = DataStream.Stored[player]

    task.spawn(function()
        while player.Parent and task.wait(1) do
            playerStoredStream.PlaytimeSeconds += 1
            globalGameDataStream.GlobalPlaytime += 1
        end
    end)
end


-- Client

local DataStreamClient = require(ReplicatedStorage.DataStream).Client

DataStreamClient.Stored.PlaytimeSeconds:Changed(function(seconds : number)
    print("Current player seconds:", seconds)
end)

```

### 2. Adding and removing players to an array

```lua
-- Server
local Players = game:GetService("Players")
local DataStream = require(ReplicatedStorage.DataStream).Server

local globalGameDataStream = DataStream.GameData

function AddPlayerToGame(player)
    globalGameDataStream.PlayersInGame:Insert(player)
end

function RemovePlayerFromGame(player)
    local index = table.find(globalGameDataStream.PlayersInGame:Read(), player)
    if index then
        globalGameDataStream.PlayersInGame:Remove(index)
    end
end


-- Client

local DataStreamClient = require(ReplicatedStorage.DataStream).Client

local LocalPlayer = game.Players.LocalPlayer
local PlayerInGameStream = DataStreamClient.GameData.PlayersInGame

function isLocalPlayerInGame() : boolean
    return table.find(PlayerInGameStream:Read(), LocalPlayer) ~= nil
end
```

## Installation

DataStream is available on the Forest Package Manager:
**https://forest.dev/p/roblox/stratiz/datastream**