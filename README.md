# Stream

DataStream is a intuitive ReplicaService alternative. All schemas are replicated in real time between the client and server with no need to call obnoxious methods.

## `DataStreamObject`

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

