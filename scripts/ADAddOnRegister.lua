-- ADAddOn (PropaineX)
-- Registers the adAddOn specialization (the ON/OFF state per vehicle) and adds it to every drivable vehicle type.

local modName = g_currentModName
local modDirectory = g_currentModDirectory

local SPEC_NAME = modName .. ".adAddOn"

if g_specializationManager:getSpecializationByName("adAddOn") == nil then
    g_specializationManager:addSpecialization("adAddOn", "ADAddOnSpec", Utils.getFilename("scripts/ADAddOnSpec.lua", modDirectory), nil)
end

local function addADAddOnToVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local count = 0
    for typeName, typeEntry in pairs(typeManager.types) do
        local specs = typeEntry.specializations
        -- horses are drivable too, AutoDrive leaves them out as well
        local isHorse = Rideable ~= nil and SpecializationUtil.hasSpecialization(Rideable, specs)
        if SpecializationUtil.hasSpecialization(Drivable, specs) and not isHorse and typeEntry.specializationsByName[SPEC_NAME] == nil then
            typeManager:addSpecialization(typeName, SPEC_NAME)
            count = count + 1
        end
    end

    Logging.info("[ADAddOn] Added to %d vehicle types", count)
end

TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, addADAddOnToVehicleTypes)
