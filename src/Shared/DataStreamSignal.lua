--[[
    DataStreamSignal.lua
    Stratiz
    Created on 06/28/2023 @ 01:30
    
    Description:
        No description provided.
    
--]]

--= Root =--

local DataStreamSignal = { }

--= Types =--

export type Signal = {
	Connect: (self : Signal, toExecute : (...any) -> ()) -> RBXScriptConnection,
    Once: (self : Signal, toExecute : (...any) -> ()) -> RBXScriptConnection,
	Fire: (self : Signal, ...any) -> (),
	Wait: (self : Signal) -> ...any,
    Destroy: (self : Signal) -> ()
}

--= API Functions =--

function DataStreamSignal:Connect(toExecute : (...any) -> ()) : RBXScriptConnection
    return self._bindable.Event:Connect(toExecute)
end

function DataStreamSignal:Once(toExecute : (...any) -> ()) : RBXScriptConnection
    return self._bindable.Event:Once(toExecute)
end

function DataStreamSignal:Wait() : any
    return self._bindable.Event:Wait()
end

function DataStreamSignal:Fire(... : any)
    self._bindable:Fire(...)
end

function DataStreamSignal:Destroy()
    self._bindable:Destroy()
end

--= Initializers =--

DataStreamSignal.__index = DataStreamSignal

function DataStreamSignal.new() : Signal
    local self = setmetatable({}, DataStreamSignal)

    self._bindable = Instance.new("BindableEvent")
    
    return self
end

--= Return Module =--
return DataStreamSignal