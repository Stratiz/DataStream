local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStreamUtils = {}

local DATASTORE_BUFFER_SIZE = 5
local CONFIG = require(script.Parent:WaitForChild("DataStreamConfig"))

function DataStreamUtils.ResolveIndex(Index)
	local TargetIndex = nil
	local UserId = nil
	if typeof(Index) == "Instance" then
		TargetIndex = CONFIG.DATASTORE_ENTRY_PREFIX..Index.UserId
		UserId = Index.UserId
	elseif tonumber(Index) then
		TargetIndex = CONFIG.DATASTORE_ENTRY_PREFIX..Index
		UserId = Index
	end
	return TargetIndex, UserId
end

function DataStreamUtils:DeepCopy(target, _context)
	_context = _context or  {}
	if _context[target] then
		return _context[target]
	end

	if type(target) == "table" then
		local new = {}
		_context[target] = new
		for index, value in pairs(target) do
			new[self:DeepCopy(index, _context)] = self:DeepCopy(value, _context)
		end
		return setmetatable(new, self:DeepCopy(getmetatable(target), _context))
	else
		return target
	end
end

function DataStreamUtils:WaitForNext(requestType : Enum)
	while not DataStoreService:GetRequestBudgetForRequestType(requestType) >= DATASTORE_BUFFER_SIZE do
		task.wait()
	end
end

function DataStreamUtils:InvokeOnNext(requestType : Enum, callback : () -> ())
	task.spawn(function()
		self:WaitForNext(requestType)
		callback()
	end)
end

return DataStreamUtils