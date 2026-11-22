-- ADAddOn (PropaineX)
-- Per vehicle ON/OFF state of the ADAddOn button and the selected mode: saved with the vehicle and synced to every player.
-- The work itself (fill robot, milk transport, bale collection) is done on the server by ADAddOn.lua.

ADAddOnSpec = {}
ADAddOnSpec.MOD_NAME = g_currentModName
ADAddOnSpec.SPEC_NAME = g_currentModName .. ".adAddOn"
ADAddOnSpec.SPEC_TABLE_NAME = "spec_" .. ADAddOnSpec.SPEC_NAME

-- the modes of the menu on the bar
ADAddOnSpec.MODE_FILL_ROBOT = 1
ADAddOnSpec.MODE_MILK = 2
ADAddOnSpec.MODE_BALES = 3
ADAddOnSpec.MODE_TOP_OFF = 4
-- Fill Robot - In Stock Only (how it works: still to be decided by the user)
ADAddOnSpec.MODE_FILL_ROBOT_STOCK = 5
-- Repair/Refill (how it works: still to be decided by the user)
ADAddOnSpec.MODE_REPAIR_REFILL = 6
ADAddOnSpec.NUM_MODES = 6
ADAddOnSpec.MODE_BITS = 3

-- the two Fill Robot modes: Fill Robot $$$ (buys what's missing, no money limit) and In Stock Only (never buys)
function ADAddOnSpec.isFillRobotMode(mode)
    return mode == ADAddOnSpec.MODE_FILL_ROBOT or mode == ADAddOnSpec.MODE_FILL_ROBOT_STOCK
end

function ADAddOnSpec.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Drivable, specializations)
end

function ADAddOnSpec.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    schemaSavegame:register(XMLValueType.BOOL, "vehicles.vehicle(?)." .. ADAddOnSpec.SPEC_NAME .. "#isOn", "ADAddOn is switched on", false)
    schemaSavegame:register(XMLValueType.INT,
        "vehicles.vehicle(?)." .. ADAddOnSpec.SPEC_NAME .. "#mode",
        "ADAddOn mode (1 fill robot $$$, 2 milk transport, 3 bale collection, 4 top it off, 5 fill robot in stock only, 6 repair/refill)",
        1)
end

function ADAddOnSpec.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "setADAddOn", ADAddOnSpec.setADAddOn)
    SpecializationUtil.registerFunction(vehicleType, "getIsADAddOnOn", ADAddOnSpec.getIsADAddOnOn)
    SpecializationUtil.registerFunction(vehicleType, "setADAddOnMode", ADAddOnSpec.setADAddOnMode)
    SpecializationUtil.registerFunction(vehicleType, "getADAddOnMode", ADAddOnSpec.getADAddOnMode)
end

function ADAddOnSpec.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ADAddOnSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", ADAddOnSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", ADAddOnSpec)
end

local function validMode(mode)
    if type(mode) ~= "number" or mode < 1 or mode > ADAddOnSpec.NUM_MODES then
        return ADAddOnSpec.MODE_FILL_ROBOT
    end
    return mode
end

function ADAddOnSpec:onLoad(savegame)
    local spec = self[ADAddOnSpec.SPEC_TABLE_NAME]

    spec.isOn = false
    spec.mode = ADAddOnSpec.MODE_FILL_ROBOT
    -- server only: what the current run is doing (see ADAddOn.lua)
    spec.job = nil

    if savegame ~= nil and not savegame.resetVehicles then
        spec.isOn = savegame.xmlFile:getValue(savegame.key .. "." .. ADAddOnSpec.SPEC_NAME .. "#isOn", false)
        spec.mode = validMode(savegame.xmlFile:getValue(savegame.key .. "." .. ADAddOnSpec.SPEC_NAME .. "#mode", ADAddOnSpec.MODE_FILL_ROBOT))
    end
end

function ADAddOnSpec:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[ADAddOnSpec.SPEC_TABLE_NAME]
    xmlFile:setValue(key .. "#isOn", spec.isOn)
    xmlFile:setValue(key .. "#mode", spec.mode)
end

function ADAddOnSpec:onReadStream(streamId, connection)
    local spec = self[ADAddOnSpec.SPEC_TABLE_NAME]
    spec.isOn = streamReadBool(streamId)
    spec.mode = validMode(streamReadUIntN(streamId, ADAddOnSpec.MODE_BITS))
end

function ADAddOnSpec:onWriteStream(streamId, connection)
    local spec = self[ADAddOnSpec.SPEC_TABLE_NAME]
    streamWriteBool(streamId, spec.isOn)
    streamWriteUIntN(streamId, spec.mode, ADAddOnSpec.MODE_BITS)
end

function ADAddOnSpec:getIsADAddOnOn()
    return self[ADAddOnSpec.SPEC_TABLE_NAME].isOn
end

function ADAddOnSpec:getADAddOnMode()
    return self[ADAddOnSpec.SPEC_TABLE_NAME].mode
end

-- button and mode together, so one event carries both
local function setState(vehicle, isOn, mode, noEventSend)
    local spec = vehicle[ADAddOnSpec.SPEC_TABLE_NAME]
    mode = validMode(mode)
    if isOn == spec.isOn and mode == spec.mode then
        return
    end
    local switched = isOn ~= spec.isOn
    local modeChanged = mode ~= spec.mode

    spec.isOn = isOn
    spec.mode = mode
    ADAddOnEvent.sendEvent(vehicle, isOn, mode, noEventSend)

    -- set by ADAddOn.lua once AutoDrive is found
    if vehicle.isServer then
        if switched and ADAddOnSpec.onSwitchedCallback ~= nil then
            ADAddOnSpec.onSwitchedCallback(vehicle, isOn)
        elseif modeChanged and ADAddOnSpec.onModeChangedCallback ~= nil then
            ADAddOnSpec.onModeChangedCallback(vehicle, mode)
        end
    end
end

function ADAddOnSpec:setADAddOn(isOn, noEventSend)
    setState(self, isOn, self[ADAddOnSpec.SPEC_TABLE_NAME].mode, noEventSend)
end

function ADAddOnSpec:setADAddOnMode(mode, noEventSend)
    setState(self, self[ADAddOnSpec.SPEC_TABLE_NAME].isOn, mode, noEventSend)
end

ADAddOnSpec.setState = setState


-- Syncs the button and the mode between server and clients.
ADAddOnEvent = {}
local ADAddOnEvent_mt = Class(ADAddOnEvent, Event)
InitEventClass(ADAddOnEvent, "ADAddOnEvent")

function ADAddOnEvent.emptyNew()
    return Event.new(ADAddOnEvent_mt)
end

function ADAddOnEvent.new(vehicle, isOn, mode)
    local self = ADAddOnEvent.emptyNew()
    self.vehicle = vehicle
    self.isOn = isOn
    self.mode = mode
    return self
end

function ADAddOnEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.isOn = streamReadBool(streamId)
    self.mode = streamReadUIntN(streamId, ADAddOnSpec.MODE_BITS)
    self:run(connection)
end

function ADAddOnEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.isOn)
    streamWriteUIntN(streamId, self.mode, ADAddOnSpec.MODE_BITS)
end

function ADAddOnEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end

    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() and self.vehicle[ADAddOnSpec.SPEC_TABLE_NAME] ~= nil then
        ADAddOnSpec.setState(self.vehicle, self.isOn, self.mode, true)
    end
end

function ADAddOnEvent.sendEvent(vehicle, isOn, mode, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(ADAddOnEvent.new(vehicle, isOn, mode), nil, nil, vehicle)
        else
            g_client:getServerConnection():sendEvent(ADAddOnEvent.new(vehicle, isOn, mode))
        end
    end
end
