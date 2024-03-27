# DataStream

DataStream is a intuitive ReplicaService alternative. All schemas are replicated in real time (no loops!) between the client and server with no need to call obnoxious methods.

DataStreams can be used for anything from PlayerData to NPC data replication. As long as its an instance that exists on the client and server, it can be replicated!

Recommended for use with projects that use external editors such as VSCode

## Table of Contents
- [DataStream](#datastream)
  - [Table of Contents](#table-of-contents)
  - [Schemas](#schemas)
    - [Global:](#global)
    - [Player:](#player)
  - [Methods `DataStreamObject`](#methods-datastreamobject)
    - [**:Read()**](#read)
    - [**:Write()**](#write)
    - [**:Changed((newValue : any) -\> ())**](#changednewvalue--any---)
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

### **:Changed((newValue : any) -> ())**
Fires a callback function when the referenced value is changed

```lua
DataStream.SchemaName.ValueName:Changed(function(newValue)
    print("Value changed to", newValue)
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
local DataStream = require(DataStreamModule)

local globalGameDataStream = DataStream.GameData

local function SetupPlayer(player : Player)
    local playerStoredStream = DataStream.Stored[olayer]

    task.spawn(function()
        while player.Parent and task.wait(1) do
            playerStoredStream.PlaytimeSeconds += 1
            globalGameDataStream.GlobalPlaytime += 1
        end
    end)
end


-- Client

local DataStreamClient = require(DataStreamClientModule)

DataStreamClient.Stored.PlaytimeSeconds:Changed(function(seconds : number)
    print("Current player seconds:", seconds)
end)

```

### 2. Adding and removing players to an array

```lua
-- Server
local Players = game:GetService("Players")
local DataStream = require(DataStreamModule)

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

local DataStreamClient = require(DataStreamClientModule)

local LocalPlayer = game.Players.LocalPlayer
local PlayerInGameStream = DataStreamClient.GameData.PlayersInGame

function isLocalPlayerInGame() : boolean
    return table.find(PlayerInGameStream:Read(), LocalPlayer) ~= nil
end
```

## Installation

There are three folders:

1. Move folders
   - `src/Server` content should go in `ServerScriptService`
   - `src/Client` content should go in `StarterPlayerScripts`
   - `src/Shared` content should go in `ReplicatedStorage`
  

2. Edit `ServerDataStreamConfig.lua` and change `SHARED_MODULES_LOCATION` to the location of `DataStreamShared` folder.
3. Edit `ClientDataStreamConfig.lua` and change `SHARED_MODULES_LOCATION` to the location of `DataStreamShared` folder.
4. Done! the only two modules you should ever need to access are `DataStream` on the server and `ClientDataStream` on the client.