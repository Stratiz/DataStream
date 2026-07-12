--[[
    DataStream.luau
    Authors: Stratiz
    
    Description:
        Primary entry point for DataStream installed by packages

        ex:

        local DataStream = require(packages.DataStream).Server
        local DataStreamClient = require(packages.DataStream).Client
    
--]]

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

return setmetatable({
    Server = if IS_SERVER then require(script.Server) else nil,
    Client = if not IS_SERVER then require(script.Client) else nil
}, {
    __index = function(_, key)
        if key == "Server" or key == "Client" then
            error(`Attempt to access DataStream.{key} while in a {if IS_SERVER then "server" else "client"} context.`, 2)
        end

        return nil
    end
})