local ReplicatorRemotes = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_FOLDER_NAME = "_TABLE_REPLICATION_REMOTES"

local IsServer = RunService:IsServer()

local RemoteFolder = IsServer == false and ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME) or nil
local RemoteCache = {
    Function = {},
    Event = {}
}

function ReplicatorRemotes:Get(remoteType : "Function" | "Event", name : string)
    local internalName = remoteType .. name
    if RemoteCache[remoteType][name] then
        return RemoteCache[remoteType][name]
    end

    if IsServer then
        if not RemoteFolder then
            RemoteFolder = Instance.new("Folder")
            RemoteFolder.Name = REMOTE_FOLDER_NAME
            RemoteFolder.Parent = ReplicatedStorage
        end

        local NewRemote = Instance.new("Remote"..remoteType)
        NewRemote.Name = internalName
        NewRemote.Parent = RemoteFolder

        RemoteCache[remoteType][name] = NewRemote

        return NewRemote
    else
        local foundRemote = RemoteFolder:WaitForChild(internalName)

        RemoteCache[remoteType][name] = foundRemote

        return foundRemote
    end
end

return ReplicatorRemotes