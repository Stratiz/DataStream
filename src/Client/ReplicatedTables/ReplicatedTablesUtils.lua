local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicatedTablesUtils = {}

function ReplicatedTablesUtils.MakeRemote(remoteType : "Function" | "Event", name : string)
	local RemoteFolder = ReplicatedStorage:FindFirstChild("_TABLE_REPLICATION_REMOTES")
	if not RemoteFolder then
		RemoteFolder = Instance.new("Folder")
		RemoteFolder.Name = "_TABLE_REPLICATION_REMOTES"
		RemoteFolder.Parent = ReplicatedStorage
	end

	local NewRemote = Instance.new("Remote"..remoteType)
	NewRemote.Name = name
	NewRemote.Parent = RemoteFolder

	return NewRemote
end

function ReplicatedTablesUtils.CopyTable(target)
	local new = {}
	for key, value in pairs(target) do
		new[key] = value
	end
	return new
end

function ReplicatedTablesUtils:DeepCopyTable(target, _context)
    _context = _context or  {}
    if _context[target] then
        return _context[target]
    end

    if type(target) == "table" then
        local new = {}
        _context[target] = new
        for index, value in pairs(target) do
            new[self:DeepCopyTable(index, _context)] = self:DeepCopyTable(value, _context)
        end
        return setmetatable(new, self:DeepCopyTable(getmetatable(target), _context))
    else
        return target
    end
end

function ReplicatedTablesUtils.MakeSignal()
    local bindableEvent = Instance.new("BindableEvent")
	local newSignal = {}
	function newSignal:Connect(toExecute : (any) -> ()) : RBXScriptConnection
		return bindableEvent.Event:Connect(toExecute)
	end

	function newSignal:Once(toExecute : (any) -> ()) : RBXScriptConnection
		return bindableEvent.Event:Once(toExecute)
	end

	function newSignal:Fire(... : any)
		bindableEvent:Fire(...)
	end

	function newSignal:Wait() : any
		return bindableEvent.Event:Wait()
	end

	return newSignal
end

return ReplicatedTablesUtils