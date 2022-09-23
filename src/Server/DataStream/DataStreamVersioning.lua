--[[
    DataVersioning.lua
    Stratiz
    Created/Documented on 05/24/2022 @ 13:13:48
    
    Description:
        Handles the versioning of player data
    
    Documentation:
        To make a new version, add to the .Versions table and set it as your updater function.
        
        :UpdateVersion(Data) 
        -> Updates provided player data to new verion. (Used only by PlayerDataModule)
--]]

local DataVersioning = {}

DataVersioning.Versions = {}

DataVersioning.Versions[1] = function(Data)
    Data._VERSION = 1
    Data.Currency.PetTokens = Data.Rebirths
    Data.Pets =  {
        Owned = {},
        Equipped = {}
    }
    Data.ClaimedCodes = {}
    print("Updated to version 1")
end


function DataVersioning:UpdateVersion(Data)
    local CurrentVersion = Data._VERSION or 0
    for Index, VersionFunction in pairs(self.Versions) do
        if CurrentVersion < Index then
            VersionFunction(Data)
            Data._VERSION = Index
            print("Data updated!")
        end
    end
end

return DataVersioning