--[[
    TableReplicatorSignal.lua
    Stratiz
    Created on 06/28/2023 @ 01:30
    
    Description:
        No description provided.
    
--]]

--= Root =--

local TableReplicatorSignal = { }

--= Types =--

export type Signal = {
	Connect: (self : Signal, toExecute : (...any) -> ()) -> RBXScriptConnection,
    Once: (self : Signal, toExecute : (...any) -> ()) -> RBXScriptConnection,
	Fire: (self : Signal, ...any) -> (),
	Wait: (self : Signal) -> ...any,
    Destroy: (self : Signal) -> ()
}

--= API Functions =--

function TableReplicatorSignal:Connect(toExecute : (...any) -> ()) : RBXScriptConnection
    return self._bindable.Event:Connect(toExecute)
end

function TableReplicatorSignal:Once(toExecute : (...any) -> ()) : RBXScriptConnection
    return self._bindable.Event:Once(toExecute)
end

function TableReplicatorSignal:Wait() : any
    return self._bindable.Event:Wait()
end

function TableReplicatorSignal:Fire(... : any)
    self._bindable:Fire(...)
end

function TableReplicatorSignal:Destroy()
    self._bindable:Destroy()
end

--= Initializers =--

TableReplicatorSignal.__index = TableReplicatorSignal

function TableReplicatorSignal.new() : Signal
    local self = setmetatable({}, TableReplicatorSignal)

    self._bindable = Instance.new("BindableEvent")
    
    return self
end

--= Return Module =--
return TableReplicatorSignal